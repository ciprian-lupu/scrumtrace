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
        NSApp.setActivationPolicy(.accessory)
        let hud = RecordingHUDWindow(controller: controller)
        self.hud = hud
        menuBar = MenuBarController(controller: controller, hud: hud)
        hotkeys = HotkeyManager(controller: controller, captureFreeze: controller.captureFreeze)
        hotkeys?.register()
        MetadataSampler.requestTrust(prompt: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregister()
        controller.haltCaptureForTermination()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: controller.settings))
            let window = NSWindow(contentViewController: hosting)
            window.title = "ScrumTrace Settings"
            window.setContentSize(NSSize(width: 540, height: 780))
            window.styleMask = [.titled, .closable, .miniaturizable]
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
