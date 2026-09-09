import AVFoundation
import Foundation
import WhisperKit

/// Local WhisperKit CoreML / ANE transcriber. Model: large-v3-turbo
/// (`openai_whisper-large-v3-turbo`).
final class WhisperTranscriber: @unchecked Sendable {
    private var kit: WhisperKit?
    private let lock = NSLock()
    private var preparing: Task<Void, Error>?
    private var ready = false

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func prepare(model: String = "large-v3-turbo") async throws {
        let work: Task<Void, Error>
        lock.lock()
        if ready {
            lock.unlock()
            return
        }
        if let preparing {
            work = preparing
            lock.unlock()
            try await work.value
            return
        }
        work = Task {
            let config = WhisperKitConfig(
                model: Self.whisperKitModelName(model),
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            let loaded = try await WhisperKit(config)
            self.lock.lock()
            self.kit = loaded
            self.ready = true
            self.lock.unlock()
        }
        preparing = work
        lock.unlock()
        do {
            try await work.value
        } catch {
            lock.lock()
            if !self.ready {
                preparing = nil
            }
            lock.unlock()
            throw error
        }
    }

    func transcribeFile(at url: URL) async throws -> FullTranscript {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw NSError(
                domain: "ScrumTrace",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to transcribe a symbolic link."]
            )
        }
        let local = lockKit()
        guard let local else {
            throw NSError(
                domain: "ScrumTrace",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model is not loaded yet."]
            )
        }
        let options = DecodingOptions(wordTimestamps: true)
        let results = try await local.transcribe(audioPath: url.path, decodeOptions: options)
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

    /// System audio lives in `archive/session.mp4`. Extract AAC, then fall back to the movie path.
    func transcribeMovieAudio(at movie: URL) async throws -> FullTranscript {
        if (try? movie.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw NSError(
                domain: "ScrumTrace",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to transcribe a symbolic link."]
            )
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scrumtrace-system-audio-\(UUID().uuidString).m4a"
        )
        do {
            try await extractAudio(from: movie, to: dest)
            defer { try? FileManager.default.removeItem(at: dest) }
            return try await transcribeFile(at: dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            return try await transcribeFile(at: movie)
        }
    }

    func extractAudio(from movie: URL, to dest: URL) async throws {
        try? FileManager.default.removeItem(at: dest)
        let asset = AVURLAsset(url: movie)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(
                domain: "ScrumTrace",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot extract system audio from the session movie."]
            )
        }
        session.outputURL = dest
        session.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw session.error ?? NSError(
                domain: "ScrumTrace",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "System-audio extract from session.mp4 failed."]
            )
        }
    }

    private func lockKit() -> WhisperKit? {
        lock.lock()
        defer { lock.unlock() }
        return kit
    }

    /// Spec model is `large-v3-turbo`; WhisperKit downloads `openai_whisper-large-v3-turbo`.
    static func whisperKitModelName(_ requested: String) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "openai_whisper-large-v3-turbo"
        }
        if trimmed.hasPrefix("openai_whisper-") || trimmed.hasPrefix("distil-whisper_") {
            return trimmed
        }
        return "openai_whisper-\(trimmed)"
    }
}

enum TranscriptQuery {
    struct SourcePass: Sendable {
        var speaker: String
        var transcript: FullTranscript
    }

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

    /// Merge room-mic and system-audio passes on `t_media`. Near-duplicate overlapping
    /// segments (mic bleed of the same system speech) collapse; distinct speech is kept.
    static func merge(_ passes: [SourcePass], sessionId: String) -> FullTranscript {
        var labeled: [TranscriptSegment] = []
        var language = "en"
        var sources: [String] = []
        for pass in passes {
            if !pass.transcript.language.isEmpty {
                language = pass.transcript.language
            }
            if !pass.speaker.isEmpty {
                sources.append(pass.speaker)
            }
            for segment in pass.transcript.segments where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var copy = segment
                if copy.speaker == nil || copy.speaker?.isEmpty == true {
                    copy.speaker = pass.speaker
                }
                labeled.append(copy)
            }
        }
        labeled.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
        var seen = Set<String>()
        let uniqueSources = sources.filter { seen.insert($0).inserted }
        return FullTranscript(
            sessionId: sessionId,
            language: language,
            segments: collapseDuplicates(labeled),
            sources: uniqueSources
        )
    }

    static func overlapFraction(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Double {
        let start = max(a.start, b.start)
        let end = min(a.end, b.end)
        let overlap = max(0, end - start)
        let shorter = max(0.001, min(a.end - a.start, b.end - b.start))
        return overlap / shorter
    }

    static func similarText(_ a: String, _ b: String) -> Bool {
        let na = EvidenceValidator.normalize(a)
        let nb = EvidenceValidator.normalize(b)
        if na.isEmpty || nb.isEmpty { return false }
        if na == nb { return true }
        if na.contains(nb) || nb.contains(na) { return true }
        let sa = Set(na.split(separator: " ").map(String.init))
        let sb = Set(nb.split(separator: " ").map(String.init))
        let union = sa.union(sb).count
        guard union > 0 else { return false }
        return Double(sa.intersection(sb).count) / Double(union) >= 0.75
    }

    static func collapseDuplicates(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            if let lastIndex = result.indices.last,
               overlapFraction(result[lastIndex], segment) >= 0.5,
               similarText(result[lastIndex].text, segment.text) {
                var merged = result[lastIndex]
                merged.start = min(merged.start, segment.start)
                merged.end = max(merged.end, segment.end)
                if segment.text.count > merged.text.count {
                    merged.text = segment.text
                    if segment.words.count >= merged.words.count {
                        merged.words = segment.words
                    }
                }
                if let left = merged.speaker, let right = segment.speaker, left != right {
                    if !left.contains(right) && !right.contains(left) {
                        merged.speaker = "\(left)+\(right)"
                    }
                }
                result[lastIndex] = merged
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
