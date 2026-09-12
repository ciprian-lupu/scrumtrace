import Foundation

struct SpeakerInterval: Codable, Sendable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var speakerID: String
}

enum SpeakerAttribution: String, Codable, Sendable {
    case estimated, manual, overlap, uncertain, sourceOnly
}

struct SessionSpeaker: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var source: String
    var label: String
    /// A name entered by the user for this session, never inferred from biometrics.
    var name: String? = nil
    var displayName: String { name?.isEmpty == false ? name! : label }
}

struct SpeakerAnalysis: Codable, Sendable, Hashable {
    var source: String
    var status: String
    var method: String = "FluidAudio 0.15.7 · offline community-1"
}

enum SpeakerTimeline {
    static func load(sessionURL: URL) -> FullTranscript? {
        guard let data = ExportRel.readContainedData(relative: ScrumTracePath.fullTranscript, sessionURL: sessionURL) else { return nil }
        return try? JSONDecoder().decode(FullTranscript.self, from: data)
    }

    static func save(_ transcript: FullTranscript, sessionURL: URL) throws {
        try ExportRel.writeContainedData(JSONEncoder().encode(transcript), relative: ScrumTracePath.fullTranscript, sessionURL: sessionURL)
    }

    static func source(of segment: TranscriptSegment) -> String? {
        if let source = segment.source { return source }
        if segment.speaker == "room" || segment.speaker == "system" { return segment.speaker }
        return nil
    }

    static func displaySpeaker(_ segment: TranscriptSegment, in transcript: FullTranscript) -> String {
        let names = (transcript.speakers ?? []).reduce(into: [String: String]()) { $0[$1.id] = $1.displayName }
        if segment.speakerAttribution == .overlap {
            let labels = (segment.speakerCandidates ?? []).compactMap { names[$0] }
            return labels.isEmpty ? "Overlapping voices" : "Overlapping voices: " + labels.joined(separator: " + ")
        }
        if let id = segment.speaker, let name = names[id] { return name + (segment.speakerAttribution == .manual ? " · reviewed" : " · estimated") }
        switch source(of: segment) {
        case "room": return "Room microphone · speaker unclear"
        case "system": return "System audio · speaker unclear"
        case "mixed": return "Room + call audio · source unclear (possible echo)"
        default: return "Speaker unclear"
        }
    }

    /// Word boundaries prevent assigning a whole Whisper sentence to the speaker
    /// who merely occupied most of it. Overlap remains ambiguous: one word is not
    /// duplicated as if both people said it.
    static func assigning(_ transcript: FullTranscript, intervals: [SpeakerInterval], source: String) -> FullTranscript {
        let valid = intervals.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && !$0.speakerID.isEmpty }
            .sorted { $0.start == $1.start ? $0.speakerID < $1.speakerID : $0.start < $1.start }
        var identities: [String: String] = [:]
        var profiles = (transcript.speakers ?? []).filter { $0.source != source }
        for interval in valid where identities[interval.speakerID] == nil {
            let number = identities.count + 1
            let id = "\(source)_speaker_\(number)"
            identities[interval.speakerID] = id
            profiles.append(SessionSpeaker(id: id, source: source, label: "\(source == "room" ? "Room" : "Call") · Speaker \(number)"))
        }
        let mapped = valid.map { SpeakerInterval(start: $0.start, end: $0.end, speakerID: identities[$0.speakerID]!) }
        var output: [TranscriptSegment] = []
        for segment in transcript.segments {
            guard self.source(of: segment) == source else { output.append(segment); continue }
            let words = segment.words.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            if words.isEmpty {
                var copy = segment
                let match = attribution(start: segment.start, end: segment.end, intervals: mapped)
                apply(match, to: &copy, source: source)
                output.append(copy)
                continue
            }
            var pending: TranscriptSegment?
            for word in words {
                let match = attribution(start: word.start, end: word.end, intervals: mapped)
                if var previous = pending, previous.speaker == match.0,
                   previous.speakerAttribution == match.1, previous.speakerCandidates == match.2,
                   word.start - previous.end < 0.8 {
                    previous.end = max(previous.end, word.end)
                    previous.words.append(word)
                    previous.text = joinedWords(previous.words)
                    pending = previous
                } else {
                    if let pending { output.append(pending) }
                    var next = TranscriptSegment(start: word.start, end: word.end, text: word.text.trimmingCharacters(in: .whitespacesAndNewlines), speaker: nil, words: [word])
                    apply(match, to: &next, source: source)
                    pending = next
                }
            }
            if let pending { output.append(pending) }
        }
        var result = transcript
        result.segments = output.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        result.speakers = profiles
        return result
    }

    private static func apply(_ match: (String?, SpeakerAttribution, [String]?), to segment: inout TranscriptSegment, source: String) {
        segment.source = source
        segment.speaker = match.0
        segment.speakerAttribution = match.1
        segment.speakerCandidates = match.2
    }

    private static func attribution(start: Double, end: Double, intervals: [SpeakerInterval]) -> (String?, SpeakerAttribution, [String]?) {
        guard start.isFinite, end.isFinite, end > start else { return (nil, .uncertain, nil) }
        let duration = end - start
        let hits = intervals.filter { min(end, $0.end) - max(start, $0.start) > 0 }
        var coverage: [String: Double] = [:]
        // Union intervals from the same voice; overlapping SDK windows must
        // not count twice and turn an uncertain word into a confident label.
        for (speaker, windows) in Dictionary(grouping: hits, by: \.speakerID) {
            var coveredEnd = start
            for window in windows.sorted(by: { $0.start < $1.start }) {
                let lower = max(start, max(coveredEnd, window.start))
                let upper = min(end, window.end)
                coverage[speaker, default: 0] += max(0, upper - lower)
                coveredEnd = max(coveredEnd, upper)
            }
        }
        let ranked = coverage.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let first = ranked.first, first.value / duration >= 0.6 else { return (nil, .uncertain, nil) }
        let contenders = ranked.filter { $0.value / duration >= 0.25 }.map(\.key).sorted()
        if contenders.count > 1 {
            let simultaneous = hits.contains { a in hits.contains { b in
                a.speakerID != b.speakerID && min(end, min(a.end, b.end)) - max(start, max(a.start, b.start)) > min(0.05, duration * 0.2)
            } }
            return (nil, simultaneous ? .overlap : .uncertain, contenders)
        }
        return (first.key, .estimated, nil)
    }

    static func joinedWords(_ words: [TranscriptWord]) -> String {
        // Whisper normally supplies leading spaces. Preserve punctuation, and
        // also support imported word lists that contain plain tokens.
        var result = ""
        for word in words {
            if !result.isEmpty, let first = word.text.first, !first.isWhitespace,
               !",.!?:;)]}".contains(first), let last = result.last, !last.isWhitespace {
                result += " "
            }
            result += word.text
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Export only the selected window. Word timestamps prevent a boundary
    /// sentence from disclosing speech outside the selected clip.
    static func turns(in transcript: FullTranscript, start: Double, end: Double) -> [TranscriptSegment] {
        transcript.segments.compactMap { segment in
            guard segment.end > start, segment.start < end else { return nil }
            var copy = segment
            if segment.start < start || segment.end > end {
                let words = segment.words.filter { $0.start >= start && $0.end <= end }
                guard !words.isEmpty else { return nil }
                copy.words = words
                copy.text = joinedWords(words)
                copy.start = words.first!.start
                copy.end = words.last!.end
            }
            return copy
        }
    }

    static func quoteSpeaker(_ quote: QuoteRecord, transcript: FullTranscript) -> String {
        let text = EvidenceValidator.normalize(quote.text)
        guard !text.isEmpty else { return "Speaker unclear" }
        let matches = transcript.segments.filter {
            !EvidenceValidator.normalize($0.text).isEmpty && $0.end > quote.tMediaStart && $0.start < quote.tMediaEnd
                && (EvidenceValidator.normalize($0.text).contains(text) || text.contains(EvidenceValidator.normalize($0.text)))
        }
        guard !matches.isEmpty else { return "Speaker unclear" }
        let names = Set(matches.map { displaySpeaker($0, in: transcript) })
        return names.count == 1 ? names.first! : "Multiple or unclear speakers"
    }

    static func correcting(_ assignments: [Int: String], in transcript: FullTranscript) throws -> FullTranscript {
        var output = transcript
        for (index, id) in assignments {
            guard output.segments.indices.contains(index) else { throw SettingsValidationError("This transcript changed. Reopen speaker review.") }
            if id == "unclear" {
                output.segments[index].speaker = nil
                output.segments[index].speakerAttribution = .uncertain
            } else {
                guard let profile = transcript.speakers?.first(where: { $0.id == id }),
                      profile.source == source(of: output.segments[index]) else {
                    throw SettingsValidationError("Choose a speaker from the same audio source.")
                }
                output.segments[index].speaker = id
                output.segments[index].speakerAttribution = .manual
            }
            output.segments[index].speakerCandidates = nil
        }
        return output
    }

    static func names(_ names: [String: String], appliedTo transcript: FullTranscript) -> FullTranscript {
        var copy = transcript
        copy.speakers = transcript.speakers?.map { speaker in
            var next = speaker
            if let name = names[speaker.id] {
                let cleaned = name.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                next.name = cleaned.isEmpty ? nil : String(cleaned.prefix(80))
            }
            return next
        }
        return copy
    }
}
