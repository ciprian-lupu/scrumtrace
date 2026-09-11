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
        let readiness = CapturePermissions.readiness()
        let signature = [
            controller.captureState == .paused ? "paused" : "live",
            controller.isRecording ? "1" : "0",
            controller.lastSessionId ?? "",
            controller.isBusy ? "1" : "0",
            controller.captureState.rawValue,
            controller.privacy.isCurrentlyTripped ? "priv" : "ok",
            readiness.menuLabel,
            controller.lastError == nil ? "ok" : "err"
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
            let shotItem = actionItem("Shot  ⌥⌘S", #selector(shot))
            shotItem.isEnabled = controller.captureState.allowsNewCapture
            menu.addItem(shotItem)
            let pinItem = actionItem("Pin  ⌥⌘Space", #selector(pin))
            pinItem.isEnabled = controller.captureState.allowsNewCapture
            menu.addItem(pinItem)
            menu.addItem(actionItem("Stop & process", #selector(stop)))
        } else {
            let start = actionItem("Start recording", #selector(start))
            start.isEnabled = !controller.isBusy
            if lastStartEnabled != start.isEnabled {
                lastStartEnabled = start.isEnabled
                AgentLog.event("start_control_state", ["enabled": start.isEnabled ? "1" : "0"])
            }
            menu.addItem(start)
        }
        let status = NSMenuItem(title: controller.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.isHidden = false
        menu.addItem(status)
        statusMenuItem = status
        let readiness = CapturePermissions.readiness()
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
        menu.addItem(actionItem("Log permission probe", #selector(probePermissions)))
        menu.addItem(actionItem("Reveal agent log", #selector(revealLog)))
        menu.addItem(actionItem("Settings…", #selector(settings)))
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

    @objc private func start() {
        let readiness = CapturePermissions.readiness()
        if !readiness.allowsStart {
            presentStartBlocked(readiness)
        }
        controller.startRecording()
    }

    private func presentStartBlocked(_ readiness: CaptureReadiness) {
        let alert = NSAlert()
        alert.messageText = "Cannot start recording"
        alert.informativeText = readiness.userMessage
        switch readiness {
        case .ready:
            return
        case .screenDenied:
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
                SystemPrivacySettings.openScreenRecording()
            } else if response == .alertSecondButtonReturn {
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
    @objc private func stop() { controller.stopRecording() }
    @objc private func pause() { controller.togglePause() }
    @objc private func shot() { controller.openShot() }
    @objc private func pin() { controller.pin() }
    @objc private func retry() { controller.retryAnalysis() }
    @objc private func reveal() { controller.revealLast() }
    @objc private func revealLog() {
        AgentLog.reveal()
    }
    @objc private func probePermissions() {
        CapturePermissions.probeAndLog()
        controller.statusLine = "Permission probe written to agent log"
    }
    @objc private func settings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func relaunch() {
        controller.relaunchForPermissions()
    }
    @objc private func quit() {
        // applicationWillTerminate freezes writers. Do not start the
        // transcription pipeline — that would run Whisper/AI on a dying process.
        NSApp.terminate(nil)
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller.vault.revealInFinder(sessionId: id)
    }

    @objc private func retryRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller.retryAnalysis(sessionId: id)
    }
}
#endif
