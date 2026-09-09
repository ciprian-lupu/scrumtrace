#if os(macOS)
import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SessionController()
    private var menuBar: MenuBarController?
    private var hud: RecordingHUDWindow?
    private var hotkeys: HotkeyManager?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let hud = RecordingHUDWindow(controller: controller)
        self.hud = hud
        menuBar = MenuBarController(controller: controller, hud: hud)
        hotkeys = HotkeyManager(controller: controller)
        hotkeys?.register()
        MetadataSampler.requestTrust()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregister()
        if controller.isRecording {
            controller.stopRecording()
        }
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: controller.settings))
            let window = NSWindow(contentViewController: hosting)
            window.title = "ScrumTrace Settings"
            window.setContentSize(NSSize(width: 540, height: 680))
            window.styleMask = [.titled, .closable, .miniaturizable]
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
