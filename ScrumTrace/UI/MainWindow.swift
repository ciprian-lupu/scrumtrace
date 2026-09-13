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

/// Launch-time decision, kept pure so it is unit-tested without AppKit.
enum MainWindowLaunchPolicy {
    /// Passed by the LaunchAgent log loop so it never pops a window.
    static let backgroundArgument = "--background"

    static func shouldShowOnLaunch(arguments: [String], environment: [String: String]) -> Bool {
        if arguments.contains(backgroundArgument) { return false }
        // Hosted XCTest runs never open windows at launch.
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        return true
    }
}

struct MainWindowView: View {
    /// Not observed here: the banner observes the controller on its own so the
    /// media clock does not re-render the section content ten times a second.
    let controller: SessionController
    @ObservedObject var navigation: MainNavigation
    /// Built by the presenter so the six-tab Settings view stays whole. A builder, not a
    /// value: leaving the section removes Settings, and coming back must start from
    /// current state (for example the license line), not from window creation.
    let settingsView: @MainActor () -> SettingsView

    var body: some View {
        NavigationSplitView {
            // A required selection: clicking empty sidebar space or Command-clicking
            // the selected row cannot leave the sidebar without a highlighted section.
            List(selection: $navigation.section) {
                ForEach(MainSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityIdentifier("main.sidebar.\(section.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
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
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .overview:
            ContentUnavailableView(
                "Overview",
                systemImage: MainSection.overview.systemImage,
                description: Text("Readiness, the last recording and storage will be summarized here. Start a recording from the ScrumTrace menu bar item.")
            )
        case .recordings:
            ContentUnavailableView(
                "Recordings",
                systemImage: MainSection.recordings.systemImage,
                description: Text("Your recordings will be listed here. Until then, use Recent in the ScrumTrace menu bar item.")
            )
        case .contexts:
            ContentUnavailableView {
                Label("Contexts", systemImage: MainSection.contexts.systemImage)
            } description: {
                Text("Product contexts will be listed here. Until then, edit them in Settings under General.")
            } actions: {
                Button("Open General settings") {
                    navigation.settings.selectedTab = .general
                    navigation.section = .settings
                }
                .accessibilityIdentifier("main.contexts.openGeneral")
            }
        case .settings:
            settingsView()
        }
    }
}

/// What the live banner shows, derived from the controller so tests do not need a view tree.
struct MainLiveBannerState: Equatable {
    let isVisible: Bool
    let isPaused: Bool
    let title: String
    let elapsed: String
    let detail: String?
    let pauseTitle: String
    let canTogglePause: Bool

    /// `resumeAllowed` is `controller.canResumeFromPause`, sampled by the banner. Reading
    /// it lists on-screen windows, too costly for every tick of the media clock.
    @MainActor
    init(controller: SessionController, resumeAllowed: Bool) {
        isVisible = controller.isRecording
        // Follow the writer like the HUD: privacy freeze pauses it before `phase` changes.
        isPaused = controller.captureState == .paused
        title = isPaused ? "Paused" : "Recording"
        elapsed = SessionController.clock(controller.mediaElapsed)
        let line = controller.statusLine
        detail = line.isEmpty || line == title ? nil : line
        pauseTitle = isPaused ? "Resume" : "Pause"
        canTogglePause = !isPaused || resumeAllowed
    }
}

/// Shown above every section while a recording is live. Never opens or fronts the window.
struct MainLiveBanner: View {
    @ObservedObject var controller: SessionController
    /// The clock re-renders the banner ten times a second, so the resume gate is sampled
    /// on its own slower schedule while paused. `SessionController.togglePause()` checks it again.
    @State private var resumeAllowed = false

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
                    }
                    Spacer(minLength: 12)
                    Button(state.pauseTitle) { pauseOrResume() }
                        .disabled(!state.canTogglePause)
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
            resumeAllowed = false
            return
        }
        while !Task.isCancelled {
            resumeAllowed = controller.canResumeFromPause
            try? await Task.sleep(for: Self.resumeGateInterval)
        }
    }
}
#endif
