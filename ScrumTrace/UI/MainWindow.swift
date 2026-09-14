#if os(macOS)
import AppKit
import SwiftUI

/// Sidebar sections of the main window. Raw values are technical log fields.
enum MainSection: String, Hashable, CaseIterable, Identifiable {
    case overview
    case recordings
    case contexts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .recordings: return "Recordings"
        case .contexts: return "Contexts"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .recordings: return "film.stack"
        case .contexts: return "shippingbox"
        case .settings: return "gearshape"
        }
    }

    /// Command-1 to Command-4, in sidebar order.
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .recordings: return "2"
        case .contexts: return "3"
        case .settings: return "4"
        }
    }
}

/// Selection state for the main window. The presenter retains it, so a closed
/// window reopens on the same section, Settings tab and recording.
@MainActor
final class MainNavigation: ObservableObject {
    @Published var section = MainSection.overview
    let settings = SettingsNavigation()
    @Published var selectedSessionId: String?
}

/// Why the main window opened. Logged as a technical enum only.
enum MainWindowOpenSource: String {
    case launch
    case reopen
    case menu
    case command
}

/// Switches ScrumTrace between a menu-bar accessory and a regular app with a Dock tile, and gives focus back to
/// another app after the main window closes. Other apps pass through it as process ids only, so no name reaches
/// a log. Injected: hosted tests pass a fake or none, so the test host never gets a Dock tile or activates
/// another app.
struct MainWindowActivation {
    /// ScrumTrace's own process id.
    var ownProcessIdentifier: pid_t
    var activationPolicy: @MainActor () -> NSApplication.ActivationPolicy
    var setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    /// The frontmost application's process id, or nil when there is none.
    var frontmostProcessIdentifier: @MainActor () -> pid_t?
    /// The application whose menu bar is on screen. An active accessory has no menu bar of its own, so while the
    /// app icon, Finder or Spotlight has just activated ScrumTrace this is still the app the user came from.
    var menuBarOwnerProcessIdentifier: @MainActor () -> pid_t?
    /// True for a running app with a Dock tile, the only kind that gets focus back. Not loginwindow, a keychain
    /// prompt or another app's menu-bar panel.
    var canReceiveFocus: @MainActor (pid_t) -> Bool
    /// True when a ScrumTrace window other than `closing` has the keyboard, such as the first-run permissions window.
    var anotherWindowIsKey: @MainActor (_ closing: NSWindow?) -> Bool
    /// True when a titled ScrumTrace window other than `closing` is on screen, such as the first-run permissions
    /// window or the recording-context window. Panels such as the HUD, sheets and full-screen overlays do not count.
    var anotherWindowIsOpen: @MainActor (_ closing: NSWindow?) -> Bool
    /// Activates another running application. False when it has quit or did not come forward.
    var activateApplication: @MainActor (pid_t) -> Bool
    /// Calls `handler` with the process id of every application that becomes active, until the returned call stops it.
    var followActivations: @MainActor (_ handler: @escaping @MainActor (pid_t) -> Void) -> @MainActor () -> Void
    /// Calls `handler` with every ScrumTrace window that is about to close, until the returned call stops it.
    var followWindowCloses: @MainActor (_ handler: @escaping @MainActor (NSWindow) -> Void) -> @MainActor () -> Void
    /// How long closing waits before it checks whether ScrumTrace is still frontmost, so a switch AppKit
    /// makes by itself is not overridden.
    var focusReturnDelay: Duration

    /// The running app: `NSApp`, `NSWorkspace` and `NSRunningApplication`.
    static var live: MainWindowActivation {
        MainWindowActivation(
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            activationPolicy: { NSApp.activationPolicy() },
            setActivationPolicy: { _ = NSApp.setActivationPolicy($0) },
            frontmostProcessIdentifier: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            menuBarOwnerProcessIdentifier: { NSWorkspace.shared.menuBarOwningApplication?.processIdentifier },
            canReceiveFocus: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
                return app.activationPolicy == .regular
            },
            anotherWindowIsKey: { closing in
                guard let key = NSApp.keyWindow else { return false }
                return key !== closing && key.isVisible
            },
            anotherWindowIsOpen: { closing in
                NSApp.windows.contains { window in
                    window !== closing && window.isVisible && window.styleMask.contains(.titled)
                        && !(window is NSPanel) && window.sheetParent == nil
                }
            },
            activateApplication: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                      app.activationPolicy == .regular else { return false }
                return app.activate(options: [])
            },
            followActivations: { handler in
                let center = NSWorkspace.shared.notificationCenter
                let token = center.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { notification in
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    let pid = app.processIdentifier
                    MainActor.assumeIsolated { handler(pid) }
                }
                return { center.removeObserver(token) }
            },
            followWindowCloses: { handler in
                // No queue: AppKit posts this on the main thread, before the window leaves the screen.
                let token = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: nil,
                    queue: nil
                ) { notification in
                    guard let window = notification.object as? NSWindow else { return }
                    MainActor.assumeIsolated { handler(window) }
                }
                return { NotificationCenter.default.removeObserver(token) }
            },
            focusReturnDelay: .milliseconds(150)
        )
    }
}

/// The number on the Recordings sidebar row.
enum MainSidebarBadge {
    /// Unfinished recordings that need attention, the ones Overview lists under Needs attention. The recording a
    /// running capture or analysis holds is in progress, so it is not counted.
    static func unfinishedCount(entries: [SessionEntry], canChangeSessions: Bool, activeSessionId: String?) -> Int {
        OverviewAttention.make(
            entries: entries,
            heldSessionId: canChangeSessions ? nil : activeSessionId,
            lastError: nil,
            retentionDays: 0,
            update: nil
        ).unfinished.count
    }

    /// The row's help tag. Empty without a badge.
    static func help(unfinishedCount count: Int) -> String {
        switch count {
        case 0: return ""
        case 1: return "1 unfinished recording"
        default: return "\(count) unfinished recordings"
        }
    }
}

/// Launch-time decisions, kept pure so they are unit-tested without AppKit.
enum MainWindowLaunchPolicy {
    /// Passed by the LaunchAgent log loop so it never pops a window, and by Relaunch ScrumTrace unless the window
    /// was open.
    static let backgroundArgument = "--background"

    /// True only for a launch the user opened: Finder, Launchpad, Spotlight, the Dock or `open` without
    /// `--background`. A Login Item launch stays in the menu bar, and so does a relaunch that forwarded
    /// `--background`.
    static func shouldShowOnLaunch(arguments: [String], environment: [String: String], launchedAsLoginItem: Bool) -> Bool {
        if arguments.contains(backgroundArgument) { return false }
        if launchedAsLoginItem { return false }
        // Hosted XCTest runs never open windows at launch.
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        return true
    }

    /// True when `event` is the open-application event macOS sends to a Login Item at login. The app delegate
    /// passes `NSAppleEventManager.shared().currentAppleEvent`, which holds that event only while AppKit handles
    /// the launch.
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Arguments for Relaunch ScrumTrace. The new instance shows the window only when it was open, and a process
    /// started with `--background` keeps the flag, so the agent loop's instance never shows the window.
    static func relaunchArguments(currentArguments: [String], windowOpen: Bool) -> [String] {
        if currentArguments.contains(backgroundArgument) || !windowOpen { return [backgroundArgument] }
        return []
    }
}

struct MainWindowView: View {
    /// Not observed here: the banner observes the controller on its own so the
    /// media clock does not re-render the section content ten times a second.
    let controller: SessionController
    @ObservedObject var navigation: MainNavigation
    /// Owned by the presenter, so the session index and its caches outlive section changes.
    let recordings: RecordingsModel
    /// Owned by the presenter too. Its session rows and their actions come from `recordings`.
    let overview: OverviewModel
    /// Owned by the presenter too. Its recording counts come from the session index `recordings` keeps.
    let contexts: ContextsModel
    /// Built by the presenter so the six-tab Settings view stays whole. A builder, not a
    /// value: leaving the section removes Settings, and coming back must start from
    /// current state (for example the license line), not from window creation.
    let settingsView: @MainActor () -> SettingsView

    /// The widest the sidebar column can be dragged. macOS 26 draws the sidebar 8 pt wider than its column, so at the
    /// 840 pt minimum width the detail pane keeps at least 632 pt: Settings (620 pt plus its padding) loses some padding,
    /// never its sides.
    static let sidebarMaximumWidth: CGFloat = 200

    var body: some View {
        NavigationSplitView {
            // A required selection: clicking empty sidebar space or Command-clicking
            // the selected row cannot leave the sidebar without a highlighted section.
            List(selection: $navigation.section) {
                ForEach(MainSection.allCases) { section in
                    Group {
                        if section == .recordings {
                            RecordingsSidebarLabel(model: recordings, library: recordings.library)
                        } else {
                            Label(section.title, systemImage: section.systemImage)
                        }
                    }
                    .tag(section)
                    .accessibilityIdentifier("main.sidebar.\(section.rawValue)")
                }
            }
            .listStyle(.sidebar)
            // At most `sidebarMaximumWidth`, so the Settings section keeps both sides beside the widest sidebar at the
            // minimum window width.
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: Self.sidebarMaximumWidth)
        } detail: {
            VStack(spacing: 0) {
                MainLiveBanner(controller: controller)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Near the minimum size, Settings plus the banner is taller than the window.
            // Take exactly the offered size and let any overflow fall off the bottom edge,
            // so the banner controls and the Settings tabs stay visible.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .modifier(StableWindowToolbar())
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .overview:
            OverviewView(model: overview, recordings: recordings, library: recordings.library)
        case .recordings:
            RecordingsView(
                model: recordings,
                library: recordings.library,
                navigation: navigation,
                controller: controller
            )
        case .contexts:
            ContextsView(
                model: contexts,
                settings: controller.settings,
                recordings: recordings,
                library: recordings.library
            )
        case .settings:
            settingsView()
        }
    }
}

/// The Recordings sidebar row, badged with the unfinished recordings that need attention.
private struct RecordingsSidebarLabel: View {
    @ObservedObject var model: RecordingsModel
    @ObservedObject var library: SessionLibrary

    var body: some View {
        let count = MainSidebarBadge.unfinishedCount(
            entries: library.entries,
            canChangeSessions: model.canChangeSessions,
            activeSessionId: model.activeSessionId
        )
        Label(MainSection.recordings.title, systemImage: MainSection.recordings.systemImage)
            .badge(count)
            .help(MainSidebarBadge.help(unfinishedCount: count))
    }
}

/// Keeps one window toolbar in every section. Without it AppKit adds the toolbar when a section brings
/// its own items (Recordings' search field) and grows the window frame by the toolbar height, then
/// shrinks it again on the next section.
private struct StableWindowToolbar: ViewModifier {
    func body(content: Content) -> some View {
        // `sharedBackgroundVisibility` exists only in the macOS 26 SDK (Swift 6.2 / Xcode 26).
        // The compiler check keeps older toolchains such as the Xcode 16.4 CI runner building;
        // the availability check keeps macOS 14 and 15 working at run time.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // macOS 26 draws a shared glass capsule behind toolbar items; this one holds nothing to see.
            content.toolbar {
                ToolbarItem(placement: .navigation) { Self.placeholder }
                    .sharedBackgroundVisibility(.hidden)
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .navigation) { Self.placeholder }
            }
        }
        #else
        content.toolbar {
            ToolbarItem(placement: .navigation) { Self.placeholder }
        }
        #endif
    }

    private static var placeholder: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
    }
}

/// What the live banner shows, derived from the controller so tests do not need a view tree.
struct MainLiveBannerState: Equatable {
    /// Why Resume waits while the privacy gate holds the recording. Short enough for the banner line.
    static let privacyHoldReason = "Resume waits while a password manager is on screen."

    let isVisible: Bool
    let isPaused: Bool
    let title: String
    let elapsed: String
    let detail: String?
    let pauseTitle: String
    let canTogglePause: Bool
    /// Set only while paused and the sampled gate holds the recording, so a disabled Resume always says why.
    let resumeBlockedReason: String?

    /// `resumeAllowed` is `controller.canResumeFromPause` as the banner last sampled it, or nil before the first
    /// sample. Reading it lists on-screen windows, too costly for every tick of the media clock.
    @MainActor
    init(controller: SessionController, resumeAllowed: Bool?) {
        isVisible = controller.isRecording
        // Follow the writer like the HUD: privacy freeze pauses it before `phase` changes.
        isPaused = controller.captureState == .paused
        title = isPaused ? "Paused" : "Recording"
        elapsed = SessionController.clock(controller.mediaElapsed)
        pauseTitle = isPaused ? "Resume" : "Pause"
        canTogglePause = !isPaused || resumeAllowed == true
        let held = isPaused && resumeAllowed == false
        resumeBlockedReason = held ? Self.privacyHoldReason : nil
        let line = controller.statusLine
        let status = line.isEmpty || line == title ? nil : line
        // An automatic pause already says why, naming the app. After a pause the user chose, the line does not.
        if held, !(status.map(Self.namesPrivacyPause) ?? false) {
            detail = Self.privacyHoldReason
        } else {
            detail = status
        }
    }

    /// The Pause or Resume button's help tag.
    var pauseHelp: String {
        if let resumeBlockedReason { return resumeBlockedReason }
        return isPaused ? "Resume the recording." : "Pause the recording. Nothing is written while paused."
    }

    /// The status lines `SessionController` writes while the privacy guard holds a pause.
    static func namesPrivacyPause(_ line: String) -> Bool {
        line.hasPrefix("Auto-paused") || line.hasPrefix("Still auto-paused")
    }
}

/// Shown above every section while a recording is live. Never opens or fronts the window.
struct MainLiveBanner: View {
    @ObservedObject var controller: SessionController
    /// The clock re-renders the banner ten times a second, so the resume gate is sampled
    /// on its own slower schedule while paused. `SessionController.togglePause()` checks it again.
    /// Nil while not paused, so a new pause shows no reason before its first sample.
    @State private var resumeAllowed: Bool?

    static let resumeGateInterval: Duration = .milliseconds(500)

    var body: some View {
        let state = MainLiveBannerState(controller: controller, resumeAllowed: resumeAllowed)
        if state.isVisible {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(state.isPaused ? Color.orange : Color.red)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(state.title)
                        .font(.headline)
                    Text(state.elapsed)
                        .font(.body.monospacedDigit())
                        .help("Recorded time, excluding pauses")
                        .accessibilityLabel("Recorded time \(state.elapsed)")
                    if let detail = state.detail {
                        Text(detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(detail)
                    }
                    Spacer(minLength: 12)
                    Button(state.pauseTitle) { pauseOrResume() }
                        .disabled(!state.canTogglePause)
                        .help(state.pauseHelp)
                        .accessibilityIdentifier("main.banner.pause")
                    Button("Stop & process") { stopAndProcess() }
                        .accessibilityIdentifier("main.banner.stop")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("main.banner")
            .task(id: state.isPaused) { await sampleResumeGate(whilePaused: state.isPaused) }
        }
    }

    /// Same actions and technical log events as the HUD buttons.
    func pauseOrResume() {
        AgentLog.event("main_pause", [:])
        controller.togglePause()
    }

    func stopAndProcess() {
        AgentLog.event("main_stop", [:])
        controller.stopRecording()
    }

    @MainActor
    private func sampleResumeGate(whilePaused paused: Bool) async {
        guard paused else {
            resumeAllowed = nil
            return
        }
        while !Task.isCancelled {
            resumeAllowed = controller.canResumeFromPause
            try? await Task.sleep(for: Self.resumeGateInterval)
        }
    }
}
#endif
