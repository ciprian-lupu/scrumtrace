import Foundation

extension Notification.Name {
    static let scrumTraceCaptureGate = Notification.Name("ScrumTrace.captureGate")
    static let scrumTraceHUDSuppress = Notification.Name("ScrumTrace.hudSuppress")
    static let scrumTraceSessionEnding = Notification.Name("ScrumTrace.sessionEnding")
}

/// Paths agents see are relative to `export/` (`shots/…`, `media/…`).
enum ExportRel {
    static func toExportRoot(_ path: String) -> String {
        guard let parts = normalizedComponents(path) else { return "" }
        if parts.first == "export" {
            return parts.dropFirst().joined(separator: "/")
        }
        return parts.joined(separator: "/")
    }

    /// Session-root path used for file I/O. Never rewrites `archive/` into `export/`.
    static func sessionPath(_ path: String) -> String {
        guard let parts = normalizedComponents(path) else { return "invalid" }
        if parts.first == "export" || parts.first == "archive" {
            return parts.joined(separator: "/")
        }
        return (["export"] + parts).joined(separator: "/")
    }

    static func isUnderExport(_ path: String) -> Bool {
        guard let parts = normalizedComponents(path) else { return false }
        return parts.first == "export" && parts.count >= 2 && parts[1] != "archive"
    }

    /// Paths agents and SESSION_BRIEF may link. Never `archive/`, never `..`.
    static func handoffPath(_ path: String) -> String? {
        let session = sessionPath(path)
        guard isUnderExport(session) else { return nil }
        let rel = toExportRoot(session)
        return rel.isEmpty ? nil : rel
    }

    /// Omitted-asset labels in `export/`. Strip `archive/` so the pack never names that folder.
    static func omittedHandoffPath(_ path: String) -> String {
        guard let parts = normalizedComponents(path) else { return "omitted" }
        var rest = parts
        if rest.first == "export" {
            rest = Array(rest.dropFirst())
        }
        if rest.first == "archive" {
            rest = Array(rest.dropFirst())
        }
        return rest.joined(separator: "/")
    }

    /// Collapse `.` / `..` and reject absolute paths that escape the session root.
    static func normalizedComponents(_ path: String) -> [String]? {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("./") {
            value = String(value.dropFirst(2))
        }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.contains("://") {
            return nil
        }
        var stack: [String] = []
        for part in value.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if stack.isEmpty { return nil }
                stack.removeLast()
                continue
            }
            if part.contains("\\") { return nil }
            stack.append(String(part))
        }
        return stack.isEmpty ? nil : stack
    }

    static func isUnderSession(_ path: String) -> Bool {
        guard let parts = normalizedComponents(path), let first = parts.first else { return false }
        return (first == "archive" || first == "export") && parts.count >= 2
    }

    /// Normalized session-relative path that still lives under the session folder.
    static func containedRelative(_ path: String, sessionURL: URL) -> String? {
        guard isUnderSession(path), let parts = normalizedComponents(path) else { return nil }
        let joined = parts.joined(separator: "/")
        let root = sessionURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = sessionURL.appendingPathComponent(joined).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { return nil }
        return joined
    }

    static func existingSessionFile(_ path: String, sessionURL: URL) -> String? {
        guard let relative = containedRelative(path, sessionURL: sessionURL) else { return nil }
        let url = sessionURL.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return relative
    }
}

enum MediaBudget {
    static let maxZipBytes = 35 * 1024 * 1024
    static let maxTasks = 8
    static let maxCandidateSlices = 12
    static let maxStills = 16
    static let clipWidth = 1280
    static let clipHeight = 720
    static let clipVideoBitrate = 1_200_000
    static let clipAudioBitrate = 96_000
    static let clipMinDuration: TimeInterval = 15
    static let clipMaxDuration: TimeInterval = 25
    static let clipMeanDuration: TimeInterval = 20
    static let stillMaxWidth = 1440
    static let stillJPEGQuality: CGFloat = 0.82
    static let keepConfidenceFloor = 0.55
    static let metadataSampleTimeoutMs: UInt64 = 200
    static let manifestVersion = "1.1.0"
}

enum CaptureSessionState: String, Codable, Sendable {
    case recording
    case paused

    var allowsNewCapture: Bool {
        switch self {
        case .recording:
            return true
        case .paused:
            return false
        }
    }
}

enum PipelineStatus: String, Codable, Sendable {
    case idle
    case recording
    case paused
    case transcribing
    case slicing
    case evaluating
    case synthesizing
    case completed
    case offlineFailed = "offline_failed"
}

enum SliceTrigger: String, Codable, Sendable {
    case shot
    case pin
    case keyword
}

enum SliceAnalysisStatus: String, Codable, Sendable {
    case pending
    case success
    case offlineFailed = "offline_failed"
    case skipped
}

enum TaskKind: String, Codable, Sendable {
    case bug
    case decision
    case actionItem = "action_item"
    case architectureNote = "architecture_note"
    case improvement
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskKind(rawValue: raw) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TaskStatus: String, Codable, Sendable {
    case confirmed
    case needsReview = "needs_review"
    case dropped

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskStatus(rawValue: raw) ?? .needsReview
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum CandidateDecision: String, Codable, Sendable {
    case keep
    case needsReview = "needs_review"
    case drop

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CandidateDecision(rawValue: raw) ?? .needsReview
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ShotSource: String, Codable, Sendable {
    case voice
    case typed
    case mixed
}

enum SessionEventKind: String, Codable, Sendable {
    case start
    case stop
    case pause
    case resume
    case pin
    case shot
    case url
    case window
    case privacyPause = "privacy_pause"
    case error
}

struct DurationPair: Codable, Sendable, Hashable {
    var wallSeconds: TimeInterval
    var mediaSeconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case wallSeconds = "wall_seconds"
        case mediaSeconds = "media_seconds"
    }
}

struct PauseInterval: Codable, Sendable, Hashable {
    var pauseWall: TimeInterval
    var resumeWall: TimeInterval?
    var duration: TimeInterval

    enum CodingKeys: String, CodingKey {
        case pauseWall = "pause_wall"
        case resumeWall = "resume_wall"
        case duration
    }

    init(pauseWall: TimeInterval, resumeWall: TimeInterval?) {
        self.pauseWall = pauseWall
        self.resumeWall = resumeWall
        if let resumeWall {
            self.duration = max(0, resumeWall - pauseWall)
        } else {
            self.duration = 0
        }
    }

    mutating func close(at resumeWall: TimeInterval) {
        self.resumeWall = resumeWall
        self.duration = max(0, resumeWall - pauseWall)
    }
}

struct ProductContext: Codable, Sendable, Hashable {
    var appName: String
    var repoURL: String
    var techStack: String

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case repoURL = "repo_url"
        case techStack = "tech_stack"
    }

    static let empty = ProductContext(appName: "", repoURL: "", techStack: "")
}

struct ShotRecord: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var tMedia: TimeInterval
    var rawPath: String
    var annotatedPath: String?
    var exportPath: String? = nil
    var note: String
    var source: ShotSource

    /// Annotated PNG exists only after Save. Unsaved Shots still have the raw frame.
    var stillCandidates: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in [annotatedPath, rawPath] {
            guard let path, !path.isEmpty, seen.insert(path).inserted else { continue }
            out.append(path)
        }
        return out
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tMedia = "t_media"
        case rawPath = "raw_path"
        case annotatedPath = "annotated_path"
        case exportPath = "export_path"
        case note
        case source
    }
}

struct SliceRecord: Codable, Sendable, Identifiable, Hashable {
    var sliceId: String
    var startMedia: TimeInterval
    var endMedia: TimeInterval
    var trigger: SliceTrigger
    var associatedShotId: String?
    var clipPath: String?
    var exportClipPath: String? = nil
    var stills: [String]
    var analysisStatus: SliceAnalysisStatus
    var score: Double
    var mediaSent: [String]? = nil

    var id: String { sliceId }

    /// Drop clip/still paths that were never written (failed encode or still grab).
    func withExistingMedia(sessionURL: URL) -> SliceRecord {
        var copy = self
        if let clip = clipPath,
           !FileManager.default.fileExists(atPath: sessionURL.appendingPathComponent(clip).path) {
            copy.clipPath = nil
        }
        copy.stills = stills.filter {
            FileManager.default.fileExists(atPath: sessionURL.appendingPathComponent($0).path)
        }
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case sliceId = "slice_id"
        case startMedia = "start_media"
        case endMedia = "end_media"
        case trigger
        case associatedShotId = "associated_shot_id"
        case clipPath = "clip_path"
        case exportClipPath = "export_clip_path"
        case stills
        case analysisStatus = "analysis_status"
        case score
        case mediaSent = "media_sent"
    }
}

struct QuoteRecord: Codable, Sendable, Hashable {
    var speaker: String
    var text: String
    var tMediaStart: TimeInterval
    var tMediaEnd: TimeInterval

    enum CodingKeys: String, CodingKey {
        case speaker
        case text
        case tMediaStart = "t_media_start"
        case tMediaEnd = "t_media_end"
    }
}

struct TaskRecord: Codable, Sendable, Identifiable, Hashable {
    var taskId: String
    var sourceSliceId: String
    var kind: TaskKind
    var status: TaskStatus
    var title: String
    var observed: String
    var stated: String
    var inferred: String
    var agentInstructions: String
    var quotes: [QuoteRecord]
    var evidenceMedia: [String]
    var confidence: Double

    var id: String { taskId }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case sourceSliceId = "source_slice_id"
        case kind
        case status
        case title
        case observed
        case stated
        case inferred
        case agentInstructions = "agent_instructions"
        case quotes
        case evidenceMedia = "evidence_media"
        case confidence
    }

    init(
        taskId: String,
        sourceSliceId: String,
        kind: TaskKind,
        status: TaskStatus,
        title: String,
        observed: String,
        stated: String,
        inferred: String,
        agentInstructions: String,
        quotes: [QuoteRecord],
        evidenceMedia: [String],
        confidence: Double
    ) {
        self.taskId = taskId
        self.sourceSliceId = sourceSliceId
        self.kind = kind
        self.status = status
        self.title = title
        self.observed = observed
        self.stated = stated
        self.inferred = inferred
        self.agentInstructions = agentInstructions
        self.quotes = quotes
        self.evidenceMedia = evidenceMedia
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decode(String.self, forKey: .taskId)
        sourceSliceId = try container.decode(String.self, forKey: .sourceSliceId)
        kind = try container.decode(TaskKind.self, forKey: .kind)
        status = try container.decode(TaskStatus.self, forKey: .status)
        title = try container.decode(String.self, forKey: .title)
        observed = try container.decodeIfPresent(String.self, forKey: .observed) ?? ""
        stated = try container.decodeIfPresent(String.self, forKey: .stated) ?? ""
        inferred = try container.decodeIfPresent(String.self, forKey: .inferred) ?? ""
        agentInstructions = try container.decodeIfPresent(String.self, forKey: .agentInstructions) ?? ""
        quotes = try container.decodeIfPresent([QuoteRecord].self, forKey: .quotes) ?? []
        evidenceMedia = try container.decodeIfPresent([String].self, forKey: .evidenceMedia) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    }
}

/// D7: when the pack can only keep `maxTasks`, human shots and `confirmed` win.
enum TaskRanking {
    static func selectForPack(_ tasks: [TaskRecord], limit: Int = MediaBudget.maxTasks) -> [TaskRecord] {
        let kept = tasks.filter { $0.status != .dropped }
        let sorted = kept.sorted(by: moreImportant)
        return Array(sorted.prefix(limit)).enumerated().map { index, task in
            var copy = task
            copy.taskId = String(format: "TASK-%02d", index + 1)
            return copy
        }
    }

    static func isShotBacked(_ task: TaskRecord) -> Bool {
        task.evidenceMedia.contains { path in
            path.lowercased().contains("shots/")
        }
    }

    static func moreImportant(lhs: TaskRecord, rhs: TaskRecord) -> Bool {
        let leftShot = isShotBacked(lhs)
        let rightShot = isShotBacked(rhs)
        if leftShot != rightShot { return leftShot }
        let leftRank = statusRank(lhs.status)
        let rightRank = statusRank(rhs.status)
        if leftRank != rightRank { return leftRank > rightRank }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        return lhs.taskId < rhs.taskId
    }

    private static func statusRank(_ status: TaskStatus) -> Int {
        switch status {
        case .confirmed: return 2
        case .needsReview: return 1
        case .dropped: return 0
        }
    }
}

struct CandidateRecord: Codable, Sendable, Hashable {
    var decision: CandidateDecision
    var confidence: Double
    var kind: TaskKind
    var title: String
    var observed: String
    var stated: String
    var inferred: String
    var agentInstructionsDraft: String
    var quotes: [QuoteRecord]
    var frameReferences: [String]

    enum CodingKeys: String, CodingKey {
        case decision
        case confidence
        case kind
        case title
        case observed
        case stated
        case inferred
        case agentInstructionsDraft = "agent_instructions_draft"
        case agentInstructions = "agent_instructions"
        case quotes
        case frameReferences = "frame_references"
    }

    init(
        decision: CandidateDecision,
        confidence: Double,
        kind: TaskKind,
        title: String,
        observed: String,
        stated: String,
        inferred: String,
        agentInstructionsDraft: String,
        quotes: [QuoteRecord],
        frameReferences: [String]
    ) {
        self.decision = decision
        self.confidence = confidence
        self.kind = kind
        self.title = title
        self.observed = observed
        self.stated = stated
        self.inferred = inferred
        self.agentInstructionsDraft = agentInstructionsDraft
        self.quotes = quotes
        self.frameReferences = frameReferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(CandidateDecision.self, forKey: .decision)
        confidence = try container.decode(Double.self, forKey: .confidence)
        kind = try container.decode(TaskKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        observed = try container.decodeIfPresent(String.self, forKey: .observed) ?? ""
        stated = try container.decodeIfPresent(String.self, forKey: .stated) ?? ""
        inferred = try container.decodeIfPresent(String.self, forKey: .inferred) ?? ""
        agentInstructionsDraft = try container.decodeIfPresent(String.self, forKey: .agentInstructionsDraft)
            ?? container.decodeIfPresent(String.self, forKey: .agentInstructions)
            ?? ""
        quotes = try container.decodeIfPresent([QuoteRecord].self, forKey: .quotes) ?? []
        frameReferences = try container.decodeIfPresent([String].self, forKey: .frameReferences) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decision, forKey: .decision)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(observed, forKey: .observed)
        try container.encode(stated, forKey: .stated)
        try container.encode(inferred, forKey: .inferred)
        try container.encode(agentInstructionsDraft, forKey: .agentInstructionsDraft)
        try container.encode(quotes, forKey: .quotes)
        try container.encode(frameReferences, forKey: .frameReferences)
    }
}

struct CandidateEvaluationResponse: Codable, Sendable {
    var candidates: [CandidateRecord]
}

struct SessionEvent: Codable, Sendable {
    var tWall: TimeInterval
    var tMedia: TimeInterval
    var kind: SessionEventKind
    var payload: [String: String]

    enum CodingKeys: String, CodingKey {
        case tWall = "t_wall"
        case tMedia = "t_media"
        case kind
        case payload
    }
}

struct TranscriptWord: Codable, Sendable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct TranscriptSegment: Codable, Sendable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speaker: String?
    var words: [TranscriptWord]
}

struct FullTranscript: Codable, Sendable {
    var sessionId: String
    var language: String
    var segments: [TranscriptSegment]
    /// Hypotheses: `room` (microphone WAV) and/or `system` (movie audio).
    var sources: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case language
        case segments
        case sources
    }
}

/// What landed in `archive/audio.wav` vs `archive/session.mp4` audio.
struct CaptureAudioLayout: Codable, Sendable, Hashable {
    var microphoneWav: Bool
    var systemAudioInMovie: Bool

    enum CodingKeys: String, CodingKey {
        case microphoneWav = "microphone_wav"
        case systemAudioInMovie = "system_audio_in_movie"
    }

    static let both = CaptureAudioLayout(microphoneWav: true, systemAudioInMovie: true)

    static func load(sessionURL: URL) -> CaptureAudioLayout {
        let url = sessionURL.appendingPathComponent(ScrumTracePath.captureLayout)
        guard let data = try? Data(contentsOf: url),
              let layout = try? JSONDecoder().decode(CaptureAudioLayout.self, from: data) else {
            return .both
        }
        return layout
    }

    func write(sessionURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: sessionURL.appendingPathComponent(ScrumTracePath.captureLayout),
            options: .atomic
        )
    }

    /// Room mic WAV is a different source from movie system audio. If WAV *is*
    /// system audio (no mic tap), transcribing the movie would duplicate it.
    func shouldTranscribeMovie(wavExists: Bool, movieExists: Bool) -> Bool {
        guard movieExists, systemAudioInMovie else { return false }
        if microphoneWav { return true }
        return !wavExists
    }
}

/// Gate 3 / Gate 6 measurements. Archive-only — never on the export allow-list.
struct PipelineTiming: Codable, Sendable, Hashable {
    var whisperWallSeconds: TimeInterval?
    var whisperSources: [String]
    var zipBytes: Int?
    var omittedCount: Int

    enum CodingKeys: String, CodingKey {
        case whisperWallSeconds = "whisper_wall_seconds"
        case whisperSources = "whisper_sources"
        case zipBytes = "zip_bytes"
        case omittedCount = "omitted_count"
    }

    init(
        whisperWallSeconds: TimeInterval? = nil,
        whisperSources: [String] = [],
        zipBytes: Int? = nil,
        omittedCount: Int = 0
    ) {
        self.whisperWallSeconds = whisperWallSeconds
        self.whisperSources = whisperSources
        self.zipBytes = zipBytes
        self.omittedCount = omittedCount
    }

    static func load(sessionURL: URL) -> PipelineTiming? {
        let url = sessionURL.appendingPathComponent(ScrumTracePath.pipelineTiming)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PipelineTiming.self, from: data)
    }

    func write(sessionURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: sessionURL.appendingPathComponent(ScrumTracePath.pipelineTiming),
            options: .atomic
        )
    }
}

struct WindowMetadata: Sendable, Hashable {
    var appName: String
    var windowTitle: String
    var bundleIdentifier: String
    var url: String?
}

struct SessionManifest: Codable, Sendable {
    var manifestVersion: String
    var sessionId: String
    var createdAt: Date
    var pipelineStatus: PipelineStatus
    var duration: DurationPair
    var pauses: [PauseInterval]
    var productContext: ProductContext
    var shots: [ShotRecord]
    var slices: [SliceRecord]
    var tasks: [TaskRecord]
    var completedStages: [PipelineStatus]
    var includeFullTranscriptInZip: Bool
    var uploadConsent: UploadConsent
    var omitted: [OmittedAsset]

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case sessionId = "session_id"
        case createdAt = "created_at"
        case pipelineStatus = "pipeline_status"
        case duration
        case pauses
        case productContext = "product_context"
        case shots
        case slices
        case tasks
        case completedStages = "completed_stages"
        case includeFullTranscriptInZip = "include_full_transcript_in_zip"
        case uploadConsent = "upload_consent"
        case omitted
    }

    static func makeNew(sessionId: String, product: ProductContext) -> SessionManifest {
        SessionManifest(
            manifestVersion: MediaBudget.manifestVersion,
            sessionId: sessionId,
            createdAt: Date(),
            pipelineStatus: .idle,
            duration: DurationPair(wallSeconds: 0, mediaSeconds: 0),
            pauses: [],
            productContext: product,
            shots: [],
            slices: [],
            tasks: [],
            completedStages: [],
            includeFullTranscriptInZip: false,
            uploadConsent: .denied,
            omitted: []
        )
    }

    func hasCompleted(_ stage: PipelineStatus) -> Bool {
        completedStages.contains(stage)
    }

    mutating func markCompleted(_ stage: PipelineStatus) {
        if !completedStages.contains(stage) {
            completedStages.append(stage)
        }
    }
}

struct UploadConsent: Codable, Sendable, Hashable {
    var approved: Bool
    var approvedAt: Date?
    var provider: String
    var endpoint: String
    var model: String
    var includesClipAudio: Bool
    var includesStills: Bool

    enum CodingKeys: String, CodingKey {
        case approved
        case approvedAt = "approved_at"
        case provider
        case endpoint
        case model
        case includesClipAudio = "includes_clip_audio"
        case includesStills = "includes_stills"
    }

    static let denied = UploadConsent(
        approved: false,
        approvedAt: nil,
        provider: "",
        endpoint: "",
        model: "",
        includesClipAudio: false,
        includesStills: false
    )

    /// D15: Retry does not re-prompt unless this session never asked, the
    /// destination changed, or the payload kind (clip bytes vs stills-only) changed.
    /// `acceptsVideo` is the **actual** clip-upload capability (`willUploadClip`),
    /// not the settings flag alone.
    func needsReprompt(provider: String, endpoint: String, model: String, acceptsVideo: Bool) -> Bool {
        let neverAsked = self.provider.isEmpty && self.endpoint.isEmpty && self.model.isEmpty
        if neverAsked {
            return true
        }
        if self.provider != provider || self.endpoint != endpoint || self.model != model {
            return true
        }
        if includesClipAudio != acceptsVideo {
            return true
        }
        return false
    }
}

struct OmittedAsset: Codable, Sendable, Hashable {
    var path: String
    var reason: String
}

enum ScrumTracePath {
    static let archive = "archive"
    static let export = "export"
    static let shots = "archive/shots"
    static let exportShots = "export/shots"
    static let media = "export/media"
    static let mediaWork = "archive/media-work"
    static let manifest = "session.manifest.json"
    static let exportManifest = "export/session.manifest.json"
    static let agentContext = "export/AGENT_CONTEXT.md"
    static let sessionBrief = "export/SESSION_BRIEF.html"
    static let agentPrompt = "export/AGENT_PROMPT.txt"
    static let packZip = "export/session-pack.zip"
    static let omitted = "export/OMITTED.md"
    static let sessionMovie = "archive/session.mp4"
    static let audioWav = "archive/audio.wav"
    static let captureLayout = "archive/capture-layout.json"
    static let pipelineTiming = "archive/pipeline-timing.json"
    static let fullTranscript = "archive/full_transcript.json"
    static let events = "archive/events.jsonl"
}

enum PipelineStatusOrder {
    static let processingFlow: [PipelineStatus] = [
        .transcribing, .slicing, .evaluating, .synthesizing, .completed
    ]

    static func label(_ status: PipelineStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .transcribing: return "Transcribing"
        case .slicing: return "Slicing"
        case .evaluating: return "Evaluating"
        case .synthesizing: return "Synthesizing"
        case .completed: return "Completed"
        case .offlineFailed: return "Offline — needs review"
        }
    }
}
