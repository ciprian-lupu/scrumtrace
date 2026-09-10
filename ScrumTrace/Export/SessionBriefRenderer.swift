import Foundation

enum BriefTemplateLoader {
    static func text(_ name: String, ext: String) -> String {
        let subdirs = ["Resources", "Export/Resources", "Export"]
        for folder in subdirs {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let text = try? String(contentsOf: url, encoding: .utf8) {
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
                       let text = try? String(contentsOf: url, encoding: .utf8) {
                        return text
                    }
                }
            }
        }
        return ""
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
            "{{PRODUCT_NAME}}": HTMLEscaper.escape(manifest.productContext.appName),
            "{{REPO_URL}}": HTMLEscaper.escape(manifest.productContext.repoURL),
            "{{REPO_HREF}}": HTMLEscaper.httpHref(manifest.productContext.repoURL),
            "{{TECH_STACK}}": HTMLEscaper.escape(manifest.productContext.techStack),
            "{{TASKS_HTML}}": confirmed.map { taskCard($0, excerpts: excerpts, sessionURL: sessionURL) }.joined(),
            "{{NEEDS_REVIEW_HTML}}": review.isEmpty ? "" : review.map { taskCard($0, excerpts: excerpts, sessionURL: sessionURL) }.joined(),
            "{{TIMELINE_HTML}}": timeline(manifest),
            "{{SHOTS_HTML}}": shots(manifest, sessionURL: sessionURL),
            "{{TRANSCRIPT_HTML}}": transcriptHTML(manifest: manifest, excerpts: excerpts),
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

    private func taskCard(_ task: TaskRecord, excerpts: [String: String], sessionURL: URL) -> String {
        let media = task.evidenceMedia.compactMap { path -> String? in
            guard let rel = ExportRel.handoffFileIfPresent(path, sessionURL: sessionURL) else { return nil }
            if rel.hasSuffix(".mp4") {
                return """
                <video class="clip" controls preload="metadata" src="\(HTMLEscaper.escape(rel))"></video>
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
            <h2>\(HTMLEscaper.escape(task.title))</h2>
          </header>
          <dl class="epistemic">
            <div><dt>Observed</dt><dd>\(HTMLEscaper.escape(task.observed))</dd></div>
            <div><dt>Stated</dt><dd>\(HTMLEscaper.escape(task.stated))</dd></div>
            <div><dt>Inferred</dt><dd>\(HTMLEscaper.escape(task.inferred))</dd></div>
          </dl>
          <p class="agent">\(HTMLEscaper.escape(task.agentInstructions))</p>
          \(quotes)
          \(excerpt)
          <div class="evidence">\(media)</div>
        </article>
        """
    }

    private func transcriptHTML(manifest: SessionManifest, excerpts: [String: String]) -> String {
        manifest.tasks.compactMap { task -> String? in
            guard let text = excerpts[task.taskId], !text.isEmpty else { return nil }
            return "<p><span class=\"slate\">\(HTMLEscaper.escape(task.taskId))</span> \(HTMLEscaper.escape(text))</p>"
        }.joined()
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
        return "<div class=\"ruler\">\(pauses)\(marks)</div>"
    }

    private func shots(_ manifest: SessionManifest, sessionURL: URL) -> String {
        let figures = manifest.shots.compactMap { shot -> String? in
            var path: String?
            for candidate in [shot.exportPath].compactMap({ $0 }) + shot.stillCandidates {
                if let rel = ExportRel.handoffFileIfPresent(candidate, sessionURL: sessionURL) {
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
            <span>{{PRODUCT_NAME}}</span>
            <span>{{TECH_STACK}}</span>
            <a href="{{REPO_HREF}}">{{REPO_URL}}</a>
            <span>{{CREATED_AT}}</span>
          </div>
        </header>
        {{TIMELINE_HTML}}
        <section>
          {{TASKS_HTML}}
        </section>
        <section class="review">
          <details>
            <summary>Needs review</summary>
            {{NEEDS_REVIEW_HTML}}
          </details>
        </section>
        {{OMITTED_HTML}}
        <section>
          <h2>Contact sheet</h2>
          <div class="contact">{{SHOTS_HTML}}</div>
        </section>
        <section class="review">
          <details>
            <summary>Transcript excerpts</summary>
            {{TRANSCRIPT_HTML}}
          </details>
        </section>
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
    .clip { width: 100%; border-radius: 12px; background: #000; }
    .still img, figure img { width: 100%; border-radius: 12px; display: block; }
    .contact { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 14px; }
    .lightbox { position: fixed; inset: 0; background: rgba(6,5,4,.92); display: none; place-items: center; z-index: 20; padding: 24px; cursor: zoom-out; }
    .lightbox.open { display: grid; }
    .lightbox img { max-width: min(92vw, 1400px); max-height: 92vh; cursor: default; }
    .spk { display: block; font-size: 11px; color: #f0a35e; }
    .when { display: block; font-size: 10px; opacity: 0.6; margin-bottom: 6px; }
    @media (max-width: 860px) { .epistemic { grid-template-columns: 1fr; } }
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
          if (!href) return;
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
