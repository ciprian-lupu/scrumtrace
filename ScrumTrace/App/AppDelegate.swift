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
    private var mainPresenterStorage: MainWindowPresenter?
    var mainPresenter: MainWindowPresenter {
        if let mainPresenterStorage { return mainPresenterStorage }
        let presenter = MainWindowPresenter(controller: controller)
        mainPresenterStorage = presenter
        return presenter
    }

    /// Hosted tests route through the delegate with an isolated controller and no frame autosave.
    func setMainPresenterForTesting(_ presenter: MainWindowPresenter) {
        mainPresenterStorage = presenter
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        ClaudeCLIHandoff.tryExecFromArguments(ProcessInfo.processInfo.arguments)
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
            openLogs: { [weak self] in self?.showAgentLogWindow(nil) },
            openMain: { [weak self] in self?.showMainWindow(source: .menu) }
        )
        hotkeys = HotkeyManager(controller: controller, captureFreeze: controller.captureFreeze)
        hotkeys?.register()
        MetadataSampler.requestTrust(prompt: false)
        controller.vault.pruneCompletedOlderThan(days: controller.settings.retentionDays)
        // Open the window first so a first-run permissions window stays in front of it.
        if MainWindowLaunchPolicy.shouldShowOnLaunch(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        ) {
            showMainWindow(source: .launch)
        }
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
        mainPresenter.show(section: .settings)
    }

    @objc func showAgentLogWindow(_ sender: Any?) {
        AgentLog.event("settings_open", ["tab": "logs"])
        mainPresenter.show(tab: .logs)
    }

    /// Explicit user actions only: launch, the menu item and Command-1 to Command-4.
    func showMainWindow(section: MainSection? = nil, source: MainWindowOpenSource) {
        var fields = ["source": source.rawValue]
        if let section { fields["section"] = section.rawValue }
        AgentLog.event("main_open", fields)
        if let section {
            mainPresenter.show(section: section)
        } else {
            mainPresenter.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The app icon fronts the main window on its current section.
        AgentLog.event("main_open", ["source": MainWindowOpenSource.reopen.rawValue])
        mainPresenter.show()
        return true
    }
}

/// Own one retained main window for the app icon, the menu bar and commands.
/// Settings is a section of this window, so Command-comma and the menu reuse it.
@MainActor
final class MainWindowPresenter: NSObject, NSWindowDelegate {
    nonisolated static let frameAutosaveName = "ScrumTraceMain"
    nonisolated static let minimumContentSize = NSSize(width: 840, height: 580)
    let navigation: MainNavigation
    private let controller: SessionController
    private let autosaveName: String?
    private(set) var window: NSWindow?

    /// Tests pass `nil` so window frames never reach the app's real defaults.
    init(controller: SessionController, frameAutosaveName: String? = MainWindowPresenter.frameAutosaveName) {
        self.navigation = MainNavigation()
        self.controller = controller
        self.autosaveName = frameAutosaveName
        super.init()
    }

    /// The only place the main window activates ScrumTrace. Call it from explicit user actions.
    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: MainWindowView(
                    controller: controller,
                    navigation: navigation,
                    settingsView: { [controller, navigation] in
                        SettingsView(settings: controller.settings, controller: controller, navigation: navigation.settings)
                    }
                )
            )
            // Explicit window sizing prevents the macOS 26 hosting/safe-area feedback
            // loop (see RecordingContextPresenter) when the live banner or section changes.
            hosting.sizingOptions = []
            let created = NSWindow(contentViewController: hosting)
            created.title = "ScrumTrace"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 960, height: 640))
            created.isReleasedWhenClosed = false
            created.delegate = self
            if let autosaveName {
                if !created.setFrameUsingName(autosaveName) { created.center() }
                created.setFrameAutosaveName(autosaveName)
            } else {
                created.center()
            }
            window = created
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Keeps the window at least 840×580 points of content, for user resizes and for a
    /// frame restored from the autosave name. `contentMinSize` is not used: SwiftUI
    /// resets it whenever the split view content changes, even with `sizingOptions = []`.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    /// Changing the section removes the current section's views, which dismisses an open
    /// sheet (a context editor, speaker review) and loses its edits. Command-1 to Command-4
    /// and the menu stay enabled, so while a sheet is attached they only front the window.
    private var canNavigate: Bool { window?.attachedSheet == nil }

    func show(section: MainSection) {
        if canNavigate { navigation.section = section }
        show()
    }

    func show(tab: SettingsTab) {
        if canNavigate { navigation.settings.selectedTab = tab }
        show(section: .settings)
    }

    func show(sessionId: String) {
        if canNavigate { navigation.selectedSessionId = sessionId }
        show(section: .recordings)
    }
}
#endif
