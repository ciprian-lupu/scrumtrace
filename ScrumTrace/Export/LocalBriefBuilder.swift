import CryptoKit
import Foundation

/// Builds the default local outline from the selected evidence only. It does
/// not paraphrase speech, infer visual facts, or call any provider.
struct LocalBriefBuilder {
    static let maxSections = 12
    static let maxPassagesPerSection = 2
    static let maxSectionScalars = 700
    static let maxSelectedScalars = 12_000
    static let maxEncodedBytes = 64 * 1024

    func build(manifest: SessionManifest, transcript: FullTranscript) -> HandoffBrief {
        let ordered = manifest.slices.sorted {
            $0.startMedia == $1.startMedia ? $0.sliceId < $1.sliceId : $0.startMedia < $1.startMedia
        }
        var sections: [HandoffSection] = []
        var passages: [HandoffPassage] = []
        var selectedScalars = 0
        for slice in ordered.prefix(Self.maxSections) {
            let linkedShots = manifest.shots.filter { shot in
                shot.id == slice.associatedShotId || (shot.tMedia >= slice.startMedia && shot.tMedia <= slice.endMedia)
            }
            let turns = SpeakerTimeline.turns(in: transcript, start: slice.startMedia, end: slice.endMedia)
            var ids: [String] = []
            for turn in turns where ids.count < Self.maxPassagesPerSection {
                guard let text = boundedPassage(turn.text, remaining: Self.maxSelectedScalars - selectedScalars) else { continue }
                let count = text.unicodeScalars.count
                guard selectedScalars + count <= Self.maxSelectedScalars else { continue }
                let id = String(format: "passage-%02d-%02d", sections.count + 1, ids.count + 1)
                passages.append(HandoffPassage(
                    id: id,
                    text: text,
                    startMedia: max(slice.startMedia, turn.start),
                    endMedia: min(slice.endMedia, turn.end),
                    source: sourceLabel(turn),
                    uncertain: turn.speakerAttribution == .uncertain || turn.speakerAttribution == .overlap || turn.source == "mixed",
                    sliceIDs: [slice.sliceId],
                    shotIDs: linkedShots.map(\.id),
                    evidenceMedia: [],
                    evidenceState: .transcriptOnly
                ))
                selectedScalars += count
                ids.append(id)
            }
            let note = linkedShots.first(where: { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.note
            guard !ids.isEmpty || note != nil else { continue }
            let title = boundedTitle(note ?? passages.first(where: { ids.contains($0.id) })?.text ?? "Selected recording passage")
            let state: HandoffEvidenceState = ids.isEmpty ? .noteOnly : .transcriptOnly
            sections.append(HandoffSection(
                id: String(format: "section-%02d", sections.count + 1),
                title: title,
                startMedia: slice.startMedia,
                endMedia: slice.endMedia,
                passageIDs: ids,
                sliceIDs: [slice.sliceId],
                shotIDs: linkedShots.map(\.id),
                evidenceState: state
            ))
        }
        var brief = HandoffBrief(
            selectionVersion: HandoffBrief.selectionVersion,
            briefVersion: HandoffBrief.briefVersion,
            selective: true,
            sections: sections,
            passages: passages,
            evaluationDiagnostic: evaluationDiagnostic(manifest)
        )
        // Codable byte count is the final disclosure guard, rather than an
        // estimate based on Swift character counts.
        while (try? JSONEncoder().encode(brief).count) ?? 0 > Self.maxEncodedBytes {
            guard let section = brief.sections.popLast() else { break }
            let removed = Set(section.passageIDs)
            brief.passages.removeAll { removed.contains($0.id) }
        }
        return brief
    }

    /// Keep an input identity only in the canonical manifest. It is not an
    /// export API and must be cleared by projection before handing files off.
    func generation(manifest: SessionManifest, transcript: FullTranscript) -> LocalExportGeneration {
        let source = transcript.segments.map { segment in
            "\(segment.start)|\(segment.end)|\(segment.source ?? "")|\(segment.text)"
        }.joined(separator: "\n")
        let selection = manifest.slices.map { slice in
            "\(slice.sliceId)|\(slice.startMedia)|\(slice.endMedia)|\(slice.associatedShotId ?? "")"
        }.joined(separator: "\n")
        let notes = manifest.shots.map { shot in "\(shot.id)|\(shot.tMedia)|\(shot.note)" }.joined(separator: "\n")
        let payload = Data((source + "\n--selection--\n" + selection + "\n--shots--\n" + notes).utf8)
        let fingerprint = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return LocalExportGeneration(
            selectionVersion: HandoffBrief.selectionVersion,
            briefVersion: HandoffBrief.briefVersion,
            privateInputFingerprint: fingerprint,
            rebuiltAt: Date()
        )
    }

    private func sourceLabel(_ segment: TranscriptSegment) -> String {
        let source = segment.source?.lowercased() ?? "unclear"
        return ["room", "system", "mixed"].contains(source) ? source : "unclear"
    }

    private func boundedPassage(_ raw: String, remaining: Int) -> String? {
        let cleaned = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        let cap = min(Self.maxSectionScalars, remaining)
        guard cleaned.unicodeScalars.count <= cap else {
            // Do not cut a command, URL, number, or negation midway. A whole
            // sentence is selected only when it fits the disclosure contract.
            let sentences = cleaned.split(whereSeparator: { ".!?".contains($0) })
            return sentences.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty && $0.unicodeScalars.count <= cap })
        }
        return cleaned
    }

    private func boundedTitle(_ raw: String) -> String {
        let cleaned = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard cleaned.unicodeScalars.count > 100 else { return cleaned }
        let words = cleaned.split(separator: " ")
        var result = ""
        for word in words {
            let candidate = result.isEmpty ? String(word) : result + " " + word
            guard candidate.unicodeScalars.count <= 97 else { break }
            result = candidate
        }
        return result.isEmpty ? "Selected recording passage" : result + "…"
    }

    private func evaluationDiagnostic(_ manifest: SessionManifest) -> String? {
        if !manifest.uploadConsent.approved { return "consent_not_approved" }
        if manifest.slices.isEmpty { return "source_unavailable" }
        if manifest.slices.contains(where: { $0.analysisStatus == .offlineFailed }) { return "provider_failure" }
        if manifest.slices.allSatisfy({ $0.analysisStatus == .skipped }) { return "no_service_or_missing_key" }
        return nil
    }
}
