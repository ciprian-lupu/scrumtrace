import CryptoKit
import Foundation

/// Speech is deliberately modeled independently from chat/vision analysis. A
/// speech configuration is a snapshot-able request to turn audio into text;
/// it is never inferred from an AI analysis provider.
enum SpeechBackendKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisperKit = "whisperkit"
    case openAITranscription = "openai_transcription"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .whisperKit: return "WhisperKit (local)"
        case .openAITranscription: return "OpenAI transcription"
        }
    }
    var requiresCredential: Bool { self == .openAITranscription }
    var defaultEndpoint: String { "https://api.openai.com" }
    var defaultModel: String {
        switch self {
        case .whisperKit: return WhisperTranscriber.defaultStoredModel
        // Current OpenAI file-transcription model, verified against the
        // official Audio API before this adapter was added.
        case .openAITranscription: return "gpt-transcribe"
        }
    }
}

/// A list is not passed to WhisperKit's single `DecodingOptions.language`.
/// For expected-language mode engines detect language; the saved list is
/// context/validation and is shown as such in the UI and run snapshot.
struct SpeechLanguageSelection: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic, single, expected
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Automatic detection"
            case .single: return "One expected language"
            case .expected: return "Several expected languages"
            }
        }
    }

    var mode: Mode
    var languages: [SpeechLanguage]

    static let automatic = SpeechLanguageSelection(mode: .automatic, languages: [])
    static func one(_ language: SpeechLanguage) -> Self { .init(mode: .single, languages: [language]) }

    /// Only engines that expose a single language field receive this value.
    /// Multi-language mode must remain `nil` to enable native detection.
    var singleEngineHint: String? {
        guard mode == .single, languages.count == 1 else { return nil }
        return languages[0].code
    }

    var explanation: String {
        switch mode {
        case .automatic: return "The engine detects the spoken language; no translation is requested."
        case .single: return "The selected language is sent as a recognition hint; no translation is requested."
        case .expected:
            let names = languages.map(\.title).joined(separator: ", ")
            return "Expected languages: \(names). This is context/validation; WhisperKit still detects each pass because its decoder accepts one language code, not a list."
        }
    }

    func validated() throws {
        if mode == .single && languages.count != 1 {
            throw SettingsValidationError("Choose exactly one language for a single-language speech configuration.")
        }
        if mode == .expected && languages.count < 2 {
            throw SettingsValidationError("Choose at least two expected languages, or use one-language mode.")
        }
        if languages.contains(.automatic) {
            throw SettingsValidationError("Automatic cannot be combined with an explicit expected language.")
        }
    }
}

/// Non-secret saved configuration. `credentialID` only names the Keychain
/// account and may be shared by multiple cloud configurations.
struct SavedTranscriptionService: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var backend: SpeechBackendKind
    var endpoint: String
    var model: String
    var credentialID: String?
    var language: SpeechLanguageSelection
    var isIncludedInComparison: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        backend: SpeechBackendKind,
        endpoint: String? = nil,
        model: String? = nil,
        credentialID: String? = nil,
        language: SpeechLanguageSelection = .automatic,
        isIncludedInComparison: Bool = false
    ) {
        self.id = id; self.name = name; self.backend = backend
        self.endpoint = endpoint ?? backend.defaultEndpoint
        self.model = model ?? backend.defaultModel
        self.credentialID = credentialID
        self.language = language
        self.isIncludedInComparison = isIncludedInComparison
    }
}

struct TranscriptionServiceLibrary: Codable, Equatable, Sendable {
    static let defaultsKey = "scrumtrace.transcriptionServices.v1"
    var services: [SavedTranscriptionService] = []
    var selectedID: String?
    var selected: SavedTranscriptionService? { services.first { $0.id == selectedID } }
}

struct TranscriptionServiceConfiguration: Sendable {
    var service: SavedTranscriptionService
    /// Runtime only; never encoded into a manifest, run, log, or export.
    var apiKey: String

    struct Snapshot: Codable, Equatable, Sendable {
        var serviceID: String
        var name: String
        var backend: SpeechBackendKind
        var endpoint: String
        var requestedModel: String
        var language: SpeechLanguageSelection
        var credentialRequired: Bool
    }
    var snapshot: Snapshot {
        .init(serviceID: service.id, name: service.name, backend: service.backend,
              endpoint: service.endpoint, requestedModel: service.model,
              language: service.language, credentialRequired: service.backend.requiresCredential)
    }
}

enum TranscriptionRunStatus: String, Codable, Sendable { case pending, running, succeeded, failed }

struct TranscriptionInputFingerprint: Codable, Equatable, Sendable {
    var source: String
    var sha256: String
    var bytes: Int
    var startMediaSeconds: TimeInterval?
}

/// Each run is immutable evidence of one audio/configuration pair. The text
/// lives in a private archive sidecar; it is only copied to the normal transcript
/// after the user explicitly selects it as primary.
struct TranscriptionRun: Codable, Identifiable, Sendable {
    var id: String
    var createdAt: Date
    var status: TranscriptionRunStatus
    var configuration: TranscriptionServiceConfiguration.Snapshot
    var inputs: [TranscriptionInputFingerprint]
    var resolvedModel: String?
    var processingSeconds: TimeInterval?
    var transcriptPath: String?
    var diagnostic: String?
}

enum TranscriptionRunStore {
    static let indexPath = "archive/transcription-runs/index.json"
    static let primaryPath = "archive/transcription-runs/primary.json"
    static func transcriptPath(_ id: String) -> String { "archive/transcription-runs/\(id).json" }

    static func load(sessionURL: URL) -> [TranscriptionRun] {
        guard let data = ExportRel.readContainedData(relative: indexPath, sessionURL: sessionURL) else { return [] }
        return (try? JSONDecoder().decode([TranscriptionRun].self, from: data)) ?? []
    }
    static func save(_ runs: [TranscriptionRun], sessionURL: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ExportRel.writeContainedData(try encoder.encode(runs), relative: indexPath, sessionURL: sessionURL)
    }
    static func saveTranscript(_ transcript: FullTranscript, id: String, sessionURL: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ExportRel.writeContainedData(try encoder.encode(transcript), relative: transcriptPath(id), sessionURL: sessionURL)
    }
    static func loadTranscript(id: String, sessionURL: URL) -> FullTranscript? {
        guard let data = ExportRel.readContainedData(relative: transcriptPath(id), sessionURL: sessionURL) else { return nil }
        return try? JSONDecoder().decode(FullTranscript.self, from: data)
    }
    static func selectPrimary(id: String, sessionURL: URL) throws -> FullTranscript {
        guard var transcript = loadTranscript(id: id, sessionURL: sessionURL) else {
            throw SettingsValidationError("The selected transcription result is missing from this session archive.")
        }
        transcript.sessionId = sessionURL.lastPathComponent
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ExportRel.writeContainedData(try encoder.encode(transcript), relative: ScrumTracePath.fullTranscript, sessionURL: sessionURL)
        try ExportRel.writeContainedData(Data(id.utf8), relative: primaryPath, sessionURL: sessionURL)
        return transcript
    }

    static func fingerprint(relative: String, sessionURL: URL, startMediaSeconds: TimeInterval? = nil) throws -> TranscriptionInputFingerprint {
        guard ExportRel.existingSessionFile(relative, sessionURL: sessionURL) != nil else {
            throw SettingsValidationError("Audio input \(relative) is unavailable; no transcription result was created.")
        }
        let copy = try ExportRel.copyContainedToTemporaryFile(relative: relative, sessionURL: sessionURL, prefix: "scrumtrace-audio-fingerprint")
        defer { ExportRel.removePrivateTemporaryURL(copy) }
        let handle = try FileHandle(forReadingFrom: copy); defer { try? handle.close() }
        var hash = SHA256(); var bytes = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk); bytes += chunk.count }
        return .init(source: relative, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes, startMediaSeconds: startMediaSeconds)
    }
}

/// A narrow engine contract keeps orchestration independent of local vs cloud
/// implementation. Runs are serial at the caller, so a WhisperKit model is
/// never swapped while another decode is using it.
protocol TranscriptionEngine: Sendable {
    func transcribe(audioURL: URL, sessionURL: URL, configuration: TranscriptionServiceConfiguration) async throws -> FullTranscript
}

struct WhisperKitTranscriptionEngine: TranscriptionEngine {
    let transcriber: WhisperTranscriber
    func transcribe(audioURL: URL, sessionURL: URL, configuration: TranscriptionServiceConfiguration) async throws -> FullTranscript {
        let selection = configuration.service.language
        // Expected-language mode deliberately enables detection. Passing the
        // first expected language here would silently misrepresent the setting.
        transcriber.setLanguage(selection.mode == .single && selection.languages.count == 1 ? selection.languages[0] : .automatic)
        try await transcriber.prepare(model: configuration.service.model)
        return try await transcriber.transcribeFile(at: audioURL, sessionURL: sessionURL)
    }
}

/// Serial orchestration for a canonical input. A new explicit comparison run
/// is appended even when an older run has the same configuration and bytes;
/// retry therefore never pretends an old success belongs to a changed model.
final class TranscriptionComparisonRunner: @unchecked Sendable {
    private let transcriber: WhisperTranscriber
    private let cloud = OpenAITranscriptionEngine()
    init(transcriber: WhisperTranscriber) { self.transcriber = transcriber }

    func run(sessionURL: URL, configurations: [TranscriptionServiceConfiguration]) async throws -> [TranscriptionRun] {
        guard !configurations.isEmpty else { throw SettingsValidationError("Select at least one transcription service for comparison.") }
        let canonical = canonicalInput(sessionURL: sessionURL)
        let input = try TranscriptionRunStore.fingerprint(relative: canonical.relative, sessionURL: sessionURL, startMediaSeconds: canonical.offset)
        var runs = TranscriptionRunStore.load(sessionURL: sessionURL)
        var created: [TranscriptionRun] = []
        for configuration in configurations {
            try configuration.service.language.validated()
            let id = UUID().uuidString
            var run = TranscriptionRun(id: id, createdAt: Date(), status: .running, configuration: configuration.snapshot, inputs: [input], resolvedModel: nil, processingSeconds: nil, transcriptPath: nil, diagnostic: nil)
            runs.append(run); try TranscriptionRunStore.save(runs, sessionURL: sessionURL)
            let started = Date()
            do {
                let engine: any TranscriptionEngine = configuration.service.backend == .whisperKit
                    ? WhisperKitTranscriptionEngine(transcriber: transcriber) : cloud
                var transcript = try await engine.transcribe(audioURL: sessionURL.appendingPathComponent(canonical.relative), sessionURL: sessionURL, configuration: configuration)
                transcript.sessionId = sessionURL.lastPathComponent
                try TranscriptionRunStore.saveTranscript(transcript, id: id, sessionURL: sessionURL)
                run.status = .succeeded
                run.resolvedModel = configuration.service.backend == .whisperKit
                    ? transcriber.loadedModelName : configuration.service.model
                run.transcriptPath = TranscriptionRunStore.transcriptPath(id)
            } catch {
                run.status = .failed
                run.diagnostic = error.localizedDescription
            }
            run.processingSeconds = Date().timeIntervalSince(started)
            if let index = runs.firstIndex(where: { $0.id == id }) { runs[index] = run }
            try TranscriptionRunStore.save(runs, sessionURL: sessionURL)
            created.append(run)
        }
        return created
    }

    private func canonicalInput(sessionURL: URL) -> (relative: String, offset: TimeInterval?) {
        // One canonical regular file is selected for every compared service.
        // We deliberately do not claim byte equality when a future provider
        // needs chunking/conversion; that transformation must receive its own
        // input fingerprint before it is added.
        if ExportRel.existingSessionFile(ScrumTracePath.audioWav, sessionURL: sessionURL) != nil {
            return (ScrumTracePath.audioWav, CaptureAudioLayout.load(sessionURL: sessionURL).wavStartMediaSeconds)
        }
        if ExportRel.existingSessionFile(ScrumTracePath.sessionMovie, sessionURL: sessionURL) != nil {
            return (ScrumTracePath.sessionMovie, 0)
        }
        return ("", nil)
    }
}

struct OpenAITranscriptionEngine: TranscriptionEngine {
    func transcribe(audioURL: URL, sessionURL: URL, configuration: TranscriptionServiceConfiguration) async throws -> FullTranscript {
        guard configuration.service.backend == .openAITranscription else { throw SettingsValidationError("This engine only supports OpenAI transcription.") }
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SettingsValidationError("This cloud transcription service needs a saved API key.") }
        let base = try ProviderEndpoint.requireHTTPSOrLocal(configuration.service.endpoint)
        let endpoint = base.appendingPathComponent("v1/audio/transcriptions")
        let copy = try ExportRel.copyUnfollowedToTemporaryFile(audioURL, prefix: "scrumtrace-openai-audio")
        defer { ExportRel.removePrivateTemporaryURL(copy) }
        let boundary = "ScrumTrace-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) { body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!) }
        field("model", configuration.service.model)
        // `gpt-transcribe` accepts multiple language hints through the modern API;
        // the file-transcription field remains one code, so expected-language mode
        // intentionally sends no false comma-separated language value.
        if let hint = configuration.service.language.singleEngineHint { field("language", hint) }
        if configuration.service.language.mode == .expected {
            field("prompt", "Expected meeting languages: \(configuration.service.language.languages.map(\.rawValue).joined(separator: ", ")). Preserve the original spoken language; do not translate.")
        }
        let filename = "audio.\(copy.pathExtension.isEmpty ? "m4a" : copy.pathExtension)"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime(for: copy))\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: copy)); body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SettingsValidationError("OpenAI transcription failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        let segments = decoded.segments?.compactMap { item -> TranscriptSegment? in
            guard let start = item.start, let end = item.end, end > start else { return nil }
            return TranscriptSegment(start: start, end: end, text: item.text, speaker: nil, words: [])
        } ?? (decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [TranscriptSegment(start: 0, end: 0.001, text: decoded.text, speaker: nil, words: [])])
        return FullTranscript(sessionId: "", language: decoded.language ?? configuration.service.language.singleEngineHint ?? "und", segments: segments, transcriptionAnalysis: [.init(source: "cloud", status: segments.isEmpty ? "unrecognized" : "transcribed")], sources: ["cloud"])
    }
    private struct OpenAIResponse: Decodable { struct Segment: Decodable { var start: TimeInterval?; var end: TimeInterval?; var text: String }; var text: String; var language: String?; var segments: [Segment]? }
    private func mime(for url: URL) -> String { ["wav": "audio/wav", "m4a": "audio/mp4", "mp3": "audio/mpeg", "webm": "audio/webm" ][url.pathExtension.lowercased()] ?? "application/octet-stream" }
}
