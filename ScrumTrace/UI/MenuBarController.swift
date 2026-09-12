#if os(macOS)
import AppKit
import SwiftUI

/// Status-item UI. Isolated on the main actor so it can read `SessionController`
/// on Xcode 26 / Swift 6. `@objc` selectors need `NSObject`.
@MainActor
final class MenuBarController: NSObject {
    private let controller: SessionController
    private let item: NSStatusItem
    private var hud: RecordingHUDWindow?
    private var lastMenuSignature = ""
    private var statusMenuItem: NSMenuItem?
    private var hudObserver: NSObjectProtocol?
    private var lastStartEnabled: Bool?

    init(controller: SessionController, hud: RecordingHUDWindow) {
        self.controller = controller
        self.hud = hud
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
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
            controller.captureState.rawValue,
            controller.privacy.isCurrentlyTripped ? "priv" : "ok",
            readiness.menuLabel,
            controller.lastError == nil ? "ok" : "err",
            controller.settings.captureArea.summary
        ].joined(separator: "|")
        if signature != lastMenuSignature {
            lastMenuSignature = signature
            rebuild()
        }
        statusMenuItem?.title = controller.statusLine
        statusMenuItem?.isHidden = false
    }

    private func rebuild() {
        let menu = NSMenu()
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
                "Start recording — \(controller.settings.captureArea.summary)",
                #selector(start)
            )
            start.isEnabled = !controller.isBusy
            if lastStartEnabled != start.isEnabled {
                lastStartEnabled = start.isEnabled
                AgentLog.event("start_control_state", ["enabled": start.isEnabled ? "1" : "0"])
            }
            menu.addItem(start)
            let areaRoot = NSMenuItem(
                title: "Capture area: \(controller.settings.captureArea.summary)",
                action: nil,
                keyEquivalent: ""
            )
            let areaMenu = NSMenu()
            let change = actionItem("Select area on screen…", #selector(selectCaptureArea))
            change.isEnabled = !controller.isBusy
            areaMenu.addItem(change)
            let full = actionItem("Use entire display", #selector(useEntireDisplay))
            full.isEnabled = !controller.isBusy && !controller.settings.captureArea.isEntireDisplay
            areaMenu.addItem(full)
            areaRoot.submenu = areaMenu
            menu.addItem(areaRoot)
        }
        let status = NSMenuItem(title: controller.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.isHidden = false
        menu.addItem(status)
        statusMenuItem = status
        let readiness = CapturePermissions.readiness(requireMicrophone: controller.settings.includeMicrophone)
        let perm = NSMenuItem(title: readiness.menuLabel, action: nil, keyEquivalent: "")
        perm.isEnabled = false
        menu.addItem(perm)
        if !readiness.allowsStart {
            let relaunch = actionItem("Relaunch ScrumTrace", #selector(relaunch))
            relaunch.isEnabled = !controller.isRecording && !controller.isBusy
            menu.addItem(relaunch)
        }
        menu.addItem(.separator())
        let retry = actionItem("Retry analysis", #selector(retry))
        retry.isEnabled = controller.lastSessionId != nil && !controller.isBusy && !controller.isRecording
        menu.addItem(retry)
        let reveal = actionItem("Reveal last session", #selector(reveal))
        reveal.isEnabled = controller.lastSessionId != nil
        menu.addItem(reveal)
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let sessions = controller.vault.recentSessions()
        if sessions.isEmpty {
            recentMenu.addItem(NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: ""))
        } else {
            for session in sessions {
                let item = NSMenuItem(
                    title: "\(session.sessionId) · \(PipelineStatusOrder.label(session.pipelineStatus))",
                    action: nil,
                    keyEquivalent: ""
                )
                let sub = NSMenu()
                let revealItem = NSMenuItem(
                    title: "Reveal export/",
                    action: #selector(openRecent(_:)),
                    keyEquivalent: ""
                )
                revealItem.representedObject = session.sessionId
                revealItem.target = self
                let retryItem = NSMenuItem(
                    title: "Retry analysis",
                    action: #selector(retryRecent(_:)),
                    keyEquivalent: ""
                )
                retryItem.representedObject = session.sessionId
                retryItem.target = self
                retryItem.isEnabled = !controller.isBusy && !controller.isRecording
                sub.addItem(revealItem)
                sub.addItem(retryItem)
                item.submenu = sub
                recentMenu.addItem(item)
            }
        }
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        let settingsRoot = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        settingsMenu.addItem(actionItem("Settings Window…", #selector(settings)))
        settingsMenu.addItem(actionItem("Agent Log…", #selector(settings)))
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(actionItem("Log permission probe", #selector(probePermissions)))
        settingsMenu.addItem(actionItem("Reveal agent log", #selector(revealLog)))
        settingsMenu.addItem(actionItem("Export diagnostic bundle", #selector(exportDiagnostics)))
        settingsMenu.addItem(actionItem("Reveal sessions folder", #selector(revealSessions)))
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(actionItem("Ask for Screen Recording", #selector(askScreen)))
        settingsMenu.addItem(actionItem("Open Screen Recording settings", #selector(openScreenSettings)))
        settingsMenu.addItem(actionItem("Open Microphone settings", #selector(openMicSettings)))
        settingsMenu.addItem(actionItem("Relaunch ScrumTrace", #selector(relaunch)))
        settingsMenu.addItem(actionItem("Check for updates", #selector(checkUpdates)))
        settingsRoot.submenu = settingsMenu
        menu.addItem(settingsRoot)
        menu.addItem(actionItem("Quit ScrumTrace", #selector(quit)))
        for item in menu.items where item.action != nil && item.target == nil {
            item.target = self
        }
        self.item.menu = menu
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func selectCaptureArea() {
        AgentLog.event("menu_select_area", [:])
        CaptureAreaPicker.present(current: controller.settings.captureArea) { [weak self] area in
            self?.controller.settings.captureArea = area
            self?.rebuild()
        }
    }

    @objc private func useEntireDisplay() {
        AgentLog.event("menu_area_full", [:])
        controller.settings.captureArea = .entireDisplay
        rebuild()
    }

    @objc private func start() {
        AgentLog.event("menu_start", [:])
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
        CaptureAreaPicker.present(current: controller.settings.captureArea, mode: .record) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancelled:
                return
            case .selected(let area):
                self.controller.settings.captureArea = area
                self.rebuild()
            case .record(let area):
                self.controller.settings.captureArea = area
                self.rebuild()
                self.controller.startRecording()
            }
        }
    }

    @discardableResult
    private func presentMeetingNotice() -> Bool {
        let alert = NSAlert()
        alert.messageText = "This Mac will record the meeting"
        alert.informativeText = "Screen, system audio, and microphone are captured locally. Tell other participants before you press Record. See docs/PARTICIPANT_NOTICE.md."
        alert.addButton(withTitle: "I will tell participants")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let accepted = alert.runModal() == .alertFirstButtonReturn
        AgentLog.event("meeting_notice", ["accepted": accepted ? "1" : "0"])
        if accepted {
            controller.settings.meetingNoticeAccepted = true
        }
        return accepted
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
    @objc private func reveal() {
        AgentLog.event("menu_reveal", [:])
        controller.revealLast()
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
    @objc private func settings() {
        AgentLog.event("menu_settings", [:])
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
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
        AgentLog.event("menu_updates", [:])
        Task {
            let result = await UpdateChecker.check()
            AgentLog.event("update_check", [
                "result": {
                    switch result {
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
        AgentLog.event("menu_quit", [:])
        // applicationWillTerminate freezes writers. Do not start the
        // transcription pipeline — that would run Whisper/AI on a dying process.
        NSApp.terminate(nil)
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
}
#endif
