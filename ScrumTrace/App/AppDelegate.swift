#if os(macOS)
import AppKit
import ApplicationServices
import Combine
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
        // Overview, the empty Recordings state and Record with this context… start a session through the same
        // flow as the menu, and all three disable their buttons while it shows the recording-context window.
        let presenter = MainWindowPresenter(
            controller: controller,
            activation: .live,
            onStartRecording: { [weak self] in
                self?.menuBar?.requestStart()
            },
            isPreparingRecording: { [weak self] in
                self?.menuBar?.isPreparingRecording ?? false
            }
        )
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
        // A Login Item launch stays in the menu bar. AppKit still handles the launch event here, so it is readable.
        if MainWindowLaunchPolicy.shouldShowOnLaunch(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            launchedAsLoginItem: MainWindowLaunchPolicy.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)
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

    /// New Recording… (Command-N).
    @objc func startRecording(_ sender: Any?) {
        menuBar?.startFromCommand()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        AgentLog.event("settings_open", [:])
        mainPresenter.show(section: .settings)
    }

    @objc func showAgentLogWindow(_ sender: Any?) {
        AgentLog.event("settings_open", ["tab": "logs"])
        mainPresenter.show(tab: .logs)
    }

    // MARK: Main-menu commands

    /// True while ScrumTrace is the active app. Tests replace it.
    var isActiveApp: @MainActor () -> Bool = { NSApp.isActive }
    /// The window that has the keyboard, if any. Tests replace it.
    var currentKeyWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow }

    /// Command-comma, Command-F and Command-1 to Command-4 act only while ScrumTrace is the active app. Their key
    /// equivalents also reach the main menu from a non-activating panel that has the keyboard while another app
    /// stays in front, such as the Shot note typed into during a presentation. Opening the window from there would
    /// bring ScrumTrace over the presentation (Gate 0). The menu bar item and the app icon do not come through here.
    private var acceptsMainMenuCommand: Bool { isActiveApp() }

    /// Command-comma from the app menu.
    func showSettingsFromCommand() {
        guard acceptsMainMenuCommand else { return }
        showSettingsWindow(nil)
    }

    /// Explicit user actions only: launch, the menu item and Command-1 to Command-4. A command is ignored while
    /// ScrumTrace is not the active app.
    func showMainWindow(section: MainSection? = nil, source: MainWindowOpenSource) {
        if source == .command, !acceptsMainMenuCommand { return }
        var fields = ["source": source.rawValue]
        if let section { fields["section"] = section.rawValue }
        AgentLog.event("main_open", fields)
        if let section {
            mainPresenter.show(section: section)
        } else {
            mainPresenter.show()
        }
    }

    /// Command-F from the Edit menu: the main window on Recordings with its search field focused. Like the other
    /// main-menu commands it waits for ScrumTrace to be active. Find belongs to the window in front, so it also does
    /// nothing while another ScrumTrace window or a sheet has the keyboard, or while a text field is being typed in.
    @objc func findRecordings(_ sender: Any?) {
        guard acceptsMainMenuCommand, mainPresenter.acceptsFindCommand(keyWindow: currentKeyWindow()) else { return }
        AgentLog.event("main_open", [
            "source": MainWindowOpenSource.command.rawValue,
            "section": MainSection.recordings.rawValue
        ])
        mainPresenter.showRecordingsSearch()
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
    /// The Recordings section and its session index, kept for the life of the presenter.
    let recordings: RecordingsModel
    /// The Overview section, which shares the Recordings session index and actions.
    let overview: OverviewModel
    /// The Contexts section, which counts recordings from the same session index.
    let contexts: ContextsModel
    private let controller: SessionController
    private let autosaveName: String?
    /// Nil leaves the activation policy and other apps alone.
    private let activation: MainWindowActivation?
    /// Whether the window is on screen after AppKit reports an occlusion change.
    private let isWindowOnScreen: @MainActor (NSWindow) -> Bool
    private(set) var window: NSWindow?
    /// True from `show()` until the window closes, while it is minimized too. The Dock tile follows it.
    private(set) var isWindowOpen = false
    /// True after the window closed while another titled ScrumTrace window, such as the first-run permissions
    /// window, was still on screen. The Dock tile stays until the last of them closes.
    var isWaitingForOtherWindows: Bool { stopFollowingWindowCloses != nil }
    /// The app that gets focus back when ScrumTrace's last window closes: the last app with a Dock tile, other
    /// than ScrumTrace, that became active since the presenter was created, or the one in front when `show()`
    /// ran. A process id only.
    private(set) var focusReturnProcessIdentifier: pid_t?
    /// Waits out `MainWindowActivation.focusReturnDelay` after a close. Showing the window again cancels it.
    private(set) var pendingFocusReturn: Task<Void, Never>?
    private var stopFollowingWindowCloses: (@MainActor () -> Void)?
    private var dockPreference: AnyCancellable?
    private var searchFocus: Task<Void, Never>?

    /// Tests pass `nil` so window frames never reach the app's real defaults, and leave `activation` nil so the
    /// test host never gets a Dock tile or activates another app. The app delegate passes `.live`.
    /// `isWindowOnScreen` defaults to the live read, visible, not minimized and not covered by other windows. Hosted
    /// tests ignore occlusion so what else is on the test Mac's screen cannot stop the window's periodic work.
    init(
        controller: SessionController,
        frameAutosaveName: String? = MainWindowPresenter.frameAutosaveName,
        isWindowOnScreen: @escaping @MainActor (NSWindow) -> Bool = {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        },
        activation: MainWindowActivation? = nil,
        onStartRecording: @escaping @MainActor () -> Void = {},
        isPreparingRecording: @escaping @MainActor () -> Bool = { false }
    ) {
        let navigation = MainNavigation()
        self.navigation = navigation
        self.controller = controller
        self.autosaveName = frameAutosaveName
        self.isWindowOnScreen = isWindowOnScreen
        self.activation = activation
        let recordings = RecordingsModel(
            library: SessionLibrary(vault: controller.vault),
            navigation: navigation,
            dependencies: .live(controller: controller, startRecording: onStartRecording, isPreparingRecording: isPreparingRecording)
        )
        self.recordings = recordings
        self.overview = OverviewModel(
            recordings: recordings,
            navigation: navigation,
            dependencies: .live(
                controller: controller,
                startRecording: onStartRecording,
                isPreparingRecording: isPreparingRecording
            )
        )
        self.contexts = ContextsModel(
            settings: controller.settings,
            recordings: recordings,
            dependencies: .live(
                controller: controller,
                startRecording: onStartRecording,
                isPreparingRecording: isPreparingRecording
            )
        )
        super.init()
        // Relaunch ScrumTrace brings the window back only when it is open.
        controller.isMainWindowOpen = { [weak self] in self?.isWindowOpen ?? false }
        recordings.observe(controller: controller)
        overview.observe(controller: controller)
        contexts.observe(controller: controller)
        // Synchronous, like the navigation sinks in RecordingsModel. @Published emits before it stores the new
        // value, so the sink applies the value it receives.
        dockPreference = controller.settings.$showInDockWhileWindowOpen
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] showInDock in
                MainActor.assumeIsolated { self?.updateDockPresence(showInDock: showInDock) }
            }
        // Every app switch from now on, not only while the window is open: the app icon, Finder and Spotlight
        // activate ScrumTrace before they ask it to reopen, so the app the user came from is known only from
        // before. Followed for the presenter's life, which is the app's.
        if let activation {
            _ = activation.followActivations { [weak self] pid in
                self?.rememberFocusReturn(pid)
            }
        }
    }

    /// The only place the main window activates ScrumTrace. Call it from explicit user actions.
    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: MainWindowView(
                    controller: controller,
                    navigation: navigation,
                    recordings: recordings,
                    overview: overview,
                    contexts: contexts,
                    settingsView: { [controller, navigation] in
                        SettingsView(settings: controller.settings, controller: controller, navigation: navigation.settings)
                    }
                )
            )
            // Explicit window sizing prevents the macOS 26 hosting/safe-area feedback
            // loop (see RecordingContextPresenter) when the live banner or section changes.
            hosting.sizingOptions = []
            // Recordings puts its search field and actions in the window toolbar. The title stays ours.
            hosting.sceneBridgingOptions = [.toolbars]
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
        // Before ScrumTrace comes forward, while the app in front is still the one to return to.
        openDockPresence()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        setWindowVisible(true)
    }

    /// The session list refreshes, Overview checks readiness and Contexts follows the Start flow periodically only
    /// while the window is on screen.
    private func setWindowVisible(_ visible: Bool) {
        recordings.setWindowVisible(visible)
        overview.setWindowVisible(visible)
        contexts.setWindowVisible(visible)
    }

    func windowWillClose(_ notification: Notification) {
        setWindowVisible(false)
        searchFocus?.cancel()
        searchFocus = nil
        closeDockPresence(closing: window)
    }

    // MARK: Dock presence

    /// Remembers the app in front and adds the Dock tile when the preference allows it. Cancels a focus return
    /// that a close scheduled moments ago, and a wait for other ScrumTrace windows to close.
    private func openDockPresence() {
        pendingFocusReturn?.cancel()
        pendingFocusReturn = nil
        stopWaitingForOtherWindows()
        isWindowOpen = true
        guard let activation else { return }
        // The app in front, unless that is ScrumTrace itself. Then the last app followed stays, or, before any
        // was followed, the app whose menu bar an active accessory ScrumTrace leaves on screen.
        rememberFocusReturn(activation.frontmostProcessIdentifier())
        if focusReturnProcessIdentifier == nil {
            rememberFocusReturn(activation.menuBarOwnerProcessIdentifier())
        }
        updateDockPresence(showInDock: controller.settings.showInDockWhileWindowOpen)
    }

    /// Only another app with a Dock tile: never ScrumTrace, loginwindow after the screen locks, or a keychain prompt.
    private func rememberFocusReturn(_ pid: pid_t?) {
        guard let activation, let pid, pid != activation.ownProcessIdentifier, activation.canReceiveFocus(pid) else { return }
        focusReturnProcessIdentifier = pid
    }

    /// `.regular`, with a Dock tile and a place in Command-Tab, while the window or another ScrumTrace window
    /// after it is open and the preference is on. Otherwise `.accessory`, as the app delegate sets it at launch.
    private func updateDockPresence(showInDock: Bool) {
        guard let activation else { return }
        let keepsTile = isWindowOpen || isWaitingForOtherWindows
        let policy: NSApplication.ActivationPolicy = keepsTile && showInDock ? .regular : .accessory
        guard activation.activationPolicy() != policy else { return }
        activation.setActivationPolicy(policy)
        AgentLog.event("main_dock", ["policy": policy == .regular ? "regular" : "accessory"])
    }

    /// The window closed. When it was ScrumTrace's last titled window, back to the menu bar at once. While another
    /// one is still on screen, such as the first-run permissions window or the recording-context window, that
    /// window keeps the Dock tile and the keyboard until the last of them closes.
    private func closeDockPresence(closing: NSWindow?) {
        isWindowOpen = false
        guard let activation else { return }
        if activation.anotherWindowIsOpen(closing) {
            waitForOtherWindows()
        } else {
            leaveDockPresence(closing: closing)
        }
    }

    private func waitForOtherWindows() {
        guard let activation, stopFollowingWindowCloses == nil else { return }
        stopFollowingWindowCloses = activation.followWindowCloses { [weak self] closed in
            self?.otherWindowWillClose(closed)
        }
    }

    private func stopWaitingForOtherWindows() {
        stopFollowingWindowCloses?()
        stopFollowingWindowCloses = nil
    }

    /// A panel or sheet closing changes nothing; the last titled window closing ends the wait.
    private func otherWindowWillClose(_ closed: NSWindow) {
        guard let activation, !isWindowOpen, closed !== window, !activation.anotherWindowIsOpen(closed) else { return }
        stopWaitingForOtherWindows()
        leaveDockPresence(closing: closed)
    }

    /// Back to a menu-bar accessory. AppKit can leave no app active after that switch, so once
    /// `focusReturnDelay` has passed, the remembered app is activated if ScrumTrace is still frontmost and none
    /// of its other windows has the keyboard. With the preference off the policy does not change, but focus
    /// still goes back the same way.
    private func leaveDockPresence(closing: NSWindow?) {
        guard let activation else { return }
        updateDockPresence(showInDock: controller.settings.showInDockWhileWindowOpen)
        guard let pid = focusReturnProcessIdentifier else { return }
        pendingFocusReturn?.cancel()
        pendingFocusReturn = Task { @MainActor [weak self] in
            if activation.focusReturnDelay > .zero {
                try? await Task.sleep(for: activation.focusReturnDelay)
            }
            guard let self, !Task.isCancelled, !self.isWindowOpen, !self.isWaitingForOtherWindows else { return }
            self.pendingFocusReturn = nil
            guard activation.frontmostProcessIdentifier() == activation.ownProcessIdentifier,
                  !activation.anotherWindowIsKey(closing) else { return }
            let activated = activation.activateApplication(pid)
            // An app that quit is not asked again.
            if !activated, self.focusReturnProcessIdentifier == pid { self.focusReturnProcessIdentifier = nil }
            AgentLog.event("main_focus_return", ["activated": activated ? "1" : "0"])
        }
    }

    // MARK: Search

    nonisolated static let searchFocusAttempts = 50
    nonisolated static let searchFocusInterval: Duration = .milliseconds(20)

    /// Command-F: Recordings with its search field ready for typing. A section change rebuilds the toolbar, so
    /// this waits briefly for SwiftUI to add the field. While a sheet is open the section and keyboard stay put.
    func showRecordingsSearch() {
        show(section: .recordings)
        searchFocus?.cancel()
        searchFocus = nil
        guard canNavigate, navigation.section == .recordings else { return }
        searchFocus = Task { @MainActor [weak self] in
            for _ in 0..<Self.searchFocusAttempts {
                guard let self, !Task.isCancelled else { return }
                if let window = self.window, window.attachedSheet == nil, self.navigation.section == .recordings,
                   let item = Self.searchToolbarItem(in: window),
                   Self.focusSearch(item, in: window) {
                    self.searchFocus = nil
                    return
                }
                try? await Task.sleep(for: Self.searchFocusInterval)
            }
        }
    }

    /// True when Command-F may take the keyboard to the recordings search: no ScrumTrace window has the keyboard, or
    /// the main window has it without a sheet and nothing is being typed except the recordings search itself.
    /// Another window, panel or sheet keeps Command-F, and so does a field such as the Settings → Logs filter.
    func acceptsFindCommand(keyWindow: NSWindow?) -> Bool {
        guard let keyWindow else { return true }
        guard keyWindow === window, keyWindow.attachedSheet == nil else { return false }
        guard let editor = keyWindow.firstResponder as? NSTextView, editor.isEditable else { return true }
        guard navigation.section == .recordings, let item = Self.searchToolbarItem(in: keyWindow) else { return false }
        return Self.isEditingSearch(item, in: keyWindow)
    }

    /// The window toolbar's search field, present while Recordings is shown.
    static func searchToolbarItem(in window: NSWindow) -> NSSearchToolbarItem? {
        window.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
    }

    /// True when typing goes to `item`'s search field.
    static func isEditingSearch(_ item: NSSearchToolbarItem, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder === item.searchField { return true }
        return ((responder as? NSText)?.delegate as AnyObject?) === item.searchField
    }

    /// Expands a collapsed search field and gives it the keyboard.
    private static func focusSearch(_ item: NSSearchToolbarItem, in window: NSWindow) -> Bool {
        if isEditingSearch(item, in: window) { return true }
        item.beginSearchInteraction()
        if isEditingSearch(item, in: window) { return true }
        return window.makeFirstResponder(item.searchField) && isEditingSearch(item, in: window)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        setWindowVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        setWindowVisible(true)
    }

    /// Fully covered by other windows counts as hidden: no periodic work until the window is uncovered.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        setWindowVisible(isWindowOnScreen(window))
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
        if canNavigate {
            recordings.revealInList(sessionId: sessionId)
            navigation.selectedSessionId = sessionId
        }
        show(section: .recordings)
    }
}
#endif
