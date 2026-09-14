#if os(macOS)
import AppKit
import Combine
import SwiftUI

// MARK: - Readiness

/// A button a readiness row offers. Raw values are technical log fields.
enum OverviewReadinessAction: String, CaseIterable, Identifiable, Sendable {
    case askScreenRecording
    case openScreenRecordingSettings
    case openMicrophoneSettings
    case relaunch
    case preloadSpeechModel
    case openCaptureSettings
    case openPermissionsSettings
    case openSpeechSettings
    case openAISettings
    case openGeneralSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askScreenRecording: return "Ask for Screen Recording"
        case .openScreenRecordingSettings: return "Open Screen Recording settings"
        case .openMicrophoneSettings: return "Open Microphone settings"
        case .relaunch: return "Relaunch ScrumTrace"
        case .preloadSpeechModel: return "Preload Whisper model"
        case .openCaptureSettings: return "Open Capture settings"
        case .openPermissionsSettings: return "Open Permissions settings"
        case .openSpeechSettings: return "Open Speech settings"
        case .openAISettings: return "Open AI settings"
        case .openGeneralSettings: return "Open General settings"
        }
    }

    /// The Settings tab this action shows in the same window. Nil for actions that do something else.
    var settingsTab: SettingsTab? {
        switch self {
        case .openCaptureSettings: return .capture
        case .openPermissionsSettings: return .permissions
        case .openSpeechSettings: return .speech
        case .openAISettings: return .ai
        case .openGeneralSettings: return .general
        case .askScreenRecording, .openScreenRecordingSettings, .openMicrophoneSettings, .relaunch, .preloadSpeechModel:
            return nil
        }
    }

    /// Waits for recording and analysis to finish, like the same buttons in Settings.
    var needsIdleCapture: Bool {
        switch self {
        case .askScreenRecording, .relaunch, .preloadSpeechModel: return true
        default: return false
        }
    }
}

/// “Ready to record?”, composed from the checks that exist today. When the capture preflight snapshot
/// (TASK D01) lands it replaces `Inputs`; the rows keep this layout.
struct OverviewReadiness: Equatable, Sendable {
    enum State: String, Sendable {
        /// Nothing to do.
        case ok
        /// Something to do. Only Screen Recording and the microphone also stop a recording from starting.
        case actionNeeded
        /// Optional or informational. Never stops a recording.
        case optional
    }

    /// What a row's icon says. A row that stops a recording from starting looks different from one that only
    /// asks for something, such as the meeting notice that Start recording asks for itself.
    enum Marker: String, Sendable {
        case done
        case blocksRecording
        case actionNeeded
        case optional

        var label: String {
            switch self {
            case .done: return "Done"
            case .blocksRecording: return "Blocks recording"
            case .actionNeeded: return "Action needed"
            case .optional: return "Optional"
            }
        }
    }

    enum Item: String, CaseIterable, Identifiable, Sendable {
        case screenRecording
        case microphone
        case accessibility
        case speechModel
        case aiService
        case meetingNotice

        var id: String { rawValue }

        var title: String {
            switch self {
            case .screenRecording: return "Screen Recording"
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .speechModel: return "Speech model"
            case .aiService: return "AI service"
            case .meetingNotice: return "Meeting notice"
            }
        }
    }

    /// Everything the card reads. Built on the main actor by `live(settings:transcriber:)`; tests build it directly.
    struct Inputs: Equatable, Sendable {
        var capture: CaptureReadiness
        /// Settings → Capture → Record microphone.
        var microphoneEnabled: Bool
        /// `CapturePermissions.microphoneStatus()`.
        var microphoneStatus: String
        /// `MetadataSampler.requestTrust(prompt: false)`, which never shows a prompt.
        var accessibilityTrusted: Bool
        var speechModel: String
        var speechModelReady: Bool
        var speechModelLoading: Bool
        var aiServiceSelected: Bool
        var aiKeySaved: Bool
        var aiConfigurationValid: Bool
        /// `AppSettings.configurationSummary`.
        var aiSummary: String
        var meetingNoticeAccepted: Bool

        @MainActor
        static func live(settings: AppSettings, transcriber: WhisperTranscriber) -> Inputs {
            let model = settings.whisperModel
            return Inputs(
                capture: CapturePermissions.readiness(requireMicrophone: settings.includeMicrophone),
                microphoneEnabled: settings.includeMicrophone,
                microphoneStatus: CapturePermissions.microphoneStatus(),
                accessibilityTrusted: MetadataSampler.requestTrust(prompt: false),
                speechModel: model,
                speechModelReady: transcriber.isReady(for: model),
                speechModelLoading: transcriber.isPreparing,
                aiServiceSelected: settings.connectionLibrary.selected != nil,
                aiKeySaved: settings.hasSavedAPIKey,
                aiConfigurationValid: settings.configurationIssue == nil,
                aiSummary: settings.configurationSummary,
                meetingNoticeAccepted: settings.meetingNoticeAccepted
            )
        }
    }

    struct Row: Identifiable, Equatable, Sendable {
        let item: Item
        let state: State
        /// A few words, such as “Allowed” or “Relaunch required”.
        let status: String
        /// Plain explanation of what is missing, or nil when there is nothing to add.
        let detail: String?
        let actions: [OverviewReadinessAction]
        /// True only when this row is why `CaptureReadiness.allowsStart` is false.
        let blocksRecording: Bool

        var id: Item { item }
        var title: String { item.title }

        var marker: Marker {
            switch state {
            case .ok: return .done
            case .actionNeeded: return blocksRecording ? .blocksRecording : .actionNeeded
            case .optional: return .optional
            }
        }

        /// Names the row as well as the action, so each button on the card has its own identifier.
        func accessibilityIdentifier(for action: OverviewReadinessAction) -> String {
            "main.overview.readiness.\(item.rawValue).\(action.rawValue)"
        }
    }

    let inputs: Inputs
    let rows: [Row]

    init(inputs: Inputs) {
        self.inputs = inputs
        rows = [
            Self.screenRow(inputs),
            Self.microphoneRow(inputs),
            Self.accessibilityRow(inputs),
            Self.speechRow(inputs),
            Self.aiRow(inputs),
            Self.noticeRow(inputs)
        ]
    }

    /// The same rule the menu and `SessionController.startRecording` apply.
    var allowsStart: Bool { inputs.capture.allowsStart }

    var requiresRelaunch: Bool { inputs.capture == .screenGrantedNeedsRelaunch }

    func row(_ item: Item) -> Row? {
        rows.first { $0.item == item }
    }

    var headline: String {
        if allowsStart { return "Ready to record" }
        return requiresRelaunch ? "Relaunch ScrumTrace before recording" : "Recording is blocked"
    }

    /// Names what blocks recording, so a row that only asks for something is not read as a blocker.
    var summary: String {
        switch inputs.capture {
        case .screenDenied:
            return "A recording will not start until Screen Recording is allowed. Nothing else below blocks recording."
        case .screenGrantedNeedsRelaunch:
            return "Screen Recording is allowed, but a recording will not start until ScrumTrace relaunches. Nothing else below blocks recording."
        case .microphoneDenied:
            return "A recording will not start until microphone access is allowed, or Record microphone is turned off in Capture settings. Nothing else below blocks recording."
        case .ready:
            break
        }
        if !inputs.meetingNoticeAccepted {
            return "Start recording first asks you to confirm that you will tell participants."
        }
        return "Start recording asks for the product context, then the capture area."
    }

    /// The Start button's help while readiness stops a recording from starting: what to do, and the row whose buttons
    /// do it. Nil while a recording can start.
    var startBlockedReason: String? {
        switch inputs.capture {
        case .ready:
            return nil
        case .screenDenied:
            return "Recording is blocked until Screen Recording is allowed. Use the buttons in the Screen Recording row below."
        case .screenGrantedNeedsRelaunch:
            return "Relaunch ScrumTrace before recording. Use the button in the Screen Recording row below."
        case .microphoneDenied:
            return "Recording is blocked until microphone access is allowed or Record microphone is turned off. Use the buttons in the Microphone row below."
        }
    }

    /// Accessibility in the words the card shows. Settings → Permissions uses the same words.
    static func accessibilityStatus(trusted: Bool) -> String {
        trusted ? "Allowed" : "Not allowed"
    }

    /// A `CapturePermissions.microphoneStatus()` value in the words the card shows. Settings → Permissions uses the
    /// same words.
    static func microphoneStatus(_ status: String) -> String {
        switch status {
        case "allowed": return "Allowed"
        case "denied": return "Denied"
        case "restricted": return "Restricted"
        case "not asked for this process": return "Not asked yet"
        default: return status.prefix(1).uppercased() + status.dropFirst()
        }
    }

    private static func screenRow(_ inputs: Inputs) -> Row {
        switch inputs.capture {
        case .ready, .microphoneDenied:
            return Row(item: .screenRecording, state: .ok, status: "Allowed", detail: nil, actions: [], blocksRecording: false)
        case .screenDenied:
            return Row(
                item: .screenRecording,
                state: .actionNeeded,
                status: "Not allowed",
                detail: CaptureReadiness.screenDenied.userMessage,
                actions: [.askScreenRecording, .openScreenRecordingSettings, .relaunch],
                blocksRecording: true
            )
        case .screenGrantedNeedsRelaunch:
            return Row(
                item: .screenRecording,
                state: .actionNeeded,
                status: "Relaunch required",
                detail: CaptureReadiness.screenGrantedNeedsRelaunch.userMessage,
                actions: [.relaunch],
                blocksRecording: true
            )
        }
    }

    /// A microphone turned off in Settings is never a problem: nothing asks for it.
    private static func microphoneRow(_ inputs: Inputs) -> Row {
        guard inputs.microphoneEnabled else {
            return Row(
                item: .microphone,
                state: .optional,
                status: "Off",
                detail: "Record microphone is off in Capture settings, so room audio is not recorded and no microphone access is needed.",
                actions: [.openCaptureSettings],
                blocksRecording: false
            )
        }
        let status = inputs.microphoneStatus
        if inputs.capture == .microphoneDenied || status == "denied" || status == "restricted" {
            // While Screen Recording blocks, its row already offers Relaunch: one button, on the blocking row.
            let screenOffersRelaunch = inputs.capture == .screenDenied || inputs.capture == .screenGrantedNeedsRelaunch
            // Turning Record microphone off in Capture settings also clears the block, as the summary says.
            let fixes: [OverviewReadinessAction] = [.openMicrophoneSettings, .openCaptureSettings]
            return Row(
                item: .microphone,
                state: .actionNeeded,
                status: status == "restricted" ? "Restricted" : "Denied",
                detail: CaptureReadiness.microphoneDenied.userMessage,
                actions: screenOffersRelaunch ? fixes : fixes + [.relaunch],
                blocksRecording: inputs.capture == .microphoneDenied
            )
        }
        switch status {
        case "allowed":
            return Row(item: .microphone, state: .ok, status: microphoneStatus(status), detail: nil, actions: [], blocksRecording: false)
        case "not asked for this process":
            return Row(
                item: .microphone,
                state: .optional,
                status: microphoneStatus(status),
                detail: "macOS asks for microphone access when a recording starts.",
                actions: [],
                blocksRecording: false
            )
        default:
            return Row(
                item: .microphone,
                state: .optional,
                status: microphoneStatus(status),
                detail: nil,
                actions: [.openMicrophoneSettings],
                blocksRecording: false
            )
        }
    }

    private static func accessibilityRow(_ inputs: Inputs) -> Row {
        guard !inputs.accessibilityTrusted else {
            return Row(item: .accessibility, state: .ok, status: accessibilityStatus(trusted: true), detail: nil, actions: [], blocksRecording: false)
        }
        return Row(
            item: .accessibility,
            state: .optional,
            status: accessibilityStatus(trusted: false),
            detail: "Optional. Accessibility adds window titles and scrubbed browser URLs to help explain the recording. Screen and microphone recording work without it.",
            actions: [.openPermissionsSettings],
            blocksRecording: false
        )
    }

    private static func speechRow(_ inputs: Inputs) -> Row {
        if inputs.speechModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Row(
                item: .speechModel,
                state: .optional,
                status: "Not chosen",
                detail: "Choose a speech model in Speech settings. Recordings are transcribed on this Mac.",
                actions: [.openSpeechSettings],
                blocksRecording: false
            )
        }
        if inputs.speechModelReady {
            return Row(item: .speechModel, state: .ok, status: "Ready", detail: nil, actions: [], blocksRecording: false)
        }
        if inputs.speechModelLoading {
            return Row(
                item: .speechModel,
                state: .optional,
                status: "Loading…",
                detail: "The first download can take several minutes.",
                actions: [],
                blocksRecording: false
            )
        }
        return Row(
            item: .speechModel,
            state: .optional,
            status: "Not loaded",
            detail: "Speech is processed on this Mac. Preload before a meeting to finish the model download and preparation in advance.",
            actions: [.preloadSpeechModel],
            blocksRecording: false
        )
    }

    /// Informational only: recording and the local export work without an AI service.
    private static func aiRow(_ inputs: Inputs) -> Row {
        let configured = inputs.aiServiceSelected && inputs.aiKeySaved && inputs.aiConfigurationValid
        let status: String
        if configured {
            status = "Configured"
        } else if !inputs.aiServiceSelected {
            status = "No service selected"
        } else if !inputs.aiConfigurationValid {
            status = "Check settings"
        } else {
            status = "No saved key"
        }
        return Row(
            item: .aiService,
            state: configured ? .ok : .optional,
            status: status,
            detail: inputs.aiSummary,
            actions: configured ? [] : [.openAISettings],
            blocksRecording: false
        )
    }

    /// Start recording asks for the notice itself, so a missing confirmation does not block.
    private static func noticeRow(_ inputs: Inputs) -> Row {
        guard !inputs.meetingNoticeAccepted else {
            return Row(item: .meetingNotice, state: .ok, status: "Confirmed", detail: nil, actions: [], blocksRecording: false)
        }
        return Row(
            item: .meetingNotice,
            state: .actionNeeded,
            status: "Not confirmed",
            detail: "ScrumTrace captures other people’s voices and shared screens. Confirm that you will tell participants, here in General settings or when you start recording.",
            actions: [.openGeneralSettings],
            blocksRecording: false
        )
    }
}

// MARK: - Needs attention

/// What the Needs attention list shows, derived from the session index and a few settings. Pure, so tests
/// need no view. Sessions contribute metadata only (C2).
struct OverviewAttention: Equatable {
    /// Unfinished recordings shown before “Show all in Recordings”.
    static let unfinishedLimit = 5

    /// Newest first. The recording held by a running capture or analysis is not listed: it is in progress.
    let unfinished: [SessionSummary]
    let unreadableIds: [String]
    let lastError: String?
    /// Set only when retention deletes old recordings.
    let retentionDays: Int?
    /// Set only for a check that already ran in this launch and found a newer release.
    let availableUpdate: UpdateChecker.Result?

    var isEmpty: Bool {
        unfinished.isEmpty && unreadableIds.isEmpty && lastError == nil && retentionDays == nil && availableUpdate == nil
    }

    static func make(
        entries: [SessionEntry],
        heldSessionId: String?,
        lastError: String?,
        retentionDays: Int,
        update: UpdateChecker.Result?
    ) -> OverviewAttention {
        let unfinished = entries.compactMap(\.summary).filter { summary in
            guard summary.isUnfinished else { return false }
            guard let heldSessionId else { return true }
            return heldSessionId.caseInsensitiveCompare(summary.sessionId) != .orderedSame
        }
        let error = lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
        let available: UpdateChecker.Result?
        if case .newerAvailable = update {
            available = update
        } else {
            available = nil
        }
        return OverviewAttention(
            unfinished: unfinished,
            unreadableIds: entries.filter { $0.summary == nil }.map(\.id),
            lastError: error?.isEmpty == false ? error : nil,
            retentionDays: retentionDays > 0 ? retentionDays : nil,
            availableUpdate: available
        )
    }

    static func retentionLine(days: Int) -> String {
        let limit = days == 1 ? "1 day" : "\(days) days"
        return "Completed recordings older than \(limit) are deleted, including their archive and export, the next time ScrumTrace launches. Unfinished recordings are kept."
    }
}

// MARK: - Model

/// Reads the result of an update check that already ran. The Overview never starts a check: one runs only
/// from Settings or the menu bar. Tests count checks through `UpdateChecker.setRequestForTesting`.
struct OverviewUpdateSource {
    var lastResult: @MainActor () -> UpdateChecker.Result?

    static var live: OverviewUpdateSource {
        OverviewUpdateSource(lastResult: { UpdateChecker.lastResult })
    }
}

/// Everything the Overview does outside its own state. Tests inject closures; the app uses `live`.
struct OverviewDependencies {
    var readinessInputs: @MainActor () -> OverviewReadiness.Inputs
    var canChangeSessions: @MainActor () -> Bool
    /// True while a Start from the menu, Recordings or here shows the context window or the capture-area overlay.
    var isPreparingRecording: @MainActor () -> Bool
    /// True while a recording starts, runs or is paused. While sessions cannot change and this is false, analysis runs.
    var isRecordingActive: @MainActor () -> Bool
    var lastError: @MainActor () -> String?
    var retentionDays: @MainActor () -> Int
    var captureAreaSummary: @MainActor () -> String
    /// Home-scrubbed path of the sessions folder.
    var sessionsFolder: @MainActor () -> String
    var updates: OverviewUpdateSource
    /// The menu's Start flow: meeting notice, readiness, context confirmation, capture area.
    var startRecording: @MainActor () -> Void
    var askForScreenRecording: @MainActor () -> Void
    var openScreenRecordingSettings: @MainActor () -> Void
    var openMicrophoneSettings: @MainActor () -> Void
    var relaunch: @MainActor () -> Void
    /// Runs off the main actor.
    var preloadSpeechModel: @Sendable (String) async throws -> Void
    var revealSessionsFolder: @MainActor () -> Void
    var openReleasesPage: @MainActor () -> Void

    @MainActor
    static func live(
        controller: SessionController,
        startRecording: @escaping @MainActor () -> Void,
        isPreparingRecording: @escaping @MainActor () -> Bool
    ) -> OverviewDependencies {
        let settings = controller.settings
        let transcriber = controller.transcriber
        let vault = controller.vault
        return OverviewDependencies(
            readinessInputs: { .live(settings: settings, transcriber: transcriber) },
            canChangeSessions: { controller.canChangeCaptureSettings },
            isPreparingRecording: isPreparingRecording,
            isRecordingActive: { controller.isRecording || controller.startInFlight },
            lastError: { controller.lastError },
            retentionDays: { settings.retentionDays },
            captureAreaSummary: { settings.captureArea.summary },
            sessionsFolder: { CapturePermissions.scrubHome(vault.rootURL.path) },
            updates: .live,
            startRecording: startRecording,
            // Only from the button, never on appear (TCC: at most one sheet per client).
            askForScreenRecording: {
                Task.detached { _ = CapturePermissions.requestScreenAccess() }
            },
            openScreenRecordingSettings: { SystemPrivacySettings.openScreenRecording() },
            openMicrophoneSettings: { SystemPrivacySettings.openMicrophone() },
            relaunch: { controller.relaunchForPermissions() },
            preloadSpeechModel: { try await transcriber.prepare(model: $0) },
            revealSessionsFolder: { vault.revealRootInFinder() },
            openReleasesPage: { NSWorkspace.shared.open(UpdateChecker.releasesURL) }
        )
    }
}

/// State and actions of the Overview section. The presenter owns one per window. Session rows and their
/// actions come from the shared `RecordingsModel`. It never shows or activates the window, and it checks
/// readiness every `evaluationInterval` only while the section is shown in a visible window.
@MainActor
final class OverviewModel: ObservableObject {
    nonisolated static let evaluationInterval: Duration = .seconds(2)
    /// While a Start shows its context window, the Start button follows it at this pace.
    nonisolated static let preparingInterval: Duration = .milliseconds(500)
    nonisolated static let preparingReason = "Finish or cancel the recording you started: choose its context and capture area."
    /// The Start button's help while it can run. The Recordings empty state shows it too.
    nonisolated static let startHelp = "Confirm the product context, then choose the capture area."
    nonisolated static let lastRecordingActions: [RecordingAction] = [.revealExport, .openInClaude, .openInChatGPT]
    nonisolated static let sessionsFolderWarning = "This folder holds every recording’s archive/ folder, with the full recording and transcript. Never hand it, or anything inside archive/, to an agent."

    let recordings: RecordingsModel
    let navigation: MainNavigation
    var library: SessionLibrary { recordings.library }

    /// Nil until the section first appears.
    @Published private(set) var readiness: OverviewReadiness?
    @Published private(set) var canChangeSessions: Bool
    @Published private(set) var isPreparingRecording: Bool
    /// `dependencies.isRecordingActive()`, followed like `canChangeSessions`, so the card tells recording from analysis.
    @Published private(set) var isRecordingActive: Bool
    @Published private(set) var lastError: String?
    @Published private(set) var retentionDays = 0
    @Published private(set) var captureAreaSummary = ""
    @Published private(set) var sessionsFolder = ""
    @Published private(set) var updateResult: UpdateChecker.Result?
    @Published private(set) var isPreloadingSpeechModel = false
    /// A short line about the last preload. Never a path.
    @Published private(set) var preloadLine: String?
    /// True after the user dismissed `lastError`, until the controller clears or sets its error again.
    @Published private var isLastErrorDismissed = false
    /// True while the warning before Reveal recordings folder… is shown.
    @Published var isConfirmingSessionsReveal = false

    private(set) var evaluationLoop: Task<Void, Never>?
    private(set) var preloadTask: Task<Void, Never>?
    /// Asks for the archive total once the session index this appearance started or joined has been read.
    private(set) var archiveTotalTask: Task<Void, Never>?
    private(set) var isWindowVisible = false
    private(set) var isSectionShown = false

    private let dependencies: OverviewDependencies
    private let evaluationInterval: Duration
    private let preparingInterval: Duration
    private var observations: Set<AnyCancellable> = []

    init(
        recordings: RecordingsModel,
        navigation: MainNavigation,
        dependencies: OverviewDependencies,
        evaluationInterval: Duration = OverviewModel.evaluationInterval,
        preparingInterval: Duration = OverviewModel.preparingInterval
    ) {
        self.recordings = recordings
        self.navigation = navigation
        self.dependencies = dependencies
        self.evaluationInterval = evaluationInterval
        self.preparingInterval = preparingInterval
        canChangeSessions = dependencies.canChangeSessions()
        isPreparingRecording = dependencies.isPreparingRecording()
        isRecordingActive = dependencies.isRecordingActive()
        // Plain settings and cached values, so the first frame shows them. Readiness, which asks macOS about
        // permissions, is read only when the section appears.
        lastError = dependencies.lastError()
        retentionDays = dependencies.retentionDays()
        captureAreaSummary = dependencies.captureAreaSummary()
        sessionsFolder = dependencies.sessionsFolder()
        updateResult = dependencies.updates.lastResult()
    }

    // MARK: Visibility

    /// Follows the controller for the Start button and the last error. Settings changes are read again only
    /// while the section is on screen; otherwise the next appearance reads them.
    func observe(controller: SessionController) {
        observations.removeAll()
        Publishers.Merge3(
            controller.$phase.map { _ in () },
            controller.$isBusy.map { _ in () },
            controller.$startInFlight.map { _ in () }
        )
        // @Published emits before the new value is stored; read the controller after it is.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.syncControllerState() }
        }
        .store(in: &observations)
        // Every assignment counts, even one that clears and sets the same text before this block runs.
        controller.$lastError
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.controllerDidSetLastError() }
            }
            .store(in: &observations)
        controller.settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.evaluate()
                }
            }
            .store(in: &observations)
    }

    /// True while the section is shown in a visible window.
    var isActive: Bool { isSectionShown && isWindowVisible }

    var isEvaluationLoopActive: Bool { evaluationLoop != nil }

    /// OverviewView appeared: read everything once, join or start a session index refresh, then ask for the
    /// archive total, which is measured off the main actor and cached. Asking after that scan keeps the total
    /// to one pass. The library itself measures nothing before a scan published and then waits for the newest
    /// refresh, so a refresh that replaced this scan never leaves the total at zero bytes.
    func sectionDidAppear() {
        isSectionShown = true
        evaluate()
        let scan = recordings.sectionDidAppear()
        archiveTotalTask?.cancel()
        archiveTotalTask = Task { @MainActor [weak self] in
            await scan.value
            guard !Task.isCancelled, let self else { return }
            await self.library.loadTotalArchiveBytes().value
        }
        updateEvaluationLoop()
    }

    func sectionDidDisappear() {
        isSectionShown = false
        updateEvaluationLoop()
    }

    /// The presenter reports whether the window is on screen. Coming back on screen with the section shown,
    /// for example after granting a permission in System Settings, reads readiness and the Start state at
    /// once instead of after the next interval.
    func setWindowVisible(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        if isActive { evaluate() }
        updateEvaluationLoop()
    }

    private func updateEvaluationLoop() {
        guard isActive != (evaluationLoop != nil) else { return }
        evaluationLoop?.cancel()
        evaluationLoop = nil
        guard isActive else { return }
        startEvaluationLoop()
    }

    private func startEvaluationLoop() {
        let full = evaluationInterval
        let fast = min(preparingInterval, evaluationInterval)
        evaluationLoop = Task { @MainActor [weak self] in
            var sinceEvaluation: Duration = .zero
            while !Task.isCancelled {
                guard let preparing = self?.isPreparingRecording else { return }
                let interval = preparing ? fast : full
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                sinceEvaluation += interval
                if sinceEvaluation >= full {
                    sinceEvaluation = .zero
                    self.evaluate()
                } else {
                    self.syncStartState()
                }
            }
        }
    }

    // MARK: State

    /// Reads readiness, settings, the cached update result and the controller again. Publishes only changes.
    func evaluate() {
        let next = OverviewReadiness(inputs: dependencies.readinessInputs())
        if next != readiness { readiness = next }
        let days = dependencies.retentionDays()
        if days != retentionDays { retentionDays = days }
        let area = dependencies.captureAreaSummary()
        if area != captureAreaSummary { captureAreaSummary = area }
        let folder = dependencies.sessionsFolder()
        if folder != sessionsFolder { sessionsFolder = folder }
        let update = dependencies.updates.lastResult()
        if update != updateResult { updateResult = update }
        syncControllerState()
    }

    func syncControllerState() {
        syncStartState()
        let error = dependencies.lastError()
        guard error != lastError else { return }
        lastError = error
        // A dismissal hides one error. Once the controller clears or replaces it, the next error shows.
        if isLastErrorDismissed { isLastErrorDismissed = false }
    }

    /// The controller assigned `lastError`. A failure that repeats the dismissed text is a new failure.
    func controllerDidSetLastError() {
        if isLastErrorDismissed { isLastErrorDismissed = false }
        syncControllerState()
    }

    func syncStartState() {
        let canChange = dependencies.canChangeSessions()
        if canChange != canChangeSessions { canChangeSessions = canChange }
        let recording = dependencies.isRecordingActive()
        if recording != isRecordingActive { isRecordingActive = recording }
        let preparing = dependencies.isPreparingRecording()
        guard preparing != isPreparingRecording else { return }
        isPreparingRecording = preparing
        // Follow the context window at the faster pace at once instead of after the current sleep.
        if preparing, isActive {
            evaluationLoop?.cancel()
            startEvaluationLoop()
        }
    }

    // MARK: Start recording

    /// The Start flow is free: no recording, analysis or start runs, and no Start shows its context window.
    var canStartRecording: Bool { canChangeSessions && !isPreparingRecording }

    /// Why readiness stops a recording from starting, or nil. Nil too before readiness is first read.
    var readinessStartBlock: String? { readiness?.startBlockedReason }

    /// The card's Start button runs only when the flow is free and readiness allows a start, so it never ends in the
    /// flow's “Cannot start recording” alert. The blocking row below has the buttons that fix it.
    var isStartButtonEnabled: Bool { canStartRecording && readinessStartBlock == nil }

    /// The Start button's help tag while it waits: for recording, analysis or a Start first, then for readiness.
    var startUnavailableReason: String? {
        Self.startUnavailableReason(canChangeSessions: canChangeSessions, isPreparingRecording: isPreparingRecording)
            ?? readinessStartBlock
    }

    /// Why a Start button waits for the Start flow. The Recordings empty state asks here too, so both buttons say the
    /// same thing; only Overview's card, which shows readiness, also waits for it.
    nonisolated static func startUnavailableReason(canChangeSessions: Bool, isPreparingRecording: Bool) -> String? {
        if !canChangeSessions { return RecordingsModel.busyReason }
        if isPreparingRecording { return preparingReason }
        return nil
    }

    /// What the first row of Ready to record? shows.
    var startCard: OverviewStartCard {
        OverviewStartCard(
            readiness: readiness,
            canChangeSessions: canChangeSessions,
            isRecordingActive: isRecordingActive,
            isPreparingRecording: isPreparingRecording
        )
    }

    /// Runs the menu's Start flow. Refused while recording, analysis or a start is running, and while a Start already
    /// shows its context window. The card's button also waits while readiness blocks; the flow checks readiness itself.
    @discardableResult
    func startRecording() -> Bool {
        syncStartState()
        guard canStartRecording else { return false }
        AgentLog.event("main_start", ["section": MainSection.overview.rawValue])
        dependencies.startRecording()
        syncStartState()
        return true
    }

    // MARK: Readiness actions

    nonisolated static let speechModelLoadingReason = "The Whisper model is already loading."

    func isEnabled(_ action: OverviewReadinessAction) -> Bool {
        guard let readiness, readiness.rows.contains(where: { $0.actions.contains(action) }) else { return false }
        return unavailableReason(action) == nil
    }

    /// Why a row's button waits, for its help tag. Nil when it can run, and for an action no row offers.
    func unavailableReason(_ action: OverviewReadinessAction) -> String? {
        guard let readiness, readiness.rows.contains(where: { $0.actions.contains(action) }) else { return nil }
        if action.needsIdleCapture && !canChangeSessions { return RecordingsModel.busyReason }
        if action == .preloadSpeechModel, isPreloadingSpeechModel || readiness.inputs.speechModelLoading {
            return Self.speechModelLoadingReason
        }
        return nil
    }

    /// Runs a row's button. Screen Recording is requested only here, from its button.
    @discardableResult
    func perform(_ action: OverviewReadinessAction) -> Bool {
        syncStartState()
        guard isEnabled(action), let readiness else { return false }
        AgentLog.event("main_readiness", ["action": action.rawValue])
        if let tab = action.settingsTab {
            showSettings(tab)
            return true
        }
        switch action {
        case .askScreenRecording:
            dependencies.askForScreenRecording()
        case .openScreenRecordingSettings:
            dependencies.openScreenRecordingSettings()
        case .openMicrophoneSettings:
            dependencies.openMicrophoneSettings()
        case .relaunch:
            dependencies.relaunch()
        case .preloadSpeechModel:
            preloadSpeechModel(readiness.inputs.speechModel)
        case .openCaptureSettings, .openPermissionsSettings, .openSpeechSettings, .openAISettings, .openGeneralSettings:
            break
        }
        return true
    }

    private func preloadSpeechModel(_ model: String) {
        isPreloadingSpeechModel = true
        preloadLine = "Loading the local model. The first download can take several minutes."
        let prepare = dependencies.preloadSpeechModel
        preloadTask = Task { @MainActor [weak self] in
            let failure: String?
            do {
                try await prepare(model)
                failure = nil
            } catch {
                failure = "Could not load Whisper: \(error.localizedDescription)"
            }
            guard let self else { return }
            self.isPreloadingSpeechModel = false
            self.preloadLine = failure ?? "The selected model is ready. No relaunch is needed."
            self.evaluate()
        }
    }

    // MARK: Sessions

    /// The session a running recording, start or analysis holds. Nil while sessions can change.
    var heldSessionId: String? {
        canChangeSessions ? nil : recordings.activeSessionId
    }

    /// Everything Needs attention lists now.
    var attention: OverviewAttention {
        OverviewAttention.make(
            entries: library.entries,
            heldSessionId: heldSessionId,
            lastError: isLastErrorDismissed ? nil : lastError,
            retentionDays: retentionDays,
            update: updateResult
        )
    }

    /// Hides the current error here. The controller keeps it. The next error it sets shows again, even with
    /// the same text.
    func dismissLastError() {
        if lastError != nil, !isLastErrorDismissed { isLastErrorDismissed = true }
    }

    /// What “Show all” opens: every recording the Recordings status filter lists as unfinished, including
    /// the one in progress that Needs attention leaves out.
    var unfinishedInRecordingsCount: Int {
        library.filtered(search: "", status: .unfinished, contextID: nil).count
    }

    /// The newest recording whose manifest could be read. A recording still being captured is not a last
    /// recording yet, so while capture runs the card shows the one before it. Analysis in progress is shown.
    var lastRecording: SessionSummary? {
        let held = heldSessionId
        return library.entries.lazy.compactMap(\.summary).first { summary in
            guard let held, held.caseInsensitiveCompare(summary.sessionId) == .orderedSame else { return true }
            return !Self.isCapturing(summary.pipelineStatus)
        }
    }

    /// Manifest states of a recording whose capture has not ended: created, recording or paused.
    nonisolated static func isCapturing(_ status: PipelineStatus) -> Bool {
        switch status {
        case .idle, .recording, .paused:
            return true
        case .transcribing, .slicing, .evaluating, .synthesizing, .completed, .offlineFailed:
            return false
        }
    }

    /// Retry analysis through the Recordings action model: same checks, closure and log event.
    @discardableResult
    func retryAnalysis(_ id: String) -> Bool {
        recordings.perform(.retryAnalysis, on: id)
    }

    func showInRecordings(_ id: String) {
        recordings.revealInList(sessionId: id)
        navigation.selectedSessionId = id
        navigation.section = .recordings
    }

    func showUnfinishedInRecordings() {
        recordings.clearFilters()
        recordings.statusFilter = .unfinished
        navigation.section = .recordings
    }

    func showSettings(_ tab: SettingsTab) {
        navigation.settings.selectedTab = tab
        navigation.section = .settings
    }

    /// Reveal recordings folder… first shows `sessionsFolderWarning`, like Reveal archive… in Recordings.
    func requestRevealSessionsFolder() {
        if !isConfirmingSessionsReveal { isConfirmingSessionsReveal = true }
    }

    func cancelRevealSessionsFolder() {
        if isConfirmingSessionsReveal { isConfirmingSessionsReveal = false }
    }

    /// Shows the sessions folder in Finder after the warning was confirmed.
    func confirmRevealSessionsFolder() {
        if isConfirmingSessionsReveal { isConfirmingSessionsReveal = false }
        AgentLog.event("main_reveal_sessions", [:])
        dependencies.revealSessionsFolder()
    }

    func openReleasesPage() {
        AgentLog.event("main_open_releases", [:])
        dependencies.openReleasesPage()
    }
}

// MARK: - Views

struct OverviewView: View {
    @ObservedObject var model: OverviewModel
    @ObservedObject var recordings: RecordingsModel
    @ObservedObject var library: SessionLibrary

    var body: some View {
        Form {
            readinessSection
            attentionSection
            lastRecordingSection
            storageSection
        }
        .formStyle(.grouped)
        .onAppear { model.sectionDidAppear() }
        .onDisappear { model.sectionDidDisappear() }
        .confirmationDialog(
            "Reveal private files?",
            isPresented: Binding(
                get: { model.isConfirmingSessionsReveal },
                set: { if !$0 { model.cancelRevealSessionsFolder() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Reveal folder") { model.confirmRevealSessionsFolder() }
                .accessibilityIdentifier("main.overview.confirmRevealSessions")
            Button("Cancel", role: .cancel) { model.cancelRevealSessionsFolder() }
        } message: {
            Text(OverviewModel.sessionsFolderWarning)
        }
        .accessibilityIdentifier("main.overview")
    }

    /// The first scan of the session index has not finished.
    private var isLoadingSessions: Bool {
        library.isLoading || (!recordings.hasLoaded && library.entries.isEmpty)
    }

    // MARK: Ready to record?

    private var readinessSection: some View {
        Section("Ready to record?") {
            startRow
            if let readiness = model.readiness {
                ForEach(readiness.rows) { row in
                    OverviewReadinessRowView(model: model, row: row)
                }
                if let line = model.preloadLine {
                    Text(line)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var startRow: some View {
        let card = model.startCard
        return HStack(alignment: .center, spacing: 12) {
            OverviewStartIcon(icon: card.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.headline)
                    .font(.headline)
                ForEach(card.lines, id: \.self) { line in
                    Text(line)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button {
                model.startRecording()
            } label: {
                Text("Start recording — \(model.captureAreaSummary)")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .fixedSize()
            .disabled(!model.isStartButtonEnabled)
            .help(model.startUnavailableReason ?? OverviewModel.startHelp)
            .accessibilityIdentifier("main.overview.start")
        }
        .padding(.vertical, 4)
    }

    // MARK: Needs attention

    private var attentionSection: some View {
        let attention = model.attention
        return Section("Needs attention") {
            if attention.isEmpty {
                if isLoadingSessions {
                    ProgressView("Checking recordings…")
                        .controlSize(.small)
                } else {
                    Label("Nothing needs attention.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(attention.unfinished.prefix(OverviewAttention.unfinishedLimit)) { summary in
                unfinishedRow(summary)
            }
            if attention.unfinished.count > OverviewAttention.unfinishedLimit {
                Button("Show all \(model.unfinishedInRecordingsCount) unfinished recordings") {
                    model.showUnfinishedInRecordings()
                }
                .accessibilityIdentifier("main.overview.attention.showUnfinished")
            }
            if let first = attention.unreadableIds.first {
                let count = attention.unreadableIds.count
                OverviewAttentionRow(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "Unreadable manifest",
                    detail: count == 1
                        ? "1 recording could not be read. Reveal its folder or delete it in Recordings."
                        : "\(count) recordings could not be read. Reveal their folders or delete them in Recordings."
                ) {
                    Button("Show in Recordings") { model.showInRecordings(first) }
                        .accessibilityIdentifier("main.overview.attention.showUnreadable")
                }
            }
            if let error = attention.lastError {
                OverviewAttentionRow(systemImage: "xmark.octagon.fill", tint: .red, title: "Last error", detail: error) {
                    Button("Open agent log") { model.showSettings(.logs) }
                        .accessibilityIdentifier("main.overview.attention.openLog")
                    Button("Dismiss") { model.dismissLastError() }
                        .accessibilityIdentifier("main.overview.attention.dismissError")
                }
            }
            if let days = attention.retentionDays {
                OverviewAttentionRow(
                    systemImage: "clock.arrow.circlepath",
                    tint: .secondary,
                    title: "Retention",
                    detail: OverviewAttention.retentionLine(days: days)
                ) {
                    Button("Open General settings") { model.showSettings(.general) }
                        .accessibilityIdentifier("main.overview.attention.retention")
                }
            }
            if let update = attention.availableUpdate {
                OverviewAttentionRow(
                    systemImage: "arrow.down.circle.fill",
                    tint: .accentColor,
                    title: "Update available",
                    detail: update.settingsLine
                ) {
                    Button("Open releases page") { model.openReleasesPage() }
                        .accessibilityIdentifier("main.overview.attention.releases")
                }
            }
        }
    }

    private func unfinishedRow(_ summary: SessionSummary) -> some View {
        let entry = SessionEntry.loaded(summary)
        let retryReason = recordings.unavailableReason(.retryAnalysis, for: entry)
        return OverviewAttentionRow(
            systemImage: "exclamationmark.circle.fill",
            tint: .orange,
            title: RecordingRowText.date(entry),
            status: PipelineStatusOrder.label(summary.pipelineStatus),
            detail: "\(RecordingRowText.contextAndProduct(summary)) · \(SessionController.clock(summary.mediaSeconds)) recorded. \(RecordingRowText.unfinishedNote(summary))"
        ) {
            Button(RecordingAction.retryAnalysis.title) { model.retryAnalysis(summary.sessionId) }
                .disabled(!recordings.isEnabled(.retryAnalysis, for: entry))
                .help(retryReason ?? "Run the analysis of this recording again.")
                .accessibilityIdentifier("main.overview.attention.retry.\(summary.sessionId)")
            Button("Show in Recordings") { model.showInRecordings(summary.sessionId) }
                .accessibilityIdentifier("main.overview.attention.show.\(summary.sessionId)")
        }
    }

    // MARK: Last recording

    private var lastRecordingSection: some View {
        Section("Last recording") {
            if let summary = model.lastRecording {
                lastRecordingCard(summary)
            } else if isLoadingSessions {
                ProgressView("Loading recordings…")
                    .controlSize(.small)
            } else if library.entries.contains(where: { $0.summary == nil }) {
                Text("No recording could be read. Recordings lists each folder with what you can do.")
                    .foregroundStyle(.secondary)
            } else {
                // Also shown while the first recording is still being captured.
                Text("No recordings yet. A recording appears here after you stop it.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func lastRecordingCard(_ summary: SessionSummary) -> some View {
        let entry = SessionEntry.loaded(summary)
        let tasks = summary.taskCounts
        let shots = summary.shotCount == 1 ? "1 Shot" : "\(summary.shotCount) Shots"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(RecordingRowText.date(entry))
                    .font(.headline)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(PipelineStatusOrder.label(summary.pipelineStatus))
                    .foregroundStyle(.secondary)
            }
            Text("\(RecordingRowText.contextAndProduct(summary)) · \(SessionController.clock(summary.mediaSeconds)) recorded · \(shots) · \(tasks.confirmed) confirmed, \(tasks.needsReview) need review")
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            OverviewButtonRow {
                Button("Show in Recordings") { model.showInRecordings(summary.sessionId) }
                    .accessibilityIdentifier("main.overview.last.show")
                ForEach(OverviewModel.lastRecordingActions) { action in
                    Button(action.title) { recordings.perform(action, on: summary.sessionId) }
                        .disabled(!recordings.isEnabled(action, for: entry))
                        .help(recordings.unavailableReason(action, for: entry) ?? action.title)
                        .accessibilityIdentifier("main.overview.last.\(action.rawValue)")
                }
            }
            if let message = recordings.message {
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Storage

    private var storageSection: some View {
        Section("Storage") {
            // The same noun as the rest of the window and the Keep recordings picker in General settings.
            LabeledContent("Recordings folder") {
                Text(model.sessionsFolder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(model.sessionsFolder)
            }
            LabeledContent("Recordings", value: recordingCount)
            LabeledContent("Private archives") {
                Text(library.totalArchiveBytes.map(RecordingRowText.bytes) ?? "Measuring…")
                    .monospacedDigit()
            }
            LabeledContent("Keep recordings", value: model.retentionDays > 0 ? "\(model.retentionDays) days" : "Forever")
            OverviewButtonRow {
                Button("Reveal recordings folder…") { model.requestRevealSessionsFolder() }
                    .accessibilityIdentifier("main.overview.revealSessions")
                Button("Open General settings") { model.showSettings(.general) }
                    .accessibilityIdentifier("main.overview.retentionSettings")
            }
            Text("Every recording’s archive/ folder counts toward Private archives. The total is measured in the background. Retention is set in General settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var recordingCount: String {
        if isLoadingSessions { return "Counting…" }
        let total = library.entries.count
        let unreadable = library.entries.filter { $0.summary == nil }.count
        let count = total == 1 ? "1 recording" : "\(total) recordings"
        return unreadable == 0 ? count : "\(count), \(unreadable) unreadable"
    }
}

/// Buttons side by side, or stacked when the section is too narrow for one line.
private struct OverviewButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
        .controlSize(.small)
    }
}

private struct OverviewReadinessRowView: View {
    @ObservedObject var model: OverviewModel
    let row: OverviewReadiness.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            OverviewStateIcon(marker: row.marker)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                    Spacer(minLength: 8)
                    Text(row.status)
                        .foregroundStyle(row.state == .actionNeeded ? .primary : .secondary)
                        .multilineTextAlignment(.trailing)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !row.actions.isEmpty {
                    OverviewButtonRow {
                        ForEach(row.actions) { action in
                            Button(title(for: action)) { model.perform(action) }
                                .disabled(!model.isEnabled(action))
                                .help(model.unavailableReason(action) ?? action.title)
                                .accessibilityIdentifier(row.accessibilityIdentifier(for: action))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("main.overview.readiness.row.\(row.item.rawValue)")
    }

    private func title(for action: OverviewReadinessAction) -> String {
        action == .preloadSpeechModel && model.isPreloadingSpeechModel ? "Loading Whisper model…" : action.title
    }
}

/// The first row of Ready to record?: an icon, a headline and the lines under it. Pure, so tests read what the card says
/// without a view. While recording or analysis runs, the card says so instead of showing readiness, so it never reads
/// “Ready to record” beside a Start button that waits.
struct OverviewStartCard: Equatable {
    enum Icon: Equatable {
        /// Readiness has not been read yet.
        case checking
        /// Neutral: a recording starts, runs or is paused.
        case recording
        /// Neutral: analysis runs.
        case analysis
        case ready
        case blocked
    }

    static let checkingHeadline = "Checking whether a recording can start…"
    static let recordingHeadline = "Recording in progress"
    static let analysisHeadline = "Analysis in progress"

    let icon: Icon
    let headline: String
    let lines: [String]

    init(readiness: OverviewReadiness?, canChangeSessions: Bool, isRecordingActive: Bool, isPreparingRecording: Bool) {
        if !canChangeSessions {
            icon = isRecordingActive ? .recording : .analysis
            headline = isRecordingActive ? Self.recordingHeadline : Self.analysisHeadline
            lines = [RecordingsModel.busyReason]
            return
        }
        let preparing = isPreparingRecording ? [OverviewModel.preparingReason] : []
        guard let readiness else {
            icon = .checking
            headline = Self.checkingHeadline
            lines = preparing
            return
        }
        icon = readiness.allowsStart ? .ready : .blocked
        headline = readiness.headline
        lines = [readiness.summary] + preparing
    }
}

/// The Start row's icon. Recording and analysis in progress are neutral: nothing is wrong.
private struct OverviewStartIcon: View {
    let icon: OverviewStartCard.Icon

    var body: some View {
        image
            .font(.title2)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var image: some View {
        switch icon {
        case .checking:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .recording:
            Image(systemName: "record.circle").foregroundStyle(.secondary)
        case .analysis:
            Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .blocked:
            // The same symbol as the row that blocks recording.
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// A blocking row has its own symbol, not only its own colour, so it reads apart from one that only asks.
private struct OverviewStateIcon: View {
    let marker: OverviewReadiness.Marker

    var body: some View {
        icon
            .help(marker.label)
            .accessibilityLabel(marker.label)
    }

    @ViewBuilder
    private var icon: some View {
        switch marker {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .blocksRecording:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .actionNeeded:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .optional:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

/// One Needs attention line: an icon, a title with an optional status, plain detail and its buttons.
private struct OverviewAttentionRow<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    var status: String?
    let detail: String
    @ViewBuilder let actions: Actions

    init(
        systemImage: String,
        tint: Color,
        title: String,
        status: String? = nil,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.status = status
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    if let status {
                        Text(status).foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                OverviewButtonRow { actions }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
