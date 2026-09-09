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
        if let root = Bundle.main.resourceURL,
           let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if url.deletingPathExtension().lastPathComponent == name, url.pathExtension == ext,
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    return text
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
}

struct SessionBriefRenderer {
    func render(manifest: SessionManifest, excerpts: [String: String]) -> String {
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
            "{{PAUSE_COUNT}}": "\(manifest.pauses.count)",
            "{{PRODUCT_NAME}}": HTMLEscaper.escape(manifest.productContext.appName),
            "{{REPO_URL}}": HTMLEscaper.escape(manifest.productContext.repoURL),
            "{{TECH_STACK}}": HTMLEscaper.escape(manifest.productContext.techStack),
            "{{TASKS_HTML}}": confirmed.map { taskCard($0, excerpts: excerpts) }.joined(),
            "{{NEEDS_REVIEW_HTML}}": review.isEmpty ? "" : review.map { taskCard($0, excerpts: excerpts) }.joined(),
            "{{TIMELINE_HTML}}": timeline(manifest),
            "{{SHOTS_HTML}}": shots(manifest),
            "{{TRANSCRIPT_HTML}}": excerpts.values.map { "<p>\(HTMLEscaper.escape($0))</p>" }.joined(),
            "{{CONFIRMED_COUNT}}": "\(confirmed.count)",
            "{{REVIEW_COUNT}}": "\(review.count)",
            "{{OMITTED_HTML}}": omittedHTML(manifest)
        ]
        var html = shell
        for (token, value) in replacements {
            html = html.replacingOccurrences(of: token, with: value)
        }
        return html
    }

    private func taskCard(_ task: TaskRecord, excerpts: [String: String]) -> String {
        let media = task.evidenceMedia.compactMap { path -> String? in
            guard let rel = ExportRel.handoffPath(path) else { return nil }
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
          <div class="evidence">\(media)</div>
        </article>
        """
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

    private func shots(_ manifest: SessionManifest) -> String {
        let figures = manifest.shots.compactMap { shot -> String? in
            let raw = shot.exportPath ?? shot.annotatedPath ?? (shot.rawPath.isEmpty ? nil : shot.rawPath)
            guard let raw, let path = ExportRel.handoffPath(raw) else { return nil }
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
        let items = manifest.omitted.compactMap { item -> String? in
            let rel = ExportRel.toExportRoot(item.path)
            if rel.hasPrefix("archive/") { return nil }
            return "<li><code>\(HTMLEscaper.escape(rel))</code> — \(HTMLEscaper.escape(item.reason))</li>"
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
            <span>{{PAUSE_COUNT}} pauses</span>
            <span>{{CONFIRMED_COUNT}} confirmed</span>
            <span>{{REVIEW_COUNT}} review</span>
          </div>
          <div class="meta">
            <span>{{PRODUCT_NAME}}</span>
            <span>{{TECH_STACK}}</span>
            <a href="{{REPO_URL}}">{{REPO_URL}}</a>
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
    .epistemic { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
    .clip { width: 100%; border-radius: 12px; background: #000; }
    .still img, figure img { width: 100%; border-radius: 12px; display: block; }
    .contact { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 14px; }
    .lightbox { position: fixed; inset: 0; background: rgba(6,5,4,.92); display: none; place-items: center; z-index: 20; padding: 24px; }
    .lightbox.open { display: grid; }
    .lightbox img { max-width: min(92vw, 1400px); max-height: 92vh; }
    .spk { display: block; font-size: 11px; color: #f0a35e; }
    .when { display: block; font-size: 10px; opacity: 0.6; margin-bottom: 6px; }
    @media (max-width: 860px) { .epistemic { grid-template-columns: 1fr; } }
    """

    private static let fallbackJS = """
    (() => {
      const box = document.createElement("div");
      box.className = "lightbox";
      box.innerHTML = "<img alt=''>";
      document.body.appendChild(box);
      const img = box.querySelector("img");
      const close = () => box.classList.remove("open");
      box.addEventListener("click", close);
      document.addEventListener("keydown", (event) => {
        if (event.key === "Escape") close();
      });
      document.querySelectorAll("[data-lightbox]").forEach((link) => {
        link.addEventListener("click", (event) => {
          event.preventDefault();
          const href = link.getAttribute("href");
          if (!href) return;
          img.src = href;
          box.classList.add("open");
        });
      });
    })();
    """
}
