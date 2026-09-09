import Foundation

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
        case .recording: return true
        case .paused: return false
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
}

enum TaskStatus: String, Codable, Sendable {
    case confirmed
    case needsReview = "needs_review"
    case dropped
}

enum CandidateDecision: String, Codable, Sendable {
    case keep
    case needsReview = "needs_review"
    case drop
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
    var note: String
    var source: ShotSource

    enum CodingKeys: String, CodingKey {
        case id
        case tMedia = "t_media"
        case rawPath = "raw_path"
        case annotatedPath = "annotated_path"
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
    var stills: [String]
    var analysisStatus: SliceAnalysisStatus
    var score: Double

    var id: String { sliceId }

    enum CodingKeys: String, CodingKey {
        case sliceId = "slice_id"
        case startMedia = "start_media"
        case endMedia = "end_media"
        case trigger
        case associatedShotId = "associated_shot_id"
        case clipPath = "clip_path"
        case stills
        case analysisStatus = "analysis_status"
        case score
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
        case quotes
        case frameReferences = "frame_references"
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

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case language
        case segments
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
