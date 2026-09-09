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

    static func existingPaths(_ paths: [String], sessionURL: URL) -> [String] {
        paths.filter { FileManager.default.fileExists(atPath: sessionURL.appendingPathComponent($0).path) }
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
        return issues
    }
}
