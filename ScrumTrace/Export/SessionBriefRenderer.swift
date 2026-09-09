import Foundation

enum BriefTemplateLoader {
    static func text(_ name: String, ext: String) -> String {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
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
        let css = BriefTemplateLoader.text("brief", ext: "css")
        let js = BriefTemplateLoader.text("brief", ext: "js")
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
            "{{REVIEW_COUNT}}": "\(review.count)"
        ]
        var html = shell
        for (token, value) in replacements {
            html = html.replacingOccurrences(of: token, with: value)
        }
        return html
    }

    private func taskCard(_ task: TaskRecord, excerpts: [String: String]) -> String {
        let media = task.evidenceMedia.map { path -> String in
            if path.hasSuffix(".mp4") {
                return """
                <video class="clip" controls preload="metadata" src="\(HTMLEscaper.escape(path))"></video>
                """
            }
            return """
            <a class="still" href="\(HTMLEscaper.escape(path))" data-lightbox>
              <img src="\(HTMLEscaper.escape(path))" alt="\(HTMLEscaper.escape(task.title))">
            </a>
            """
        }.joined()
        let quotes = task.quotes.map { quote in
            "<blockquote><span class=\"spk\">\(HTMLEscaper.escape(quote.speaker))</span>\(HTMLEscaper.escape(quote.text))</blockquote>"
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
        manifest.shots.map { shot in
            let path = shot.annotatedPath ?? shot.rawPath
            return """
            <figure>
              <a href="\(HTMLEscaper.escape(path))" data-lightbox>
                <img src="\(HTMLEscaper.escape(path))" alt="\(HTMLEscaper.escape(shot.note))">
              </a>
              <figcaption>\(HTMLEscaper.escape(shot.id)) · \(Self.clock(shot.tMedia)) · \(HTMLEscaper.escape(shot.note))</figcaption>
            </figure>
            """
        }.joined()
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

    private static let fallbackShell = """
    <!doctype html><html><head><meta charset="utf-8"><style>{{CSS}}</style></head>
    <body><main>{{TASKS_HTML}}</main><script>{{JS}}</script></body></html>
    """
}
