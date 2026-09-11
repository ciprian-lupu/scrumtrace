#if os(macOS)
import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllerStorage: SessionController?
    /// Built on first MainActor access. A stored `SessionController()` hits NSObject's
    /// nonisolated `init` and fails Swift concurrency on Xcode 26.
    var controller: SessionController {
        if let controllerStorage {
            return controllerStorage
        }
        let created = SessionController(settings: AppSettings.shared)
        controllerStorage = created
        return created
    }
    private var menuBar: MenuBarController?
    private var hud: RecordingHUDWindow?
    private var hotkeys: HotkeyManager?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted XCTest sets this; skip prune/hotkeys/launch rows (TASK-16).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        CapturePermissions.snapshotLaunchState()
        AgentLog.eventSync("launch", [
            "ax_silent": MetadataSampler.requestTrust(prompt: false) ? "1" : "0",
            "crash_ips": String(CapturePermissions.pendingCrashReportCount())
        ])
        NSApp.setActivationPolicy(.accessory)
        let hud = RecordingHUDWindow(controller: controller)
        self.hud = hud
        menuBar = MenuBarController(controller: controller, hud: hud)
        hotkeys = HotkeyManager(controller: controller, captureFreeze: controller.captureFreeze)
        hotkeys?.register()
        MetadataSampler.requestTrust(prompt: false)
        controller.vault.pruneCompletedOlderThan(days: controller.settings.retentionDays)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentLog.eventSync("terminate", [:])
        AgentLog.setRecording(false, sessionId: nil)
        hotkeys?.unregister()
        controller.haltCaptureForTermination()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(settings: controller.settings, controller: controller)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "ScrumTrace Settings"
            window.setContentSize(NSSize(width: 640, height: 640))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAgentLogWindow(_ sender: Any?) {
        showSettingsWindow(sender)
    }
}
#endif
