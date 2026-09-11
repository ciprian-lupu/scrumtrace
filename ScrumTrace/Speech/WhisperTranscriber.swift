import AVFoundation
import Foundation
import WhisperKit

/// Local WhisperKit CoreML / ANE transcriber.
/// Default: compressed turbo `openai_whisper-large-v3-v20240930_turbo_632MB`.
/// Uncompressed `openai_whisper-large-v3_turbo` is opt-in (multi-GB first download).
final class WhisperTranscriber: @unchecked Sendable {
    static let defaultStoredModel = "large-v3-v20240930_turbo_632MB"
    static let defaultKitModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let uncompressedKitModel = "openai_whisper-large-v3_turbo"
    static let prepareTimeoutSeconds: TimeInterval = 12 * 60

    private var kit: WhisperKit?
    private let lock = NSLock()
    private var preparing: Task<Void, Error>?
    private var ready = false

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func prepare(model: String = WhisperTranscriber.defaultStoredModel) async throws {
        let started = Date()
        let resolved = Self.whisperKitModelName(model)
        let work: Task<Void, Error>
        lock.lock()
        if ready {
            lock.unlock()
            AgentLog.event("whisper_prepare_ok", [
                "model": resolved,
                "reuse": "1",
                "elapsed_ms": "0"
            ])
            return
        }
        if let preparing {
            work = preparing
            lock.unlock()
            AgentLog.event("whisper_prepare_wait", ["model": resolved])
            do {
                try await work.value
                AgentLog.event("whisper_prepare_ok", [
                    "model": resolved,
                    "reuse": "1",
                    "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000))
                ])
                return
            } catch {
                AgentLog.event("whisper_prepare_fail", [
                    "model": resolved,
                    "error": AgentLog.sanitize(error.localizedDescription)
                ])
                throw error
            }
        }
        work = Task.detached {
            AgentLog.event("whisper_prepare_begin", ["model": resolved])
            let config = WhisperKitConfig(
                model: resolved,
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
            AgentLog.event("whisper_prepare_ok", [
                "model": resolved,
                "reuse": "0",
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000))
            ])
        } catch {
            lock.lock()
            if !self.ready {
                preparing = nil
            }
            lock.unlock()
            AgentLog.event("whisper_prepare_fail", [
                "model": resolved,
                "error": AgentLog.sanitize(error.localizedDescription)
            ])
            throw error
        }
    }

    func transcribeFile(at url: URL, sessionURL: URL? = nil) async throws -> FullTranscript {
        let via = sessionURL == nil ? "tmp" : "session"
        let started = Date()
        AgentLog.event("whisper_file_begin", ["via": via])
        do {
            try Self.refuseSymlinkMedia(url, sessionRoot: sessionURL)
            let work: URL
            if let sessionURL {
                guard let rel = ExportRel.unfollowedRelative(url, sessionRoot: sessionURL) else {
                    throw NSError(
                        domain: "ScrumTrace",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Refusing to transcribe a symbolic link."]
                    )
                }
                work = try ExportRel.copyContainedToTemporaryFile(
                    relative: rel,
                    sessionURL: sessionURL,
                    prefix: "scrumtrace-whisper"
                )
            } else {
                // Hold-to-Talk and extracted AAC live under TMPDIR. `/tmp` is a
                // symlink on macOS; copy via O_NOFOLLOW instead of refusing the parent.
                work = try ExportRel.copyUnfollowedToTemporaryFile(
                    url,
                    prefix: "scrumtrace-whisper"
                )
            }
            defer { ExportRel.removePrivateTemporaryURL(work) }
            let local = lockKit()
            guard let local else {
                throw NSError(
                    domain: "ScrumTrace",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Whisper model is not loaded yet."]
                )
            }
            let options = DecodingOptions(wordTimestamps: true)
            let results = try await local.transcribe(audioPath: work.path, decodeOptions: options)
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
            let transcript = FullTranscript(
                sessionId: "",
                language: results.first?.language ?? "en",
                segments: segments
            )
            AgentLog.event("whisper_file_ok", [
                "via": via,
                "segments": String(transcript.segments.count),
                "ms": String(Int(Date().timeIntervalSince(started) * 1000))
            ])
            return transcript
        } catch {
            AgentLog.event("whisper_file_fail", [
                "via": via,
                "error": AgentLog.sanitize(error.localizedDescription)
            ])
            throw error
        }
    }

    func transcribeVoiceNote(at url: URL) async throws -> String {
        let transcript = try await transcribeFile(at: url)
        return transcript.segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// System audio lives in `archive/session.mp4`. Extract AAC, then fall back to the movie path.
    /// Temp AAC is not under the session folder — do not pass `sessionURL` into that transcribe.
    func transcribeMovieAudio(at movie: URL, sessionURL: URL) async throws -> FullTranscript {
        try Self.refuseSymlinkMedia(movie, sessionRoot: sessionURL)
        let movieCopy = try ExportRel.copyContainedToTemporaryFile(
            relative: ScrumTracePath.sessionMovie,
            sessionURL: sessionURL,
            prefix: "scrumtrace-movie"
        )
        defer { ExportRel.removePrivateTemporaryURL(movieCopy) }
        let dest: URL
        do {
            dest = try ExportRel.makePrivateTemporaryURL(prefix: "scrumtrace-system-audio", ext: "m4a")
        } catch {
            AgentLog.event("extract_audio_fail", ["error": "temp_url"])
            return try await transcribeFile(at: movieCopy)
        }
        do {
            try await extractAudio(from: movieCopy, to: dest)
            defer { ExportRel.removePrivateTemporaryURL(dest) }
            return try await transcribeFile(at: dest)
        } catch {
            AgentLog.event("extract_audio_fail", ["error": AgentLog.sanitize(error.localizedDescription)])
            ExportRel.removePrivateTemporaryURL(dest)
            return try await transcribeFile(at: movieCopy)
        }
    }

    func extractAudio(from movie: URL, to dest: URL) async throws {
        // AVAssetExportSession follows a dest symlink. Unlink a planted file
        // or trailing link; do not recurse if the name is a directory.
        ExportRel.unlinkLastComponentUnfollowed(dest)
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
        AgentLog.event("extract_audio_ok", [:])
    }

    private func lockKit() -> WhisperKit? {
        lock.lock()
        defer { lock.unlock() }
        return kit
    }

    private static func refuseSymlinkMedia(_ url: URL, sessionRoot: URL? = nil) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw NSError(
                domain: "ScrumTrace",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to transcribe a symbolic link."]
            )
        }
        // `/tmp` is a symlink on macOS. Hold-to-Talk WAVs live there; do not
        // refuse the parent unless this is a session-tree path.
        if let sessionRoot {
            if ExportRel.parentIsSymbolicLink(url)
                || !ExportRel.isReadableSessionFile(url, sessionRoot: sessionRoot) {
                throw NSError(
                    domain: "ScrumTrace",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Refusing to transcribe a symbolic link."]
                )
            }
        }
    }

    /// Old defaults and the hyphen typo map to the 632 MB compressed turbo.
    /// `large-v3_turbo_uncompressed` keeps `openai_whisper-large-v3_turbo`.
    static func whisperKitModelName(_ requested: String) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "",
             "large-v3_turbo",
             "large-v3-turbo",
             "openai_whisper-large-v3-turbo",
             "openai_whisper-large-v3_turbo",
             "large-v3-v20240930_turbo",
             "openai_whisper-large-v3-v20240930_turbo",
             "large-v3-v20240930_turbo_632MB":
            return defaultKitModel
        case "large-v3_turbo_uncompressed", "uncompressed-large-v3_turbo":
            return uncompressedKitModel
        default:
            if trimmed.hasPrefix("openai_whisper-") || trimmed.hasPrefix("distil-whisper_") {
                return trimmed
            }
            return "openai_whisper-\(trimmed)"
        }
    }
}

enum TranscriptQuery {
    struct SourcePass: Sendable {
        var speaker: String
        var transcript: FullTranscript
        var offsetSeconds: TimeInterval = 0
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
                if pass.offsetSeconds != 0 {
                    copy.start += pass.offsetSeconds
                    copy.end += pass.offsetSeconds
                    copy.words = copy.words.map { word in
                        var shifted = word
                        shifted.start += pass.offsetSeconds
                        shifted.end += pass.offsetSeconds
                        return shifted
                    }
                }
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
