import Foundation
import WhisperKit

/// Local WhisperKit CoreML / ANE transcriber. Model: large-v3-turbo
/// (`openai_whisper-large-v3-turbo`).
final class WhisperTranscriber: @unchecked Sendable {
    private var kit: WhisperKit?
    private let lock = NSLock()
    private(set) var isReady = false

    func prepare(model: String = "large-v3-turbo") async throws {
        let config = WhisperKitConfig(
            model: model,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        let loaded = try await WhisperKit(config)
        lock.lock()
        kit = loaded
        isReady = true
        lock.unlock()
    }

    func transcribeFile(at url: URL) async throws -> FullTranscript {
        let local = lockKit()
        guard let local else {
            throw NSError(
                domain: "ScrumTrace",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model is not loaded yet."]
            )
        }
        let results = try await local.transcribe(audioPath: url.path)
        var segments: [TranscriptSegment] = []
        for result in results {
            for segment in result.segments {
                let words = (segment.words ?? []).map { word in
                    TranscriptWord(start: TimeInterval(word.start), end: TimeInterval(word.end), text: word.word)
                }
                segments.append(
                    TranscriptSegment(
                        start: TimeInterval(segment.start),
                        end: TimeInterval(segment.end),
                        text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        speaker: nil,
                        words: words
                    )
                )
            }
        }
        return FullTranscript(sessionId: "", language: results.first?.language ?? "en", segments: segments)
    }

    func transcribeVoiceNote(at url: URL) async throws -> String {
        let transcript = try await transcribeFile(at: url)
        return transcript.segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lockKit() -> WhisperKit? {
        lock.lock()
        defer { lock.unlock() }
        return kit
    }
}

enum TranscriptQuery {
    static func excerpt(from transcript: FullTranscript, start: TimeInterval, end: TimeInterval) -> String {
        transcript.segments
            .filter { $0.end >= start && $0.start <= end }
            .map(\.text)
            .joined(separator: " ")
    }

    static func keywordHits(in transcript: FullTranscript) -> [TimeInterval] {
        let keywords = [
            "bug", "broken", "doesn't work", "does not work", "should",
            "decision", "action item", "let's", "fix", "regression",
            "ship", "blocker", "todo"
        ]
        var hits: [TimeInterval] = []
        for segment in transcript.segments {
            let lowered = segment.text.lowercased()
            if keywords.contains(where: { lowered.contains($0) }) {
                hits.append((segment.start + segment.end) / 2)
            }
        }
        return hits
    }
}
