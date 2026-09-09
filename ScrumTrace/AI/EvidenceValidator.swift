import Foundation

struct EvidenceIssue: Sendable, Hashable {
    var reason: String
}

enum EvidenceValidator {
    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func quoteMatchesTranscript(_ quote: QuoteRecord, transcript: FullTranscript) -> Bool {
        let needle = normalize(quote.text)
        guard !needle.isEmpty else { return false }
        return transcript.segments.contains { segment in
            segment.end >= quote.tMediaStart
                && segment.start <= quote.tMediaEnd
                && normalize(segment.text).contains(needle)
        }
    }

    /// Model `frame_references` are untrusted strings: basename, `shots/…`, or archive paths.
    static func resolvePath(_ path: String, sessionURL: URL) -> String? {
        let fileManager = FileManager.default
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        var tries: [String] = [
            trimmed,
            ExportRel.sessionPath(trimmed),
            "archive/shots/\(name)",
            "archive/shots/\(stem).png",
            "archive/shots/\(stem).annotated.png",
            "export/shots/\(stem).jpg",
            "export/shots/\(stem).annotated.jpg"
        ]
        if trimmed.hasPrefix("./") {
            tries.insert(String(trimmed.dropFirst(2)), at: 1)
        }
        var seen = Set<String>()
        for rel in tries where seen.insert(rel).inserted {
            if fileManager.fileExists(atPath: sessionURL.appendingPathComponent(rel).path) {
                return rel
            }
        }
        for folder in [ScrumTracePath.shots, ScrumTracePath.mediaWork, ScrumTracePath.exportShots, ScrumTracePath.media] {
            if let match = firstMatch(name: name, stem: stem, in: sessionURL.appendingPathComponent(folder), sessionURL: sessionURL) {
                return match
            }
        }
        return nil
    }

    static func existingPaths(_ paths: [String], sessionURL: URL) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths {
            guard let resolved = resolvePath(path, sessionURL: sessionURL) else { continue }
            if seen.insert(resolved).inserted {
                out.append(resolved)
            }
        }
        return out
    }

    static func canConfirm(
        candidate: CandidateRecord,
        slice: SliceRecord,
        transcript: FullTranscript,
        sessionURL: URL
    ) -> [EvidenceIssue] {
        var issues: [EvidenceIssue] = []
        if candidate.confidence < MediaBudget.keepConfidenceFloor {
            issues.append(EvidenceIssue(reason: "confidence below 0.55"))
        }
        let inferred = normalize(candidate.inferred)
        if !inferred.isEmpty {
            if normalize(candidate.observed) == inferred || normalize(candidate.stated) == inferred {
                issues.append(EvidenceIssue(reason: "inferred copied into observed/stated"))
            }
        }
        let frames = existingPaths(candidate.frameReferences, sessionURL: sessionURL)
        if frames.isEmpty {
            issues.append(EvidenceIssue(reason: "no valid frame_references on disk"))
        }
        for quote in candidate.quotes where !quoteMatchesTranscript(quote, transcript: transcript) {
            issues.append(EvidenceIssue(reason: "quote not found in transcript window"))
        }
        if slice.sliceId.isEmpty {
            issues.append(EvidenceIssue(reason: "missing source_slice_id"))
        }
        if candidate.kind == .unknown {
            issues.append(EvidenceIssue(reason: "unknown task kind"))
        }
        return issues
    }

    /// C5: after projection/omit, `confirmed` requires a real file under `export/`.
    static func applyExportEvidence(tasks: [TaskRecord], sessionURL: URL) -> [TaskRecord] {
        tasks.map { task in
            var copy = task
            copy.evidenceMedia = task.evidenceMedia.filter { path in
                exportFileExists(path, sessionURL: sessionURL)
            }
            if copy.status == .confirmed && copy.evidenceMedia.isEmpty {
                copy.status = .needsReview
            }
            return copy
        }
    }

    static func exportFileExists(_ path: String, sessionURL: URL) -> Bool {
        let session = ExportRel.sessionPath(path)
        guard ExportRel.isUnderExport(session) else { return false }
        return FileManager.default.fileExists(atPath: sessionURL.appendingPathComponent(session).path)
    }

    private static func firstMatch(name: String, stem: String, in root: URL, sessionURL: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let prefix = sessionURL.path.hasSuffix("/") ? sessionURL.path : sessionURL.path + "/"
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if url.lastPathComponent == name || url.deletingPathExtension().lastPathComponent == stem {
                return url.path.replacingOccurrences(of: prefix, with: "")
            }
        }
        return nil
    }
}
