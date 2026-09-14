import Foundation

enum ComparisonReport {
    static func rows(_ manifest: SessionManifest) -> [[String]] {
        manifest.slices.flatMap { slice in
            slice.serviceEvaluations.map { entry in
                [entry.serviceName, entry.model, slice.sliceId, entry.status.rawValue,
                 entry.mediaSent.joined(separator: ", "), entry.inputFingerprint ?? "Legacy — unverified input",
                 entry.diagnostic ?? ""]
            }
        }
    }

    static let explanation = "Each model is evaluated separately on the same prompt, transcript excerpts and up to four JPEG stills. Video is excluded. Matching SHA-256 values identify identical inputs for a slice. Results are not merged or ranked across models. Legacy results without a fingerprint are not verified comparisons."

    static func html(_ manifest: SessionManifest) -> String {
        let values = rows(manifest)
        guard !values.isEmpty else { return "" }
        let headers = ["Service", "Model", "Slice", "Status", "Media", "Input SHA-256", "Detail"]
        let heading = headers.map { "<th scope=\"col\">\(HTMLEscaper.escape($0))</th>" }.joined()
        let body = values.map { row in
            "<tr>" + row.map { "<td style=\"overflow-wrap:anywhere\">\(HTMLEscaper.escape($0))</td>" }.joined() + "</tr>"
        }.joined()
        return "<section class=\"brief-panel\"><h2>Model comparison</h2><p>\(explanation)</p><div style=\"overflow-x:auto\"><table><thead><tr>\(heading)</tr></thead><tbody>\(body)</tbody></table></div></section>"
    }

    static func markdown(_ manifest: SessionManifest) -> String {
        let values = rows(manifest)
        guard !values.isEmpty else { return "" }
        let body = values.map { row in
            row.map { PromptTemplates.wrapUntrustedInline($0).replacingOccurrences(of: "|", with: "&#124;").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ")
        }.joined(separator: "\n")
        return "## Model comparison\n\n\(explanation)\n\nService | Model | Slice | Status | Media | Input SHA-256 | Detail\n--- | --- | --- | --- | --- | --- | ---\n\(body)\n"
    }
}
