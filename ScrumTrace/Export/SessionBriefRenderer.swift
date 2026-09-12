import Foundation

enum BriefTemplateLoader {
    static func text(_ name: String, ext: String) -> String {
        let subdirs = ["Resources", "Export/Resources", "Export"]
        for folder in subdirs {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder),
               let text = readableResourceText(url) {
                return text
            }
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let text = readableResourceText(url) {
            return text
        }
        if let root = Bundle.main.resourceURL {
            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return ""
            }
            if let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            ) {
                for case let url as URL in enumerator {
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                        enumerator.skipDescendants()
                        continue
                    }
                    if url.deletingPathExtension().lastPathComponent == name, url.pathExtension == ext,
                       let text = readableResourceText(url) {
                        return text
                    }
                }
            }
        }
        return ""
    }

    /// Bundle lookups follow a planted resource symlink; refuse those URLs.
    private static func readableResourceText(_ url: URL) -> String? {
        ExportRel.unfollowedUTF8Text(url)
    }
}

enum HTMLEscaper {
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// `href` only. Product repo is user-typed; `javascript:` / `data:` must not run.
    static func httpHref(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "#"
        }
        return escape(trimmed)
    }
}

struct SessionBriefRenderer {
    func render(manifest: SessionManifest, excerpts: [String: String], sessionURL: URL) -> String {
        var shell = BriefTemplateLoader.text("brief.shell", ext: "html")
        if shell.isEmpty {
            shell = Self.fallbackShell
        }
        var css = BriefTemplateLoader.text("brief", ext: "css")
        var js = BriefTemplateLoader.text("brief", ext: "js")
        if css.isEmpty {
            css = Self.fallbackCSS
        }
        if js.isEmpty {
            js = Self.fallbackJS
        }
        js += Self.speakerJS
        css += Self.speakerCSS + BriefPresentation.css
        let transcript = SpeakerTimeline.load(sessionURL: sessionURL)
        let presentation = BriefPresentation(manifest: manifest, transcript: transcript, sessionURL: sessionURL)
        let confirmed = manifest.tasks.filter { $0.status == .confirmed }
        let review = manifest.tasks.filter { $0.status == .needsReview }
        let replacements: [String: String] = [
            "{{CSS}}": css,
            "{{JS}}": js,
            "{{TITLE}}": HTMLEscaper.escape(manifest.productContext.appName.isEmpty ? "ScrumTrace session" : manifest.productContext.appName),
            "{{SESSION_ID}}": HTMLEscaper.escape(manifest.sessionId),
            "{{CREATED_AT}}": ISO8601DateFormatter().string(from: manifest.createdAt),
            "{{MEDIA_DURATION}}": Self.clock(manifest.duration.mediaSeconds),
            "{{WALL_DURATION}}": Self.clock(manifest.duration.wallSeconds),
            "{{PAUSE_COUNT}}": manifest.pauses.count == 1 ? "1 pause" : "\(manifest.pauses.count) pauses",
            "{{CONTEXT_BADGE}}": manifest.productContext.contextName.map { "<span>Context: \(HTMLEscaper.escape($0))</span>" } ?? "",
            "{{PRODUCT_NAME}}": HTMLEscaper.escape(manifest.productContext.appName),
            "{{REPO_URL}}": HTMLEscaper.escape(manifest.productContext.repoURL),
            "{{REPO_HREF}}": HTMLEscaper.httpHref(manifest.productContext.repoURL),
            "{{TECH_STACK}}": HTMLEscaper.escape(manifest.productContext.techStack),
            "{{STATUS_HTML}}": presentation.statusHTML,
            "{{SUMMARY_HTML}}": presentation.summaryHTML,
            "{{SPEAKERS_HTML}}": presentation.speakersHTML,
            "{{DOWNLOADS_HTML}}": presentation.downloadsHTML,
            "{{REVIEW_OPEN}}": confirmed.isEmpty ? "open" : "",
            "{{TASKS_HTML}}": confirmed.isEmpty ? "<p class=\"muted\">No confirmed findings. Review the captured evidence below.</p>" : confirmed.map { task in taskCard(task, excerpts: excerpts, sessionURL: sessionURL, omitted: manifest.omitted, slice: manifest.slices.first { $0.sliceId == task.sourceSliceId }, transcript: transcript) }.joined(),
            "{{NEEDS_REVIEW_HTML}}": review.isEmpty ? "<p class=\"muted\">No items need review.</p>" : review.map { task in taskCard(task, excerpts: excerpts, sessionURL: sessionURL, omitted: manifest.omitted, slice: manifest.slices.first { $0.sliceId == task.sourceSliceId }, transcript: transcript) }.joined(),
            "{{TIMELINE_HTML}}": timeline(manifest),
            "{{SHOTS_HTML}}": shots(manifest, sessionURL: sessionURL),
            "{{TRANSCRIPT_HTML}}": transcriptHTML(manifest: manifest, excerpts: excerpts, sessionURL: sessionURL, transcript: transcript) + fullTranscriptHTML(manifest: manifest, sessionURL: sessionURL),
            "{{CONFIRMED_COUNT}}": "\(confirmed.count)",
            "{{REVIEW_COUNT}}": "\(review.count)",
            "{{OMITTED_HTML}}": omittedHTML(manifest)
        ]
        return Self.applyReplacements(shell, replacements)
    }

    /// Fill shell tokens only. Do not rescan substituted task/transcript text
    /// or a model string containing `{{OMITTED_HTML}}` would inject pack HTML.
    static func applyReplacements(_ shell: String, _ replacements: [String: String]) -> String {
        var output = ""
        var index = shell.startIndex
        while index < shell.endIndex {
            if shell[index] == "{",
               shell.distance(from: index, to: shell.endIndex) >= 2 {
                let second = shell.index(after: index)
                if shell[second] == "{",
                   let close = shell[shell.index(after: second)...].range(of: "}}") {
                    let token = String(shell[index..<close.upperBound])
                    if let value = replacements[token] {
                        output.append(value)
                        index = close.upperBound
                        continue
                    }
                }
            }
            output.append(shell[index])
            index = shell.index(after: index)
        }
        return output
    }

    private func taskCard(_ task: TaskRecord, excerpts: [String: String], sessionURL: URL, omitted: [OmittedAsset], slice: SliceRecord?, transcript: FullTranscript?) -> String {
        let turns = transcript.flatMap { value in slice.map { SpeakerTimeline.turns(in: value, start: $0.startMedia, end: $0.endMedia) } } ?? []
        let sanitized = PromptTemplates.sanitizeUntrusted(task.agentInstructions)
        let instructions = slice?.analysisStatus == .skipped
            ? sanitized.replacingOccurrences(of: "[Requires Manual Review - API Offline]", with: "[Requires Manual Review]")
            : sanitized
        let confidenceLabel = slice?.analysisStatus == .success
            ? String(format: "%.2f", task.confidence) : "Not evaluated"
        let observed = task.observed.isEmpty ? "No visual observation recorded." : task.observed
        let stated = task.stated.isEmpty ? "No participant statement linked." : task.stated
        let inferred = task.inferred.isEmpty ? "No inference recorded." : task.inferred
        let playbackHint = turns.isEmpty ? "No transcript is available for this clip. You can still play the recording." : "Select a transcript passage to play it."
        let media = task.evidenceMedia.compactMap { path -> String? in
            guard let rel = ExportRel.packMediaHandoff(path, sessionURL: sessionURL, omitted: omitted) else { return nil }
            if rel.hasSuffix(".mp4") {
                return """
                <div class="speaker-player"><video class="clip" controls tabindex="0" preload="metadata" aria-label="Evidence video for \(HTMLEscaper.escape(task.taskId))" src="\(HTMLEscaper.escape(rel))"></video><p class="now-speaking" aria-live="polite">\(playbackHint)</p></div>
                """
            }
            return """
            <a class="still" href="\(HTMLEscaper.escape(rel))" data-lightbox>
              <img src="\(HTMLEscaper.escape(rel))" alt="\(HTMLEscaper.escape(task.title))">
            </a>
            """
        }.joined()
        let quotes = task.quotes.map { quote in
            let when = "t_media \(Self.clock(quote.tMediaStart))–\(Self.clock(quote.tMediaEnd))"
            return "<blockquote><span class=\"spk\">\(HTMLEscaper.escape(quote.speaker))</span><span class=\"when\">\(HTMLEscaper.escape(when))</span>\(HTMLEscaper.escape(quote.text))</blockquote>"
        }.joined()
        let excerpt: String
        if let text = excerpts[task.taskId], !text.isEmpty {
            excerpt = "<p class=\"excerpt\">\(HTMLEscaper.escape(text))</p>"
        } else {
            excerpt = ""
        }
        return """
        <article class="take" id="\(HTMLEscaper.escape(task.taskId))" data-status="\(task.status.rawValue)">
          <header>
            <span class="slate">\(HTMLEscaper.escape(task.taskId))</span>
            <span class="kind">\(HTMLEscaper.escape(task.kind.rawValue.replacingOccurrences(of: "_", with: " ")))</span>
            <span class="conf">\(HTMLEscaper.escape(confidenceLabel))</span>
            <h3>\(HTMLEscaper.escape(task.title))</h3>
          </header>
          <dl class="epistemic">
            <div><dt>Observed</dt><dd>\(HTMLEscaper.escape(observed))</dd></div>
            <div><dt>Stated</dt><dd>\(HTMLEscaper.escape(stated))</dd></div>
            <div><dt>Inferred</dt><dd>\(HTMLEscaper.escape(inferred))</dd></div>
          </dl>
          <p class="agent">\(HTMLEscaper.escape(instructions))</p>
          \(quotes)
          \(excerpt)
          <div class="evidence">\(media)</div>
          <details class="clip-transcript" id="transcript-\(HTMLEscaper.escape(task.taskId))" open>
            <summary>Transcript for this clip</summary>
            \(transcriptRows(task: task, slice: slice, transcript: transcript, sessionURL: sessionURL, omitted: omitted))
          </details>
        </article>
        """
    }

    private func transcriptHTML(manifest: SessionManifest, excerpts: [String: String], sessionURL: URL, transcript: FullTranscript?) -> String {
        let available = manifest.tasks.filter { task in
            guard task.status != .dropped, let transcript,
                  let slice = manifest.slices.first(where: { $0.sliceId == task.sourceSliceId }) else { return false }
            return !SpeakerTimeline.turns(in: transcript, start: slice.startMedia, end: slice.endMedia).isEmpty
        }
        guard !available.isEmpty else {
            return "<p class=\"muted\">No transcript excerpts are available in this pack. Use Retry Analysis in ScrumTrace if speech was recorded.</p>"
        }
        return "<p>Read the timed passages beside each clip:</p><ul class=\"brief-list\">" + available.map {
            "<li><a href=\"#transcript-\(HTMLEscaper.escape($0.taskId))\">\(HTMLEscaper.escape($0.taskId)) · \(HTMLEscaper.escape($0.title))</a></li>"
        }.joined() + "</ul>"
    }

    private func fullTranscriptHTML(manifest: SessionManifest, sessionURL: URL) -> String {
        // Render only the consented, projected file; a private archive transcript
        // must never leak into HTML when the JSON was omitted by the pack budget.
        guard manifest.includeFullTranscriptInZip,
              !manifest.omitted.contains(where: { ExportRel.toExportRoot($0.path) == "full_transcript.json" }),
              let data = ExportRel.readContainedData(relative: "export/full_transcript.json", sessionURL: sessionURL),
              let full = try? JSONDecoder().decode(FullTranscript.self, from: data), full.hasUsableText else { return "" }
        let rows = full.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { turn in
            let label = SpeakerTimeline.displaySpeaker(turn, in: full)
            let content = "<span class=\"turn-meta\">\(Self.clock(turn.start))–\(Self.clock(turn.end)) · \(HTMLEscaper.escape(label))</span><span>\(HTMLEscaper.escape(turn.text))</span>"
            for task in manifest.tasks where task.status != .dropped {
                guard let slice = manifest.slices.first(where: { $0.sliceId == task.sourceSliceId }),
                      turn.start >= slice.startMedia, turn.end <= slice.endMedia,
                      let clip = task.evidenceMedia.compactMap({ ExportRel.packMediaHandoff($0, sessionURL: sessionURL, omitted: manifest.omitted) }).first(where: { $0.hasSuffix(".mp4") }) else { continue }
                let start = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), turn.start - slice.startMedia)
                let end = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), turn.end - slice.startMedia)
                return "<button class=\"transcript-turn\" data-clip=\"\(HTMLEscaper.escape(clip))\" data-start=\"\(start)\" data-end=\"\(end)\" data-speaker=\"\(HTMLEscaper.escape(label))\">\(content)</button>"
            }
            return "<p class=\"transcript-turn\">\(content)<span class=\"muted\">Outside selected video clips</span></p>"
        }.joined()
        return "<details class=\"clip-transcript\"><summary>Full transcript · included in this export</summary><p class=\"muted\">Only passages within selected clips can play video here.</p>\(rows)</details>"
    }

    private func transcriptRows(task: TaskRecord, slice: SliceRecord?, transcript: FullTranscript?, sessionURL: URL, omitted: [OmittedAsset]) -> String {
        guard let transcript, let slice else {
            return "<p class=\"muted\">No transcript is available for this clip.</p>"
        }
        let turns = SpeakerTimeline.turns(in: transcript, start: slice.startMedia, end: slice.endMedia)
        guard !turns.isEmpty else {
            return "<p class=\"muted\">No transcript passages within this clip. The recording is still available above.</p>"
        }
        let clip = task.evidenceMedia.compactMap { ExportRel.packMediaHandoff($0, sessionURL: sessionURL, omitted: omitted) }.first { $0.hasSuffix(".mp4") }
        let rows = turns.map { turn -> String in
            let label = SpeakerTimeline.displaySpeaker(turn, in: transcript)
            let content = "<span class=\"turn-meta\">t_media \(Self.clock(turn.start))–\(Self.clock(turn.end)) · \(HTMLEscaper.escape(label))</span><span>\(HTMLEscaper.escape(turn.text))</span>"
            if let clip {
                let start = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, turn.start - slice.startMedia))
                let end = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, turn.end - slice.startMedia))
                return "<button class=\"transcript-turn\" data-clip=\"\(HTMLEscaper.escape(clip))\" data-start=\"\(start)\" data-end=\"\(end)\" data-speaker=\"\(HTMLEscaper.escape(label))\">\(content)</button>"
            }
            return "<p class=\"transcript-turn\">\(content)</p>"
        }.joined()
        return "<p class=\"muted\">Selected clip only · speaker labels are estimates unless reviewed.</p>\(rows)"
    }

    private func timeline(_ manifest: SessionManifest) -> String {
        let duration = max(manifest.duration.mediaSeconds, 1)
        let pauses = manifest.pauses.map { pause -> String in
            let start = TimelineMath.mediaTime(wall: pause.pauseWall, pauses: manifest.pauses)
            let width = max(0.4, (pause.duration / duration) * 100)
            let left = (start / duration) * 100
            return "<i class=\"pause\" style=\"left:\(left)%;width:\(width)%\" title=\"pause \(Int(pause.duration))s\"></i>"
        }.joined()
        let marks = manifest.shots.map { shot -> String in
            let left = (shot.tMedia / duration) * 100
            return "<b class=\"shot\" style=\"left:\(left)%\" title=\"\(HTMLEscaper.escape(shot.id))\"></b>"
        }.joined()
        let windows = manifest.tasks.filter { $0.status != .dropped }.compactMap { task -> String? in
            guard let slice = manifest.slices.first(where: { $0.sliceId == task.sourceSliceId }) else { return nil }
            return "<a href=\"#\(HTMLEscaper.escape(task.taskId))\">\(Self.clock(slice.startMedia))–\(Self.clock(slice.endMedia)) · \(HTMLEscaper.escape(task.taskId))</a>"
        }.joined()
        return "<div class=\"ruler\" aria-hidden=\"true\">\(pauses)\(marks)</div><nav class=\"brief-nav\" aria-label=\"Selected evidence windows\">\(windows)</nav>"
    }

    private func shots(_ manifest: SessionManifest, sessionURL: URL) -> String {
        let figures = manifest.shots.compactMap { shot -> String? in
            var path: String?
            let candidates = EvidenceValidator.exportRelativeStillPaths(for: shot)
                + [shot.exportPath].compactMap { $0 }
                + shot.stillCandidates
            for candidate in candidates {
                if let rel = ExportRel.packMediaHandoff(candidate, sessionURL: sessionURL, omitted: manifest.omitted) {
                    path = rel
                    break
                }
            }
            guard let path else { return nil }
            return """
            <figure>
              <a href="\(HTMLEscaper.escape(path))" data-lightbox>
                <img src="\(HTMLEscaper.escape(path))" alt="\(HTMLEscaper.escape(shot.note))">
              </a>
              <figcaption>\(HTMLEscaper.escape(shot.id)) · \(Self.clock(shot.tMedia)) · \(HTMLEscaper.escape(shot.note))</figcaption>
            </figure>
            """
        }
        if figures.isEmpty {
            return "<p class=\"muted\">No shots in this pack.</p>"
        }
        return figures.joined()
    }

    private func omittedHTML(_ manifest: SessionManifest) -> String {
        if manifest.omitted.isEmpty { return "" }
        let items = manifest.omitted.map { item in
            "<li><code>\(HTMLEscaper.escape(ExportRel.omittedHandoffPath(item.path)))</code> — \(HTMLEscaper.escape(item.reason))</li>"
        }.joined()
        return """
        <section class="omitted">
          <h2>Omitted from this pack</h2>
          <p>These files stayed on this Mac so the zip could stay at or under 35 MB.</p>
          <ul>\(items)</ul>
        </section>
        """
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private static let speakerCSS = """
    .speaker-player{width:100%;min-width:0}.now-speaking{font-size:.85rem;color:var(--muted,#aaa);min-height:1.4em}
    .speaker-transcript{margin:1.5rem 0}.transcript-turn{display:flex;flex-direction:column;gap:.3rem;text-align:left;width:100%;padding:.75rem;margin:.4rem 0;border:1px solid #6665;border-radius:6px;background:transparent;color:inherit;font:inherit}
    button.transcript-turn{cursor:pointer}button.transcript-turn:hover,.transcript-turn[aria-current=true]{background:#688bd326;border-color:#769dde}.transcript-turn:focus-visible{outline:3px solid #769dde;outline-offset:2px}.turn-meta{font-size:.8rem;opacity:.8}
    """

    private static let speakerJS = #"""
    ;(() => {
      const turns = Array.from(document.querySelectorAll('button.transcript-turn[data-clip]'));
      const videos = Array.from(document.querySelectorAll('video.clip'));
      const revealTarget = () => {
        let id; try { id = decodeURIComponent(location.hash.slice(1)); } catch { return; }
        const target = document.getElementById(id);
        if (!target) return;
        let parent = target;
        while (parent) { if (parent.tagName === 'DETAILS') parent.open = true; parent = parent.parentElement; }
        target.scrollIntoView({block:'start'});
      };
      window.addEventListener('hashchange', revealTarget);
      if (location.hash) revealTarget();
      const related = video => turns.filter(turn => turn.getAttribute('data-clip') === video.getAttribute('src'));
      videos.forEach(video => {
        const rows = related(video);
        const status = video.parentElement.querySelector('.now-speaking');
        const update = () => {
          const labels = [];
          rows.forEach(row => {
            const active = video.currentTime >= Number(row.dataset.start) && video.currentTime < Number(row.dataset.end);
            if (active) { row.setAttribute('aria-current', 'true'); labels.push(row.dataset.speaker); }
            else row.removeAttribute('aria-current');
          });
          const label = rows.length === 0 ? 'No transcript is available for this clip.' : (Array.from(new Set(labels)).join(' / ') || 'No attributed speech at this time');
          if (status && status.textContent !== label) status.textContent = label;
        };
        video.addEventListener('timeupdate', update);
        video.addEventListener('seeked', update);
      });
      turns.forEach(turn => turn.addEventListener('click', () => {
        const nearby = turn.closest('.take')?.querySelector('video.clip');
        const video = nearby?.getAttribute('src') === turn.getAttribute('data-clip')
          ? nearby : videos.find(item => item.getAttribute('src') === turn.getAttribute('data-clip'));
        const start = Number(turn.dataset.start);
        if (!video || !Number.isFinite(start) || start < 0) return;
        videos.forEach(other => { if (other !== video) other.pause(); });
        video.currentTime = start;
        video.scrollIntoView({block:'center', behavior:'smooth'});
        video.focus({preventScroll:true});
        const playing = video.play();
        if (playing) playing.catch(() => {
          const status = video.parentElement.querySelector('.now-speaking');
          if (status) status.textContent = 'Press Play to hear this passage.';
        });
      }));
    })();
    """#

    /// Used when `brief.shell.html` is missing from the bundle. Must keep
    /// timeline, contact sheet, lightbox, and omitted-assets tokens.
    private static let fallbackShell = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>{{TITLE}} · ScrumTrace</title>
      <style>{{CSS}}</style>
    </head>
    <body>
      <div class="sprocket" aria-hidden="true"></div>
      <div class="shell">
        <header class="slate">
          <div>
            <div class="clapper">ScrumTrace · session slate</div>
            <h1>{{TITLE}}<br><em>{{SESSION_ID}}</em></h1>
          </div>
          <div class="meta">
            <span>t_media {{MEDIA_DURATION}}</span>
            <span>wall {{WALL_DURATION}}</span>
            <span>{{PAUSE_COUNT}}</span>
            <span>{{CONFIRMED_COUNT}} confirmed</span>
            <span>{{REVIEW_COUNT}} review</span>
          </div>
          <div class="meta">
            {{CONTEXT_BADGE}}
            <span>{{PRODUCT_NAME}}</span>
            <span>{{TECH_STACK}}</span>
            <a href="{{REPO_HREF}}">{{REPO_URL}}</a>
            <span>{{CREATED_AT}}</span>
          </div>
        </header>
        <nav class="brief-nav" aria-label="Brief sections">
          <a href="#summary">Summary</a><a href="#decisions">Decisions</a><a href="#actions">Actions</a>
          <a href="#questions">Questions</a><a href="#evidence">Evidence</a><a href="#transcript">Transcript</a><a href="#exports">Export</a>
        </nav>
        {{STATUS_HTML}}
        {{SUMMARY_HTML}}
        {{SPEAKERS_HTML}}
        {{TIMELINE_HTML}}
        <section id="evidence">
          <h2>Confirmed evidence</h2>
          {{TASKS_HTML}}
        </section>
        <section class="review">
          <details {{REVIEW_OPEN}}>
            <summary>Needs review</summary>
            {{NEEDS_REVIEW_HTML}}
          </details>
        </section>
        {{OMITTED_HTML}}
        <section>
          <h2>Contact sheet</h2>
          <div class="contact">{{SHOTS_HTML}}</div>
        </section>
        <section id="transcript" class="brief-panel">
          <h2>Transcript excerpts</h2>
          {{TRANSCRIPT_HTML}}
        </section>
        {{DOWNLOADS_HTML}}
      </div>
      <script>{{JS}}</script>
    </body>
    </html>
    """

    private static let fallbackCSS = """
    :root { --ink:#0c0b09; --panel:#16140f; --paper:#ede6d6; --amber:#f0a35e; --rec:#e23b2e; --line:rgba(237,230,214,.12); --muted:rgba(237,230,214,.62); }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: var(--ink); color: var(--paper); font-family: sans-serif; }
    .shell { padding: 28px 8vw 80px; }
    .slate { display: grid; gap: 12px; border-bottom: 1px solid var(--line); padding-bottom: 22px; margin-bottom: 28px; }
    .ruler { position: relative; height: 28px; margin: 18px 0 36px; background: rgba(237,230,214,.08); border-radius: 999px; overflow: hidden; }
    .ruler .pause { position: absolute; top: 0; bottom: 0; background: #3a2a18; }
    .ruler .shot { position: absolute; top: 4px; width: 8px; height: 8px; background: var(--rec); border-radius: 50%; transform: translateX(-50%); }
    .take { background: var(--panel); border: 1px solid var(--line); border-radius: 18px; padding: 22px; margin: 0 0 22px; }
    .excerpt { font-size: 13px; color: var(--muted); margin: 0 0 12px; }
    .epistemic { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
    .kind { font-size: 11px; letter-spacing: 0.12em; text-transform: uppercase; }
    .conf { font-family: ui-monospace, monospace; font-size: 11px; opacity: 0.7; }
    .clip { width: 100%; border-radius: 12px; background: #000; }
    .still img, figure img { width: 100%; border-radius: 12px; display: block; }
    .contact { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 14px; }
    .lightbox { position: fixed; inset: 0; background: rgba(6,5,4,.92); display: none; place-items: center; z-index: 20; padding: 24px; cursor: zoom-out; }
    .lightbox.open { display: grid; }
    .lightbox img { max-width: min(92vw, 1400px); max-height: 92vh; cursor: default; }
    .spk { display: block; font-size: 11px; color: #f0a35e; }
    .when { display: block; font-size: 10px; opacity: 0.6; margin-bottom: 6px; }
    @media (max-width: 860px) {
      .epistemic, .evidence { grid-template-columns: 1fr; }
      .slate { grid-template-columns: 1fr; }
      .meta { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 14px; }
    }
    """

    private static let fallbackJS = """
    (() => {
      const box = document.createElement("div");
      box.className = "lightbox";
      box.setAttribute("role", "dialog");
      box.setAttribute("aria-modal", "true");
      box.setAttribute("aria-label", "Screenshot");
      box.setAttribute("tabindex", "-1");
      box.innerHTML = "<img alt=''>";
      document.body.appendChild(box);
      const img = box.querySelector("img");
      let lastOpener = null;
      const isPackMediaHref = (href) => {
        if (!href || href.includes("\\\\") || href.includes(":") || href.includes("\\n") || href.includes("\\r") || href.includes("\\0")) return false;
        if (href.startsWith("/") || href.startsWith("#")) return false;
        let decoded = href;
        try { decoded = decodeURIComponent(href); } catch (e) { return false; }
        if (decoded.includes("\\\\") || decoded.includes(":") || decoded.includes("\\n") || decoded.includes("\\r") || decoded.includes("\\0")) return false;
        const parts = decoded.split("/").filter((part) => part.length > 0);
        if (parts.length < 2) return false;
        if (parts.some((part) => part === "." || part === "..")) return false;
        return parts[0] === "shots" || parts[0] === "media";
      };
      const isOpen = () => box.classList.contains("open");
      const close = () => {
        if (!isOpen()) return;
        box.classList.remove("open");
        img.removeAttribute("src");
        img.alt = "";
        box.setAttribute("aria-label", "Screenshot");
        const opener = lastOpener;
        lastOpener = null;
        if (opener && typeof opener.focus === "function") {
          opener.focus();
        }
      };
      box.addEventListener("click", (event) => {
        if (event.target === box) close();
      });
      document.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && isOpen()) {
          event.preventDefault();
          close();
        }
      });
      document.querySelectorAll("[data-lightbox]").forEach((link) => {
        link.addEventListener("click", (event) => {
          event.preventDefault();
          const href = link.getAttribute("href");
          if (!isPackMediaHref(href)) return;
          img.src = href;
          const thumb = link.querySelector("img");
          img.alt =
            link.getAttribute("aria-label") ||
            (thumb && thumb.getAttribute("alt")) ||
            (link.textContent || "").trim() ||
            "Screenshot";
          box.setAttribute("aria-label", img.alt);
          lastOpener = link;
          box.classList.add("open");
          box.focus();
        });
      });
    })();
    """
}
