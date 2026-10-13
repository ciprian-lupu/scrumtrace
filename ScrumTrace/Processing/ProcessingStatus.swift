import Foundation

/// The rows of the processing panel, in pipeline order. Raw values are the `stage` field of the agent log and
/// the keys of `stage_seconds` in `archive/pipeline-timing.json`; they never change meaning.
enum ProcessingStage: String, CaseIterable, Codable, Sendable {
    case resuming
    case loadingModel = "loading_model"
    case transcribing
    case slicing
    case evaluating
    case packaging
    case done

    /// The row title. The first row's title depends on how the run started (`ProcessingOrigin.resumingTitle`).
    var title: String {
        switch self {
        case .resuming: return "Resuming last recording"
        case .loadingModel: return "Loading speech model"
        case .transcribing: return "Transcribing"
        case .slicing: return "Slicing"
        case .evaluating: return "Evaluating"
        case .packaging: return "Packaging"
        case .done: return "Done"
        }
    }

    /// Stages that can take minutes, so the panel says what to expect under them.
    var isSlow: Bool {
        switch self {
        case .loadingModel, .transcribing, .evaluating: return true
        case .resuming, .slicing, .packaging, .done: return false
        }
    }
}

/// How a processing run started. Logged as `origin` on the first `processing_stage` row.
enum ProcessingOrigin: String, Sendable, Equatable {
    case stop
    case launchResume = "launch_resume"
    case retry
    case localExport = "local_export"

    /// Title of the first row.
    var resumingTitle: String {
        switch self {
        case .stop: return "Saving recording"
        case .launchResume: return "Resuming last recording"
        case .retry: return "Retrying analysis"
        case .localExport: return "Regenerating local export"
        }
    }

    /// One plain sentence under the panel title, so an old recording picked up at launch is obvious.
    var subtitle: String? {
        switch self {
        case .stop: return nil
        case .launchResume: return "This recording never finished. ScrumTrace picked it up when it opened."
        case .retry: return "Retry analysis."
        case .localExport: return "Local export only: no transcription, no provider calls."
        }
    }
}

/// Real progress where the pipeline has it. Never an estimate of the whole run.
enum ProcessingProgressValue: Equatable, Sendable {
    case indeterminate
    /// Seconds of audio transcribed out of the audio the run will decode. With two passes (room microphone and
    /// system audio) the total is the sum of both, so the label says so.
    case audioSeconds(done: Double, total: Double, passes: Int = 1)
    /// Finished items out of the items the stage will handle; `unit` is a plural noun ("clips", "provider calls").
    case count(done: Int, total: Int, unit: String)

    var fraction: Double? {
        switch self {
        case .indeterminate:
            return nil
        case let .audioSeconds(done, total, _):
            guard total > 0, done.isFinite, total.isFinite else { return nil }
            return min(1, max(0, done / total))
        case let .count(done, total, _):
            guard total > 0 else { return nil }
            return min(1, max(0, Double(done) / Double(total)))
        }
    }

    var label: String? {
        switch self {
        case .indeterminate:
            return nil
        case let .audioSeconds(done, total, passes):
            guard total > 0 else { return nil }
            let base = "\(ProcessingClock.label(min(done, total))) of \(ProcessingClock.label(total)) of audio"
            return passes > 1 ? "\(base) (\(passes) passes)" : base
        case let .count(done, total, unit):
            guard total > 0 else { return nil }
            return "\(min(done, total)) of \(total) \(unit)"
        }
    }
}

/// One row's timing. A stage is entered at most once per run; a skipped stage has a reason and no duration.
struct ProcessingStageRecord: Equatable, Sendable {
    let stage: ProcessingStage
    let startedAt: Date
    var endedAt: Date?
    /// One of `ProcessingSkipReason`'s values, the `reason` field of `processing_skip`. A closed set, so the log
    /// never carries free text here.
    var skipReason: String?
    var progress: ProcessingProgressValue = .indeterminate

    var isOpen: Bool { endedAt == nil && skipReason == nil }

    func elapsed(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// The words the panel shows for a skip reason.
    var skipText: String? {
        skipReason.flatMap(ProcessingSkipReason.init(rawValue:))?.text
    }
}

/// Why a stage did not run. Raw values are logged; `text` is shown.
enum ProcessingSkipReason: String, CaseIterable, Sendable {
    case alreadyLoaded = "already_loaded"
    case alreadyDone = "already_done"
    case consent
    case localOnly = "local_only"
    case modelRefused = "model_refused"
    case keyMissing = "key_missing"
    case transcriptionIncomplete = "transcription_incomplete"
    case noAnchors = "no_anchors"

    var text: String {
        switch self {
        case .alreadyLoaded: return "Already loaded"
        case .alreadyDone: return "Already done"
        case .consent: return "Upload not approved"
        case .localOnly: return "Local export only"
        case .modelRefused: return "Model missing or retired"
        case .keyMissing: return "API key missing"
        case .transcriptionIncomplete: return "Transcription incomplete"
        case .noAnchors: return "No clips"
        }
    }
}

enum ProcessingOutcome: Equatable, Sendable {
    case running
    /// The processor returned a completed manifest; the text is its final line, for example "Session pack ready".
    case done(String)
    /// The processor returned normally but the manifest is not complete (an incomplete transcription handoff or
    /// offline-failed provider results). Retry analysis continues it; the text is the processor's final line.
    case incomplete(String)
    /// `error.localizedDescription`, the same text as `SessionController.lastError`.
    case failed(String)
    /// Finish later: the run stopped at a stage boundary and Retry analysis continues it.
    case deferred

    var needsRetry: Bool {
        switch self {
        case .incomplete, .failed: return true
        case .running, .done, .deferred: return false
        }
    }
}

/// What `SessionController.processing` publishes: one recording, its stages so far, and how the run ended.
struct ProcessingStatus: Equatable, Sendable {
    /// A finished run clears itself from both surfaces after this long.
    static let doneAutoClearSeconds: TimeInterval = 8

    /// Ticker, auto-clear and deferral act only on the run they were started for.
    let runID: UUID
    let sessionId: String
    /// `SessionManifest.createdAt`; nil when the manifest could not be read.
    let recordedAt: Date?
    let mediaSeconds: TimeInterval
    let origin: ProcessingOrigin
    let startedAt: Date
    /// Ticked once a second while running, then frozen at the end.
    var now: Date
    private(set) var records: [ProcessingStageRecord]
    private(set) var outcome: ProcessingOutcome = .running
    private(set) var endedAt: Date?
    /// Filled in when the off-main read of earlier runs finishes; the fallback wording is used until then.
    var history: ProcessingTimingHistory

    init(
        sessionId: String,
        recordedAt: Date?,
        mediaSeconds: TimeInterval,
        origin: ProcessingOrigin,
        history: ProcessingTimingHistory = .empty,
        startedAt: Date = Date(),
        runID: UUID = UUID()
    ) {
        self.runID = runID
        self.sessionId = sessionId
        self.recordedAt = recordedAt
        self.mediaSeconds = mediaSeconds
        self.origin = origin
        self.startedAt = startedAt
        self.now = startedAt
        self.history = history
        self.records = [ProcessingStageRecord(stage: .resuming, startedAt: startedAt)]
    }

    var isRunning: Bool { outcome == .running }

    /// Finish later works until packaging starts; from then on the run finishes with its real outcome.
    var canFinishLater: Bool {
        isRunning && current != .packaging && record(for: .packaging) == nil
    }

    /// The stage whose record is still open.
    var current: ProcessingStage? {
        records.last { $0.isOpen }?.stage
    }

    func record(for stage: ProcessingStage) -> ProcessingStageRecord? {
        records.last { $0.stage == stage }
    }

    /// Enters a stage, closing the open one. Returns whether a transition happened and the stage that just ended
    /// with its seconds, for the log. Entering the stage that is already open changes nothing.
    @discardableResult
    mutating func enter(_ stage: ProcessingStage, at now: Date? = nil) -> (entered: Bool, previous: ProcessingStage?, previousSeconds: TimeInterval?) {
        let now = now ?? self.now
        self.now = now
        if let open = records.lastIndex(where: { $0.isOpen }) {
            if records[open].stage == stage { return (false, nil, nil) }
            records[open].endedAt = now
            let ended = records[open]
            records.append(ProcessingStageRecord(stage: stage, startedAt: now))
            return (true, ended.stage, ended.elapsed(at: now))
        }
        records.append(ProcessingStageRecord(stage: stage, startedAt: now))
        return (true, nil, nil)
    }

    /// Records a stage that will not run, closing the open one like `enter`.
    @discardableResult
    mutating func skip(_ stage: ProcessingStage, reason: String, at now: Date? = nil) -> (previous: ProcessingStage?, previousSeconds: TimeInterval?) {
        let now = now ?? self.now
        self.now = now
        var ended: ProcessingStageRecord?
        if let open = records.lastIndex(where: { $0.isOpen }) {
            records[open].endedAt = now
            ended = records[open]
        }
        var skipped = ProcessingStageRecord(stage: stage, startedAt: now)
        skipped.endedAt = now
        skipped.skipReason = reason
        records.append(skipped)
        return (ended?.stage, ended.map { $0.elapsed(at: now) })
    }

    mutating func update(progress: ProcessingProgressValue) {
        guard let open = records.lastIndex(where: { $0.isOpen }) else { return }
        records[open].progress = progress
    }

    /// Ends the run. `.done` adds the Done row; the others leave the open row where it stopped.
    mutating func finish(_ outcome: ProcessingOutcome, at now: Date? = nil) {
        let now = now ?? self.now
        self.now = now
        if let open = records.lastIndex(where: { $0.isOpen }) {
            records[open].endedAt = now
        }
        if case .done = outcome {
            var done = ProcessingStageRecord(stage: .done, startedAt: now)
            done.endedAt = now
            records.append(done)
        }
        self.outcome = outcome
        endedAt = now
    }

    var totalElapsed: TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// "22 Sep 2026, 12:55" for the recording's start.
    static func recordedLabel(_ date: Date?) -> String {
        guard let date else { return "an unknown date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var title: String {
        "Processing the recording from \(Self.recordedLabel(recordedAt)) · \(ProcessingClock.label(mediaSeconds)) recorded"
    }

    /// The row the failure stopped at, when the run failed.
    var failedStage: ProcessingStage? {
        guard case .failed = outcome else { return nil }
        return records.last { $0.skipReason == nil && $0.stage != .done }?.stage
    }

    /// The outcome a normal return means, read from the manifest the processor handed back.
    static func outcome(forReturned status: PipelineStatus, line: String) -> ProcessingOutcome {
        status == .completed ? .done(line) : .incomplete(line)
    }
}

/// Clock text for the panel. Elapsed and media times use the HUD's `mm:ss` form; expectations use words.
enum ProcessingClock {
    static func label(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// "9 min 52 s", "45 s", "1 h 2 min".
    static func prose(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return m > 0 ? "\(h) h \(m) min" : "\(h) h"
        }
        if m > 0 {
            return s > 0 ? "\(m) min \(s) s" : "\(m) min"
        }
        return "\(s) s"
    }
}

/// What the processor tells the controller while a run goes on. Typed, never parsed from status lines.
enum ProcessingEvent: Equatable, Sendable {
    case stage(ProcessingStage)
    /// `reason` is a `ProcessingSkipReason` raw value.
    case skipped(ProcessingStage, reason: String)
    case progress(ProcessingProgressValue)
}

// MARK: - Measured history

/// What earlier runs on this Mac measured, read once per run. Model loads come from `UserDefaults` because the
/// load at recording start belongs to no session folder; stage seconds come from `archive/pipeline-timing.json`.
struct ProcessingTimingHistory: Equatable, Sendable {
    static let modelLoadKey = "scrumtrace.processing.modelLoadSeconds"
    /// How many model loads are kept.
    static let keptModelLoads = 12
    /// Loads at or above this are the slow kind (the CoreML compile that the first load after a restart usually
    /// pays); faster ones reuse the compiled model. A measurement, not a diagnosis.
    static let slowLoadThreshold: TimeInterval = 60
    /// How many recent sessions' timing files are read.
    static let sessionLimit = 20

    var modelLoadSeconds: [TimeInterval]
    /// Seconds of audio transcribed per wall second, one per session that measured it.
    var transcribeRates: [Double]
    var stageSeconds: [ProcessingStage: [TimeInterval]]

    static let empty = ProcessingTimingHistory(modelLoadSeconds: [], transcribeRates: [], stageSeconds: [:])

    init(modelLoadSeconds: [TimeInterval], transcribeRates: [Double], stageSeconds: [ProcessingStage: [TimeInterval]]) {
        self.modelLoadSeconds = modelLoadSeconds
        self.transcribeRates = transcribeRates
        self.stageSeconds = stageSeconds
    }

    /// `timings` pairs a session's timing file with its recorded media seconds, newest first. The caller leaves out
    /// imported sessions, whose timing describes another Mac.
    init(defaults: UserDefaults, timings: [(timing: PipelineTiming, mediaSeconds: TimeInterval)]) {
        var loads = Self.storedModelLoads(defaults: defaults)
        var rates: [Double] = []
        var stages: [ProcessingStage: [TimeInterval]] = [:]
        for entry in timings.prefix(Self.sessionLimit) {
            if let load = entry.timing.whisperLoadSeconds, load > 0 {
                loads.append(load)
            }
            for (key, seconds) in entry.timing.stageSeconds {
                guard let stage = ProcessingStage(rawValue: key), seconds.isFinite, seconds >= 0 else { continue }
                stages[stage, default: []].append(seconds)
                if stage == .transcribing, seconds > 0, entry.mediaSeconds > 0 {
                    rates.append(entry.mediaSeconds / seconds)
                }
            }
        }
        self.init(modelLoadSeconds: loads, transcribeRates: rates, stageSeconds: stages)
    }

    /// Reads the newest `sessionLimit` session folders by id (ids are date-stamped, so nothing is decoded to sort),
    /// skipping imported sessions, whose timing describes another Mac. Called off the main actor.
    static func load(vault: SessionVault, defaults: UserDefaults) -> ProcessingTimingHistory {
        let ids = vault.listedSessionIds().sorted(by: >).prefix(sessionLimit)
        var timings: [(timing: PipelineTiming, mediaSeconds: TimeInterval)] = []
        for id in ids {
            guard let manifest = try? vault.loadManifest(id: id), manifest.importOrigin == nil else { continue }
            guard let timing = PipelineTiming.load(sessionURL: vault.sessionURL(id: id)) else { continue }
            timings.append((timing, manifest.duration.mediaSeconds))
        }
        return ProcessingTimingHistory(defaults: defaults, timings: timings)
    }

    static func storedModelLoads(defaults: UserDefaults) -> [TimeInterval] {
        (defaults.array(forKey: modelLoadKey) as? [Double] ?? []).filter { $0.isFinite && $0 > 0 }
    }

    /// Appends one measured load and keeps the newest `keptModelLoads`.
    static func recordModelLoad(seconds: TimeInterval, defaults: UserDefaults) {
        guard seconds.isFinite, seconds > 0 else { return }
        var loads = storedModelLoads(defaults: defaults)
        loads.append(seconds)
        if loads.count > keptModelLoads {
            loads.removeFirst(loads.count - keptModelLoads)
        }
        defaults.set(loads, forKey: modelLoadKey)
    }

    var slowModelLoads: [TimeInterval] { modelLoadSeconds.filter { $0 >= Self.slowLoadThreshold } }
    var fastModelLoads: [TimeInterval] { modelLoadSeconds.filter { $0 < Self.slowLoadThreshold } }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

/// The plain-language line under a slow stage: measured values first, the known range on this Mac second.
enum ProcessingExpectation {
    /// `WhisperTranscriber.prepareTimeoutSeconds`: the processor gives up on a load after this long.
    static let modelLoadLimit: TimeInterval = 12 * 60

    static func line(stage: ProcessingStage, history: ProcessingTimingHistory, mediaSeconds: TimeInterval, elapsed: TimeInterval) -> String? {
        switch stage {
        case .loadingModel:
            if elapsed >= modelLoadLimit {
                return "Longer than the 12-minute wait. The run will go on without a transcript, the model keeps loading, and Retry analysis can finish the recording."
            }
            let slow = history.slowModelLoads
            let fast = history.fastModelLoads
            let count = history.modelLoadSeconds.count
            if let slowest = slow.max(), let fastest = slow.min() {
                var line = fastest == slowest
                    ? "On this Mac a slow load took \(ProcessingClock.prose(slowest))"
                    : "On this Mac a slow load took \(ProcessingClock.prose(fastest)) to \(ProcessingClock.prose(slowest))"
                if let fastMedian = ProcessingTimingHistory.median(fast) {
                    line += " and a fast one about \(ProcessingClock.prose(fastMedian))"
                }
                return "\(line) (\(Self.samples(count))). The first load after a restart is usually the slow kind."
            }
            if let fastMedian = ProcessingTimingHistory.median(fast) {
                return "Earlier loads on this Mac took about \(ProcessingClock.prose(fastMedian)) (\(Self.samples(count))); the first load after a restart can take 5 to 11 minutes."
            }
            return "The first load after a restart usually takes 5 to 11 minutes on this Mac; later loads take a few seconds."
        case .transcribing:
            if let rate = ProcessingTimingHistory.median(history.transcribeRates), rate > 0, mediaSeconds > 0 {
                let estimate = max(1, mediaSeconds / rate)
                return "About \(ProcessingClock.prose(estimate)) for this \(ProcessingClock.label(mediaSeconds)) recording, judging by \(Self.recordings(history.transcribeRates.count))."
            }
            return "Usually under a minute for a short recording, and about as long as the recording for a long one."
        case .slicing:
            if let median = ProcessingTimingHistory.median(history.stageSeconds[.slicing] ?? []) {
                return "About \(ProcessingClock.prose(median)), judging by \(Self.recordings(history.stageSeconds[.slicing]?.count ?? 0))."
            }
            return "Usually a few seconds per clip."
        case .evaluating:
            if let median = ProcessingTimingHistory.median(history.stageSeconds[.evaluating] ?? []) {
                return "One call per clip. About \(ProcessingClock.prose(median)), judging by \(Self.recordings(history.stageSeconds[.evaluating]?.count ?? 0))."
            }
            return "One call per clip; each usually takes 10 to 60 seconds."
        case .packaging:
            if let median = ProcessingTimingHistory.median(history.stageSeconds[.packaging] ?? []) {
                return "About \(ProcessingClock.prose(median)), judging by \(Self.recordings(history.stageSeconds[.packaging]?.count ?? 0))."
            }
            return "Usually under a minute."
        case .resuming, .done:
            return nil
        }
    }

    static func samples(_ count: Int) -> String {
        count == 1 ? "1 load" : "\(count) loads"
    }

    static func recordings(_ count: Int) -> String {
        count == 1 ? "1 earlier recording" : "\(count) earlier recordings"
    }
}

// MARK: - Panel state

/// One row of the panel, derived from a status so both surfaces draw the same thing and tests need no view.
struct ProcessingPanelRow: Equatable, Identifiable {
    enum State: Equatable {
        case pending, active, done, skipped, failed
    }

    let stage: ProcessingStage
    let title: String
    let state: State
    /// `mm:ss` for an active or finished row; nil while pending or skipped.
    let elapsed: String?
    /// The expectation or progress line under an active row, the skip reason, or the failure reason.
    let detail: String?
    /// Set only when the active row has determinate progress.
    let fraction: Double?

    var id: ProcessingStage { stage }
}

struct ProcessingPanelState: Equatable {
    static let finishLaterTitle = "Finish later"
    static let retryTitle = "Retry"
    static let closeTitle = "Close"
    static let finishLaterHelp = "Stop working on this recording for now. Start recording becomes available; Retry analysis finishes it later."
    static let deferredFooter = "Stopped for now. Retry analysis in Recordings or the menu finishes this recording; nothing was lost."
    static let deferredModelFooter = "Stopped for now. The speech model keeps loading in the background; Retry analysis or your next recording will use it."

    let title: String
    let subtitle: String?
    let rows: [ProcessingPanelRow]
    let footer: String?
    let isRunning: Bool
    let showsFinishLater: Bool
    let showsRetry: Bool
    let showsClose: Bool
    /// The run's total time so far, for the header.
    let totalElapsed: String

    /// `modelStillLoading` is `WhisperTranscriber.isPreparing` at the time of the deferral.
    static func make(_ status: ProcessingStatus, modelStillLoading: Bool = false) -> ProcessingPanelState {
        let failedStage = status.failedStage
        let rows = ProcessingStage.allCases.map { stage -> ProcessingPanelRow in
            let title = stage == .resuming ? status.origin.resumingTitle : stage.title
            guard let record = status.record(for: stage) else {
                return ProcessingPanelRow(stage: stage, title: title, state: .pending, elapsed: nil, detail: nil, fraction: nil)
            }
            if let skipText = record.skipText {
                return ProcessingPanelRow(stage: stage, title: title, state: .skipped, elapsed: nil, detail: skipText, fraction: nil)
            }
            let elapsed = record.elapsed(at: status.now)
            let elapsedLabel = stage == .done ? nil : ProcessingClock.label(elapsed)
            if stage == failedStage, case let .failed(reason) = status.outcome {
                return ProcessingPanelRow(stage: stage, title: title, state: .failed, elapsed: elapsedLabel, detail: reason, fraction: nil)
            }
            if record.isOpen {
                var detail = record.progress.label
                if detail == nil, stage.isSlow {
                    detail = ProcessingExpectation.line(stage: stage, history: status.history, mediaSeconds: status.mediaSeconds, elapsed: elapsed)
                }
                return ProcessingPanelRow(stage: stage, title: title, state: .active, elapsed: elapsedLabel, detail: detail, fraction: record.progress.fraction)
            }
            if stage == .done, case let .done(line) = status.outcome {
                return ProcessingPanelRow(stage: stage, title: title, state: .done, elapsed: nil, detail: line, fraction: nil)
            }
            if case .incomplete = status.outcome, record.stage == status.records.last?.stage {
                // The run returned here without a complete manifest: Retry continues from this stage.
                return ProcessingPanelRow(stage: stage, title: title, state: .failed, elapsed: elapsedLabel, detail: record.progress.label, fraction: nil)
            }
            let finishedDetail: String? = record.progress.label
            return ProcessingPanelRow(stage: stage, title: title, state: .done, elapsed: elapsedLabel, detail: finishedDetail, fraction: nil)
        }
        let footer: String?
        switch status.outcome {
        case .running:
            footer = nil
        case let .done(line):
            footer = "\(line) · \(ProcessingClock.prose(status.totalElapsed)) in all"
        case let .incomplete(line):
            footer = line
        case let .failed(reason):
            footer = reason
        case .deferred:
            footer = modelStillLoading ? Self.deferredModelFooter : Self.deferredFooter
        }
        return ProcessingPanelState(
            title: status.title,
            subtitle: status.origin.subtitle,
            rows: rows,
            footer: footer,
            isRunning: status.isRunning,
            showsFinishLater: status.canFinishLater,
            showsRetry: status.outcome.needsRetry,
            showsClose: !status.isRunning,
            totalElapsed: ProcessingClock.label(status.totalElapsed)
        )
    }
}
