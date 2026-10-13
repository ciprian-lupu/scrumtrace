#if os(macOS)
import AppKit
import SwiftUI

/// Status-item UI. Isolated on the main actor so it can read `SessionController`
/// on Xcode 26 / Swift 6. `@objc` selectors need `NSObject`.
@MainActor
final class MenuBarController: NSObject {
    private let controller: SessionController
    private let item: NSStatusItem
    let menu = NSMenu()
    private let openSettings: () -> Void
    private let openLogs: () -> Void
    private let openMain: () -> Void
    private let openRecordings: () -> Void
    private var isMenuOpen = false
    private var checkingUpdates = false
    private var hud: RecordingHUDWindow?
    private var lastMenuSignature = ""
    private var statusMenuItem: NSMenuItem?
    private var hudObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var lastStartEnabled: Bool?
    private let contextPresenter = RecordingContextPresenter()
    var openBriefURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// True while the recording-context window or the capture-area overlay of a Start is up.
    /// The main window reads it to disable its own Start recording button.
    private(set) var isPreparingRecording = false

    init(
        controller: SessionController,
        hud: RecordingHUDWindow? = nil,
        openSettings: @escaping () -> Void,
        openLogs: @escaping () -> Void,
        openMain: @escaping () -> Void = {},
        openRecordings: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.hud = hud
        self.openSettings = openSettings
        self.openLogs = openLogs
        self.openMain = openMain
        self.openRecordings = openRecordings ?? openMain
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "ScrumTrace")
            button.image?.isTemplate = true
        }
        rebuild()
        hudObserver = NotificationCenter.default.addObserver(
            forName: .scrumTraceHUDSuppress,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sync()
            }
        }
        // A display plugged in or removed changes the Display rows; the pinned recording target never changes.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.controller.settings.refreshConnectedDisplays()
                if !self.isMenuOpen {
                    self.rebuild()
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sync()
            }
        }
    }

    private func sync() {
        hud?.refresh()
        hud?.setVisible(controller.hudShouldShow)
        if let button = item.button {
            let symbol: String
            if controller.isBusy {
                symbol = "gearshape.circle.fill"
            } else if controller.isRecording && controller.captureState == .paused {
                symbol = "pause.circle.fill"
            } else if controller.isRecording {
                symbol = "record.circle.fill"
            } else {
                symbol = "record.circle"
            }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScrumTrace")
        }
        // Do not include statusLine — rebuilding the menu closes it. Update the
        // disabled status item in place while processing.
        let readiness = CapturePermissions.readiness(requireMicrophone: controller.settings.includeMicrophone)
        let signature = [
            controller.captureState == .paused ? "paused" : "live",
            controller.isRecording ? "1" : "0",
            controller.lastSessionId ?? "",
            controller.isBusy ? "1" : "0",
            controller.startInFlight ? "1" : "0",
            checkingUpdates ? "updates" : "idle",
            isPreparingRecording ? "context" : "idle",
            controller.captureState.rawValue,
            controller.privacy.isCurrentlyTripped ? "priv" : "ok",
            readiness.menuLabel,
            controller.lastError == nil ? "ok" : "err",
            controller.settings.captureSummary
        ].joined(separator: "|")
        if signature != lastMenuSignature && !isMenuOpen {
            lastMenuSignature = signature
            rebuild()
        }
        statusMenuItem?.title = menuStatusTitle
        statusMenuItem?.toolTip = controller.displayStatusLine
        statusMenuItem?.isHidden = false
    }

    private func rebuild() {
        menu.removeAllItems()
        let status = NSMenuItem(title: menuStatusTitle, action: nil, keyEquivalent: "")
        status.toolTip = controller.displayStatusLine
        status.isEnabled = false
        status.isHidden = false
        menu.addItem(status)
        statusMenuItem = status
        menu.addItem(.separator())
        if controller.isRecording {
            let pauseItem = actionItem(
                controller.captureState == .paused ? "Resume" : "Pause",
                #selector(pause)
            )
            if controller.captureState == .paused {
                pauseItem.isEnabled = controller.canResumeFromPause
            }
            menu.addItem(pauseItem)
            let shotItem = actionItem("Shot  \(HotkeyManager.shotLabel)", #selector(shot))
            shotItem.isEnabled = controller.captureState.allowsNewCapture
            menu.addItem(shotItem)
            let pinItem = actionItem("Pin  \(HotkeyManager.pinLabel)", #selector(pin))
            pinItem.isEnabled = controller.captureState.allowsNewCapture
            menu.addItem(pinItem)
            menu.addItem(actionItem("Stop & process", #selector(stop)))
        } else {
            let start = actionItem(
                "Start recording…",
                #selector(start)
            )
            start.toolTip = "Start recording — \(controller.settings.captureSummary)"
            start.isEnabled = !controller.isBusy && !controller.startInFlight && !isPreparingRecording
            if lastStartEnabled != start.isEnabled {
                lastStartEnabled = start.isEnabled
                AgentLog.event("start_control_state", ["enabled": start.isEnabled ? "1" : "0"])
            }
            menu.addItem(start)
            let areaRoot = NSMenuItem(
                title: "Capture area: \(controller.settings.captureSummary)",
                action: nil,
                keyEquivalent: ""
            )
            let areaMenu = NSMenu()
            areaMenu.autoenablesItems = false
            let change = actionItem("Select area on screen…", #selector(selectCaptureArea))
            change.isEnabled = controller.canChangeCaptureSettings
            areaMenu.addItem(change)
            // "Main display" is disabled only when it is already the choice, so a named display can be reset.
            let full = actionItem("Main display", #selector(useEntireDisplay))
            full.isEnabled = controller.canChangeCaptureSettings
                && (controller.settings.recordSingleWindow || !controller.settings.captureArea.targetsMainDisplay)
            full.state = controller.settings.selectedDisplayID == 0 && !controller.settings.recordSingleWindow ? .on : .off
            areaMenu.addItem(full)
            let displays = controller.settings.connectedDisplays
            for display in displays {
                let row = actionItem(
                    CaptureDisplayResolver.label(for: display, among: displays),
                    #selector(selectDisplay(_:))
                )
                row.representedObject = NSNumber(value: display.id)
                row.isEnabled = controller.canChangeCaptureSettings
                row.state = controller.settings.selectedDisplayID == display.id ? .on : .off
                areaMenu.addItem(row)
            }
            if let missing = controller.settings.savedDisplayNotConnected {
                let row = NSMenuItem(
                    title: "\(missing.displayName ?? "Display \(missing.displayID)") (not connected)",
                    action: nil,
                    keyEquivalent: ""
                )
                row.isEnabled = false
                row.state = .on
                areaMenu.addItem(row)
            }
            areaMenu.addItem(.separator())
            let window = actionItem("Record a single window", #selector(recordSingleWindow))
            window.isEnabled = controller.canChangeCaptureSettings
            window.state = controller.settings.recordSingleWindow ? .on : .off
            areaMenu.addItem(window)
            areaRoot.submenu = areaMenu
            menu.addItem(areaRoot)
        }
        let readiness = CapturePermissions.readiness(requireMicrophone: controller.settings.includeMicrophone)
        if !readiness.allowsStart {
            let permission = NSMenuItem(title: readiness.menuLabel, action: nil, keyEquivalent: "")
            permission.isEnabled = false
            menu.addItem(permission)
            let fix: NSMenuItem
            switch readiness {
            case .screenGrantedNeedsRelaunch:
                fix = actionItem("Relaunch ScrumTrace", #selector(relaunch))
                fix.isEnabled = controller.canChangeCaptureSettings
            case .microphoneDenied:
                fix = actionItem("Open Microphone settings", #selector(openMicSettings))
            case .screenDenied, .ready:
                fix = actionItem("Open Screen Recording settings", #selector(openScreenSettings))
            }
            menu.addItem(fix)
        }
        menu.addItem(.separator())
        let sessions = controller.vault.recentSessions(limit: 5)
        let last = NSMenuItem(title: "Last recording", action: nil, keyEquivalent: "")
        last.isEnabled = controller.lastSessionId != nil
        last.submenu = recordingMenu(sessionId: controller.lastSessionId, isLast: true)
        menu.addItem(last)

        let recent = NSMenuItem(title: "Recent recordings", action: nil, keyEquivalent: "")
        let recentMenu = makeSubmenu()
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for session in sessions {
                let isActive = (controller.isRecording || controller.isBusy) && controller.activeSessionId == session.sessionId
                let probe = session.pipelineStatus == .offlineFailed
                    ? SessionExportProbe.probe(sessionURL: controller.vault.sessionURL(id: session.sessionId)) : SessionExportProbe()
                let recording = NSMenuItem(title: Self.recordingLabel(session, isActive: isActive,
                    exportReady: session.hasCompleted(.synthesizing) && probe.hasBrief && probe.hasAgentContext), action: nil, keyEquivalent: "")
                recording.submenu = recordingMenu(sessionId: session.sessionId, isLast: false)
                recentMenu.addItem(recording)
            }
            recentMenu.addItem(.separator())
        }
        recentMenu.addItem(actionItem("Show all recordings…", #selector(showAllRecordings)))
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        // Enabled in every state: opening the window never changes capture.
        menu.addItem(actionItem("Open ScrumTrace…", #selector(openMainWindow)))
        menu.addItem(actionItem("Settings…", #selector(settings)))
        let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagnostics.submenu = diagnosticMenu(readiness: readiness)
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit ScrumTrace", #selector(quit)))
    }

    /// Keep the menu narrow while preserving the measured percentage and elapsed time.
    private var menuStatusTitle: String {
        func shortened(_ text: String, limit: Int) -> String {
            let line = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        if controller.isBusy, let progress = controller.processingProgress {
            return [progress.percent.map { "\($0)%" }, shortened(progress.message, limit: 48), progress.elapsedLabel]
                .compactMap { $0 }.joined(separator: " · ")
        }
        return shortened(controller.statusLine, limit: 64)
    }

    private func makeSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        return submenu
    }

    /// Dates, duration and pipeline state come from manifest metadata only.
    static func recordingLabel(_ session: SessionManifest, isActive: Bool = false, exportReady: Bool = false) -> String {
        let date = DateFormatter.localizedString(from: session.createdAt, dateStyle: .short, timeStyle: .short)
        let seconds = session.duration.mediaSeconds
        let duration = seconds.isFinite && seconds >= 0 && seconds < Double(Int.max) / 2
            ? SessionController.clock(seconds) : "—"
        return "\(date) · \(duration) · \(RecordingStatusText.label(session.pipelineStatus, isActive: isActive, exportReady: exportReady))"
    }

    private func recordingMenu(sessionId: String?, isLast: Bool) -> NSMenu {
        let submenu = makeSubmenu()
        guard let sessionId else {
            let empty = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return submenu
        }
        if isLast, let session = try? controller.vault.loadManifest(id: sessionId) {
            let summary = NSMenuItem(title: Self.recordingLabel(session), action: nil, keyEquivalent: "")
            summary.isEnabled = false
            submenu.addItem(summary)
            submenu.addItem(.separator())
        }
        let brief = actionItem("Open brief", isLast ? #selector(openLastBrief) : #selector(openRecentBrief(_:)))
        brief.isEnabled = SessionFileAccess.briefURL(vault: controller.vault, id: sessionId) != nil
        let reveal = actionItem("Reveal export/", isLast ? #selector(reveal) : #selector(openRecent(_:)))
        let codex = actionItem("Open export in Codex", isLast ? #selector(openLastInChatGPT) : #selector(openRecentInChatGPT(_:)))
        let claude = actionItem("Open in Claude", isLast ? #selector(openLastInClaude) : #selector(openRecentInClaude(_:)))
        if isLast {
            claude.toolTip = "Open last session in Claude"
            codex.toolTip = "Open last export in Codex"
        }
        for item in [brief, reveal, codex, claude] {
            item.representedObject = sessionId
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let retry = actionItem("Retry analysis", isLast ? #selector(retry) : #selector(retryRecent(_:)))
        let review = actionItem("Review transcription results", isLast ? #selector(reviewTranscriptions) : #selector(reviewRecentTranscriptions(_:)))
        let compare = actionItem("Compare transcriptions", isLast ? #selector(compareTranscriptions) : #selector(compareRecentTranscriptions(_:)))
        for item in [retry, review, compare] {
            item.representedObject = sessionId
            item.isEnabled = controller.canChangeCaptureSettings
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let archive = actionItem("Open archive in Codex…", isLast ? #selector(openLastArchiveInCodex) : #selector(openRecentArchiveInCodex(_:)))
        archive.representedObject = sessionId
        archive.isEnabled = controller.canChangeCaptureSettings
        archive.toolTip = isLast ? "Open last archive in Codex — copies private originals after confirmation" : "Copies private originals after confirmation"
        submenu.addItem(archive)
        return submenu
    }

    private func diagnosticMenu(readiness: CaptureReadiness) -> NSMenu {
        let submenu = makeSubmenu()
        let permissions = NSMenuItem(title: readiness.menuLabel, action: nil, keyEquivalent: "")
        permissions.isEnabled = false
        submenu.addItem(permissions)
        submenu.addItem(.separator())
        submenu.addItem(actionItem("View logs…", #selector(agentLog)))
        submenu.addItem(actionItem("Reveal agent log", #selector(revealLog)))
        submenu.addItem(actionItem("Export diagnostic bundle", #selector(exportDiagnostics)))
        submenu.addItem(actionItem("Log permission probe", #selector(probePermissions)))
        submenu.addItem(actionItem("Reveal recordings folder", #selector(revealSessions)))
        submenu.addItem(.separator())
        let permissionsRoot = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let permissionsMenu = makeSubmenu()
        permissionsMenu.addItem(actionItem("Ask for Screen Recording", #selector(askScreen)))
        permissionsMenu.addItem(actionItem("Open Screen Recording settings", #selector(openScreenSettings)))
        permissionsMenu.addItem(actionItem("Open Microphone settings", #selector(openMicSettings)))
        permissionsRoot.submenu = permissionsMenu
        submenu.addItem(permissionsRoot)
        let relaunch = actionItem("Relaunch ScrumTrace", #selector(relaunch))
        relaunch.isEnabled = controller.canChangeCaptureSettings
        submenu.addItem(relaunch)
        submenu.addItem(.separator())
        let updates = actionItem(checkingUpdates ? "Checking for updates…" : "Check for updates", #selector(checkUpdates))
        updates.isEnabled = !checkingUpdates
        submenu.addItem(updates)
        return submenu
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func selectCaptureArea() {
        guard controller.canChangeCaptureSettings else { return }
        AgentLog.event("menu_select_area", [:])
        CaptureAreaPicker.present(current: controller.settings.captureArea) { [weak self] area in
            guard let self, self.controller.canChangeCaptureSettings else { return }
            self.controller.settings.captureArea = area
            self.controller.settings.recordSingleWindow = false
            self.rebuild()
        }
    }

    @objc private func useEntireDisplay() {
        guard controller.canChangeCaptureSettings else { return }
        AgentLog.event("menu_area_full", [:])
        controller.settings.captureArea = .entireDisplay
        controller.settings.recordSingleWindow = false
        rebuild()
    }

    /// One connected display as the whole-display capture area. The id is logged; names stay in the menu.
    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard controller.canChangeCaptureSettings,
              let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        AgentLog.event("menu_area_display", ["display": String(id)])
        controller.settings.selectDisplay(id: id)
        rebuild()
    }

    /// The window itself is picked at Start, because window IDs do not outlive the app.
    @objc private func recordSingleWindow() {
        guard controller.canChangeCaptureSettings else { return }
        AgentLog.event("menu_area_window", [:])
        controller.settings.recordSingleWindow = true
        rebuild()
    }

    /// A Start from the main window, which logs `main_start` itself. Logs no start row of its own.
    func requestStart() { runStartFlow(logging: nil) }

    /// New Recording… (Command-N) in the app menu.
    func startFromCommand() { runStartFlow(logging: "command_start") }

    /// Start recording in the status-bar menu, the only Start that logs `menu_start`.
    @objc private func start() {
        runStartFlow(logging: "menu_start")
    }

    /// Asks whether the user will tell participants. Tests replace it so the Start flow stops there without an alert.
    var askMeetingNotice: @MainActor () -> Bool = MenuBarController.runMeetingNoticeAlert

    /// Meeting notice, readiness, recording context, then the capture-area picker (the window chooser in
    /// single-window mode). `event` names the start row
    /// written once the flow begins; nil when the caller already logged one.
    private func runStartFlow(logging event: String?) {
        guard controller.canChangeCaptureSettings, !isPreparingRecording else { return }
        if let event { AgentLog.event(event, [:]) }
        if !controller.settings.meetingNoticeAccepted {
            if !presentMeetingNotice() {
                return
            }
        }
        let readiness = CapturePermissions.readiness(requireMicrophone: controller.settings.includeMicrophone)
        if !readiness.allowsStart {
            presentStartBlocked(readiness)
            return
        }
        isPreparingRecording = true
        rebuild()
        contextPresenter.present(controller: controller) { [weak self] product in
            guard let self else { return }
            guard let product, self.controller.canChangeCaptureSettings else {
                self.isPreparingRecording = false
                self.rebuild()
                return
            }
            if self.controller.settings.recordSingleWindow {
                CaptureWindowChooser.present { [weak self] window in
                    guard let self else { return }
                    self.isPreparingRecording = false
                    self.rebuild()
                    guard let window, self.controller.canChangeCaptureSettings else { return }
                    self.controller.startRecording(product: product, window: window)
                }
                return
            }
            CaptureAreaPicker.present(current: self.controller.settings.captureArea, mode: .record) { [weak self] outcome in
                guard let self else { return }
                self.isPreparingRecording = false
                self.rebuild()
                guard self.controller.canChangeCaptureSettings else { return }
                switch outcome {
                case .cancelled:
                    return
                case .selected(let area):
                    self.controller.settings.captureArea = area
                    self.rebuild()
                case .record(let area):
                    self.controller.settings.captureArea = area
                    self.rebuild()
                    self.controller.startRecording(product: product)
                }
            }
        }
    }

    @discardableResult
    private func presentMeetingNotice() -> Bool {
        let accepted = askMeetingNotice()
        AgentLog.event("meeting_notice", ["accepted": accepted ? "1" : "0"])
        if accepted {
            controller.settings.meetingNoticeAccepted = true
        }
        return accepted
    }

    /// The meeting-notice alert. True when the user will tell participants.
    private static func runMeetingNoticeAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "This Mac will record the meeting"
        alert.informativeText = "Screen, system audio, and microphone are captured locally. Tell other participants before you press Record. See docs/PARTICIPANT_NOTICE.md."
        alert.addButton(withTitle: "I will tell participants")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentStartBlocked(_ readiness: CaptureReadiness) {
        AgentLog.event("start_blocked_sheet", ["reason": CapturePermissions.readinessLabel()])
        let alert = NSAlert()
        alert.messageText = "Cannot start recording"
        alert.informativeText = readiness.userMessage
        switch readiness {
        case .ready:
            return
        case .screenDenied:
            // A fresh install is not listed under Screen Recording until the app
            // has asked once; "Open" alone shows a list without ScrumTrace.
            alert.addButton(withTitle: "Ask now")
            alert.addButton(withTitle: "Open Screen Recording")
            alert.addButton(withTitle: "Relaunch ScrumTrace")
            alert.addButton(withTitle: "Cancel")
        case .screenGrantedNeedsRelaunch:
            alert.addButton(withTitle: "Relaunch ScrumTrace")
            alert.addButton(withTitle: "Cancel")
        case .microphoneDenied:
            alert.addButton(withTitle: "Open Microphone")
            alert.addButton(withTitle: "Relaunch ScrumTrace")
            alert.addButton(withTitle: "Cancel")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch readiness {
        case .ready:
            return
        case .screenDenied:
            if response == .alertFirstButtonReturn {
                askScreen()
            } else if response == .alertSecondButtonReturn {
                SystemPrivacySettings.openScreenRecording()
            } else if response == .alertThirdButtonReturn {
                controller.relaunchForPermissions()
            }
        case .screenGrantedNeedsRelaunch:
            if response == .alertFirstButtonReturn {
                controller.relaunchForPermissions()
            }
        case .microphoneDenied:
            if response == .alertFirstButtonReturn {
                SystemPrivacySettings.openMicrophone()
            } else if response == .alertSecondButtonReturn {
                controller.relaunchForPermissions()
            }
        }
    }
    @objc private func stop() {
        AgentLog.event("menu_stop", [:])
        controller.stopRecording()
    }
    @objc private func pause() {
        AgentLog.event("menu_pause", [:])
        controller.togglePause()
    }
    @objc private func shot() {
        AgentLog.event("menu_shot", [:])
        controller.openShot()
    }
    @objc private func pin() {
        AgentLog.event("menu_pin", [:])
        controller.pin()
    }
    @objc private func retry() {
        AgentLog.event("menu_retry", [:])
        controller.retryAnalysis()
    }
    @objc private func compareTranscriptions() {
        guard let id = controller.lastSessionId else { return }
        AgentLog.event("menu_transcription_compare", ["session": id])
        controller.compareTranscriptions(sessionId: id)
    }
    @objc private func reviewTranscriptions() {
        guard let id = controller.lastSessionId else { return }
        AgentLog.event("menu_transcription_review", ["session": id])
        controller.reviewTranscriptions(sessionId: id)
    }
    @objc private func reveal() {
        AgentLog.event("menu_reveal", [:])
        controller.revealLast()
    }
    @objc private func openLastInClaude() {
        AgentLog.event("menu_claude", [:])
        controller.openInClaude()
    }
    @objc private func openLastInChatGPT() {
        AgentLog.event("menu_chatgpt", [:])
        controller.openInChatGPT()
    }
    @objc private func openLastArchiveInCodex() {
        AgentLog.event("menu_codex_archive", [:])
        controller.openPrivateArchiveInCodex()
    }
    @objc private func revealLog() {
        AgentLog.event("menu_reveal_log", [:])
        AgentLog.reveal()
    }
    @objc private func probePermissions() {
        AgentLog.event("menu_probe", [:])
        CapturePermissions.probeAndLog()
        controller.statusLine = "Permission probe written to agent log"
    }
    @objc private func openMainWindow() {
        AgentLog.event("menu_open_main", [:])
        openMain()
    }
    @objc private func showAllRecordings() {
        AgentLog.event("menu_open_recordings", [:])
        openRecordings()
    }

    @objc private func openLastBrief() {
        guard let id = controller.lastSessionId else { return }
        openBrief(sessionId: id)
    }

    @objc private func openRecentBrief(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openBrief(sessionId: id)
    }

    private func openBrief(sessionId: String) {
        guard let url = SessionFileAccess.briefURL(vault: controller.vault, id: sessionId) else {
            controller.statusLine = "The brief is not available yet."
            return
        }
        AgentLog.event("menu_open_brief", ["session": sessionId])
        if !openBriefURL(url) { controller.statusLine = "Could not open the recording brief." }
    }
    @objc private func settings() {
        AgentLog.event("menu_settings", [:])
        openSettings()
    }
    @objc private func agentLog() {
        AgentLog.event("menu_agent_log", [:])
        openLogs()
    }
    @objc private func exportDiagnostics() {
        AgentLog.event("menu_diagnostics", [:])
        do {
            let url = try AgentLog.exportDiagnosticBundle()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            controller.statusLine = "Diagnostic bundle written"
        } catch {
            controller.statusLine = error.localizedDescription
        }
    }
    @objc private func revealSessions() {
        AgentLog.event("menu_reveal_sessions", [:])
        controller.vault.revealRootInFinder()
    }
    @objc private func askScreen() {
        AgentLog.event("menu_ask_screen", [:])
        Task.detached {
            _ = CapturePermissions.requestScreenAccess()
        }
    }
    @objc private func openScreenSettings() {
        AgentLog.event("menu_screen_settings", [:])
        SystemPrivacySettings.openScreenRecording()
    }
    @objc private func openMicSettings() {
        AgentLog.event("menu_mic_settings", [:])
        SystemPrivacySettings.openMicrophone()
    }
    @objc private func checkUpdates() {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        AgentLog.event("menu_updates", [:])
        Task {
            defer { checkingUpdates = false }
            let result = await UpdateChecker.check()
            AgentLog.event("update_check", [
                "result": {
                    switch result {
                    case .noPublishedReleases:
                        return "no_releases"
                    case .upToDate:
                        return "up_to_date"
                    case .newerAvailable:
                        return "newer"
                    case .failed:
                        return "failed"
                    }
                }()
            ])
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "ScrumTrace updates"
                alert.informativeText = result.settingsLine
                alert.addButton(withTitle: "Open releases")
                alert.addButton(withTitle: "Close")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(UpdateChecker.releasesURL)
                }
            }
        }
    }
    @objc private func relaunch() {
        AgentLog.event("menu_relaunch", [:])
        controller.relaunchForPermissions()
    }
    @objc private func quit() {
        AgentLog.event("menu_quit", ["busy": controller.isBusy ? "1" : "0"])
        if controller.isBusy, !Self.confirmQuitWhileProcessing(statusLine: controller.statusLine) {
            AgentLog.event("menu_quit_cancelled", [:])
            return
        }
        // applicationWillTerminate freezes writers. Do not start the
        // transcription pipeline — that would run Whisper/AI on a dying process.
        NSApp.terminate(nil)
    }

    /// Quit chosen while a recording is still being processed. True when the user quits anyway; the next launch
    /// resumes the session (`SessionController.resumeInterruptedSession`).
    private static func confirmQuitWhileProcessing(statusLine: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "A recording is still being processed"
        alert.informativeText = "\(statusLine)\n\nQuitting stops it. The next launch of ScrumTrace picks the recording up where it stopped."
        alert.addButton(withTitle: "Keep processing")
        alert.addButton(withTitle: "Quit anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AgentLog.event("menu_reveal", ["session": id])
        controller.vault.revealInFinder(sessionId: id)
    }

    @objc private func retryRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AgentLog.event("menu_retry", ["session": id])
        controller.retryAnalysis(sessionId: id)
    }

    @objc private func compareRecentTranscriptions(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AgentLog.event("menu_transcription_compare", ["session": id])
        controller.compareTranscriptions(sessionId: id)
    }

    @objc private func reviewRecentTranscriptions(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AgentLog.event("menu_transcription_review", ["session": id])
        controller.reviewTranscriptions(sessionId: id)
    }

    @objc private func openRecentInClaude(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AgentLog.event("menu_claude", ["session": id])
        controller.openInClaude(sessionId: id)
    }

    @objc private func openRecentInChatGPT(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AgentLog.event("menu_chatgpt", ["session": id])
        controller.openInChatGPT(sessionId: id)
    }

    @objc private func openRecentArchiveInCodex(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AgentLog.event("menu_codex_archive", ["session": id])
        controller.openPrivateArchiveInCodex(sessionId: id)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh in the same menu before tracking begins. Replacing the status
        // item's menu while it is open dismisses recording/diagnostic submenus.
        rebuild()
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }
}
#endif
