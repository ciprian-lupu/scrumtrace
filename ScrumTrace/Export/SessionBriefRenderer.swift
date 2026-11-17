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

        let projectedTranscript = exportedTranscript(manifest: manifest, sessionURL: sessionURL)
        let presentation = BriefPresentation(manifest: manifest, transcript: projectedTranscript, sessionURL: sessionURL)
        let confirmed = manifest.tasks.filter { $0.status == .confirmed }
        let review = manifest.tasks.filter { $0.status == .needsReview }
        let replacements: [String: String] = [
            "{{CSS}}": css,
            "{{JS}}": js,
            "{{TITLE}}": HTMLEscaper.escape(manifest.productContext.appName.isEmpty ? "ScrumTrace session" : manifest.productContext.appName),
            "{{SESSION_ID}}": HTMLEscaper.escape(manifest.sessionId),
            "{{CREATED_AT}}": ISO8601DateFormatter().string(from: manifest.createdAt),
            "{{DISPLAY_DATE}}": HTMLEscaper.escape(manifest.createdAt.formatted(date: .abbreviated, time: .shortened)),
            "{{MEDIA_DURATION}}": Self.clock(manifest.duration.mediaSeconds),
            "{{WALL_DURATION}}": Self.clock(manifest.duration.wallSeconds),
            "{{PAUSE_COUNT}}": manifest.pauses.count == 1 ? "1 pause" : "\(manifest.pauses.count) pauses",
            "{{CONTEXT_BADGE}}": manifest.productContext.contextName.map { "<span>Context: \(HTMLEscaper.escape($0))</span>" } ?? "",
            "{{PRODUCT_NAME}}": HTMLEscaper.escape(manifest.productContext.appName),
            "{{REPO_URL}}": HTMLEscaper.escape(manifest.productContext.repoURL),
            "{{REPO_HREF}}": HTMLEscaper.httpHref(manifest.productContext.repoURL),
            "{{TECH_STACK}}": HTMLEscaper.escape(manifest.productContext.techStack),
            "{{STATUS_HTML}}": presentation.statusHTML,
            "{{STATUS_LABEL}}": HTMLEscaper.escape(presentation.statusLabel),
            "{{STATUS_CLASS}}": presentation.needsAttention ? "status-attention" : "",
            "{{SUMMARY_HTML}}": presentation.summaryHTML,
            "{{COMPARISON_HTML}}": ComparisonReport.html(manifest),
            "{{SPEAKERS_HTML}}": presentation.speakersHTML,
            "{{DOWNLOADS_HTML}}": presentation.downloadsHTML,
            "{{REVIEW_OPEN}}": confirmed.isEmpty ? "open" : "",
            "{{TASKS_HTML}}": confirmed.isEmpty ? "<p class=\"muted\">No confirmed findings. Review the captured evidence below.</p>" : groupedTaskCards(confirmed, excerpts: excerpts, sessionURL: sessionURL, omitted: manifest.omitted, manifest: manifest, procedure: manifest.localProcedure),
            "{{NEEDS_REVIEW_HTML}}": review.isEmpty ? "<p class=\"muted\">No review items were generated.</p>" : groupedTaskCards(review, excerpts: excerpts, sessionURL: sessionURL, omitted: manifest.omitted, manifest: manifest, procedure: manifest.localProcedure),
            "{{TIMELINE_HTML}}": timeline(manifest),
            "{{SHOTS_HTML}}": shots(manifest, sessionURL: sessionURL),
            "{{TRANSCRIPT_HTML}}": fullTranscriptHTML(projectedTranscript, manifest: manifest, sessionURL: sessionURL) + transcriptHTML(manifest: manifest, excerpts: excerpts, sessionURL: sessionURL, procedure: manifest.localProcedure, hasFullTranscript: projectedTranscript?.hasUsableText == true),
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

    private func taskCard(_ task: TaskRecord, excerpts: [String: String], sessionURL: URL, omitted: [OmittedAsset], slice: SliceRecord?, procedure: LocalProcedure?) -> String {
        let turns = slice.map { value in
            (procedure?.steps ?? []).filter { $0.sliceIds.contains(value.sliceId) }
        } ?? []
        let sanitized = PromptTemplates.sanitizeUntrusted(task.agentInstructions)
        let serviceStatus = slice?.serviceEvaluations.first(where: { $0.serviceId == task.serviceId })?.status ?? slice?.analysisStatus
        let instructions = serviceStatus == .skipped
            ? sanitized.replacingOccurrences(of: "[Requires Manual Review - API Offline]", with: "[Requires Manual Review]")
            : sanitized
        let confidenceTitle = task.serviceModel?.isEmpty == false ? "Model confidence" : "Analysis confidence"
        let confidenceLabel = serviceStatus == .success
            ? String(format: "%.2f", task.confidence) : "Not evaluated"
        let observed = task.observed.isEmpty ? "No visual observation recorded." : task.observed
        let stated = task.stated.isEmpty ? "No participant statement linked." : task.stated
        let inferred = task.inferred.isEmpty ? "No inference recorded." : task.inferred
        let playbackHint = turns.isEmpty ? "Play the recording to review this evidence." : "Select a transcript passage to play it."
        let media = task.evidenceMedia.compactMap { path -> String? in
            guard let rel = ExportRel.packMediaHandoff(path, sessionURL: sessionURL, omitted: omitted) else { return nil }
            if rel.hasSuffix(".mp4") {
                let timing = slice.map { " · \(Self.clock($0.startMedia))–\(Self.clock($0.endMedia)) in the recording" } ?? ""
                return """
                <div class="speaker-player"><video class="clip" controls tabindex="0" preload="metadata" aria-label="Evidence video for \(HTMLEscaper.escape(task.taskId))" src="\(HTMLEscaper.escape(rel))"></video><p class="clip-reference"><a href="\(HTMLEscaper.escape(rel))">Video: \(HTMLEscaper.escape(rel))</a>\(timing)</p><p class="now-speaking" aria-live="polite">\(playbackHint)</p></div>
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
            <span class="conf">\(confidenceTitle): \(HTMLEscaper.escape(confidenceLabel))</span>
            <h3>\(HTMLEscaper.escape(task.title))</h3>
          </header>
          \(task.serviceName.map { "<p class=\"clip-meta\">Source: \(HTMLEscaper.escape($0)) · model: \(HTMLEscaper.escape(task.serviceModel ?? "unknown"))</p>" } ?? "")
          <dl class="epistemic">
            <div><dt>Observed</dt><dd>\(HTMLEscaper.escape(observed))</dd></div>
            <div><dt>Stated</dt><dd>\(HTMLEscaper.escape(stated))</dd></div>
            <div><dt>Inferred</dt><dd>\(HTMLEscaper.escape(inferred))</dd></div>
          </dl>
          <p class="agent">\(HTMLEscaper.escape(instructions))</p>
          \(quotes)
          \(excerpt)
          <div class="evidence">\(media)</div>
          <details class="clip-transcript" id="transcript-\(HTMLEscaper.escape(task.taskId))">
            <summary>Transcript for this clip</summary>
            \(transcriptRows(task: task, slice: slice, procedure: procedure, sessionURL: sessionURL, omitted: omitted))
          </details>
        </article>
        """
    }

    private func groupedTaskCards(_ tasks: [TaskRecord], excerpts: [String: String], sessionURL: URL, omitted: [OmittedAsset], manifest: SessionManifest, procedure: LocalProcedure?) -> String {
        let groups = Dictionary(grouping: tasks) { task in
            task.serviceId ?? "local"
        }
        return groups.keys.sorted().map { key in
            let first = groups[key]?.first
            let hasEarlierAnalysis = (groups[key] ?? []).contains { task in
                manifest.slices.contains { $0.sliceId == task.sourceSliceId && $0.analysisStatus == .success }
            }
            let name = first?.serviceName ?? (hasEarlierAnalysis ? "Earlier analysis" : "Local review")
            let model = first?.serviceModel ?? (hasEarlierAnalysis ? "Model not recorded" : "No model")
            let cards = (groups[key] ?? []).map { task in
                taskCard(task, excerpts: excerpts, sessionURL: sessionURL, omitted: omitted, slice: manifest.slices.first { $0.sliceId == task.sourceSliceId }, procedure: procedure)
            }.joined()
            return "<section class=\"model-results\"><h3>\(HTMLEscaper.escape(name)) <span class=\"muted\">· \(HTMLEscaper.escape(model))</span></h3>\(cards)</section>"
        }.joined()
    }

    private func transcriptHTML(manifest: SessionManifest, excerpts: [String: String], sessionURL: URL, procedure: LocalProcedure?, hasFullTranscript: Bool) -> String {
        let available = manifest.tasks.filter { task in
            guard task.status != .dropped,
                  let slice = manifest.slices.first(where: { $0.sliceId == task.sourceSliceId }) else { return false }
            return (procedure?.steps ?? []).contains { $0.sliceIds.contains(slice.sliceId) }
        }
        guard !available.isEmpty else {
            return hasFullTranscript ? "" : "<p class=\"muted\">No additional clip excerpts are available in this pack.</p>"
        }
        return "<p>Read the timed passages beside each clip:</p><ul class=\"brief-list\">" + available.map {
            "<li><a href=\"#transcript-\(HTMLEscaper.escape($0.taskId))\">\(HTMLEscaper.escape($0.taskId)) · \(HTMLEscaper.escape($0.title))</a></li>"
        }.joined() + "</ul>"
    }

    private func exportedTranscript(manifest: SessionManifest, sessionURL: URL) -> FullTranscript? {
        // Only the opted-in, projected export is eligible. Never read the archive here.
        guard manifest.includeFullTranscriptInZip,
              !manifest.omitted.contains(where: { ExportRel.toExportRoot($0.path) == "full_transcript.json" }),
              let data = ExportRel.readContainedData(relative: "export/full_transcript.json", sessionURL: sessionURL),
              let full = try? JSONDecoder().decode(FullTranscript.self, from: data) else { return nil }
        return full
    }

    private func fullTranscriptHTML(_ full: FullTranscript?, manifest: SessionManifest, sessionURL: URL) -> String {
        guard let full else {
            let reason = !manifest.includeFullTranscriptInZip
                ? "The full transcript was not selected for this export."
                : manifest.omitted.contains(where: { ExportRel.toExportRoot($0.path) == "full_transcript.json" })
                    ? "The full transcript was omitted from this pack."
                    : "The full transcript is unavailable or unreadable in this export."
            return "<p class=\"coverage\"><strong>Selected excerpts only</strong>\(reason) Available excerpts are linked below; they do not represent the entire conversation.</p>"
        }
        guard full.hasUsableText else {
            let silent = full.transcriptionAnalysis?.isEmpty == false && full.transcriptionAnalysis?.allSatisfy { $0.status == "no_speech" } == true
            return "<p class=\"coverage\"><strong>\(silent ? "No speech detected" : "Transcript unavailable")</strong>The included transcript contains no usable speech passages.</p>"
        }
        let untimed = full.untimedText.flatMap { text -> String? in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "<div class=\"untimed-transcript\"><h3>Text without timestamps</h3><p class=\"muted\">Review only · this text cannot be linked to a video moment.</p><p class=\"untimed-text\">\(HTMLEscaper.escape(text))</p></div>"
        } ?? ""
        let coverage = full.needsTranscriptionRetry || !manifest.hasCompleted(.transcribing)
            ? "Included transcript · incomplete transcription"
            : "Full transcript · included in this export"
        let rows = full.segments.sorted { $0.start < $1.start }.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { turn in
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
        let count = full.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let label = count == 0 ? "Text without timestamps" : "\(count) timed passages"
        return "<p class=\"coverage\"><strong>\(coverage)</strong>All exported passages are included below. Play is available only where a clip is linked.</p><details class=\"full-transcript\" open><summary>Read conversation · \(label)</summary>\(rows)\(untimed)</details>"
    }

    private func transcriptRows(task: TaskRecord, slice: SliceRecord?, procedure: LocalProcedure?, sessionURL: URL, omitted: [OmittedAsset]) -> String {
        guard let slice else { return "<p class=\"muted\">No selected evidence window is available.</p>" }
        let passages = (procedure?.steps ?? []).filter { $0.sliceIds.contains(slice.sliceId) }.sorted { $0.order < $1.order }
        guard !passages.isEmpty else {
            return "<p class=\"muted\">No persisted local transcript excerpt is linked to this evidence.</p>"
        }
        let clip = task.evidenceMedia.compactMap { ExportRel.packMediaHandoff($0, sessionURL: sessionURL, omitted: omitted) }.first { $0.hasSuffix(".mp4") }
        let rows = passages.map { step -> String in
            let label = step.speaker ?? "unknown"
            let content = "<span class=\"turn-meta\">t_media \(Self.clock(step.start))–\(Self.clock(step.end)) · \(HTMLEscaper.escape(step.source)) · \(HTMLEscaper.escape(label))</span><span>\(HTMLEscaper.escape(step.excerpt))</span>"
            if let clip {
                let startSeconds = min(max(0, step.start - slice.startMedia), slice.endMedia - slice.startMedia)
                let endSeconds = min(slice.endMedia - slice.startMedia, max(startSeconds, step.end - slice.startMedia))
                let start = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), startSeconds)
                let end = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), endSeconds)
                return "<button class=\"transcript-turn\" data-clip=\"\(HTMLEscaper.escape(clip))\" data-start=\"\(start)\" data-end=\"\(end)\" data-speaker=\"\(HTMLEscaper.escape(label))\">\(content)</button>"
            }
            return "<p class=\"transcript-turn\">\(content)</p>"
        }.joined()
        return "<p class=\"muted\">Persisted extractive passages · speaker attribution may be uncertain.</p>\(rows)"
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
        let ruler = pauses.isEmpty && marks.isEmpty ? ""
            : "<div class=\"timeline-label\"><span>Screenshot and pause markers</span><span>0:00–\(Self.clock(manifest.duration.mediaSeconds))</span></div><div class=\"ruler\" aria-hidden=\"true\">\(pauses)\(marks)</div>"
        return "\(ruler)<nav class=\"brief-nav window-nav\" aria-label=\"Selected evidence windows\">\(windows)</nav>"
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
                <img src="\(HTMLEscaper.escape(path))" alt="\(HTMLEscaper.escape(shot.note.isEmpty ? "Screenshot at " + Self.clock(shot.tMedia) : shot.note))">
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
          <p>These assets are not included in this pack. The reason for each omission is listed below.</p>
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
        update();
      });
      turns.forEach(turn => turn.addEventListener('click', () => {
        const nearby = turn.closest('.take')?.querySelector('video.clip');
        const video = nearby?.getAttribute('src') === turn.getAttribute('data-clip')
          ? nearby : videos.find(item => item.getAttribute('src') === turn.getAttribute('data-clip'));
        const start = Number(turn.dataset.start);
        if (!video || !Number.isFinite(start) || start < 0) return;
        videos.forEach(other => { if (other !== video) other.pause(); });
        // A seek issued before metadata is loaded can be discarded by the browser.
        const seek = () => { video.currentTime = start; };
        if (video.readyState >= 1) seek();
        else video.addEventListener('loadedmetadata', seek, {once:true});
        let parent = video.parentElement;
        while (parent) { if (parent.tagName === 'DETAILS') parent.open = true; parent = parent.parentElement; }
        video.scrollIntoView({block:'center', behavior:window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth'});
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
    private static let fallbackShell = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{TITLE}} · ScrumTrace</title>
    <style>{{CSS}}</style>
    </head>
    <body>
    <a class="skip-link" href="#main">Skip to session</a>
    <div class="shell">
    <header class="session-header">
      <div class="brand"><span class="brand-mark" aria-hidden="true">S</span> ScrumTrace <span class="brand-label">Conversation brief</span></div>
      <h1>{{TITLE}}</h1>
      <div class="session-facts"><time datetime="{{CREATED_AT}}">{{DISPLAY_DATE}}</time><span>{{MEDIA_DURATION}} recorded</span><a href="#evidence">{{CONFIRMED_COUNT}} confirmed findings</a><a href="#review">{{REVIEW_COUNT}} to review</a></div>
      <details class="session-details"><summary>Session details</summary><div class="meta"><span>Session: {{SESSION_ID}}</span><span>Elapsed: {{WALL_DURATION}} · {{PAUSE_COUNT}}</span>{{CONTEXT_BADGE}}<span>{{TECH_STACK}}</span><a href="{{REPO_HREF}}">{{REPO_URL}}</a></div></details>
    </header>
    <div class="nav-wrap"><nav class="brief-nav section-nav" aria-label="Brief sections">
      <a href="#summary">Overview</a><a href="#transcript">Conversation</a><a href="#evidence">Evidence</a><a href="#captures">Screenshots</a><a href="#exports">Files</a>
    </nav><span class="nav-more" aria-hidden="true">›</span></div>
    <main id="main" tabindex="-1">
    <details class="supporting-details {{STATUS_CLASS}}"><summary>{{STATUS_LABEL}} <span class="muted">· View status</span></summary>{{STATUS_HTML}}{{SPEAKERS_HTML}}</details>
    {{SUMMARY_HTML}}
    <section id="transcript" class="brief-panel conversation" aria-labelledby="conversation-title"><div class="section-heading"><div><span class="eyebrow">The discussion</span><h2 id="conversation-title">Conversation</h2></div></div>{{TRANSCRIPT_HTML}}<noscript><p class="muted">Passage playback shortcuts need JavaScript. Use the video controls in Evidence to play included clips.</p></noscript></section>
    <section id="evidence" aria-labelledby="evidence-title"><div class="section-heading"><div><span class="eyebrow">Supporting material</span><h2 id="evidence-title">Confirmed evidence</h2></div><span class="count">{{CONFIRMED_COUNT}} findings</span></div><p class="muted evidence-note">Confirmed means automatically checked against evidence, not human approval. Review before implementation.</p>{{TIMELINE_HTML}}{{TASKS_HTML}}</section>
    <section id="review" class="review"><details {{REVIEW_OPEN}}><summary>Needs review <span class="count">{{REVIEW_COUNT}}</span></summary>{{NEEDS_REVIEW_HTML}}</details></section>
    {{COMPARISON_HTML}}
    <section id="captures" class="brief-panel" aria-labelledby="captures-title"><div class="section-heading"><h2 id="captures-title">Screenshots</h2><div class="image-tools"></div></div><div class="contact">{{SHOTS_HTML}}</div></section>
    {{OMITTED_HTML}}
    {{DOWNLOADS_HTML}}
    </main>
    <footer class="page-footer"><span>ScrumTrace · Conversation brief</span><a href="#">Back to top ↑</a><p>Summary and findings reflect selected evidence. Conversation coverage is described above.</p></footer>
    </div>
    <script>{{JS}}</script>
    </body>
    </html>
    """#

    private static let fallbackCSS = #"""
    :root{color-scheme:light;--ink:#f4f6f8;--panel:#fff;--panel-2:#f5f7f9;--paper:#182638;--muted:#566577;--line:#dce3e9;--amber:#096b60;--sage:#096b60;--rec:#b64635;--sans:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
    *{box-sizing:border-box}html{scroll-padding-top:90px}body{margin:0;background:var(--ink);color:var(--paper);font:16px/1.65 var(--sans);-webkit-font-smoothing:antialiased}a{color:var(--amber);text-underline-offset:3px}a:hover{text-decoration-thickness:2px}button,input,summary,a{-webkit-tap-highlight-color:transparent}a:focus-visible,summary:focus-visible,button:focus-visible,input:focus-visible,[tabindex]:focus-visible{outline:3px solid var(--amber);outline-offset:4px}button{font:inherit}h1,h2,h3,h4,p,figure{margin:0}h1,h2,h3,h4{line-height:1.25;overflow-wrap:anywhere}h1{font-size:clamp(2rem,4vw,3.25rem);font-weight:650;letter-spacing:-.045em;margin:24px 0 18px}h2{font-size:1.45rem;letter-spacing:-.025em;font-weight:650}h3{font-size:1.15rem;font-weight:600}p+p{margin-top:12px}p,li,dd,figcaption,.meta{overflow-wrap:anywhere}p{max-width:78ch}
    .muted{color:var(--muted)}
    .shell{max-width:1200px;padding:40px 44px 32px;margin:auto}
    .session-header{padding:0 0 26px}
    .brand{display:flex;align-items:center;gap:10px;font-size:15px;font-weight:650}
    .brand-mark{display:grid;place-items:center;width:30px;height:30px;background:var(--amber);color:#fff;border-radius:9px;font-size:19px}
    .brand-label{color:var(--muted);font-size:13px;font-weight:400;border-left:1px solid var(--line);padding-left:12px;margin-left:4px}
    .session-facts{display:flex;align-items:center;flex-wrap:wrap;gap:8px 20px;font-size:14px;color:var(--muted)}
    .session-facts a{color:inherit}
    .session-details{margin-top:14px;font-size:13px;color:var(--muted)}summary{cursor:pointer;min-height:44px;align-content:center}summary:hover{color:var(--amber)}
    .meta{display:flex;flex-wrap:wrap;gap:8px 22px;padding:8px 0}
    .meta span:empty,.meta a:empty{display:none}
    .brief-nav{display:flex;flex-wrap:wrap;gap:8px;margin:0 0 20px}
    .section-nav{position:sticky;top:0;z-index:5;background:var(--ink);padding:12px 0;border-top:1px solid var(--line);border-bottom:1px solid var(--line);margin-bottom:32px}
    .brief-nav a{padding:10px 16px;border-radius:8px;color:var(--muted);font-size:14px;text-decoration:none}
    .brief-nav a:hover,.brief-nav a[aria-current]{background:var(--panel);color:var(--amber)}
    .brief-nav a[aria-current]{box-shadow:0 1px 4px #18263812;font-weight:600}
    .brief-panel{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:28px;margin:0 0 24px;min-width:0}
    .brief-panel h2{margin-bottom:14px}
    .brief-panel>p{color:var(--muted)}#summary{border-top:3px solid var(--amber)}#summary .brief-list{margin-top:18px}
    .brief-list{padding-left:20px;margin:12px 0 0}
    .brief-list li+li{margin-top:12px}
    .brief-list a{color:var(--paper);font-weight:550}
    .brief-list p{color:var(--muted);font-size:14px;margin-top:6px}
    .outcome-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}
    .outcome-grid .brief-panel{padding:22px}
    .outcome-grid h2{font-size:17px}
    .outcome-grid p,.outcome-grid li{font-size:14px}
    .section-heading{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:12px;margin-bottom:20px}
    .section-heading h2{margin:0}
    .eyebrow{display:block;text-transform:uppercase;letter-spacing:.12em;font-size:11px;font-weight:650;color:var(--muted);margin-bottom:8px}
    .count{font-size:12px;border:1px solid var(--line);border-radius:6px;padding:3px 9px;color:var(--muted);font-weight:500}
    .coverage{background:var(--panel-2);padding:14px 18px;border-radius:10px;font-size:14px;margin-bottom:20px}
    .coverage strong{display:block;color:var(--paper);margin-bottom:3px}
    .transcript-turn{display:flex;flex-direction:column;gap:6px;width:100%;text-align:left;margin:0;padding:18px 14px;border:0;border-bottom:1px solid var(--line);border-radius:0;background:transparent;color:var(--paper);font:inherit;line-height:1.7;white-space:normal}
    .transcript-turn:last-child{border-bottom:0}
    .transcript-turn>span:not(.turn-meta){max-width:78ch;white-space:pre-wrap}
    .turn-meta{font-size:12px;color:var(--muted);font-weight:500}
    .turn-meta::first-letter{text-transform:uppercase}button.transcript-turn{cursor:pointer}button.transcript-turn:hover,.transcript-turn[aria-current=true]{background:var(--panel-2)}button.transcript-turn .turn-meta::after{content:" · Play passage";color:var(--amber)}
    .full-transcript{margin:12px 0}
    .full-transcript>summary{font-weight:600}
    .clip-transcript{width:100%;margin-top:20px;border-top:1px solid var(--line)}
    .clip-transcript>summary{font-size:14px;font-weight:600;padding:10px 0}
    .supporting-details{margin:0 0 36px;border-bottom:1px solid var(--line);font-size:14px}
    .supporting-details>summary{padding:0 4px 16px;color:var(--muted)}
    .supporting-details .brief-panel{border:0;background:transparent;padding:12px 4px;margin:0 0 18px}
    .supporting-details h2{font-size:16px}
    .status-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:24px;margin:0}
    .status-grid dt{font-weight:600;margin-bottom:5px}
    .status-grid dd{margin:0;color:var(--muted);font-size:14px}
    .model-results{margin-bottom:24px}
    .model-results>h3{font-size:13px;margin:0 0 14px;color:var(--muted)}
    .take{border:1px solid var(--line);border-radius:16px;background:var(--panel);padding:28px;margin-bottom:20px;min-width:0}
    .take header{display:flex;gap:10px;align-items:center;flex-wrap:wrap;font-size:12px;color:var(--muted)}
    .take .slate{font:12px var(--mono)}
    .kind{border-radius:5px;background:var(--panel-2);padding:3px 8px}
    .conf{margin-left:auto}
    .take h3,.take h2{font-size:1.35rem;margin:14px 0}
    .clip-meta{font-size:12px;color:var(--muted);margin:0 0 18px}
    .epistemic{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:20px;margin:22px 0}
    .epistemic dt{font-size:12px;font-weight:650;color:var(--muted);margin-bottom:5px}
    .epistemic dd{margin:0;font-size:14px}
    .agent{border-left:3px solid var(--amber);padding:12px 16px;background:var(--panel-2);font-size:14px;margin:18px 0}blockquote{border-left:2px solid var(--line);padding:4px 18px;margin:18px 0;max-width:78ch}
    .spk{display:block;font-size:13px;font-weight:600;color:var(--amber)}
    .when{display:block;color:var(--muted);font-size:12px;margin-bottom:8px}
    .excerpt{font-size:14px;color:var(--muted);margin:14px 0}
    .evidence{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px;align-items:start;margin:18px 0}
    .evidence>*{min-width:0}
    .speaker-player{width:100%;min-width:0}
    .clip{width:100%;border-radius:10px;background:#111;display:block}
    .now-speaking{font-size:12px;color:var(--muted);min-height:1.5em;margin-top:8px}
    .still{display:block;min-width:0}
    .still img,figure img{display:block;width:auto;max-width:100%;height:auto;border-radius:10px}
    .contact{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(220px,100%),1fr));gap:22px}
    .contact figure{min-width:0}
    .contact a{display:block}figcaption{font-size:12px;color:var(--muted);margin-top:10px}
    .ruler{position:relative;height:8px;background:var(--line);border-radius:5px;overflow:hidden;margin:18px 0}
    .ruler .pause{position:absolute;top:0;bottom:0;background:#9ca9b6}
    .ruler .shot{position:absolute;top:0;width:4px;height:8px;background:var(--amber)}
    .window-nav a{font-size:12px;padding:8px 10px;background:var(--panel)}
    .review{margin:24px 0}
    .review>details>summary{font-weight:600;padding:16px 20px;background:var(--panel);border:1px solid var(--line);border-radius:10px;margin-bottom:16px}
    .review .count{margin-left:8px}
    .omitted{padding:24px;border:1px dashed var(--line);border-radius:12px;margin:24px 0;font-size:14px}
    .omitted h2{font-size:18px;margin-bottom:12px}
    .export-links{display:flex;flex-wrap:wrap;gap:10px;margin-top:20px}
    .export-link{padding:10px 16px;border:1px solid var(--line);border-radius:8px;text-decoration:none;font-size:14px;font-weight:550}
    .export-link:first-child{background:var(--amber);border-color:var(--amber);color:white}#exports p{font-size:14px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;vertical-align:top;padding:12px;border-bottom:1px solid var(--line)}th{background:var(--panel-2);font-weight:600}td{overflow-wrap:anywhere}code{font:12px var(--mono);overflow-wrap:anywhere}
    .page-footer{display:flex;justify-content:space-between;flex-wrap:wrap;gap:12px;color:var(--muted);font-size:12px;padding:20px 0;border-top:1px solid var(--line)}
    .page-footer p{flex-basis:100%;max-width:none}
    .skip-link{position:absolute;top:-100px;left:16px;z-index:30;padding:12px 18px;background:var(--panel);border:2px solid var(--amber);border-radius:8px}
    .skip-link:focus{top:12px}
    .lightbox{position:fixed;inset:0;background:rgba(14,23,34,.95);display:none;place-items:center;z-index:20;padding:72px 24px 24px;overflow:auto}
    .lightbox.open{display:grid}
    .lightbox img{max-width:100%;max-height:calc(100dvh - 110px);object-fit:contain;border-radius:6px}
    .lightbox-close{position:fixed;right:24px;top:20px;border:1px solid #ffffff60;border-radius:8px;background:#fff;color:#182638;padding:10px 18px;cursor:pointer;z-index:21}
    .lightbox-close:focus-visible{outline-color:#7ae2d3}
    .still-size{display:inline-flex;align-items:center;gap:8px;font-size:12px;color:var(--muted);min-height:44px;cursor:pointer}
    .still-size input{width:18px;height:18px;accent-color:var(--amber)}body.stills-full .still img,body.stills-full figure img,body.stills-full .lightbox img{max-width:none;max-height:none;width:auto;height:auto}body.stills-full .still,body.stills-full figure,body.stills-full .evidence,body.stills-full .contact,body.stills-full .lightbox.open{overflow:auto}
    .lightbox-open{overflow:hidden}#local-outline ol{padding-left:24px}#local-outline li{padding:16px 0;border-bottom:1px solid var(--line)}#local-outline li:last-child{border:0}#local-outline li::marker{color:transparent}#local-outline .evidence img{max-height:300px;width:auto}#local-outline h2{font-size:18px}
    @media(max-width:800px){.shell{padding:24px 20px}
    .outcome-grid,.status-grid{grid-template-columns:1fr}
    .outcome-grid{gap:0}
    .outcome-grid .brief-panel{margin-bottom:12px}
    .epistemic{grid-template-columns:1fr;gap:16px}
    .evidence{grid-template-columns:1fr}
    .brief-panel,.take{padding:22px}
    .section-nav{margin-top:0;gap:2px;flex-wrap:nowrap;overflow-x:auto}
    .section-nav a{white-space:nowrap;padding:10px 12px}
    .session-facts{gap:8px 16px}
    .meta{flex-direction:column}
    .conf{margin-left:0}
    .brand-label{font-size:12px}html{scroll-padding-top:82px}}
    @media(max-width:400px){.shell{padding:20px 14px}
    .brief-panel,.take{padding:18px}
    .brand-label{margin-left:0;padding-left:8px}
    .session-facts{font-size:13px}}
    @media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}*,*::before,*::after{animation:none!important;transition:none!important}}
    @media print{:root{--ink:#fff;--panel:#fff;--paper:#111;--muted:#444;--line:#ccc;--amber:#164d45}body{font-size:11pt}
    .shell{max-width:none;padding:0}
    .section-nav,.skip-link,.image-tools,.lightbox,.page-footer>a,video,.now-speaking{display:none!important}
    .brief-panel,.take{padding:16px;border-radius:0;box-shadow:none}
    .outcome-grid,.status-grid{display:block}h2,h3,summary{break-after:avoid}
    .transcript-turn,blockquote,figure{break-inside:avoid}
    .evidence{grid-template-columns:1fr 1fr}
    .contact{grid-template-columns:1fr 1fr}a{color:inherit}
    .export-link:first-child{background:none;color:inherit}
    .supporting-details{margin-bottom:20px}body.stills-full img{max-width:100%!important;max-height:500px!important}details::details-content{content-visibility:visible!important}details>*{display:revert!important}
    .brand-mark{background:none;color:inherit;border:1px solid #aaa}
    .page-footer{font-size:9pt}}

    .evidence-note{font-size:13px;margin-bottom:20px}.untimed-transcript{padding:18px 14px;border-top:1px solid var(--line)}.untimed-text{white-space:pre-wrap;margin-top:14px}.untimed-transcript h3{font-size:16px;margin-bottom:8px}

    .take header h3{flex-basis:100%;color:var(--paper);margin:8px 0;font-size:1.35rem}.comparison-details>summary{font-weight:600}.comparison-details>p{font-size:14px;margin:12px 0 20px}.table-scroll{overflow-x:auto;max-width:100%}.table-scroll table{min-width:680px}

    .nav-wrap{position:sticky;top:0;z-index:5;margin-bottom:26px;background:var(--ink)}
    .nav-wrap .section-nav{position:static;margin-bottom:0}
    .nav-more{display:none;position:absolute;right:0;top:12px;width:28px;height:44px;text-align:right;font-size:24px;color:var(--amber);background:linear-gradient(to right,transparent,var(--ink) 55%);pointer-events:none}
    .nav-wrap.has-more .nav-more{display:block}
    .supporting-details.status-attention{border-left:3px solid #b16b17;padding-left:14px}
    .supporting-details.status-attention>summary{color:#80501c}
    .turn-meta{font-size:13px}
    .service-list{list-style:none;padding:0;margin:22px 0 0}
    .service-list li{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:5px 24px;padding:18px 0;border-top:1px solid var(--line);align-items:center}
    .service-list strong,.service-list p{grid-column:1}.service-list p{font-size:14px;color:var(--muted)}
    .service-list a,.service-list li>span{grid-column:2;grid-row:1/3;font-size:14px}.service-list a{padding:9px 14px;border:1px solid var(--line);border-radius:8px;text-decoration:none}
    .clip-reference{display:none}
    @media(max-width:800px){h1{font-size:28px;margin:18px 0 12px}.session-header{padding-bottom:16px}.session-details{margin-top:6px}.nav-wrap{margin-bottom:20px}.supporting-details{margin-bottom:24px}.supporting-details>summary{padding-bottom:10px}.service-list li{grid-template-columns:1fr;gap:8px}.service-list a,.service-list li>span{grid-column:1;grid-row:auto;justify-self:start}}
    @media print{.nav-wrap{display:none!important}.clip-reference{display:block;font-size:10pt}.service-list li{display:block}.service-list a{border:0;padding:0}.table-scroll{overflow:visible}.table-scroll table{min-width:0;table-layout:fixed}}

    .transcript-turn>.muted{font-size:12px}.timeline-label{display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px;font-size:12px;color:var(--muted);margin-top:20px}.timeline-label+.ruler{margin-top:8px}body.stills-full .lightbox.open{place-items:start}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap;border:0}
    """#

    private static let fallbackJS = #"""
    (() => {
      const box = document.createElement("div");
      box.className = "lightbox";
      box.setAttribute("role", "dialog");
      box.setAttribute("aria-modal", "true");
      box.setAttribute("aria-label", "Screenshot");
      box.setAttribute("tabindex", "-1");
      box.setAttribute("aria-describedby", "screenshot-help");
      box.innerHTML = "<button type='button' class='lightbox-close'>Close screenshot ×</button><img alt=''><p id='screenshot-help' class='sr-only'>Escape closes the screenshot. In Full size mode, use arrow keys to pan.</p>";
      document.body.appendChild(box);
      const img = box.querySelector("img");
      const closeButton = box.querySelector("button");
      let lastOpener = null;
      let background = [];
      let previousOverflow = "";
      const isPackMediaHref = (href) => {
        if (!href || href.includes("\\") || href.includes(":") || href.includes("\n") || href.includes("\r") || href.includes("\0")) return false;
        if (href.startsWith("/") || href.startsWith("#")) return false;
        let decoded = href;
        try {
          decoded = decodeURIComponent(href);
        } catch (e) {
          return false;
        }
        if (decoded.includes("\\") || decoded.includes(":") || decoded.includes("\n") || decoded.includes("\r") || decoded.includes("\0")) return false;
        const parts = decoded.split("/").filter((part) => part.length > 0);
        if (parts.length < 2) return false;
        if (parts.some((part) => part === "." || part === "..")) return false;
        return parts[0] === "shots" || parts[0] === "media";
      };
      const isOpen = () => box.classList.contains("open");
      const close = () => {
        if (!isOpen()) return;
        box.classList.remove("open");
        background.forEach(([element, wasInert]) => { element.inert = wasInert; });
        background = [];
        document.body.style.overflow = previousOverflow;
        img.removeAttribute("src");
        img.alt = "";
        box.setAttribute("aria-label", "Screenshot");
        const opener = lastOpener;
        lastOpener = null;
        if (opener && typeof opener.focus === "function") {
          opener.focus();
        }
      };
      closeButton.addEventListener("click", close);
      box.addEventListener("click", (event) => {
        if (event.target === box) close();
      });
      document.addEventListener("keydown", (event) => {
        const pan = {ArrowLeft: [-80, 0], ArrowRight: [80, 0], ArrowUp: [0, -80], ArrowDown: [0, 80]}[event.key];
        if (pan && isOpen() && document.body.classList.contains("stills-full")) {
          event.preventDefault();
          box.scrollBy({left: pan[0], top: pan[1], behavior: "auto"});
        }
        if (event.key === "Tab" && isOpen()) {
          event.preventDefault();
          closeButton.focus();
        }
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
          background = Array.from(document.body.children).filter(element => element !== box && element.tagName !== "SCRIPT").map(element => [element, element.inert]);
          background.forEach(([element]) => { element.inert = true; });
          previousOverflow = document.body.style.overflow;
          document.body.style.overflow = "hidden";
          box.classList.add("open");
          box.focus();
          closeButton.focus();
        });
      });
    })();
    (() => {
      const label = document.createElement("label");
      label.className = "still-size";
      const input = document.createElement("input");
      input.type = "checkbox";
      input.setAttribute("role", "switch");
      input.setAttribute("aria-label", "Show screenshots at full size");
      label.appendChild(input);
      label.appendChild(document.createTextNode(" Full size"));
      const tools = document.querySelector(".image-tools");
      if (!tools || !document.querySelector("[data-lightbox]")) return;
      tools.appendChild(label);
      const apply = () => {
        document.body.classList.toggle("stills-full", input.checked);
      };
      input.addEventListener("change", apply);
      apply();
    })();

    // Keep printouts complete without changing the reader's disclosure choices.
    (() => {
      let closed = [];
      window.addEventListener("beforeprint", () => {
        if (closed.length) return;
        closed = Array.from(document.querySelectorAll("details:not([open])"));
        closed.forEach(detail => { detail.open = true; });
      });
      window.addEventListener("afterprint", () => {
        closed.forEach(detail => { detail.open = false; });
        closed = [];
      });
      const links = Array.from(document.querySelectorAll(".section-nav a"));
      const update = () => {
        let current = links[0];
        links.forEach(link => {
          const target = document.querySelector(link.getAttribute("href"));
          if (target && target.getBoundingClientRect().top < 140) current = link;
        });
        links.forEach(link => {
          if (link === current) link.setAttribute("aria-current", "location");
          else link.removeAttribute("aria-current");
        });
      };
      let pending = false;
      window.addEventListener("scroll", () => {
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => { update(); pending = false; });
      }, {passive: true});
      update();
    })();

    (() => {
      const nav = document.querySelector(".section-nav");
      const wrap = document.querySelector(".nav-wrap");
      if (!nav || !wrap) return;
      const update = () => wrap.classList.toggle("has-more", nav.scrollWidth - nav.clientWidth - nav.scrollLeft > 4);
      nav.addEventListener("scroll", update, {passive: true});
      window.addEventListener("resize", update);
      update();
    })();
    """#
}
