#if os(macOS)
import AppKit
import SwiftUI

final class MenuBarController {
    private let controller: SessionController
    private let item: NSStatusItem
    private var hud: RecordingHUDWindow?
    private var cancellable: Any?

    init(controller: SessionController, hud: RecordingHUDWindow) {
        self.controller = controller
        self.hud = hud
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "ScrumTrace")
            button.image?.isTemplate = true
        }
        rebuild()
        NotificationCenter.default.addObserver(
            forName: .init("ScrumTrace.rebuildMenu"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuild()
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sync()
        }
    }

    private func sync() {
        hud?.setVisible(controller.isRecording)
        if let button = item.button {
            let symbol = controller.phase == .paused
                ? "pause.circle.fill"
                : (controller.isRecording ? "record.circle.fill" : "record.circle")
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScrumTrace")
        }
        rebuild()
    }

    private func rebuild() {
        let menu = NSMenu()
        if controller.isRecording {
            menu.addItem(actionItem(
                controller.phase == .paused ? "Resume" : "Pause",
                #selector(pause)
            ))
            menu.addItem(actionItem("Shot  ⌥⌘S", #selector(shot)))
            menu.addItem(actionItem("Pin  ⌥⌘Space", #selector(pin)))
            menu.addItem(actionItem("Stop & process", #selector(stop)))
        } else {
            menu.addItem(actionItem("Start recording", #selector(start)))
        }
        menu.addItem(.separator())
        let retry = actionItem("Retry analysis", #selector(retry))
        retry.isEnabled = controller.lastSessionId != nil
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
                    action: #selector(openRecent(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = session.sessionId
                item.target = self
                recentMenu.addItem(item)
            }
        }
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
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

    @objc private func start() { controller.startRecording() }
    @objc private func stop() { controller.stopRecording() }
    @objc private func pause() { controller.togglePause() }
    @objc private func shot() { controller.openShot() }
    @objc private func pin() { controller.pin() }
    @objc private func retry() { controller.retryAnalysis() }
    @objc private func reveal() { controller.revealLast() }
    @objc private func settings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quit() {
        if controller.isRecording {
            controller.stopRecording()
        }
        NSApp.terminate(nil)
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller.vault.revealInFinder(sessionId: id)
    }
}
#endif
