#if os(macOS)
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SessionController()
    private var menuBar: MenuBarController?
    private var hud: RecordingHUDWindow?
    private var hotkeys: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let hud = RecordingHUDWindow(controller: controller)
        self.hud = hud
        menuBar = MenuBarController(controller: controller, hud: hud)
        hotkeys = HotkeyManager(controller: controller)
        hotkeys?.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregister()
        if controller.isRecording {
            controller.stopRecording()
        }
    }
}
#endif
