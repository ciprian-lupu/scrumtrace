import Foundation

/// Where a Session last stood, as saved in its manifest: the Session status and the Stages that are done.
/// Every change to either goes through this type, and every classification of a Session is answered here.
/// It never touches the disk; facts from the archive are passed in.
struct SessionLifecycle: Equatable, Sendable {
    /// One step of processing, in fixed order. Raw values are the saved strings.
    enum Stage: String, CaseIterable, Sendable {
        case transcribing, slicing, evaluating, synthesizing, completed

        var status: PipelineStatus {
            switch self {
            case .transcribing: return .transcribing
            case .slicing: return .slicing
            case .evaluating: return .evaluating
            case .synthesizing: return .synthesizing
            case .completed: return .completed
            }
        }

        /// This Stage and every later one.
        var andLater: ArraySlice<Stage> {
            let all = Stage.allCases
            return all[all.firstIndex(of: self)!...]
        }
    }

    /// The saved Session status.
    private(set) var status: PipelineStatus
    /// Saved order is kept so a rewrite produces the same bytes. Values outside `Stage` that an older manifest
    /// may hold are kept as they are and never count as done.
    private(set) var completedStages: [PipelineStatus]

    init(status: PipelineStatus, completedStages: [PipelineStatus]) {
        self.status = status
        self.completedStages = completedStages
    }

    static let new = SessionLifecycle(status: .idle, completedStages: [])

    func isDone(_ stage: Stage) -> Bool {
        completedStages.contains(stage.status)
    }

    // MARK: - Capture

    /// The live Capture phase at a save while capturing.
    mutating func recordCapture(_ phase: CapturePhase) {
        status = phase.status
    }

    /// A normal Stop: the archive is complete and only processing is missing.
    mutating func recordStop() {
        status = .transcribing
    }

    /// A Quit that interrupted capture. Nothing captured stays idle, the only state the abandoned-start prune removes.
    /// Once the movie and audio closed, the next launch finishes it; a failed close stays a manual retry, as after a crash.
    mutating func recordQuit(hasMedia: Bool, captureClosed: Bool) {
        guard hasMedia else {
            status = .idle
            return
        }
        status = captureClosed ? .transcribing : .recording
    }

    // MARK: - Processing

    /// Processing of `stage` is under way. Use `finish(offlineFailed:)` to reach completed.
    mutating func begin(_ stage: Stage) {
        assert(stage != .completed, "finish(offlineFailed:) is the only way to complete a Session")
        status = stage.status
    }

    mutating func complete(_ stage: Stage) {
        if !completedStages.contains(stage.status) {
            completedStages.append(stage.status)
        }
    }

    /// `stage` and every later Stage are no longer done because their inputs changed. The status is not touched:
    /// callers that also move the status say so with a transition of their own.
    mutating func invalidate(from stage: Stage) {
        let dropped = Set(stage.andLater.map(\.status))
        completedStages.removeAll { dropped.contains($0) }
    }

    /// Packaging finished: synthesizing and completed are done, and the status says whether any analysis failed.
    mutating func finish(offlineFailed: Bool) {
        complete(.synthesizing)
        status = offlineFailed ? .offlineFailed : .completed
        complete(.completed)
    }

    mutating func markOfflineFailed() {
        status = .offlineFailed
    }

    /// A retry after Finish later keeps the controller's live status over the one on disk.
    mutating func takeStatus(from live: SessionLifecycle) {
        status = live.status
    }

    // MARK: - Classifications

    /// Neither idle nor completed.
    var isUnfinished: Bool {
        switch status {
        case .idle, .completed: return false
        case .recording, .paused, .transcribing, .slicing, .evaluating, .synthesizing, .offlineFailed: return true
        }
    }

    /// Saved as recording or paused. Callers exclude the Session being captured right now.
    var isInterrupted: Bool {
        status == .recording || status == .paused
    }

    /// Retention may delete it once it is old enough.
    var isPrunable: Bool {
        status == .completed
    }

    /// The brief and agent context exist and synthesizing is done.
    func isExportReady(_ facts: ArchiveFacts) -> Bool {
        isDone(.synthesizing) && facts.hasBrief && facts.hasAgentContext
    }

    /// Offline failed and not export ready.
    func needsAttention(_ facts: ArchiveFacts) -> Bool {
        status == .offlineFailed && !isExportReady(facts)
    }

    /// The last transcription pass finished and failed, so the Session waits for a manual retry.
    func awaitsTranscriptionRetry(_ facts: ArchiveFacts) -> Bool {
        status == .transcribing && !isDone(.transcribing) && facts.lastTranscriptionPassFailed
    }

    /// A killed process left processing unfinished with a complete archive: the next launch finishes it without a click.
    /// A crash while recording or a run that already failed offline stays a manual retry.
    func isResumable(_ facts: ArchiveFacts) -> Bool {
        switch status {
        case .transcribing, .slicing, .evaluating, .synthesizing:
            return !awaitsTranscriptionRetry(facts)
        case .idle, .recording, .paused, .completed, .offlineFailed:
            return false
        }
    }
}

/// Whether a Session is being captured at this moment.
enum CapturePhase: Sendable {
    case idle, recording, paused

    var status: PipelineStatus {
        switch self {
        case .idle: return .idle
        case .recording: return .recording
        case .paused: return .paused
        }
    }

    init?(_ status: PipelineStatus) {
        switch status {
        case .idle: self = .idle
        case .recording: self = .recording
        case .paused: self = .paused
        case .transcribing, .slicing, .evaluating, .synthesizing, .completed, .offlineFailed: return nil
        }
    }
}

/// Facts about a Session's files that classifications need. Callers read them; the lifecycle never does.
struct ArchiveFacts: Equatable, Sendable {
    var hasBrief = false
    var hasAgentContext = false
    var lastTranscriptionPassFailed = false
}
