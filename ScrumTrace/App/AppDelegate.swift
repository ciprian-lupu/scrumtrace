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
    private var settingsPresenterStorage: SettingsWindowPresenter?
    var settingsPresenter: SettingsWindowPresenter {
        if let settingsPresenterStorage { return settingsPresenterStorage }
        let presenter = SettingsWindowPresenter(controller: controller)
        settingsPresenterStorage = presenter
        return presenter
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted XCTest sets this; skip prune/hotkeys/launch rows (TASK-16).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        CapturePermissions.snapshotLaunchState()
        ExportRel.sweepPrivateTemporaryOrphans()
        AgentLog.eventSync("launch", [
            "ax_silent": MetadataSampler.requestTrust(prompt: false) ? "1" : "0",
            "crash_ips": String(CapturePermissions.pendingCrashReportCount())
        ])
        NSApp.setActivationPolicy(.accessory)
        let hud = RecordingHUDWindow(controller: controller)
        self.hud = hud
        menuBar = MenuBarController(
            controller: controller,
            hud: hud,
            openSettings: { [weak self] in self?.showSettingsWindow(nil) },
            openLogs: { [weak self] in self?.showAgentLogWindow(nil) }
        )
        hotkeys = HotkeyManager(controller: controller, captureFreeze: controller.captureFreeze)
        hotkeys?.register()
        MetadataSampler.requestTrust(prompt: false)
        controller.vault.pruneCompletedOlderThan(days: controller.settings.retentionDays)
        OnboardingWindow.presentIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentLog.eventSync("terminate", [:])
        hotkeys?.unregister()
        controller.haltCaptureForTermination()
        // Keep the lock while Start is still inside startCapture; that path
        // clears it on start_fail. Halt already cleared it after stop() when
        // a session was live.
        if !controller.isRecording && !controller.startInFlight {
            AgentLog.setRecording(false, sessionId: nil)
        }
    }

    @objc func startRecording(_ sender: Any?) {
        menuBar?.requestStart()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        AgentLog.event("settings_open", [:])
        settingsPresenter.show()
    }

    @objc func showAgentLogWindow(_ sender: Any?) {
        AgentLog.event("settings_open", ["tab": "logs"])
        settingsPresenter.show(tab: .logs)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow(nil)
        return true
    }
}

/// Own one retained window for menu actions, Command-comma and app reopening.
@MainActor
final class SettingsWindowPresenter {
    let navigation = SettingsNavigation()
    private let controller: SessionController
    private(set) var window: NSWindow?

    init(controller: SessionController) {
        self.controller = controller
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.selectedTab = tab }
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(settings: controller.settings, controller: controller, navigation: navigation)
            )
            let created = NSWindow(contentViewController: hosting)
            created.title = "ScrumTrace Settings"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 720, height: 640))
            created.contentMinSize = NSSize(width: 652, height: 592)
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
#endif
