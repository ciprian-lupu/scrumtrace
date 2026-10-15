import AVFoundation
import Foundation
import WhisperKit

/// The same local choice is used by preload, readiness, voice notes and processing.
struct LocalSpeechTarget: Equatable, Sendable {
    var model: String
    var source: WhisperModelSource = .standard
    var language: SpeechLanguage = .automatic

    init(model: String, source: WhisperModelSource = .standard, language: SpeechLanguage = .automatic) {
        self.model = model
        self.source = source
        self.language = language
    }

    init(service: SavedTranscriptionService) {
        model = service.model
        source = service.whisperSource ?? .standard
        language = service.language.mode == .single && service.language.languages.count == 1
            ? service.language.languages[0] : .automatic
    }
}

/// Local WhisperKit CoreML / ANE transcriber.
/// Default: compressed turbo `openai_whisper-large-v3-v20240930_turbo_632MB`.
/// Uncompressed `openai_whisper-large-v3_turbo` is opt-in (multi-GB first download).
final class WhisperTranscriber: @unchecked Sendable {
    static let defaultStoredModel = "large-v3-v20240930_turbo_632MB"
    static let defaultKitModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let uncompressedKitModel = "openai_whisper-large-v3_turbo"
    static let prepareTimeoutSeconds: TimeInterval = 12 * 60

    /// WhisperKit's default download base is `~/Documents/huggingface`, which
    /// raises a Documents-folder TCC prompt seconds into the first recording
    /// (and syncs the model into iCloud Drive). Keep models in Application Support.
    static var modelDownloadBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("ScrumTrace/whisperkit", isDirectory: true)
    }

    struct LoadedModel: @unchecked Sendable {
        var transcribe: (String, DecodingOptions) async throws -> [TranscriptionResult]
        /// `WhisperKit.progress.fractionCompleted` of the decode in flight, read fresh each call because WhisperKit
        /// replaces its `progress` per transcription. Nil when the loader keeps no figure (test fakes).
        var fraction: @Sendable () -> Double?

        init(
            transcribe: @escaping (String, DecodingOptions) async throws -> [TranscriptionResult],
            fraction: @escaping @Sendable () -> Double? = { nil }
        ) {
            self.transcribe = transcribe
            self.fraction = fraction
        }
    }

    /// Seconds of audio decoded so far and the audio's total seconds, from a background queue, at most twice a second.
    typealias ProgressSink = @Sendable (_ doneSeconds: Double, _ totalSeconds: Double) -> Void

    private var kit: LoadedModel?
    private let loadModel: (@Sendable (String) async throws -> LoadedModel)?
    private let loadModelWithSource: (@Sendable (String, WhisperModelSource) async throws -> LoadedModel)?
    let progressReporter = ProcessingProgressReporter()
    private let lock = NSLock()
    private var preparing: (id: UUID, model: String, task: Task<Void, Error>)?
    private var ready = false
    private var loadedModel: String?
    private var language: SpeechLanguage = .automatic
    /// Receives the wall seconds of every load this transcriber started itself (not one it only waited for).
    private var modelLoadSink: (@Sendable (TimeInterval) -> Void)?

    init(loadModel: (@Sendable (String) async throws -> LoadedModel)? = nil) {
        self.loadModel = loadModel
        self.loadModelWithSource = nil
    }

    init(loadModelWithSource: @escaping @Sendable (String, WhisperModelSource) async throws -> LoadedModel) {
        self.loadModel = nil
        self.loadModelWithSource = loadModelWithSource
    }

    var isReady: Bool { withStateLock { ready } }
    var loadedModelName: String? { withStateLock { loadedModel } }
    var isPreparing: Bool { withStateLock { preparing != nil } }

    /// The processing panel's measured history records every load this process started.
    func setModelLoadSink(_ sink: (@Sendable (TimeInterval) -> Void)?) {
        withStateLock { modelLoadSink = sink }
    }

    private static func modelKey(_ model: String, source: WhisperModelSource) -> String {
        "\(whisperKitModelName(model))|\(source.value ?? "standard")|\(source.title)"
    }

    func isReady(for model: String, source: WhisperModelSource = .standard) -> Bool {
        let key = Self.modelKey(model, source: source)
        return withStateLock { ready && loadedModel == key }
    }

    func isReady(for target: LocalSpeechTarget) -> Bool {
        isReady(for: target.model, source: target.source)
    }

    func prepare(target: LocalSpeechTarget) async throws {
        setLanguage(target.language)
        try await prepare(model: target.model, source: target.source)
    }

    /// Call at the start of a recording or analysis. In-flight decodes keep their snapshot.
    func setLanguage(_ language: SpeechLanguage) {
        withStateLock { self.language = language }
    }

    static func decodingOptions(language: SpeechLanguage) -> DecodingOptions {
        DecodingOptions(
            language: language.code,
            // WhisperKit 0.11's multilingual prefill cache can return empty
            // 30-second windows with the compressed turbo model. Build the
            // prompt for each decode; verified against the same recorded audio.
            usePrefillCache: false,
            detectLanguage: language == .automatic,
            skipSpecialTokens: true,
            wordTimestamps: true
        )
    }

    func prepare(model: String = WhisperTranscriber.defaultStoredModel, source: WhisperModelSource = .standard) async throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsValidationError("Choose a speech model before loading it.")
        }
        try source.validated()
        let started = Date()
        let resolved = Self.whisperKitModelName(model)
        let cacheKey = Self.modelKey(model, source: source)
        while true {
            let action = preparationAction(resolved: cacheKey, model: resolved, source: source)
            switch action {
            case .ready:
                AgentLog.event("whisper_prepare_ok", ["model": resolved, "reuse": "1", "elapsed_ms": "0"])
                return
            case .wait(let pendingKey, let work):
                AgentLog.event("whisper_prepare_wait", ["model": resolved])
                // The load is a detached task that keeps running when this caller is cancelled (Finish later):
                // only the wait ends, and the next caller for the same model and source reuses the load.
                do { try await CancellableAwait.value(of: work) }
                catch is CancellationError { throw CancellationError() }
                catch { if pendingKey == cacheKey { throw error } }
                // Another model may have been loading. Re-evaluate the requested model.
                try Task.checkCancellation()
            case .start(let work):
                do {
                    try await CancellableAwait.value(of: work)
                    let elapsed = Date().timeIntervalSince(started)
                    AgentLog.event("whisper_prepare_ok", [
                        "model": resolved, "reuse": "0",
                        "elapsed_ms": String(Int(elapsed * 1000))
                    ])
                    withStateLock { modelLoadSink }?(elapsed)
                    return
                } catch is CancellationError {
                    // The load goes on without this caller; its own success or failure is logged when it ends.
                    throw CancellationError()
                } catch {
                    AgentLog.event("whisper_prepare_fail", ["model": resolved, "error": AgentLog.sanitize(error.localizedDescription)])
                    throw error
                }
            }
        }
    }

    private enum PreparationAction {
        case ready
        case wait(String, Task<Void, Error>)
        case start(Task<Void, Error>)
    }

    private func preparationAction(resolved: String, model: String, source: WhisperModelSource) -> PreparationAction {
        withStateLock {
            if let preparing { return .wait(preparing.model, preparing.task) }
            if ready, loadedModel == resolved { return .ready }
            let id = UUID()
            let work = Task.detached {
                let activity = self.progressReporter.begin("Preparing speech model…")
                defer { self.progressReporter.end(activity) }
                AgentLog.event("whisper_prepare_begin", ["model": resolved])
                do {
                    let loaded: LoadedModel
                    if let loadModelWithSource = self.loadModelWithSource {
                        loaded = try await loadModelWithSource(model, source)
                    } else if case .standard = source, let loadModel = self.loadModel {
                        loaded = try await loadModel(model)
                    } else {
                        loaded = try await Self.loadWhisperKit(model, source: source, reporter: self.progressReporter)
                    }
                    self.withStateLock {
                        self.kit = loaded
                        self.ready = true
                        self.loadedModel = resolved
                        if self.preparing?.id == id { self.preparing = nil }
                    }
                } catch {
                    self.withStateLock {
                        if self.preparing?.id == id { self.preparing = nil }
                    }
                    throw error
                }
            }
            preparing = (id, resolved, work)
            return .start(work)
        }
    }

    private static func loadWhisperKit(_ resolved: String, source: WhisperModelSource = .standard, reporter: ProcessingProgressReporter) async throws -> LoadedModel {
        let downloadBase = Self.modelDownloadBase
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let folder: String
        let tokenizerFolder: URL?
        switch source {
        case .standard:
            folder = try await downloadModel(resolved, repository: "argmaxinc/whisperkit-coreml", reporter: reporter).path
            tokenizerFolder = nil
        case .repository(let repository):
            folder = try await downloadModel(resolved, repository: repository, reporter: reporter).path
            tokenizerFolder = nil
        case .folder(let path):
            folder = path
            tokenizerFolder = URL(fileURLWithPath: path)
        }
        let config = WhisperKitConfig(model: resolved, modelFolder: folder, tokenizerFolder: tokenizerFolder,
                                      verbose: false, logLevel: .error, prewarm: false, load: false, download: false)
        let loaded = try await WhisperKit(config)
        let prewarmStarted = Date()
        let prewarm = reporter.begin("Preparing speech model for this Mac…")
        do { try await loaded.prewarmModels() }
        catch { reporter.end(prewarm); throw error }
        reporter.end(prewarm)
        AgentLog.event("whisper_model_phase", ["phase": "prewarm", "elapsed_ms": String(Int(Date().timeIntervalSince(prewarmStarted) * 1000))])
        let loadStarted = Date()
        let loading = reporter.begin("Loading speech model…")
        do { try await loaded.loadModels() }
        catch { reporter.end(loading); throw error }
        reporter.end(loading)
        AgentLog.event("whisper_model_phase", ["phase": "load", "elapsed_ms": String(Int(Date().timeIntervalSince(loadStarted) * 1000))])
        return LoadedModel(
            transcribe: { path, options in
                try await loaded.transcribe(audioPath: path, decodeOptions: options)
            },
            fraction: {
                let progress = loaded.progress
                return progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            }
        )
    }

    private static func downloadModel(_ model: String, repository: String, reporter: ProcessingProgressReporter) async throws -> URL {
        let activity = reporter.begin("Downloading speech model (cached files are reused)…")
        defer { reporter.end(activity) }
        return try await WhisperKit.download(variant: model, downloadBase: modelDownloadBase, from: repository) { progress in
            guard progress.totalUnitCount > 0 else { return }
            reporter.update(activity, fraction: progress.fractionCompleted)
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func transcribeFile(at url: URL, sessionURL: URL? = nil, onProgress: ProgressSink? = nil) async throws -> FullTranscript {
        let via = sessionURL == nil ? "tmp" : "session"
        let started = Date()
        let preparation = progressReporter.begin("Preparing audio for transcription…")
        defer { progressReporter.end(preparation) }
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
            if (try? SpeechSignal.isDigitalSilence(work)) == true {
                AgentLog.event("whisper_silence_skipped", ["via": via])
                return FullTranscript(sessionId: "", language: withStateLock { language.code ?? "und" }, segments: [],
                                      transcriptionAnalysis: [TranscriptionAnalysis(source: "unknown", status: "no_speech")])
            }
            let local = lockKit()
            guard let local else {
                throw NSError(
                    domain: "ScrumTrace",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Whisper model is not loaded yet."]
                )
            }
            let options = Self.decodingOptions(language: withStateLock { language })
            let transcription = progressReporter.begin("Transcribing audio…")
            let ticker = Task {
                while !Task.isCancelled {
                    self.progressReporter.update(transcription, fraction: local.fraction())
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { ticker.cancel(); progressReporter.end(transcription) }
            let results = try await Self.decode(work, with: local, options: options, onProgress: onProgress)
            var segments: [TranscriptSegment] = []
            for result in results {
                for segment in result.segments {
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, segment.start.isFinite, segment.end.isFinite,
                          segment.start >= 0, segment.end > segment.start else { continue }
                    let words = (segment.words ?? []).map { word in
                        TranscriptWord(start: TimeInterval(word.start), end: TimeInterval(word.end), text: word.word)
                    }
                    segments.append(
                        TranscriptSegment(
                            start: TimeInterval(segment.start),
                            end: TimeInterval(segment.end),
                            text: text,
                            speaker: nil,
                            words: words
                        )
                    )
                }
            }
            let transcript = FullTranscript(
                sessionId: "",
                language: results.first?.language ?? "und",
                segments: segments,
                transcriptionAnalysis: [TranscriptionAnalysis(source: "unknown", status: segments.isEmpty ? "unrecognized" : "transcribed")]
            )
            AgentLog.event("whisper_file_ok", [
                "via": via,
                "segments": String(transcript.segments.count),
                "raw_segments": String(results.reduce(0) { $0 + $1.segments.count }),
                "text_characters": String(transcript.segments.reduce(0) { $0 + $1.text.count }),
                "ms": String(Int(Date().timeIntervalSince(started) * 1000))
            ])
            return transcript
        } catch {
            AgentLog.event("whisper_file_fail", [
                "via": via,
                "error": error is CancellationError ? "cancelled" : AgentLog.sanitize(error.localizedDescription)
            ])
            throw error
        }
    }

    /// Runs the decode and, when a sink is given, reports seconds of audio decoded out of the file's duration:
    /// 0 before the decode, WhisperKit's fraction every half second while it runs (stale readings and anything at
    /// or past 1 are ignored, because the kit's `progress` is replaced per call and not reset after an error), and
    /// the full duration once it returns.
    private static func decode(
        _ work: URL,
        with model: LoadedModel,
        options: DecodingOptions,
        onProgress: ProgressSink?
    ) async throws -> [TranscriptionResult] {
        guard let onProgress else {
            return try await model.transcribe(work.path, options)
        }
        let duration = (try? await audioSeconds(of: work)) ?? 0
        guard duration > 0 else {
            return try await model.transcribe(work.path, options)
        }
        onProgress(0, duration)
        let stale = model.fraction()
        let poller = Task.detached { [fraction = model.fraction] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let value = fraction(), value.isFinite, value > 0, value < 1, value != stale else { continue }
                onProgress(min(duration, value * duration), duration)
            }
        }
        defer { poller.cancel() }
        let results = try await model.transcribe(work.path, options)
        onProgress(duration, duration)
        return results
    }

    /// The audio's length in seconds. Processing uses it for the transcription total.
    static func audioSeconds(of url: URL) async throws -> TimeInterval {
        let seconds = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
        return seconds.isFinite ? max(0, seconds) : 0
    }

    func transcribeVoiceNote(at url: URL) async throws -> String {
        let transcript = try await transcribeFile(at: url)
        return transcript.segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// System audio lives in `archive/session.mp4`. Extract AAC, then fall back to the movie path.
    /// Temp AAC is not under the session folder — do not pass `sessionURL` into that transcribe.
    func transcribeMovieAudio(at movie: URL, sessionURL: URL, onProgress: ProgressSink? = nil) async throws -> FullTranscript {
        try Self.refuseSymlinkMedia(movie, sessionRoot: sessionURL)
        let audioOffset = try await SpeechSignal.audioStart(movie)
        do {
            let dest = try ExportRel.makePrivateTemporaryURL(prefix: "scrumtrace-system-audio", ext: "m4a")
            do {
                try await extractAudio(from: movie, to: dest)
                defer { ExportRel.removePrivateTemporaryURL(dest) }
                return SpeechSignal.shifted(try await transcribeFile(at: dest, onProgress: onProgress), by: audioOffset)
            } catch is CancellationError {
                // Finish later: no movie-copy fallback for a decode that was asked to stop.
                ExportRel.removePrivateTemporaryURL(dest)
                throw CancellationError()
            } catch {
                AgentLog.event("extract_audio_fail", ["error": AgentLog.sanitize(error.localizedDescription)])
                ExportRel.removePrivateTemporaryURL(dest)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AgentLog.event("extract_audio_fail", ["error": "temp_url"])
        }
        let movieCopy = try ExportRel.copyContainedToTemporaryFile(
            relative: ScrumTracePath.sessionMovie,
            sessionURL: sessionURL,
            prefix: "scrumtrace-movie"
        )
        defer { ExportRel.removePrivateTemporaryURL(movieCopy) }
        return SpeechSignal.shifted(try await transcribeFile(at: movieCopy, onProgress: onProgress), by: audioOffset)
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
        let activity = progressReporter.begin("Extracting system audio…")
        let ticker = Task {
            while !Task.isCancelled {
                self.progressReporter.update(activity, fraction: Double(session.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { ticker.cancel(); progressReporter.end(activity) }
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

    private func lockKit() -> LoadedModel? {
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

/// Awaits a task's result without tying the caller's cancellation to the task: a cancelled caller gets
/// `CancellationError` at once and the task keeps running. Used for the detached speech-model load, which CoreML
/// cannot stop part-way and which the next caller for the same model reuses.
enum CancellableAwait {
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var pending: Result<T, Error>?

        func store(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ result: Result<T, Error>) {
            lock.lock()
            guard let continuation else {
                if pending == nil { pending = result }
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    static func value<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        let once = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                once.store(continuation)
                Task.detached {
                    do {
                        once.resume(.success(try await task.value))
                    } catch {
                        once.resume(.failure(error))
                    }
                }
            }
        } onCancel: {
            once.resume(.failure(CancellationError()))
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
        SpeakerTimeline.turns(in: transcript, start: start, end: end)
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
        var language = "und"
        var languageWeight = 0
        var detectedLanguages: [String] = []
        var analysis: [TranscriptionAnalysis] = []
        var sources: [String] = []
        for pass in passes {
            let code = pass.transcript.language
            for detected in pass.transcript.detectedLanguages ?? [code] where !detected.isEmpty && detected != "und" && !detectedLanguages.contains(detected) {
                detectedLanguages.append(detected)
            }
            let weight = pass.transcript.segments.reduce(0) { $0 + $1.text.count }
            if !code.isEmpty, code != "und", weight > languageWeight {
                language = code
                languageWeight = weight
            }
            let status = pass.transcript.transcriptionAnalysis?.first?.status
                ?? (pass.transcript.hasUsableText ? "transcribed" : "unrecognized")
            analysis.append(TranscriptionAnalysis(source: pass.speaker, status: status))
            if !pass.speaker.isEmpty {
                sources.append(pass.speaker)
            }
            for segment in pass.transcript.segments where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var copy = segment
                copy.source = pass.speaker
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
            detectedLanguages: detectedLanguages.isEmpty ? nil : detectedLanguages,
            segments: collapseDuplicates(labeled),
            transcriptionAnalysis: analysis,
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
                if merged.source != segment.source {
                    // The same utterance leaked into both capture sources.
                    // Do not turn the surviving source into an invented person.
                    merged.source = "mixed"
                    merged.speakerAttribution = .uncertain
                }
                result[lastIndex] = merged
            } else {
                result.append(segment)
            }
        }
        return result
    }
}

/// Common meeting languages. Automatic explicitly enables WhisperKit language detection.
enum SpeechLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, romanian = "ro", english = "en", hungarian = "hu", german = "de", french = "fr", spanish = "es", italian = "it", portuguese = "pt"
    var id: String { rawValue }
    var code: String? { self == .automatic ? nil : rawValue }
    var title: String {
        switch self {
        case .automatic: return "Detect automatically"
        case .romanian: return "Romanian (Română)"
        case .english: return "English"
        case .hungarian: return "Hungarian (Magyar)"
        case .german: return "German"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        }
    }
}
