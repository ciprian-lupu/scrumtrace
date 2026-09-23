import AppKit
import SwiftUI
import XCTest
@testable import ScrumTrace

final class MainWindowTests: XCTestCase {
    @MainActor
    private func withController(_ body: (SessionController, URL) throws -> Void) throws {
        let id = "ScrumTrace.MainWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let log = root.appendingPathComponent("agent.jsonl")
        AgentLog.setFileURLForTesting(log)
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionController(
            settings: AppSettings(defaults: defaults, keyStore: .empty),
            vault: SessionVault(rootURL: root.appendingPathComponent("sessions"))
        )
        try body(controller, log)
    }

    /// Rows written so far. The synchronous snapshot waits for queued async events.
    private func logRows(at url: URL) throws -> [[String: String]] {
        _ = AgentLog.snapshotFieldsForTesting()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }
    }

    @MainActor
    private func spinRunLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    @MainActor
    @discardableResult
    private func spinRunLoop(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
        return condition()
    }

    /// Distance from the top of the content area to the highest AppKit pop-up button.
    /// SwiftUI builds no accessibility tree in-process, but Settings pickers are AppKit views.
    @MainActor
    private func topPopUpInset(in window: NSWindow) -> CGFloat? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        var tops: [CGFloat] = []
        func walk(_ view: NSView) {
            if let popUp = view as? NSPopUpButton, !popUp.isHiddenOrHasHiddenAncestor {
                tops.append(window.contentLayoutRect.maxY - popUp.convert(popUp.bounds, to: nil).maxY)
            }
            view.subviews.forEach(walk)
        }
        walk(content)
        return tops.min()
    }

    /// The split view between the sidebar and the detail pane: the outermost one.
    @MainActor
    private func sidebarSplitView(in window: NSWindow) -> NSSplitView? {
        guard let content = window.contentView else { return nil }
        var queue: [NSView] = [content]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2 { return split }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// How far the Settings tab view (an AppKit view) sits from the sidebar's trailing edge, from the window's trailing
    /// edge and from its bottom edge. A negative value is clipped.
    @MainActor
    private func settingsInsets(in window: NSWindow) -> (leading: CGFloat, trailing: CGFloat, bottom: CGFloat)? {
        guard let content = window.contentView, let sidebar = sidebarSplitView(in: window)?.arrangedSubviews.first else { return nil }
        content.layoutSubtreeIfNeeded()
        var stack: [NSView] = [content]
        while let view = stack.popLast() {
            if let tabs = view as? NSTabView, !tabs.isHiddenOrHasHiddenAncestor {
                let frame = tabs.convert(tabs.bounds, to: nil)
                let sidebarEdge = sidebar.convert(sidebar.bounds, to: nil).maxX
                return (frame.minX - sidebarEdge, content.bounds.width - frame.maxX, frame.minY)
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Writes a PNG only when SCRUMTRACE_SNAPSHOT_DIR is set, for manual layout review.
    @MainActor
    private func writeSnapshot(of window: NSWindow, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SCRUMTRACE_SNAPSHOT_DIR"],
              let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("main-\(name).png"))
    }

    @MainActor
    func testReopenShowsTheMainWindowAndReusesIt() throws {
        try withController { controller, log in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            let delegate = AppDelegate()
            delegate.setMainPresenterForTesting(presenter)

            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
            let window = try XCTUnwrap(presenter.window)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(window.title, "ScrumTrace")
            XCTAssertTrue(window.contentViewController is NSHostingController<MainWindowView>)
            XCTAssertTrue(window.delegate === presenter)
            XCTAssertFalse(window.isReleasedWhenClosed)
            XCTAssertEqual(presenter.navigation.section, .overview)
            XCTAssertFalse(NSApp.windows.contains { $0.title == "ScrumTrace Settings" })

            presenter.navigation.section = .contexts
            window.close()
            XCTAssertFalse(window.isVisible)
            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
            XCTAssertTrue(presenter.window === window)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(presenter.navigation.section, .contexts, "Reopen fronts the window without changing the section")

            delegate.showSettingsWindow(nil)
            XCTAssertTrue(presenter.window === window)
            XCTAssertEqual(presenter.navigation.section, .settings)
            delegate.showAgentLogWindow(nil)
            XCTAssertTrue(presenter.window === window)
            XCTAssertEqual(presenter.navigation.settings.selectedTab, .logs)

            let rows = try logRows(at: log)
            let opens = rows.filter { $0["event"] == "main_open" }
            XCTAssertEqual(opens.count, 2)
            XCTAssertTrue(opens.allSatisfy { $0["source"] == "reopen" && $0["section"] == nil })
            XCTAssertEqual(rows.filter { $0["event"] == "settings_open" }.count, 2)
        }
    }

    @MainActor
    func testShowTabSelectsSettingsInTheSameWindow() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            XCTAssertEqual(presenter.navigation.section, .overview)
            XCTAssertEqual(SettingsTab.allCases.count, 6)
            for tab in SettingsTab.allCases {
                presenter.show(section: .overview)
                presenter.show(tab: tab)
                XCTAssertEqual(presenter.navigation.section, .settings)
                XCTAssertEqual(presenter.navigation.settings.selectedTab, tab)
                XCTAssertTrue(presenter.window === window)
                XCTAssertTrue(window.isVisible)
            }
        }
    }

    @MainActor
    func testShowSessionSelectsRecordings() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            presenter.show(sessionId: "2026-09-13_10-00-00")
            let window = try XCTUnwrap(presenter.window)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(presenter.navigation.section, .recordings)
            XCTAssertEqual(presenter.navigation.selectedSessionId, "2026-09-13_10-00-00")
            presenter.show(section: .overview)
            XCTAssertEqual(presenter.navigation.selectedSessionId, "2026-09-13_10-00-00")
            presenter.show(sessionId: "2026-09-13_11-00-00")
            XCTAssertTrue(presenter.window === window)
            XCTAssertEqual(presenter.navigation.section, .recordings)
            XCTAssertEqual(presenter.navigation.selectedSessionId, "2026-09-13_11-00-00")
        }
    }

    @MainActor
    func testShowDeminiaturizesTheWindowAndKeepsTheSection() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            presenter.show(section: .recordings)
            let window = try XCTUnwrap(presenter.window)
            let recordings = presenter.recordings
            XCTAssertTrue(recordings.isPeriodicRefreshActive)
            window.miniaturize(nil)
            XCTAssertTrue(spinRunLoop(until: { window.isMiniaturized }))
            XCTAssertTrue(
                spinRunLoop(until: { !recordings.isPeriodicRefreshActive }),
                "A minimized window stops the periodic refresh"
            )
            XCTAssertFalse(recordings.isWindowVisible)
            window.deminiaturize(nil)
            XCTAssertTrue(
                spinRunLoop(until: { !window.isMiniaturized && recordings.isPeriodicRefreshActive }),
                "Restoring the window from the Dock starts it again"
            )
            XCTAssertTrue(recordings.isWindowVisible)
            // macOS 15 finishes minimizing and restoring asynchronously; wait for the state instead of reading it at once.
            XCTAssertTrue(spinRunLoop(until: { window.isVisible && !window.isMiniaturized }, timeout: 5))
            window.miniaturize(nil)
            XCTAssertTrue(spinRunLoop(until: { window.isMiniaturized }, timeout: 5), "The window must be miniaturized before show()")
            XCTAssertTrue(spinRunLoop(until: { !recordings.isPeriodicRefreshActive }))
            presenter.show()
            XCTAssertTrue(
                spinRunLoop(until: { !window.isMiniaturized && window.isVisible }, timeout: 5),
                "show() restores a minimized window"
            )
            XCTAssertTrue(presenter.window === window)
            XCTAssertEqual(presenter.navigation.section, .recordings)
            XCTAssertTrue(recordings.isPeriodicRefreshActive)
        }
    }

    @MainActor
    func testOpenScrumTraceMenuItemIsEnabledInEveryState() throws {
        try withController { controller, log in
            var opened = 0
            let menuBar = MenuBarController(
                controller: controller,
                openSettings: {},
                openLogs: {},
                openMain: { opened += 1 }
            )
            let menu = menuBar.menu
            let states: [(name: String, apply: () -> Void)] = [
                ("idle", { controller.isBusy = false; controller.phase = .idle }),
                ("busy", { controller.isBusy = true; controller.phase = .transcribing }),
                ("recording", { controller.isBusy = false; controller.phase = .recording }),
                ("paused", { controller.isBusy = false; controller.phase = .paused })
            ]
            for state in states {
                state.apply()
                menuBar.menuWillOpen(menu)
                let item = try XCTUnwrap(menu.item(withTitle: "Open ScrumTrace…"), state.name)
                let index = menu.index(of: item)
                XCTAssertEqual(index + 1, menu.indexOfItem(withTitle: "Settings"), "Open ScrumTrace… sits directly above Settings (\(state.name))")
                XCTAssertTrue(item.isEnabled, state.name)
                menu.performActionForItem(at: index)
                menuBar.menuDidClose(menu)
            }
            XCTAssertEqual(opened, states.count)
            let rows = try logRows(at: log).filter { $0["event"] == "menu_open_main" }
            XCTAssertEqual(rows.count, states.count)
        }
    }

    func testLaunchPolicySkipsBackgroundLaunchesAndTestHosts() {
        let executable = "/Applications/ScrumTrace.app/Contents/MacOS/ScrumTrace"
        XCTAssertTrue(MainWindowLaunchPolicy.shouldShowOnLaunch(arguments: [executable], environment: [:], launchedAsLoginItem: false))
        XCTAssertTrue(MainWindowLaunchPolicy.shouldShowOnLaunch(
            arguments: [executable, "-NSDocumentRevisionsDebugMode", "YES"],
            environment: [:],
            launchedAsLoginItem: false
        ))
        XCTAssertFalse(MainWindowLaunchPolicy.shouldShowOnLaunch(arguments: [executable, "--background"], environment: [:], launchedAsLoginItem: false))
        XCTAssertFalse(MainWindowLaunchPolicy.shouldShowOnLaunch(
            arguments: [executable],
            environment: ["XCTestConfigurationFilePath": "/tmp/ScrumTrace.xctestconfiguration"],
            launchedAsLoginItem: false
        ))
    }

    func testLoginItemLaunchesStayInTheMenuBar() {
        let executable = "/Applications/ScrumTrace.app/Contents/MacOS/ScrumTrace"
        XCTAssertFalse(
            MainWindowLaunchPolicy.shouldShowOnLaunch(arguments: [executable], environment: [:], launchedAsLoginItem: true),
            "A Login Item launch opens no window"
        )

        func launchEvent(_ eventID: AEEventID, property: OSType?) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor.appleEvent(
                withEventClass: kCoreEventClass,
                eventID: eventID,
                targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            if let property {
                event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: keyAEPropData)
            }
            return event
        }
        XCTAssertTrue(MainWindowLaunchPolicy.isLoginItemLaunch(launchEvent(kAEOpenApplication, property: keyAELaunchedAsLogInItem)))
        // The launch event may carry the property as a type code rather than an enumerated value.
        let typed = launchEvent(kAEOpenApplication, property: nil)
        typed.setParam(NSAppleEventDescriptor(typeCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(MainWindowLaunchPolicy.isLoginItemLaunch(typed), "The login property as a type code")
        XCTAssertFalse(
            MainWindowLaunchPolicy.isLoginItemLaunch(launchEvent(kAEOpenApplication, property: nil)),
            "Finder, Launchpad, Spotlight, the Dock and open send the launch event without the login property"
        )
        XCTAssertFalse(MainWindowLaunchPolicy.isLoginItemLaunch(launchEvent(kAEOpenApplication, property: kAEOpenApplication)))
        XCTAssertFalse(
            MainWindowLaunchPolicy.isLoginItemLaunch(launchEvent(kAEReopenApplication, property: keyAELaunchedAsLogInItem)),
            "Only the launch event counts"
        )
        XCTAssertFalse(MainWindowLaunchPolicy.isLoginItemLaunch(nil), "No Apple event")
    }

    func testRelaunchForwardsBackgroundUnlessTheWindowIsOpen() {
        let executable = "/Applications/ScrumTrace.app/Contents/MacOS/ScrumTrace"
        let background = MainWindowLaunchPolicy.backgroundArgument
        XCTAssertEqual(MainWindowLaunchPolicy.relaunchArguments(currentArguments: [executable], windowOpen: false), [background])
        XCTAssertEqual(MainWindowLaunchPolicy.relaunchArguments(currentArguments: [executable], windowOpen: true), [])
        XCTAssertEqual(MainWindowLaunchPolicy.relaunchArguments(currentArguments: [executable, background], windowOpen: false), [background])
        XCTAssertEqual(
            MainWindowLaunchPolicy.relaunchArguments(currentArguments: [executable, background], windowOpen: true),
            [background],
            "The agent loop's instance keeps --background"
        )
        // What the relaunched instance then decides.
        for windowOpen in [false, true] {
            let arguments = [executable] + MainWindowLaunchPolicy.relaunchArguments(currentArguments: [executable], windowOpen: windowOpen)
            XCTAssertEqual(
                MainWindowLaunchPolicy.shouldShowOnLaunch(arguments: arguments, environment: [:], launchedAsLoginItem: false),
                windowOpen
            )
        }
    }

    @MainActor
    func testRelaunchBringsTheWindowBackOnlyWhenItWasOpen() throws {
        try withController { controller, log in
            XCTAssertFalse(ProcessInfo.processInfo.arguments.contains(MainWindowLaunchPolicy.backgroundArgument))
            var relaunches: [[String]] = []
            controller.relaunchApplication = { relaunches.append($0) }
            controller.relaunchForPermissions()
            XCTAssertEqual(relaunches, [["--background"]], "Before any window, the new instance stays in the menu bar")

            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            controller.relaunchForPermissions()
            XCTAssertEqual(relaunches, [["--background"], ["--background"]], "A window that never opened")

            presenter.show()
            controller.relaunchForPermissions()
            XCTAssertEqual(relaunches, [["--background"], ["--background"], []], "An open window opens again after the relaunch")

            let window = try XCTUnwrap(presenter.window)
            window.close()
            controller.relaunchForPermissions()
            XCTAssertEqual(
                relaunches,
                [["--background"], ["--background"], [], ["--background"]],
                "A window closed before Relaunch stays closed"
            )

            controller.isBusy = true
            controller.relaunchForPermissions()
            XCTAssertEqual(relaunches.count, 4, "No relaunch while recording or analysis runs")
            XCTAssertEqual(try logRows(at: log).filter { $0["event"] == "relaunch_ignored" }.count, 1)
        }
    }

    @MainActor
    func testWindowStartsLogMainStartOnceAndOnlyTheStatusBarMenuLogsMenuStart() throws {
        try withController { controller, log in
            let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {})
            var notices = 0
            // Declining the meeting notice ends each Start before an alert, a window or the capture-area overlay.
            menuBar.askMeetingNotice = {
                notices += 1
                return false
            }
            let presenter = MainWindowPresenter(
                controller: controller,
                frameAutosaveName: nil,
                isWindowOnScreen: ignoringOcclusion,
                onStartRecording: { menuBar.requestStart() },
                isPreparingRecording: { menuBar.isPreparingRecording }
            )
            let context = SavedProductContext(name: "Orbit")
            try controller.settings.saveProductContext(context, isNew: true)
            let startEvents: Set<String> = ["menu_start", "main_start", "command_start"]
            func starts() throws -> [String] {
                try logRows(at: log).compactMap { row in row["event"].flatMap { startEvents.contains($0) ? $0 : nil } }
            }

            XCTAssertTrue(presenter.overview.startRecording())
            presenter.recordings.startRecording()
            try presenter.contexts.recordWithContext(id: context.id)
            XCTAssertEqual(notices, 3, "Each window Start ran the app's Start flow")
            XCTAssertEqual(try starts(), ["main_start", "main_start", "main_start"], "A window Start logs main_start once and no menu_start")

            let menu = menuBar.menu
            let item = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Start recording") })
            XCTAssertTrue(item.isEnabled)
            menu.performActionForItem(at: menu.index(of: item))
            menuBar.startFromCommand()
            XCTAssertEqual(notices, 5)
            XCTAssertEqual(try starts(), ["main_start", "main_start", "main_start", "menu_start", "command_start"])
            XCTAssertEqual(try logRows(at: log).filter { $0["event"] == "meeting_notice" }.count, 5)
        }
    }

    @MainActor
    func testCoveringTheWindowStopsItsLoopsAndUncoveringItRefreshesAtOnce() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let onScreen = MainActorBox(true)
                let presenter = MainWindowPresenter(
                    controller: controller,
                    frameAutosaveName: nil,
                    isWindowOnScreen: { $0.isVisible && !$0.isMiniaturized && onScreen.value }
                )
                defer { presenter.window?.close() }
                presenter.show(section: .overview)
                let window = try XCTUnwrap(presenter.window)
                let running = await waitUntil {
                    presenter.overview.isEvaluationLoopActive && presenter.recordings.library.entries.count == 3
                }
                XCTAssertTrue(running)
                XCTAssertTrue(presenter.recordings.isPeriodicRefreshActive)
                let changed = Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window)

                onScreen.value = false
                presenter.windowDidChangeOcclusionState(changed)
                XCTAssertTrue(window.isVisible, "Covered by other windows, not closed")
                XCTAssertFalse(presenter.recordings.isWindowVisible)
                XCTAssertFalse(presenter.recordings.isPeriodicRefreshActive, "A covered window does no periodic refresh")
                XCTAssertFalse(presenter.overview.isWindowVisible)
                XCTAssertFalse(presenter.overview.isEvaluationLoopActive, "A covered window does no readiness work")
                XCTAssertFalse(presenter.contexts.isWindowVisible)

                // A recording added while the window stays covered is not listed by any loop.
                await presenter.recordings.refresh().value
                let added = try makeSession(in: f.vault, status: .completed)
                presenter.windowDidChangeOcclusionState(changed)
                XCTAssertFalse(presenter.recordings.isPeriodicRefreshActive)

                onScreen.value = true
                presenter.windowDidChangeOcclusionState(changed)
                XCTAssertTrue(presenter.recordings.isWindowVisible)
                XCTAssertTrue(presenter.recordings.isPeriodicRefreshActive, "Uncovered, the periodic refresh runs again")
                XCTAssertTrue(presenter.overview.isEvaluationLoopActive, "Uncovered, readiness is checked again")
                XCTAssertTrue(presenter.contexts.isWindowVisible)
                // Well inside the 5 s timer, so only the refresh that uncovering starts can list the new row this soon.
                let listed = await waitUntil(timeout: 2) { presenter.recordings.library.entries.contains { $0.id == added } }
                XCTAssertTrue(listed, "Uncovering the window refreshes the list at once")
            }
        }
    }

    @MainActor
    func testLiveBannerFollowsCaptureState() throws {
        try withController { controller, _ in
            XCTAssertFalse(MainLiveBannerState(controller: controller, resumeAllowed: true).isVisible)
            controller.phase = .transcribing
            controller.isBusy = true
            XCTAssertFalse(MainLiveBannerState(controller: controller, resumeAllowed: true).isVisible, "Processing is not a live recording")

            controller.isBusy = false
            controller.phase = .recording
            controller.mediaElapsed = 754
            controller.statusLine = "Recording"
            let live = MainLiveBannerState(controller: controller, resumeAllowed: false)
            XCTAssertTrue(live.isVisible)
            XCTAssertFalse(live.isPaused)
            XCTAssertEqual(live.title, "Recording")
            XCTAssertEqual(live.elapsed, "12:34")
            XCTAssertNil(live.detail)
            XCTAssertEqual(live.pauseTitle, "Pause")
            XCTAssertTrue(live.canTogglePause, "Pause does not depend on the resume gate")
            XCTAssertNil(live.resumeBlockedReason)
            XCTAssertEqual(live.pauseHelp, "Pause the recording. Nothing is written while paused.")
            controller.statusLine = "Pinned 12:30"
            XCTAssertEqual(MainLiveBannerState(controller: controller, resumeAllowed: false).detail, "Pinned 12:30")

            controller.phase = .paused
            controller.mediaElapsed = 3723
            controller.statusLine = "Paused — nothing is written"
            let paused = MainLiveBannerState(controller: controller, resumeAllowed: true)
            XCTAssertTrue(paused.isVisible)
            XCTAssertTrue(paused.isPaused)
            XCTAssertEqual(paused.title, "Paused")
            XCTAssertEqual(paused.elapsed, "1:02:03")
            XCTAssertEqual(paused.detail, "Paused — nothing is written")
            XCTAssertEqual(paused.pauseTitle, "Resume")
            XCTAssertTrue(paused.canTogglePause)
            XCTAssertNil(paused.resumeBlockedReason)
            XCTAssertEqual(paused.pauseHelp, "Resume the recording.")

            // A password manager came on screen after a pause the user chose: Resume waits, and the banner line and the
            // button's help tag say why instead of repeating the pause line.
            let held = MainLiveBannerState(controller: controller, resumeAllowed: false)
            XCTAssertFalse(held.canTogglePause, "Resume waits for the sampled privacy gate")
            XCTAssertEqual(held.resumeBlockedReason, MainLiveBannerState.privacyHoldReason)
            XCTAssertEqual(held.detail, MainLiveBannerState.privacyHoldReason)
            XCTAssertEqual(held.pauseHelp, MainLiveBannerState.privacyHoldReason)

            // An automatic pause already names the app, so its line stays; the help tag still says why Resume waits.
            controller.statusLine = "Auto-paused for com.1password.1password"
            let automatic = MainLiveBannerState(controller: controller, resumeAllowed: false)
            XCTAssertEqual(automatic.detail, "Auto-paused for com.1password.1password")
            XCTAssertEqual(automatic.pauseHelp, MainLiveBannerState.privacyHoldReason)
            controller.statusLine = "Still auto-paused for a password manager"
            XCTAssertEqual(MainLiveBannerState(controller: controller, resumeAllowed: false).detail, "Still auto-paused for a password manager")

            // Before the banner's first sample, Resume waits without a reason, so a new pause never flashes one.
            let unsampled = MainLiveBannerState(controller: controller, resumeAllowed: nil)
            XCTAssertFalse(unsampled.canTogglePause)
            XCTAssertNil(unsampled.resumeBlockedReason)
            XCTAssertEqual(unsampled.detail, "Still auto-paused for a password manager")
        }
    }

    @MainActor
    func testWindowStaysStableWhileSectionsAndTheBannerChange() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            spinRunLoop(for: 0.1)
            let size = window.frame.size
            let phases: [PipelineStatus] = [.recording, .paused, .idle]
            for section in MainSection.allCases {
                presenter.show(section: section)
                for phase in phases {
                    controller.phase = phase
                    controller.mediaElapsed += 1
                    // A single synchronous layout can miss the hosting feedback loop:
                    // let real display cycles run.
                    spinRunLoop(for: 0.08)
                    window.layoutIfNeeded()
                    XCTAssertEqual(window.frame.size, size, "\(section) \(phase)")
                    XCTAssertTrue(window.delegate === presenter, "\(section) \(phase)")
                    let clamped = presenter.windowWillResize(window, to: NSSize(width: 200, height: 150))
                    XCTAssertEqual(
                        window.contentRect(forFrameRect: NSRect(origin: .zero, size: clamped)).size,
                        NSSize(width: 840, height: 620),
                        "\(section) \(phase)"
                    )
                    XCTAssertEqual(presenter.windowWillResize(window, to: NSSize(width: 1200, height: 900)), NSSize(width: 1200, height: 900))
                    XCTAssertTrue(window.isVisible)
                    writeSnapshot(of: window, named: "\(section.rawValue)-\(phase.rawValue)")
                }
            }
        }
    }

    @MainActor
    func testRestoredFrameBelowTheMinimumGrowsToTheMinimum() throws {
        try withController { controller, _ in
            // Frame autosave only reads the standard defaults, so use a unique name and remove it.
            let name = "ScrumTraceMainTests-\(UUID().uuidString)"
            let key = "NSWindow Frame \(name)"
            defer { UserDefaults.standard.removeObject(forKey: key) }
            let small = NSWindow(
                contentRect: NSRect(x: 120, y: 120, width: 500, height: 400),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            small.isReleasedWhenClosed = false
            UserDefaults.standard.set(small.frameDescriptor, forKey: key)
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: name, isWindowOnScreen: ignoringOcclusion)
            defer {
                presenter.window?.close()
                presenter.window?.setFrameAutosaveName("")
            }
            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            XCTAssertEqual(
                window.contentRect(forFrameRect: window.frame).size,
                MainWindowPresenter.minimumContentSize,
                "A saved 500×400 frame opens at the 840×620 minimum, not below it"
            )
        }
    }

    @MainActor
    func testNavigationWaitsWhileASheetIsOpen() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            presenter.show(tab: .general)
            let window = try XCTUnwrap(presenter.window)
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet)
            defer { if window.attachedSheet != nil { window.endSheet(sheet) } }
            XCTAssertTrue(spinRunLoop(until: { window.attachedSheet === sheet }))

            // Command-1 to Command-4 and the menu stay enabled while a sheet is open.
            presenter.show(section: .overview)
            presenter.show(tab: .logs)
            presenter.show(sessionId: "2026-09-13_10-00-00")
            XCTAssertEqual(presenter.navigation.section, .settings, "Leaving Settings would dismiss the sheet and lose its edits")
            XCTAssertEqual(presenter.navigation.settings.selectedTab, .general)
            XCTAssertNil(presenter.navigation.selectedSessionId)
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(presenter.window === window)

            window.endSheet(sheet)
            XCTAssertTrue(spinRunLoop(until: { window.attachedSheet == nil }))
            presenter.show(section: .overview)
            XCTAssertEqual(presenter.navigation.section, .overview)
        }
    }

    @MainActor
    func testSectionShortcutsAreInTheMainMenu() throws {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        func items(in menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
        }
        let all = items(in: mainMenu)
        for (index, section) in MainSection.allCases.enumerated() {
            let matches = all.filter {
                $0.keyEquivalent == "\(index + 1)"
                    && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
            }
            XCTAssertEqual(matches.map(\.title), [section.title], "Command-\(index + 1)")
        }
        XCTAssertEqual(all.filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command }.count, 1)
        XCTAssertEqual(all.filter { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command }.count, 1)
    }

    @MainActor
    func testSettingsStayPinnedBelowTheBannerAtTheMinimumSize() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            presenter.show(tab: .speech)
            let window = try XCTUnwrap(presenter.window)
            controller.phase = .recording
            let minimum = MainWindowPresenter.minimumContentSize

            // Tall enough for the banner plus Settings' own minimum height.
            window.setContentSize(NSSize(width: minimum.width, height: 800))
            var roomy: CGFloat?
            XCTAssertTrue(spinRunLoop(until: {
                roomy = topPopUpInset(in: window)
                return roomy != nil
            }))
            spinRunLoop(for: 0.2)
            let expected = try XCTUnwrap(topPopUpInset(in: window))

            // At the minimum the content overflows. It must lose its bottom edge, not
            // push the banner and the Settings tabs above the top of the window.
            window.setContentSize(minimum)
            spinRunLoop(for: 0.4)
            let inset = try XCTUnwrap(topPopUpInset(in: window))
            XCTAssertEqual(inset, expected, accuracy: 1)
            XCTAssertGreaterThan(inset, 0)
        }
    }

    @MainActor
    func testSidebarAlwaysKeepsASectionSelected() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            presenter.show(section: .recordings)
            let window = try XCTUnwrap(presenter.window)
            func sidebar(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                for subview in view.subviews {
                    if let table = sidebar(in: subview) { return table }
                }
                return nil
            }
            var found: NSTableView?
            XCTAssertTrue(spinRunLoop(until: {
                found = window.contentView.flatMap { sidebar(in: $0) }
                return (found?.selectedRow ?? -1) >= 0
            }))
            let list = try XCTUnwrap(found)
            XCTAssertEqual(list.numberOfRows, MainSection.allCases.count)
            let selected = list.selectedRow
            XCTAssertEqual(selected, MainSection.allCases.firstIndex(of: .recordings))

            // Clicking empty sidebar space or Command-clicking the row asks for an empty selection.
            list.deselectAll(nil)
            spinRunLoop(for: 0.3)
            XCTAssertEqual(list.selectedRow, selected, "The sidebar must not end up with no highlighted section")
            XCTAssertEqual(presenter.navigation.section, .recordings)
        }
    }

    @MainActor
    func testLiveBannerButtonsLogAndDriveTheController() throws {
        try withController { controller, log in
            controller.phase = .recording
            let banner = MainLiveBanner(controller: controller)
            banner.pauseOrResume()
            XCTAssertEqual(controller.phase, .paused)
            XCTAssertEqual(controller.captureState, .paused)

            // Idle, so the controller's own Stop guard ends the request without processing.
            controller.phase = .idle
            banner.stopAndProcess()
            XCTAssertTrue(spinRunLoop(until: {
                ((try? self.logRows(at: log)) ?? []).contains { $0["event"] == "stop_ignored" }
            }))
            let order = ["main_pause", "pause_ok", "main_stop", "stop_clicked", "stop_ignored"]
            let events = try logRows(at: log).compactMap { $0["event"] }.filter { order.contains($0) }
            XCTAssertEqual(events, order)
            XCTAssertEqual(controller.phase, .idle)
        }
    }

    @MainActor
    func testSettingsSectionIsRebuiltWhenShownAgain() throws {
        try withController { controller, _ in
            let navigation = MainNavigation()
            navigation.section = .settings
            var builds = 0
            let recordings = RecordingsModel(
                library: SessionLibrary(vault: controller.vault),
                navigation: navigation,
                dependencies: .live(controller: controller, startRecording: {})
            )
            let overview = OverviewModel(
                recordings: recordings,
                navigation: navigation,
                dependencies: .live(controller: controller, startRecording: {}, isPreparingRecording: { false })
            )
            let contexts = ContextsModel(
                settings: controller.settings,
                recordings: recordings,
                dependencies: .live(controller: controller, startRecording: {}, isPreparingRecording: { false })
            )
            let hosting = NSHostingController(rootView: MainWindowView(
                controller: controller,
                navigation: navigation,
                recordings: recordings,
                overview: overview,
                contexts: contexts,
                settingsView: {
                    builds += 1
                    return SettingsView(settings: controller.settings, controller: controller, navigation: navigation.settings)
                }
            ))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 960, height: 640))
            defer { window.close() }
            window.orderFront(nil)
            XCTAssertTrue(spinRunLoop(until: { builds > 0 }))

            navigation.section = .overview
            spinRunLoop(for: 0.2)
            let before = builds
            navigation.section = .settings
            // A fresh SettingsView starts from current state, such as the license line.
            XCTAssertTrue(spinRunLoop(until: { builds > before }), "Returning to Settings builds a new SettingsView")
        }
    }

    // MARK: - Recordings

    private struct RecordingsFixture {
        let root: URL
        let vault: SessionVault
        let lockURL: URL
        let log: URL
        /// Newest readable row: transcribing, no export files.
        let unfinished: String
        /// Completed, with export files, a pack, a full transcript archive and approved upload consent.
        let completed: String
        /// Oldest row: a folder whose manifest is not JSON.
        let corrupt: String
    }

    @MainActor
    private func withRecordingsFixture(_ body: (RecordingsFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrumTrace.MainWindowTests.Recordings.\(UUID().uuidString)", isDirectory: true)
        let log = root.appendingPathComponent("agent.jsonl")
        AgentLog.setFileURLForTesting(log)
        defer {
            AgentLog.setFileURLForTesting(nil)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await body(makeRecordingsFixture(root: root, log: log))
    }

    /// A controller over the fixture vault, with its own defaults suite.
    @MainActor
    private func withFixtureController(_ f: RecordingsFixture, _ body: (SessionController) async throws -> Void) async throws {
        let suite = "ScrumTrace.MainWindowTests.Controller.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: f.vault)
        try await body(controller)
    }

    private func makeRecordingsFixture(root: URL, log: URL) throws -> RecordingsFixture {
        let vault = SessionVault(rootURL: root.appendingPathComponent("sessions", isDirectory: true))
        var completed = try vault.createSession(product: ProductContext(
            appName: "Orbit Checkout",
            repoURL: "",
            techStack: "",
            contextID: "ctx-orbit",
            contextName: "Orbit web"
        )).manifest
        completed.createdAt = Date().addingTimeInterval(-7_200)
        completed.pipelineStatus = .completed
        completed.completedStages = PipelineStatusOrder.processingFlow
        completed.duration = DurationPair(wallSeconds: 700, mediaSeconds: 600)
        completed.uploadConsent = UploadConsent(
            approved: true,
            approvedAt: Date(),
            provider: "anthropic",
            endpoint: "https://api.example.test",
            model: "model-x",
            includesClipAudio: true,
            includesClipVideo: false,
            includesStills: true
        )
        try vault.write(manifest: &completed)
        let completedURL = vault.sessionURL(id: completed.sessionId)
        try writeFile(Data("# Agent context".utf8), to: ScrumTracePath.agentContext, in: completedURL)
        try writeFile(Data("<html></html>".utf8), to: ScrumTracePath.sessionBrief, in: completedURL)
        try writeFile(Data(count: 2_048), to: ScrumTracePath.packZip, in: completedURL)
        try writeFile(Data(#"{"segments":[]}"#.utf8), to: ScrumTracePath.fullTranscript, in: completedURL)
        // A movie keeps controller start-up from pruning the fixture as an abandoned start.
        try writeFile(Data(count: 64), to: ScrumTracePath.sessionMovie, in: completedURL)

        var unfinished = try vault.createSession(product: .empty).manifest
        unfinished.createdAt = Date().addingTimeInterval(-600)
        unfinished.pipelineStatus = .transcribing
        try vault.write(manifest: &unfinished)
        try writeFile(Data(count: 64), to: ScrumTracePath.sessionMovie, in: vault.sessionURL(id: unfinished.sessionId))

        let corrupt = "2020-01-01-0000-bad001"
        let corruptURL = vault.sessionURL(id: corrupt)
        try writeFile(Data("{ not json".utf8), to: ScrumTracePath.manifest, in: corruptURL)
        try writeFile(Data(count: 64), to: ScrumTracePath.sessionMovie, in: corruptURL)

        return RecordingsFixture(
            root: root,
            vault: vault,
            lockURL: root.appendingPathComponent("recording.lock"),
            log: log,
            unfinished: unfinished.sessionId,
            completed: completed.sessionId,
            corrupt: corrupt
        )
    }

    private func makeSession(in vault: SessionVault, status: PipelineStatus) throws -> String {
        var manifest = try vault.createSession(product: .empty).manifest
        manifest.pipelineStatus = status
        try vault.write(manifest: &manifest)
        try writeFile(Data(count: 64), to: ScrumTracePath.sessionMovie, in: vault.sessionURL(id: manifest.sessionId))
        return manifest.sessionId
    }

    private func writeFile(_ data: Data, to relative: String, in session: URL) throws {
        let url = session.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 640,
            pixelsHigh: 400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// A model whose every outside effect is a recorded closure, except the `export/` check, deletion and
    /// detail loading, which use the fixture vault and lock file.
    @MainActor
    private func makeRecordingsModel(
        _ f: RecordingsFixture,
        navigation: MainNavigation? = nil,
        recorder: CallRecorder,
        detailLoads: CallRecorder? = nil,
        detailLoadGate: DetailLoadGate? = nil,
        canChange: @escaping @MainActor () -> Bool = { true },
        activeSessionId: @escaping @MainActor () -> String? = { nil },
        forgotten: CallRecorder? = nil,
        handoffFailure: @escaping @MainActor () -> String? = { nil },
        manifestLoads: CallRecorder? = nil,
        manifestLoadGate: DispatchGroup? = nil,
        beforeManifestLoad: (@Sendable () -> Void)? = nil,
        refreshInterval: Duration = RecordingsModel.refreshInterval,
        isPreparingRecording: @escaping @MainActor () -> Bool = { false },
        startStateInterval: Duration = OverviewModel.evaluationInterval,
        preparingInterval: Duration = OverviewModel.preparingInterval,
        onStartRecording: @escaping @MainActor () -> Void = {}
    ) -> RecordingsModel {
        let vault = f.vault
        let lockURL = f.lockURL
        let dependencies = RecordingsDependencies(
            canChangeSessions: canChange,
            activeSessionId: activeSessionId,
            exportDirectory: { SessionFileAccess.exportDirectory(vault: vault, id: $0) },
            revealExport: { folder in
                // Finder gets the folder the off-main check accepted, `<session>/export`.
                XCTAssertEqual(folder, SessionFileAccess.exportDirectory(vault: vault, id: folder.deletingLastPathComponent().lastPathComponent))
                recorder.record("revealExport \(folder.deletingLastPathComponent().lastPathComponent)")
            },
            openInCLI: { cli, id in
                recorder.record("\(cli.rawValue) \(id)")
                return handoffFailure()
            },
            openBrief: { id in
                recorder.record("openBrief \(id)")
                return true
            },
            retryAnalysis: { recorder.record("retryAnalysis \($0)") },
            regenerateLocalExport: { recorder.record("regenerateLocalExport \($0)") },
            copyExportPath: { folder in
                // The folder is `<session>/export`; record the session it belongs to.
                recorder.record("copyExportPath \(folder.deletingLastPathComponent().lastPathComponent)")
                return true
            },
            revealArchive: { id in
                recorder.record("revealArchive \(id)")
                return true
            },
            revealFolder: { id in
                recorder.record("revealFolder \(id)")
                return true
            },
            deleteSession: { id in
                recorder.record("deleteSession \(id)")
                try vault.deleteSession(id: id, recordingLockURL: lockURL)
            },
            forgetSession: { id, newestRemaining in
                forgotten?.record(newestRemaining.map { "\(id) -> \($0)" } ?? id)
                return true
            },
            loadDetail: { id in
                detailLoads?.record(id)
                detailLoadGate?.pass(id)
                return SessionDetailFacts.load(vault: vault, id: id)
            },
            startRecording: {
                recorder.record("startRecording")
                onStartRecording()
            },
            isPreparingRecording: isPreparingRecording
        )
        return RecordingsModel(
            library: SessionLibrary(vault: vault, loadManifest: { vault, id in
                manifestLoads?.record(id)
                // A scan waits here, off the main actor, until the test leaves the group.
                manifestLoadGate?.wait()
                beforeManifestLoad?()
                return try vault.loadManifest(id: id)
            }),
            navigation: navigation ?? MainNavigation(),
            dependencies: dependencies,
            refreshInterval: refreshInterval,
            startStateInterval: startStateInterval,
            preparingInterval: preparingInterval
        )
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Lets every block already queued on the main queue run, such as Combine sinks that receive on it.
    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// `main_*` rows so far. Beyond the fields every row carries, each may hold the session id and nothing else.
    private func mainEventRows(in f: RecordingsFixture, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: String]] {
        AgentLog.event("recordings_test_baseline", [:])
        let rows = try logRows(at: f.log)
        let baseline = try XCTUnwrap(rows.last { $0["event"] == "recordings_test_baseline" }, file: file, line: line)
        let common = Set(baseline.keys)
        let main = rows.filter { ($0["event"] ?? "").hasPrefix("main_") }
        for row in main {
            let extra = Set(row.keys).subtracting(common)
            XCTAssertTrue(extra.isSubset(of: ["session"]), "\(row["event"] ?? "") carries \(extra)", file: file, line: line)
            for value in row.values {
                XCTAssertFalse(value.contains(f.root.lastPathComponent), "No path in \(row["event"] ?? "")", file: file, line: line)
            }
        }
        return main
    }

    @MainActor
    private func recordingsTable(in window: NSWindow) -> NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.tableColumns.count == 7 { return table }
            for subview in view.subviews {
                if let table = find(subview) { return table }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    @MainActor
    func testRecordingActionsDispatchToTheInjectedClosuresWithTheSelectedId() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let model = makeRecordingsModel(f, navigation: navigation, recorder: recorder)
            await model.refresh().value
            XCTAssertTrue(model.hasLoaded)
            XCTAssertEqual(model.library.entries.map(\.id), [f.unfinished, f.completed, f.corrupt])

            XCTAssertFalse(model.performOnSelection(.revealExport), "Nothing is selected")
            navigation.selectedSessionId = f.completed
            let immediate: [RecordingAction] = [.revealExport, .openInClaude, .openInChatGPT, .openBrief, .copyExportPath, .retryAnalysis, .regenerateLocalExport]
            for action in immediate {
                XCTAssertTrue(model.isEnabled(action), "\(action)")
                XCTAssertNil(model.unavailableReason(action), "\(action)")
                XCTAssertTrue(model.performOnSelection(action), "\(action)")
                // Reveal export/ and Copy export path check export/ off the main actor first.
                await model.actionTask?.value
            }
            XCTAssertEqual(recorder.calls, [
                "revealExport \(f.completed)",
                "claude \(f.completed)",
                "chatgpt \(f.completed)",
                "openBrief \(f.completed)",
                "copyExportPath \(f.completed)",
                "retryAnalysis \(f.completed)",
                "regenerateLocalExport \(f.completed)"
            ])
            XCTAssertNil(model.message)

            XCTAssertTrue(model.performOnSelection(.reviewSpeakers))
            XCTAssertEqual(model.speakerReview, SpeakerReviewRequest(sessionId: f.completed))

            XCTAssertTrue(model.performOnSelection(.revealArchive))
            let reveal = try XCTUnwrap(model.pendingPrivateReveal)
            XCTAssertEqual(reveal, PrivateRevealRequest(sessionId: f.completed, action: .revealArchive))
            XCTAssertEqual(recorder.calls.count, 7, "Reveal archive… waits for the warning")
            model.cancelPrivateReveal()
            XCTAssertNil(model.pendingPrivateReveal)
            XCTAssertEqual(recorder.calls.count, 7, "Cancelling the warning reveals nothing")
            XCTAssertTrue(model.performOnSelection(.revealArchive))
            model.confirmPrivateReveal(reveal)
            XCTAssertNil(model.pendingPrivateReveal)
            XCTAssertEqual(recorder.calls.last, "revealArchive \(f.completed)")

            // The row context menu acts on the clicked row, not the selection.
            XCTAssertTrue(model.perform(.revealExport, on: f.unfinished))
            await model.actionTask?.value
            XCTAssertEqual(recorder.calls.last, "revealExport \(f.unfinished)")
            let unfinished = try XCTUnwrap(model.entry(id: f.unfinished))
            XCTAssertFalse(model.isEnabled(.openBrief, for: unfinished), "No brief yet")
            XCTAssertEqual(model.unavailableReason(.openBrief, for: unfinished), "This recording has no brief yet.")
            XCTAssertFalse(model.perform(.openBrief, on: f.unfinished))
            for handoff in [RecordingAction.openInClaude, .openInChatGPT] {
                XCTAssertFalse(model.perform(handoff, on: f.unfinished), "No AGENT_CONTEXT.md to hand over: \(handoff)")
                XCTAssertEqual(model.unavailableReason(handoff, for: unfinished), "This recording has no export to hand to an agent yet.")
            }
            XCTAssertFalse(model.perform(.reviewSpeakers, on: f.unfinished), "No full transcript to review")
            XCTAssertEqual(model.unavailableReason(.reviewSpeakers, for: unfinished), "This recording has no transcript to review yet.")
            XCTAssertFalse(model.perform(.revealExport, on: "2026-01-01-0000-absent"), "Only listed sessions")
            XCTAssertEqual(recorder.calls.count, 9)

            model.startRecording()
            XCTAssertEqual(recorder.calls.last, "startRecording")

            let rows = try mainEventRows(in: f)
            XCTAssertEqual(rows.compactMap { $0["event"] }, [
                "main_reveal_export", "main_claude", "main_chatgpt", "main_open_brief", "main_copy_export_path",
                "main_retry", "main_local_export", "main_review_speakers", "main_reveal_archive", "main_reveal_export", "main_start"
            ])
            XCTAssertEqual(
                rows.map { $0["session"] ?? "" },
                Array(repeating: f.completed, count: 9) + [f.unfinished, ""]
            )
        }
    }

    @MainActor
    func testRecordingsStartLogsMainStartOnlyWhenTheStartFlowWouldRun() async throws {
        try await withRecordingsFixture { f in
            let recorder = CallRecorder()
            let canChange = MainActorBox(true)
            let preparing = MainActorBox(true)
            let model = makeRecordingsModel(
                f,
                recorder: recorder,
                canChange: { canChange.value },
                isPreparingRecording: { preparing.value }
            )
            func starts() throws -> [String] {
                try mainEventRows(in: f).compactMap { $0["event"] }.filter { $0 == "main_start" }
            }

            // A Start that still reaches the model while another Start shows its context window is refused too.
            model.startRecording()
            XCTAssertEqual(recorder.calls, [], "The Start flow would refuse a second Start")
            XCTAssertEqual(try starts(), [], "A refused Start logs no main_start for the Gate 0 overlay check")

            preparing.value = false
            canChange.value = false
            model.startRecording()
            XCTAssertEqual(recorder.calls, [], "No Start while recording or analysis runs")
            XCTAssertEqual(try starts(), [])

            canChange.value = true
            model.startRecording()
            XCTAssertEqual(recorder.calls, ["startRecording"])
            XCTAssertEqual(try starts(), ["main_start"])
        }
    }

    @MainActor
    func testExportActionsAndPrivateRevealsSayWhyTheyDidNotRun() async throws {
        try await withRecordingsFixture { f in
            let recorder = CallRecorder()
            let canChange = MainActorBox(true)
            let handoffFailure = MainActorBox<String?>(nil)
            let model = makeRecordingsModel(
                f,
                recorder: recorder,
                canChange: { canChange.value },
                handoffFailure: { handoffFailure.value }
            )
            await model.refresh().value

            // A handoff that fails says why here, not only in the menu bar status line.
            handoffFailure.value = "Claude Code is not installed. Install the claude command, sign in, then try again."
            XCTAssertTrue(model.perform(.openInClaude, on: f.completed))
            XCTAssertEqual(model.message, handoffFailure.value)
            handoffFailure.value = nil
            XCTAssertTrue(model.perform(.openInChatGPT, on: f.completed))
            XCTAssertNil(model.message, "A handoff that starts clears the line")

            // export/ gone: Reveal export/ and Copy export path explain, and a drag offers nothing.
            let completed = f.vault.sessionURL(id: f.completed)
            try FileManager.default.moveItem(
                at: completed.appendingPathComponent(ScrumTracePath.export),
                to: completed.appendingPathComponent("export-moved")
            )
            XCTAssertNil(model.exportDragURL(for: f.completed), "No export/ folder, nothing to drag")
            XCTAssertNil(model.dragItemProvider(for: f.completed))
            XCTAssertTrue(model.perform(.revealExport, on: f.completed))
            await model.actionTask?.value
            XCTAssertEqual(model.message, "The export folder is missing or contains a link, so it was not revealed.")
            XCTAssertTrue(model.perform(.copyExportPath, on: f.completed))
            await model.actionTask?.value
            XCTAssertEqual(model.message, "The export folder is missing or contains a link, so its path was not copied.")
            XCTAssertEqual(recorder.calls, ["claude \(f.completed)", "chatgpt \(f.completed)"], "Nothing ran without a validated folder")

            // A private reveal confirmed after recording started, or after its row went away, says why.
            XCTAssertTrue(model.perform(.revealArchive, on: f.completed))
            let reveal = try XCTUnwrap(model.pendingPrivateReveal)
            canChange.value = false
            model.confirmPrivateReveal(reveal)
            XCTAssertEqual(model.message, RecordingsModel.busyReason)
            canChange.value = true
            model.confirmPrivateReveal(PrivateRevealRequest(sessionId: "2026-01-01-0000-absent", action: .revealArchive))
            XCTAssertEqual(model.message, RecordingsModel.unlistedReason)
            XCTAssertEqual(recorder.calls.count, 2, "Neither reveal ran")
            let events = try mainEventRows(in: f).compactMap { $0["event"] }
            XCTAssertFalse(events.contains("main_reveal_archive"))
            XCTAssertFalse(events.contains("main_drag_export"))
        }
    }

    @MainActor
    func testDeleteAsksFirstCancelChangesNothingAndConfirmDeletesThenRefreshes() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let model = makeRecordingsModel(f, navigation: navigation, recorder: recorder)
            await model.refresh().value
            navigation.selectedSessionId = f.completed
            let folder = f.vault.sessionURL(id: f.completed)

            XCTAssertTrue(model.performOnSelection(.delete))
            XCTAssertEqual(model.pendingDelete, f.completed)
            XCTAssertEqual(recorder.calls, [], "Delete… only asks")
            model.cancelDelete()
            XCTAssertNil(model.pendingDelete)
            await model.refresh().value
            XCTAssertEqual(recorder.calls, [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertEqual(navigation.selectedSessionId, f.completed)
            XCTAssertEqual(model.library.entries.map(\.id), [f.unfinished, f.completed, f.corrupt])
            XCTAssertEqual(try mainEventRows(in: f).count, 0, "Nothing is logged for a cancelled delete")

            XCTAssertTrue(model.performOnSelection(.delete))
            let deletion = try XCTUnwrap(model.confirmDelete(f.completed))
            XCTAssertNil(model.pendingDelete)
            await deletion.value
            XCTAssertEqual(recorder.calls, ["deleteSession \(f.completed)"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertEqual(model.library.entries.map(\.id), [f.unfinished, f.corrupt], "The list refreshed after the delete")
            XCTAssertNil(navigation.selectedSessionId, "The deleted row is no longer selected")
            XCTAssertNil(model.message)
            let rows = try mainEventRows(in: f)
            XCTAssertEqual(rows.compactMap { $0["event"] }, ["main_delete"])
            XCTAssertEqual(rows.first?["session"], f.completed)
        }
    }

    @MainActor
    func testDeleteWaitsForRecordingAndAnalysisAndRefusesAnUnlistedRowAndALiveRecordingLock() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let forgotten = CallRecorder()
            let busy = MainActorBox(true)
            let active = ActiveSessionBox(f.completed.uppercased())
            let model = makeRecordingsModel(
                f, navigation: navigation, recorder: recorder,
                canChange: { !busy.value }, activeSessionId: { active.id }, forgotten: forgotten
            )
            await model.refresh().value
            navigation.selectedSessionId = f.completed

            // The controller records or analyses this session, named in another spelling.
            XCTAssertFalse(model.isEnabled(.delete))
            XCTAssertEqual(model.unavailableReason(.delete), RecordingsModel.busyReason, "The disabled Delete says why")
            XCTAssertFalse(model.performOnSelection(.delete))
            XCTAssertNil(model.pendingDelete)
            XCTAssertNil(model.confirmDelete(f.completed), "Confirming cannot bypass the check")
            XCTAssertEqual(model.message, RecordingsModel.busyReason)
            XCTAssertEqual(recorder.calls, [])

            // Once recording and analysis finish, the session the controller still holds in memory can be deleted.
            busy.value = false
            model.syncCaptureState()
            XCTAssertEqual(model.activeSessionId, f.completed.uppercased())
            XCTAssertTrue(model.isEnabled(.delete), "The last recorded or retried session is not held once idle")
            XCTAssertNil(model.unavailableReason(.delete))
            XCTAssertTrue(model.isEnabled(.retryAnalysis))

            // Recording started while the dialog was open.
            XCTAssertTrue(model.performOnSelection(.delete))
            busy.value = true
            XCTAssertNil(model.confirmDelete(f.completed))
            XCTAssertNil(model.pendingDelete)
            XCTAssertEqual(model.message, RecordingsModel.busyReason)
            XCTAssertEqual(recorder.calls, [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.vault.sessionURL(id: f.completed).path))
            busy.value = false

            // A row that left the list is refused with its own reason.
            XCTAssertNil(model.confirmDelete("2026-01-01-0000-absent"))
            XCTAssertEqual(model.message, RecordingsModel.unlistedReason)

            // A live recording.lock names the other session: the vault refuses and the row stays.
            try "\(f.unfinished)\n\(ProcessInfo.processInfo.processIdentifier)\n"
                .write(to: f.lockURL, atomically: true, encoding: .utf8)
            XCTAssertTrue(model.perform(.delete, on: f.unfinished))
            let refused = try XCTUnwrap(model.confirmDelete(f.unfinished))
            // Deleting a large archive can outlast a selection change; the line names its recording.
            navigation.selectedSessionId = f.corrupt
            await refused.value
            XCTAssertEqual(recorder.calls, ["deleteSession \(f.unfinished)"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.vault.sessionURL(id: f.unfinished).path))
            XCTAssertEqual(model.message, "Recording \(f.unfinished) is still live. Stop it before deleting.")
            XCTAssertEqual(model.library.entries.map(\.id), [f.unfinished, f.completed, f.corrupt])
            XCTAssertEqual(navigation.selectedSessionId, f.corrupt)
            XCTAssertTrue(try mainEventRows(in: f).contains { $0["event"] == "main_delete_refused" && $0["session"] == f.unfinished })
            XCTAssertEqual(
                forgotten.calls,
                ["\(f.unfinished) -> \(f.completed)"],
                "A refused delete is forgotten only before the removal, never again after it"
            )
        }
    }

    @MainActor
    func testTheLastRecordedOrRetriedSessionCanBeDeletedOnceIdleAndTheControllerForgetsIt() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let navigation = MainNavigation()
                let model = RecordingsModel(
                    library: SessionLibrary(vault: f.vault),
                    navigation: navigation,
                    dependencies: .live(controller: controller, startRecording: {})
                )
                model.observe(controller: controller)
                await model.refresh().value
                navigation.selectedSessionId = f.completed
                let folder = f.vault.sessionURL(id: f.completed)

                // Processing of this recording, or a retry of it, finished: the controller keeps its manifest in memory.
                controller.holdProcessedSessionForTesting(try f.vault.loadManifest(id: f.completed))
                XCTAssertEqual(controller.activeSessionId, f.completed)
                XCTAssertEqual(controller.lastSessionId, f.completed)
                let settled = await waitUntil { model.activeSessionId == f.completed && model.canChangeSessions }
                XCTAssertTrue(settled)

                // Delete still waits while analysis or a recording runs.
                let states: [(name: String, apply: () -> Void)] = [
                    ("analysis", { controller.isBusy = true; controller.phase = .transcribing }),
                    ("recording", { controller.isBusy = false; controller.phase = .recording })
                ]
                for state in states {
                    state.apply()
                    let followed = await waitUntil { !model.canChangeSessions }
                    XCTAssertTrue(followed, state.name)
                    XCTAssertFalse(model.isEnabled(.delete), state.name)
                    XCTAssertEqual(model.unavailableReason(.delete), RecordingsModel.busyReason, state.name)
                    XCTAssertFalse(model.performOnSelection(.delete), state.name)
                    XCTAssertNil(model.confirmDelete(f.completed), state.name)
                    XCTAssertEqual(model.message, RecordingsModel.busyReason, state.name)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
                XCTAssertEqual(controller.lastSessionId, f.completed)

                // Once both finish, it deletes like any other recording.
                controller.phase = .completed
                let idle = await waitUntil { model.canChangeSessions }
                XCTAssertTrue(idle)
                XCTAssertEqual(controller.activeSessionId, f.completed, "The controller still holds the manifest in memory")
                XCTAssertTrue(model.isEnabled(.delete), "The last recorded or retried session is not held once idle")
                XCTAssertNil(model.unavailableReason(.delete))
                XCTAssertTrue(model.performOnSelection(.delete))
                let deletion = try XCTUnwrap(model.confirmDelete(f.completed))
                await deletion.value
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
                XCTAssertNil(model.message)
                XCTAssertEqual(model.library.entries.map(\.id), [f.unfinished, f.corrupt])

                // The controller no longer names the deleted session: the menu's last-session items move to the next recent
                // recording, which stays listed, instead of turning off.
                XCTAssertNil(controller.activeSessionId)
                XCTAssertEqual(controller.lastSessionId, f.unfinished, "The menu's last-session items name the next recent recording")
                XCTAssertNil(model.activeSessionId)

                // A Retry Analysis of the deleted session, from a Recent item built before the delete, writes nothing back
                // and leaves the menu on the next recent recording.
                controller.retryAnalysis(sessionId: f.completed)
                let ended = await waitUntil { !controller.isBusy }
                XCTAssertTrue(ended)
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
                XCTAssertEqual(controller.lastSessionId, f.unfinished)
                XCTAssertEqual(controller.phase, .completed)
                XCTAssertNil(controller.lastError)
                XCTAssertTrue(try logRows(at: f.log).contains {
                    $0["event"] == "retry_ignored" && $0["reason"] == "session_missing" && $0["session"] == f.completed
                })

                // Deleting the last readable recording leaves the menu with no last session; an unreadable row is not one.
                navigation.selectedSessionId = f.unfinished
                XCTAssertTrue(model.performOnSelection(.delete))
                let last = try XCTUnwrap(model.confirmDelete(f.unfinished))
                await last.value
                XCTAssertEqual(model.library.entries.map(\.id), [f.corrupt])
                XCTAssertNil(controller.lastSessionId, "No readable recording remains")
            }
        }
    }

    @MainActor
    func testADeleteThatFinishesWhileTheControllerIsBusyLeavesItsSessionAloneUntilTheRunEnds() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let navigation = MainNavigation()
                let model = RecordingsModel(
                    library: SessionLibrary(vault: f.vault),
                    navigation: navigation,
                    dependencies: .live(controller: controller, startRecording: {})
                )
                model.observe(controller: controller)
                await model.refresh().value
                navigation.selectedSessionId = f.completed
                let folder = f.vault.sessionURL(id: f.completed)
                controller.holdProcessedSessionForTesting(try f.vault.loadManifest(id: f.completed))
                let settled = await waitUntil { model.activeSessionId == f.completed && model.canChangeSessions }
                XCTAssertTrue(settled)

                // The delete starts while idle, and the controller forgets the session before its folder starts to go.
                let manifest = try f.vault.loadManifest(id: f.completed)
                let deletion = try XCTUnwrap(model.confirmDelete(f.completed))
                XCTAssertNil(controller.activeSessionId)
                XCTAssertEqual(controller.lastSessionId, f.unfinished, "The menu's last-session items leave the session at once")
                // Before the delete finishes, Retry Analysis of the same session starts from a Recent item built earlier.
                controller.holdProcessedSessionForTesting(manifest)
                controller.isBusy = true
                controller.phase = .transcribing
                await deletion.value
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
                XCTAssertFalse(model.library.entries.contains { $0.id == f.completed })

                // The running analysis keeps the session it works on.
                XCTAssertEqual(controller.activeSessionId, f.completed)
                XCTAssertEqual(controller.lastSessionId, f.completed)
                XCTAssertTrue(controller.isBusy)
                XCTAssertEqual(controller.phase, .transcribing)
                XCTAssertFalse(controller.forgetSession(id: f.completed), "Nothing is forgotten while analysis runs")
                XCTAssertEqual(controller.lastSessionId, f.completed)

                // The analysis fails on the removed folder and ends; the window forgets the session then, and the menu's
                // last session moves to the next recent recording.
                controller.phase = .offlineFailed
                controller.isBusy = false
                let forgotten = await waitUntil { controller.lastSessionId == f.unfinished }
                XCTAssertTrue(forgotten, "The deleted session is forgotten once the controller is idle")
                XCTAssertNil(controller.activeSessionId)
                let followed = await waitUntil { model.activeSessionId == nil }
                XCTAssertTrue(followed)

                controller.retryAnalysis(sessionId: f.completed)
                let ignored = await waitUntil { !controller.isBusy }
                XCTAssertTrue(ignored)
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "The in-memory manifest is not written back")
                XCTAssertTrue(try logRows(at: f.log).contains { $0["event"] == "retry_ignored" && $0["reason"] == "session_missing" })
                XCTAssertEqual(controller.lastSessionId, f.unfinished)

                // Forgotten once: a session the controller holds afterwards is left alone.
                controller.holdProcessedSessionForTesting(try f.vault.loadManifest(id: f.unfinished))
                controller.isBusy = true
                controller.isBusy = false
                let synced = await waitUntil { model.activeSessionId == f.unfinished && model.canChangeSessions }
                XCTAssertTrue(synced)
                XCTAssertEqual(controller.lastSessionId, f.unfinished)
            }
        }
    }

    @MainActor
    func testARetryOfASessionDeletedMeanwhileWritesNothingBackAndLeavesTheControllerIdle() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let folder = f.vault.sessionURL(id: f.completed)
                // Processing finished: the controller holds the manifest in memory and names the session last.
                controller.holdProcessedSessionForTesting(try f.vault.loadManifest(id: f.completed))
                // The window removes the folder before the controller forgot the session, and Retry Analysis of it starts
                // from the status-bar menu.
                try f.vault.deleteSession(id: f.completed, recordingLockURL: f.lockURL)
                controller.retryAnalysis(sessionId: f.completed)
                XCTAssertTrue(controller.isBusy)
                let ended = await waitUntil { !controller.isBusy }
                XCTAssertTrue(ended, "The retry ends at once")

                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "The manifest held in memory is not written into a new folder")
                XCTAssertEqual(f.vault.sessionEntries().map(\.id), [f.unfinished, f.corrupt], "No recording without archive or export is listed")
                XCTAssertEqual(controller.phase, .completed, "The controller is idle, not offline-failed")
                XCTAssertNil(controller.lastError)
                XCTAssertEqual(controller.statusLine, "Recording was deleted — nothing to retry", "The menu's status line says why nothing ran")
                XCTAssertEqual(controller.lastSessionId, f.completed, "The menu names what it named before the retry")
                let rows = try logRows(at: f.log)
                XCTAssertTrue(rows.contains { $0["event"] == "retry_ignored" && $0["reason"] == "session_missing" && $0["session"] == f.completed })
                XCTAssertFalse(rows.contains { $0["event"] == "processor_begin" || $0["event"] == "processor_fail" })

                // Forgetting it then moves the menu to the recording the window names, never to the forgotten one, and to
                // none when none remains.
                XCTAssertTrue(controller.forgetSession(id: f.completed.uppercased(), newestRemaining: f.unfinished))
                XCTAssertNil(controller.activeSessionId)
                XCTAssertEqual(controller.lastSessionId, f.unfinished)
                XCTAssertTrue(controller.forgetSession(id: f.unfinished, newestRemaining: f.unfinished.uppercased()))
                XCTAssertNil(controller.lastSessionId)
            }
        }
    }

    @MainActor
    func testARetryWhoseFolderIsDeletedWhileTheUploadConsentAlertIsOpenWritesNothingBack() async throws {
        try await withRecordingsFixture { f in
            let suite = "ScrumTrace.MainWindowTests.Controller.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            // A stored key, so the retry asks for upload consent again: the fixture's consent names another provider.
            let keys = SettingsKeyStore(get: { _ in "sk-test" }, contains: { _ in true }, set: { _, _ in }, remove: { _ in })
            let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: keys), vault: f.vault)
            let folder = f.vault.sessionURL(id: f.completed)
            controller.lastSessionId = f.unfinished
            // The manifest and the folder are there when the retry starts. The window's delete removes the folder while
            // the consent alert is open.
            let prompts = CallRecorder()
            controller.uploadConsentPromptForTesting = {
                prompts.record("consent")
                try? f.vault.deleteSession(id: f.completed, recordingLockURL: f.lockURL)
                return .denied
            }
            controller.retryAnalysis(sessionId: f.completed)
            let ended = await waitUntil { !controller.isBusy }
            XCTAssertTrue(ended, "The retry ends at once")
            XCTAssertEqual(prompts.calls, ["consent"], "The retry asked for upload consent")

            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "The manifest is not written into a new folder")
            XCTAssertEqual(f.vault.sessionEntries().map(\.id), [f.unfinished, f.corrupt], "No recording without archive or export is listed")
            XCTAssertEqual(controller.phase, .idle, "The controller is idle, not offline-failed")
            XCTAssertNil(controller.lastError)
            XCTAssertEqual(controller.statusLine, "Recording was deleted — nothing to retry", "The menu's status line says why nothing ran")
            XCTAssertEqual(controller.lastSessionId, f.unfinished, "The menu names what it named before the retry")
            let rows = try logRows(at: f.log)
            XCTAssertTrue(rows.contains { $0["event"] == "retry_ignored" && $0["reason"] == "session_missing" && $0["session"] == f.completed })
            XCTAssertFalse(rows.contains { $0["event"] == "processor_fail" || $0["event"] == "processor_ok" })
        }
    }

    @MainActor
    func testConfirmingADeleteForgetsTheSessionBeforeTheRemovalAndAgainAfterIt() async throws {
        try await withRecordingsFixture { f in
            let newest = try makeSession(in: f.vault, status: .completed)
            let calls = CallRecorder()
            let model = makeRecordingsModel(f, recorder: calls, forgotten: calls)
            await model.refresh().value
            XCTAssertEqual(model.library.entries.map(\.id), [newest, f.unfinished, f.completed, f.corrupt])

            // The controller forgets the newest recording before its folder starts to go; its last session moves on.
            XCTAssertTrue(model.perform(.delete, on: newest))
            let first = try XCTUnwrap(model.confirmDelete(newest))
            XCTAssertEqual(calls.calls, ["\(newest) -> \(f.unfinished)"])

            // A second delete while the first runs never moves the last session to the recording being removed.
            XCTAssertTrue(model.perform(.delete, on: f.unfinished))
            let second = try XCTUnwrap(model.confirmDelete(f.unfinished))
            XCTAssertEqual(calls.calls, ["\(newest) -> \(f.unfinished)", "\(f.unfinished) -> \(f.completed)"])

            await first.value
            await second.value
            XCTAssertEqual(calls.calls.filter { $0.hasPrefix("deleteSession") }.sorted(), ["deleteSession \(newest)", "deleteSession \(f.unfinished)"].sorted())
            XCTAssertEqual(
                calls.calls.filter { !$0.hasPrefix("deleteSession") }.sorted(),
                ["\(newest) -> \(f.unfinished)", "\(f.unfinished) -> \(f.completed)", "\(newest) -> \(f.completed)", "\(f.unfinished) -> \(f.completed)"].sorted(),
                "Each delete is forgotten again once its folder is gone"
            )
            for id in [newest, f.unfinished] {
                let delete = try XCTUnwrap(calls.calls.firstIndex(of: "deleteSession \(id)"))
                XCTAssertTrue(calls.calls[..<delete].contains { $0.hasPrefix("\(id) -> ") }, "\(id) is forgotten before its removal")
                XCTAssertTrue(calls.calls[(delete + 1)...].contains { $0.hasPrefix("\(id) -> ") }, "\(id) is forgotten after its removal")
            }
            XCTAssertEqual(model.library.entries.map(\.id), [f.completed, f.corrupt])

            // With only an unreadable row left, the last session moves to none.
            XCTAssertTrue(model.perform(.delete, on: f.completed))
            await model.confirmDelete(f.completed)?.value
            XCTAssertEqual(calls.calls.suffix(3), [f.completed, "deleteSession \(f.completed)", f.completed])
        }
    }

    @MainActor
    func testTheDeleteConfirmationKeepsNamingItsRowWhileItCloses() async throws {
        try await withRecordingsFixture { f in
            let recorder = CallRecorder()
            let model = makeRecordingsModel(f, recorder: recorder)
            await model.refresh().value
            let unfinished = try XCTUnwrap(model.entry(id: f.unfinished))
            let completed = try XCTUnwrap(model.entry(id: f.completed))
            XCTAssertNil(model.closingDeleteTitle)

            // Cancel clears `pendingDelete` while the dialog still animates away; it keeps the row's title.
            XCTAssertTrue(model.perform(.delete, on: f.unfinished))
            model.cancelDelete()
            XCTAssertNil(model.pendingDelete)
            XCTAssertEqual(model.closingDeleteTitle, RecordingRowText.deleteTitle(unfinished))
            // The dialog's binding reports the dismissal again; the title stays.
            model.cancelDelete()
            XCTAssertEqual(model.closingDeleteTitle, RecordingRowText.deleteTitle(unfinished))

            // Delete recording: the title names the confirmed row, also once the row has left the list.
            XCTAssertTrue(model.perform(.delete, on: f.completed))
            let deletion = try XCTUnwrap(model.confirmDelete(f.completed))
            XCTAssertNil(model.pendingDelete)
            XCTAssertEqual(model.closingDeleteTitle, RecordingRowText.deleteTitle(completed))
            model.cancelDelete()
            await deletion.value
            XCTAssertNil(model.entry(id: f.completed))
            XCTAssertEqual(model.closingDeleteTitle, RecordingRowText.deleteTitle(completed))
            XCTAssertNotEqual(model.closingDeleteTitle, RecordingRowText.deleteTitle(nil))
            XCTAssertEqual(recorder.calls, ["deleteSession \(f.completed)"])
        }
    }

    @MainActor
    func testBusyOrRecordingDisablesRetryDeleteSpeakerReviewAndPrivateReveals() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                XCTAssertNil(controller.activeSessionId, "No session is held before a recording or a retry")
                let model = RecordingsModel(
                    library: SessionLibrary(vault: f.vault),
                    navigation: MainNavigation(),
                    dependencies: .live(controller: controller, startRecording: {})
                )
                model.observe(controller: controller)
                await model.refresh().value
                XCTAssertEqual(model.library.entries.map(\.id), [f.unfinished, f.completed, f.corrupt])
                let completed = try XCTUnwrap(model.entry(id: f.completed))
                let unreadable = try XCTUnwrap(model.entry(id: f.corrupt))
                let gated: [RecordingAction] = [.retryAnalysis, .regenerateLocalExport, .delete, .reviewSpeakers, .revealArchive]
                let handoff: [RecordingAction] = [.revealExport, .openInClaude, .openInChatGPT, .openBrief, .copyExportPath]
                for action in gated + handoff {
                    XCTAssertTrue(model.isEnabled(action, for: completed), "idle \(action)")
                }
                XCTAssertTrue(model.isEnabled(.revealFolder, for: unreadable))
                XCTAssertTrue(model.isEnabled(.delete, for: unreadable))

                let states: [(name: String, apply: () -> Void)] = [
                    ("busy", { controller.isBusy = true; controller.phase = .transcribing }),
                    ("recording", { controller.isBusy = false; controller.phase = .recording }),
                    ("paused", { controller.isBusy = false; controller.phase = .paused })
                ]
                for state in states {
                    state.apply()
                    let followed = await waitUntil { !model.canChangeSessions }
                    XCTAssertTrue(followed, "\(state.name): the model follows the controller")
                    for action in gated {
                        XCTAssertFalse(model.isEnabled(action, for: completed), "\(state.name) \(action)")
                        XCTAssertEqual(model.unavailableReason(action, for: completed), RecordingsModel.busyReason, "\(state.name) \(action)")
                        XCTAssertFalse(model.perform(action, on: f.completed), "\(state.name) \(action)")
                    }
                    XCTAssertFalse(model.isEnabled(.revealFolder, for: unreadable), state.name)
                    XCTAssertFalse(model.isEnabled(.delete, for: unreadable), state.name)
                    XCTAssertNil(model.confirmDelete(f.completed), state.name)
                    XCTAssertEqual(model.message, RecordingsModel.busyReason, state.name)
                    for action in handoff {
                        XCTAssertTrue(model.isEnabled(action, for: completed), "\(state.name) \(action)")
                    }
                    XCTAssertNil(model.pendingDelete, state.name)
                    XCTAssertNil(model.pendingPrivateReveal, state.name)
                    XCTAssertNil(model.speakerReview, state.name)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: f.vault.sessionURL(id: f.completed).path))

                controller.phase = .idle
                let idle = await waitUntil { model.canChangeSessions }
                XCTAssertTrue(idle)
                XCTAssertTrue(model.isEnabled(.delete, for: completed))
            }
        }
    }

    @MainActor
    func testAnUnreadableEntryOffersOnlyRevealFolderAndDelete() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let model = makeRecordingsModel(f, navigation: navigation, recorder: recorder)
            await model.refresh().value
            let entry = try XCTUnwrap(model.entry(id: f.corrupt))
            XCTAssertNil(entry.summary)
            XCTAssertEqual(model.actions(for: entry), [.revealFolder, .delete])
            XCTAssertFalse(model.actions(for: try XCTUnwrap(model.entry(id: f.completed))).contains(.revealFolder))
            for action in RecordingAction.allCases {
                XCTAssertEqual(model.isEnabled(action, for: entry), action == .revealFolder || action == .delete, "\(action)")
            }
            for action in RecordingAction.allCases where action != .revealFolder && action != .delete {
                XCTAssertFalse(model.perform(action, on: f.corrupt), "\(action)")
            }
            XCTAssertNil(model.exportDragURL(for: f.corrupt), "An unreadable row offers nothing to drag")
            XCTAssertNil(model.dragItemProvider(for: f.corrupt))
            XCTAssertEqual(recorder.calls, [])
            XCTAssertNil(model.speakerReview)

            XCTAssertTrue(model.perform(.revealFolder, on: f.corrupt))
            let request = try XCTUnwrap(model.pendingPrivateReveal)
            XCTAssertEqual(request.action, .revealFolder)
            XCTAssertEqual(recorder.calls, [], "The folder holds archive/, so it is revealed only after the warning")
            model.confirmPrivateReveal(request)
            XCTAssertEqual(recorder.calls, ["revealFolder \(f.corrupt)"])

            navigation.selectedSessionId = f.corrupt
            XCTAssertTrue(model.performOnSelection(.delete))
            await model.confirmDelete(f.corrupt)?.value
            XCTAssertEqual(recorder.calls.last, "deleteSession \(f.corrupt)")
            XCTAssertEqual(model.library.entries.map(\.id), [f.unfinished, f.completed])
            XCTAssertNil(navigation.selectedSessionId)
            XCTAssertEqual(try mainEventRows(in: f).compactMap { $0["event"] }, ["main_reveal_folder", "main_delete"])
        }
    }

    @MainActor
    func testASelectionHiddenBySearchOrFilterLeavesTheDetailAndToolbarIdle() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let model = makeRecordingsModel(f, navigation: navigation, recorder: recorder)
            await model.refresh().value
            navigation.selectedSessionId = f.completed
            XCTAssertEqual(model.selectedEntry?.id, f.completed)
            XCTAssertTrue(model.isEnabled(.delete))

            model.searchText = f.unfinished
            XCTAssertEqual(model.visibleEntries.map(\.id), [f.unfinished])
            XCTAssertNil(model.selectedEntry, "The table no longer lists the selected row")
            for action in RecordingAction.allCases {
                XCTAssertFalse(model.isEnabled(action), "\(action)")
                XCTAssertNil(model.unavailableReason(action), "\(action)")
                XCTAssertFalse(model.performOnSelection(action), "\(action)")
            }
            XCTAssertNil(model.pendingDelete)
            XCTAssertNil(model.pendingPrivateReveal)
            XCTAssertEqual(navigation.selectedSessionId, f.completed, "The selection is kept for when the search is cleared")

            model.searchText = ""
            model.statusFilter = .unfinished
            XCTAssertNil(model.selectedEntry, "A status filter hides it too")
            model.statusFilter = nil
            model.contextFilter = "ctx-orbit"
            XCTAssertEqual(model.selectedEntry?.id, f.completed, "Its own context keeps it listed")
            model.clearFilters()
            XCTAssertEqual(model.selectedEntry?.id, f.completed)
            XCTAssertTrue(model.performOnSelection(.delete))
            XCTAssertEqual(model.pendingDelete, f.completed)
            XCTAssertEqual(recorder.calls, [])
        }
    }

    @MainActor
    func testDetailFactsStayOnScreenAndReloadAfterSpeakerReviewRetryAndRowChanges() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let loads = CallRecorder()
            let model = makeRecordingsModel(f, navigation: navigation, recorder: recorder, detailLoads: loads)
            await model.refresh().value
            navigation.selectedSessionId = f.completed
            let summary = try XCTUnwrap(model.selectedEntry?.summary)
            @MainActor func names(_ row: SessionSummary) -> [String] {
                model.detail(for: row)?.exportFiles.map(\.name) ?? []
            }
            XCTAssertNil(model.detail(for: summary))
            await model.loadDetail(for: summary)?.value
            XCTAssertEqual(names(summary), ["AGENT_CONTEXT.md", "SESSION_BRIEF.html", "session-pack.zip"])
            XCTAssertTrue(model.isDetailCurrent(for: summary))
            XCTAssertNil(model.loadDetail(for: summary), "Current facts are not read again")
            XCTAssertEqual(loads.calls, [f.completed])

            // Review speakers closed without saving writes nothing and leaves the row unchanged. The facts stay
            // on screen and are read again, because a saved review rebuilds export files the row does not track.
            let completedURL = f.vault.sessionURL(id: f.completed)
            try writeFile(Data("prompt".utf8), to: ScrumTracePath.agentPrompt, in: completedURL)
            let addedBeforeReview = try makeSession(in: f.vault, status: .completed)
            XCTAssertTrue(model.performOnSelection(.reviewSpeakers))
            model.speakerReview = nil
            model.speakerReviewDidClose()
            XCTAssertEqual(
                names(summary), ["AGENT_CONTEXT.md", "SESSION_BRIEF.html", "session-pack.zip"],
                "The pane keeps its facts while they reload, instead of a spinner"
            )
            let reviewed = await waitUntil { names(summary).contains("AGENT_PROMPT.txt") }
            XCTAssertTrue(reviewed, "The facts come back without selecting another row")
            let listedAfterReview = await waitUntil { model.library.entries.contains { $0.id == addedBeforeReview } }
            XCTAssertTrue(listedAfterReview, "Closing the sheet refreshes the list")
            XCTAssertEqual(model.selectedEntry?.summary, summary, "The row itself did not change")
            XCTAssertTrue(model.isDetailCurrent(for: summary))
            XCTAssertEqual(loads.calls, [f.completed, f.completed])

            // Retry analysis, including a retry the controller refuses without writing anything.
            try writeFile(Data("omitted".utf8), to: ScrumTracePath.omitted, in: completedURL)
            let addedBeforeRetry = try makeSession(in: f.vault, status: .completed)
            XCTAssertTrue(model.performOnSelection(.retryAnalysis))
            XCTAssertEqual(recorder.calls.last, "retryAnalysis \(f.completed)")
            XCTAssertTrue(names(summary).contains("AGENT_PROMPT.txt"), "Still shown while reloading")
            let retried = await waitUntil { names(summary).contains("OMITTED.md") }
            XCTAssertTrue(retried)
            let listedAfterRetry = await waitUntil { model.library.entries.contains { $0.id == addedBeforeRetry } }
            XCTAssertTrue(listedAfterRetry, "Retry refreshes the list")
            XCTAssertEqual(loads.calls.count, 3)

            // A changed row shows the previous facts until its own load finishes, and one load serves both callers.
            var manifest = try f.vault.loadManifest(id: f.completed)
            manifest.duration = DurationPair(wallSeconds: 900, mediaSeconds: 800)
            try f.vault.write(manifest: &manifest)
            await model.refresh().value
            let changed = try XCTUnwrap(model.selectedEntry?.summary)
            XCTAssertNotEqual(changed, summary)
            XCTAssertFalse(model.isDetailCurrent(for: changed))
            XCTAssertEqual(names(changed), names(summary), "No flicker to a spinner while the new facts load")
            let first = try XCTUnwrap(model.loadDetail(for: changed))
            XCTAssertNotNil(model.loadDetail(for: changed), "The running load is returned")
            await first.value
            XCTAssertTrue(model.isDetailCurrent(for: changed))
            XCTAssertEqual(loads.calls.count, 4, "A second request for the same row did not read again")
        }
    }

    @MainActor
    func testDetailLoadsForRowsThatLostTheSelectionStopAndNeverEvictTheSelectedRow() async throws {
        try await withRecordingsFixture { f in
            // More rows than the detail cache keeps, each passed over while its load is still running.
            var passed: [String] = []
            for _ in 0..<RecordingsModel.detailCacheLimit {
                passed.append(try makeSession(in: f.vault, status: .completed))
            }
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let loads = CallRecorder()
            let gate = DetailLoadGate(holding: Set(passed))
            defer { gate.release() }
            let model = makeRecordingsModel(f, navigation: navigation, recorder: recorder, detailLoads: loads, detailLoadGate: gate)
            await model.refresh().value
            @MainActor func summary(_ id: String) throws -> SessionSummary {
                try XCTUnwrap(model.entry(id: id)?.summary, id)
            }

            // The row the user comes back to loaded first.
            navigation.selectedSessionId = f.completed
            let selected = try summary(f.completed)
            await model.loadDetail(for: selected)?.value
            XCTAssertTrue(model.isDetailCurrent(for: selected))

            // Arrowing through other rows starts a load for each; moving on cancels it.
            var running: [Task<Void, Never>] = []
            for id in passed {
                navigation.selectedSessionId = id
                running.append(try XCTUnwrap(model.loadDetail(for: try summary(id))))
            }
            navigation.selectedSessionId = f.completed
            XCTAssertNil(model.loadDetail(for: selected), "The selected row's facts are still current")

            gate.release()
            for task in running { await task.value }
            XCTAssertTrue(model.isDetailCurrent(for: selected), "Loads for rows that lost the selection never evict the selected row")
            XCTAssertEqual(
                model.detail(for: selected)?.exportFiles.map(\.name),
                ["AGENT_CONTEXT.md", "SESSION_BRIEF.html", "session-pack.zip"]
            )
            for id in passed {
                XCTAssertNil(model.detail(for: try summary(id)), "A row that lost the selection keeps no facts")
            }
            XCTAssertEqual(Set(gate.cancelled), Set(passed), "Every load for a row that lost the selection was cancelled")

            // Selecting a row again starts a fresh load instead of joining the cancelled one.
            let revisited = try summary(passed[0])
            navigation.selectedSessionId = revisited.sessionId
            let fresh = try XCTUnwrap(model.loadDetail(for: revisited))
            await fresh.value
            XCTAssertTrue(model.isDetailCurrent(for: revisited))
            XCTAssertEqual(loads.calls.filter { $0 == revisited.sessionId }.count, 2)
            XCTAssertEqual(Set(gate.cancelled), Set(passed), "The fresh load was not cancelled")

            // Only the selected row loads.
            XCTAssertNil(model.loadDetail(for: try summary(passed[1])))
            XCTAssertEqual(loads.calls.filter { $0 == passed[1] }.count, 1)
        }
    }

    @MainActor
    func testACancelledThumbnailLoadStopsBeforeTheNextStill() async throws {
        try await withRecordingsFixture { f in
            let session = f.vault.sessionURL(id: f.completed)
            let png = try pngData()
            for index in 1...10 {
                try writeFile(png, to: String(format: "export/shots/%03d.png", index), in: session)
            }
            let reads = CallRecorder()
            let proceed = DispatchSemaphore(value: 0)
            let loading = Task.detached { () -> Int in
                SessionThumbnailLoader.thumbnails(sessionURL: session, read: { relative, sessionURL in
                    reads.record(relative)
                    if reads.calls.count == 1 { proceed.wait() }
                    return SessionThumbnailLoader.containedRead(relative, sessionURL)
                }).count
            }
            let started = await waitUntil { reads.calls.count == 1 }
            XCTAssertTrue(started)
            loading.cancel()
            proceed.signal()
            let loaded = await loading.value
            XCTAssertEqual(loaded, 1, "The still being read finishes")
            XCTAssertEqual(reads.calls, ["export/shots/001.png"], "No further still is read once the load is cancelled")
            XCTAssertEqual(SessionThumbnailLoader.thumbnails(sessionURL: session).count, SessionThumbnailLoader.limit)
        }
    }

    @MainActor
    func testDetailFactsStoreOnlyAllowListedFields() async throws {
        try await withRecordingsFixture { f in
            try writeFile(try pngData(), to: "export/shots/001.png", in: f.vault.sessionURL(id: f.completed))
            let facts = SessionDetailFacts.load(vault: f.vault, id: f.completed)
            let review = "A new detail field needs a privacy review (C2): of the manifest the pane keeps upload consent only"
            let stored = Mirror(reflecting: facts).children
            XCTAssertEqual(stored.compactMap(\.label), ["exportFiles", "consent", "thumbnails"], review)
            XCTAssertTrue(stored.first { $0.label == "exportFiles" }?.value is [SessionDetailFacts.ExportFile])
            XCTAssertTrue(stored.first { $0.label == "consent" }?.value is SessionDetailFacts.Consent?)
            XCTAssertTrue(stored.first { $0.label == "thumbnails" }?.value is [SessionThumbnail])

            let consent = Mirror(reflecting: try XCTUnwrap(facts.consent)).children
            XCTAssertEqual(
                consent.compactMap(\.label), ["approved", "provider", "model", "includesClipAudio", "includesClipVideo"], review
            )
            XCTAssertEqual(consent.filter { $0.value is String? }.compactMap(\.label), ["provider", "model"], "Only the service is text")
            XCTAssertEqual(consent.filter { $0.value is Bool }.compactMap(\.label), ["approved", "includesClipAudio", "includesClipVideo"])

            let file = try XCTUnwrap(facts.exportFiles.first)
            XCTAssertEqual(Mirror(reflecting: file).children.compactMap(\.label), ["path", "bytes"], review)
            XCTAssertTrue(facts.exportFiles.allSatisfy { $0.path.hasPrefix("\(ScrumTracePath.export)/") })
            let thumbnail = try XCTUnwrap(facts.thumbnails.first)
            XCTAssertEqual(Mirror(reflecting: thumbnail).children.compactMap(\.label), ["id", "image"], review)
            XCTAssertTrue(facts.thumbnails.allSatisfy { SessionThumbnailLoader.isShotPath($0.id) })
        }
    }

    @MainActor
    func testThumbnailLoaderReadsOnlyExportShotsAndNeverFollowsLinks() async throws {
        try await withRecordingsFixture { f in
            let session = f.vault.sessionURL(id: f.completed)
            let png = try pngData()
            try writeFile(png, to: "export/shots/001.jpg", in: session)
            try writeFile(png, to: "export/shots/001.annotated.jpg", in: session)
            try writeFile(png, to: "export/shots/002.png", in: session)
            try writeFile(Data(), to: "export/shots/003.jpg", in: session)
            try writeFile(png, to: "export/shots/nested/005.jpg", in: session)
            try writeFile(png, to: "export/shots/.hidden.jpg", in: session)
            try writeFile(Data("text".utf8), to: "export/shots/notes.txt", in: session)
            try writeFile(png, to: "archive/shots/004.png", in: session)
            try FileManager.default.createSymbolicLink(
                at: session.appendingPathComponent("export/shots/004.jpg"),
                withDestinationURL: session.appendingPathComponent("archive/shots/004.png")
            )

            let reads = CallRecorder()
            let reader: SessionThumbnailLoader.Reader = { relative, sessionURL in
                reads.record(relative)
                return SessionThumbnailLoader.containedRead(relative, sessionURL)
            }
            XCTAssertEqual(SessionThumbnailLoader.shotCandidates(sessionURL: session), [
                ["export/shots/001.annotated.jpg", "export/shots/001.jpg"],
                ["export/shots/002.png"],
                ["export/shots/003.jpg"],
                ["export/shots/004.jpg"]
            ])
            XCTAssertEqual(SessionThumbnailLoader.thumbnails(sessionURL: session, limit: 1).map(\.id), ["export/shots/001.annotated.jpg"])
            let thumbnails = SessionThumbnailLoader.thumbnails(sessionURL: session, read: reader)
            XCTAssertEqual(thumbnails.map(\.id), ["export/shots/001.annotated.jpg", "export/shots/002.png"])
            XCTAssertEqual(
                reads.calls, ["export/shots/001.annotated.jpg", "export/shots/002.png"],
                "An empty still and a link into archive/ are refused before anything is read"
            )
            XCTAssertLessThanOrEqual(thumbnails.first?.image.width ?? .max, SessionThumbnailLoader.maxPixelSize)

            let refused = [
                "archive/shots/004.png",
                "export/shots/../../archive/shots/004.png",
                "export/shots/../shots/002.png",
                "./export/shots/002.png",
                "export//shots/002.png",
                "export/002.png",
                "export/shots/004.jpg",
                "export/shots/nested/005.jpg",
                "export/shots/.hidden.jpg",
                "export/shots/notes.txt",
                session.appendingPathComponent("export/shots/002.png").path
            ]
            for path in refused {
                XCTAssertNil(SessionThumbnailLoader.loadThumbnail(relative: path, sessionURL: session, read: reader), path)
            }
            XCTAssertTrue(SessionThumbnailLoader.isShotPath("export/shots/002.png"))
            XCTAssertEqual(reads.calls.count, 2, "Paths outside export/shots are never opened")

            let facts = SessionDetailFacts.load(vault: f.vault, id: f.completed)
            XCTAssertEqual(facts.exportFiles.map(\.name), ["AGENT_CONTEXT.md", "SESSION_BRIEF.html", "session-pack.zip"])
            XCTAssertEqual(facts.exportFiles.map(\.bytes), [15, 13, 2_048])
            XCTAssertEqual(facts.consent, SessionDetailFacts.Consent(
                approved: true, provider: "anthropic", model: "model-x", includesClipAudio: true, includesClipVideo: false
            ))
            XCTAssertEqual(facts.thumbnails.map(\.id), ["export/shots/001.annotated.jpg", "export/shots/002.png"])
            let denied = SessionDetailFacts.Consent(UploadConsent(
                approved: false, approvedAt: nil, provider: "openai", endpoint: "https://api.example.test",
                model: "model-y", includesClipAudio: false, includesClipVideo: false, includesStills: false
            ))
            XCTAssertNil(denied.provider, "Provider and model are shown only for an approved upload")
            XCTAssertNil(denied.model)

            // export/shots swapped for a link into archive/: nothing is listed or read.
            let shots = session.appendingPathComponent(ScrumTracePath.exportShots)
            try FileManager.default.moveItem(at: shots, to: session.appendingPathComponent("export/shots-real"))
            try FileManager.default.createSymbolicLink(at: shots, withDestinationURL: session.appendingPathComponent("archive/shots"))
            XCTAssertEqual(SessionThumbnailLoader.shotCandidates(sessionURL: session), [])
            XCTAssertEqual(SessionThumbnailLoader.thumbnails(sessionURL: session, read: reader), [])
            XCTAssertNil(SessionThumbnailLoader.loadThumbnail(relative: "export/shots/004.png", sessionURL: session, read: reader))

            // export/ itself swapped for a link.
            let other = f.vault.sessionURL(id: f.unfinished)
            try writeFile(png, to: "archive/shots/001.png", in: other)
            let otherExport = other.appendingPathComponent(ScrumTracePath.export)
            try FileManager.default.moveItem(at: otherExport, to: other.appendingPathComponent("export-real"))
            try FileManager.default.createSymbolicLink(at: otherExport, withDestinationURL: other.appendingPathComponent("archive"))
            XCTAssertEqual(SessionThumbnailLoader.shotCandidates(sessionURL: other), [])
            XCTAssertNil(SessionThumbnailLoader.loadThumbnail(relative: "export/shots/001.png", sessionURL: other, read: reader))
            XCTAssertEqual(SessionDetailFacts.load(vault: f.vault, id: f.unfinished).thumbnails, [])
            XCTAssertEqual(reads.calls.count, 2, "Nothing behind a link is read")
        }
    }

    @MainActor
    func testThumbnailsFallBackPastBrokenStillsAndStillFillTheLimit() async throws {
        try await withRecordingsFixture { f in
            let session = f.vault.sessionURL(id: f.completed)
            let png = try pngData()
            // Shot 001: the annotated copy is empty, the plain still is good.
            try writeFile(Data(), to: "export/shots/001.annotated.png", in: session)
            try writeFile(png, to: "export/shots/001.png", in: session)
            // Shot 002: not an image, and no other copy.
            try writeFile(Data("not an image".utf8), to: "export/shots/002.png", in: session)
            // Shot 003: two annotated copies. The png is chosen whatever order the folder lists them in.
            try writeFile(png, to: "export/shots/003.annotated.jpg", in: session)
            try writeFile(png, to: "export/shots/003.annotated.png", in: session)
            for index in 4...10 {
                try writeFile(png, to: String(format: "export/shots/%03d.png", index), in: session)
            }
            let candidates = SessionThumbnailLoader.shotCandidates(sessionURL: session)
            XCTAssertEqual(candidates.count, 10)
            XCTAssertEqual(candidates[0], ["export/shots/001.annotated.png", "export/shots/001.png"])
            XCTAssertEqual(candidates[2], ["export/shots/003.annotated.png", "export/shots/003.annotated.jpg"])

            let thumbnails = SessionThumbnailLoader.thumbnails(sessionURL: session)
            XCTAssertEqual(thumbnails.map(\.id), [
                "export/shots/001.png", "export/shots/003.annotated.png", "export/shots/004.png", "export/shots/005.png",
                "export/shots/006.png", "export/shots/007.png", "export/shots/008.png", "export/shots/009.png"
            ], "A broken still falls back to the Shot's plain copy, and a broken Shot leaves room for a later one")
            XCTAssertEqual(thumbnails.count, SessionThumbnailLoader.limit)

            // A folder of broken stills is tried only up to the attempt cap.
            let broken = f.vault.sessionURL(id: f.unfinished)
            for index in 1...(SessionThumbnailLoader.maxAttempts + 10) {
                try writeFile(Data("broken".utf8), to: String(format: "export/shots/%03d.png", index), in: broken)
            }
            let reads = CallRecorder()
            let loaded = SessionThumbnailLoader.thumbnails(sessionURL: broken, read: { relative, sessionURL in
                reads.record(relative)
                return SessionThumbnailLoader.containedRead(relative, sessionURL)
            })
            XCTAssertEqual(loaded, [])
            XCTAssertEqual(reads.calls.count, SessionThumbnailLoader.maxAttempts)
        }
    }

    @MainActor
    func testFileAccessAndDragOfferOnlyRealFoldersInsideTheSession() async throws {
        try await withRecordingsFixture { f in
            let completed = f.vault.sessionURL(id: f.completed)
            let export = try XCTUnwrap(SessionFileAccess.exportDirectory(vault: f.vault, id: f.completed))
            XCTAssertEqual(export.lastPathComponent, ScrumTracePath.export)
            XCTAssertEqual(
                export.resolvingSymlinksInPath().path,
                completed.appendingPathComponent(ScrumTracePath.export).resolvingSymlinksInPath().path
            )
            XCTAssertEqual(SessionFileAccess.archiveDirectory(vault: f.vault, id: f.completed)?.lastPathComponent, ScrumTracePath.archive)
            XCTAssertEqual(SessionFileAccess.sessionDirectory(vault: f.vault, id: f.corrupt)?.lastPathComponent, f.corrupt)
            XCTAssertEqual(SessionFileAccess.briefURL(vault: f.vault, id: f.completed)?.lastPathComponent, "SESSION_BRIEF.html")
            XCTAssertNil(SessionFileAccess.briefURL(vault: f.vault, id: f.unfinished), "No brief yet")
            for id in ["", "../outside", "2026-01-01-0000-absent"] {
                XCTAssertNil(SessionFileAccess.exportDirectory(vault: f.vault, id: id), id)
                XCTAssertNil(SessionFileAccess.archiveDirectory(vault: f.vault, id: id), id)
                XCTAssertNil(SessionFileAccess.sessionDirectory(vault: f.vault, id: id), id)
                XCTAssertNil(SessionFileAccess.briefURL(vault: f.vault, id: id), id)
            }

            let model = makeRecordingsModel(f, recorder: CallRecorder())
            await model.refresh().value
            XCTAssertEqual(model.exportDragURL(for: f.completed), export, "A row drags its export/ folder, nothing else")
            let provider = try XCTUnwrap(model.dragItemProvider(for: f.completed))
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.file-url"))
            XCTAssertEqual(try mainEventRows(in: f).compactMap { $0["event"] }, ["main_drag_export"])

            // A link planted inside export/ could lead a drop into archive/.
            let planted = completed.appendingPathComponent("export/archive-link")
            try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: completed.appendingPathComponent(ScrumTracePath.archive))
            XCTAssertNil(SessionFileAccess.exportDirectory(vault: f.vault, id: f.completed))
            XCTAssertNil(model.exportDragURL(for: f.completed))
            XCTAssertNil(model.dragItemProvider(for: f.completed))
            try FileManager.default.removeItem(at: planted)

            // archive/ or export/ replaced by a link is never offered.
            let unfinished = f.vault.sessionURL(id: f.unfinished)
            let archive = unfinished.appendingPathComponent(ScrumTracePath.archive)
            try FileManager.default.moveItem(at: archive, to: unfinished.appendingPathComponent("archive-real"))
            try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: unfinished.appendingPathComponent("archive-real"))
            XCTAssertNil(SessionFileAccess.archiveDirectory(vault: f.vault, id: f.unfinished))
            let unfinishedExport = unfinished.appendingPathComponent(ScrumTracePath.export)
            try FileManager.default.moveItem(at: unfinishedExport, to: unfinished.appendingPathComponent("export-real"))
            try FileManager.default.createSymbolicLink(at: unfinishedExport, withDestinationURL: unfinished.appendingPathComponent("archive-real"))
            XCTAssertNil(SessionFileAccess.exportDirectory(vault: f.vault, id: f.unfinished))
            XCTAssertNil(model.exportDragURL(for: f.unfinished))

            // A session folder that is itself a link is refused.
            let linked = "2020-02-02-0000-link01"
            try FileManager.default.createSymbolicLink(at: f.vault.rootURL.appendingPathComponent(linked), withDestinationURL: completed)
            XCTAssertNil(SessionFileAccess.sessionDirectory(vault: f.vault, id: linked))
            XCTAssertNil(SessionFileAccess.exportDirectory(vault: f.vault, id: linked))
            XCTAssertNil(SessionFileAccess.archiveDirectory(vault: f.vault, id: linked))
            XCTAssertNil(SessionFileAccess.briefURL(vault: f.vault, id: linked))
        }
    }

    @MainActor
    func testShowSessionSelectsItsRowInTheRecordingsTable() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
                defer { presenter.window?.close() }
                XCTAssertFalse(presenter.recordings.isWindowVisible)

                presenter.show(sessionId: f.completed)
                let window = try XCTUnwrap(presenter.window)
                XCTAssertTrue(presenter.recordings.isWindowVisible)
                XCTAssertTrue(presenter.recordings.isPeriodicRefreshActive)
                let selected = await waitUntil { (self.recordingsTable(in: window)?.selectedRow ?? -1) >= 0 }
                XCTAssertTrue(selected, "The row show(sessionId:) asked for is selected once the list loads")
                let rows = presenter.recordings.visibleEntries.map(\.id)
                XCTAssertEqual(rows, [f.unfinished, f.completed, f.corrupt])
                let table = try XCTUnwrap(recordingsTable(in: window))
                XCTAssertEqual(table.numberOfRows, 3)
                XCTAssertEqual(table.selectedRow, rows.firstIndex(of: f.completed))
                XCTAssertEqual(presenter.recordings.selectedEntry?.id, f.completed)
                XCTAssertTrue(
                    window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true,
                    "Search sits in the window toolbar"
                )
                let summary = try XCTUnwrap(presenter.recordings.selectedEntry?.summary)
                let loaded = await waitUntil { presenter.recordings.isDetailCurrent(for: summary) }
                XCTAssertTrue(loaded, "The detail pane loads the selected row's facts")
                spinRunLoop(for: 0.05)
                writeSnapshot(of: window, named: "recordings-selected")

                presenter.recordings.searchText = f.unfinished
                let filtered = await waitUntil { self.recordingsTable(in: window)?.numberOfRows == 1 }
                XCTAssertTrue(filtered)
                presenter.show(sessionId: f.corrupt)
                XCTAssertEqual(presenter.recordings.searchText, "", "A search that hides the requested row is cleared")
                let moved = await waitUntil {
                    let current = self.recordingsTable(in: window)
                    return current?.numberOfRows == 3 && current?.selectedRow == 2
                }
                XCTAssertTrue(moved)
                XCTAssertEqual(presenter.navigation.selectedSessionId, f.corrupt)
                writeSnapshot(of: window, named: "recordings-unreadable")

                window.close()
                XCTAssertFalse(presenter.recordings.isWindowVisible)
                XCTAssertFalse(presenter.recordings.isPeriodicRefreshActive, "A closed window does no periodic work")
            }
        }
    }

    @MainActor
    func testRecordingsRefreshWhenProcessingEndsAndPeriodicallyOnlyWhileVisible() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let navigation = MainNavigation()
                navigation.section = .recordings
                let model = makeRecordingsModel(f, navigation: navigation, recorder: CallRecorder(), refreshInterval: .milliseconds(50))
                model.observe(controller: controller)
                // A refresh marks the library loading at once, so after the queued sinks ran this proves none started.
                await drainMainQueue()
                XCTAssertFalse(model.library.isLoading, "Nothing refreshes until the section, the window or processing asks")
                XCTAssertEqual(model.library.entries, [])
                XCTAssertFalse(model.isPeriodicRefreshActive)

                controller.isBusy = true
                controller.phase = .transcribing
                await drainMainQueue()
                XCTAssertFalse(model.library.isLoading, "A processing stage is not the end of processing")
                XCTAssertFalse(model.hasLoaded)
                controller.phase = .completed
                controller.isBusy = false
                let refreshed = await waitUntil { model.library.entries.count == 3 }
                XCTAssertTrue(refreshed, "Processing that ends refreshes the list")

                // Analysis that ends offline is an end of processing too.
                let failedOffline = try makeSession(in: f.vault, status: .offlineFailed)
                controller.isBusy = true
                controller.phase = .evaluating
                controller.phase = .offlineFailed
                controller.isBusy = false
                let listedOffline = await waitUntil { model.library.entries.contains { $0.id == failedOffline } }
                XCTAssertTrue(listedOffline, "Processing that ends offline refreshes the list")
                for phase: PipelineStatus in [.recording, .paused, .transcribing, .slicing, .evaluating, .synthesizing] {
                    XCTAssertFalse(RecordingsModel.endsProcessing(phase), phase.rawValue)
                }

                model.setWindowVisible(true)
                XCTAssertTrue(model.isPeriodicRefreshActive)
                await model.refresh().value
                let added = try makeSession(in: f.vault, status: .completed)
                let ticked = await waitUntil { model.library.entries.contains { $0.id == added } }
                XCTAssertTrue(ticked, "A visible window refreshes on its own")

                let loop = try XCTUnwrap(model.periodicRefresh)
                model.setWindowVisible(false)
                XCTAssertFalse(model.isPeriodicRefreshActive)
                let ended = MainActorBox(false)
                Task { @MainActor in
                    await loop.value
                    ended.value = true
                }
                let stopped = await waitUntil { ended.value }
                XCTAssertTrue(stopped, "Hiding the window ends the refresh loop, so no timer refreshes a hidden window")
            }
        }
    }

    @MainActor
    func testRecordingsRefreshesNeverCreateOrShowTheWindow() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
                defer { presenter.window?.close() }
                let model = presenter.recordings

                model.sectionDidAppear()
                controller.isBusy = true
                controller.phase = .transcribing
                controller.phase = .completed
                controller.isBusy = false
                let listed = await waitUntil { model.library.entries.count == 3 }
                XCTAssertTrue(listed)
                await model.refresh().value
                XCTAssertNil(presenter.window, "Refreshing, and processing that ends, never create the window")
                XCTAssertFalse(model.isWindowVisible)
                XCTAssertFalse(model.isPeriodicRefreshActive)

                presenter.show(section: .recordings)
                let window = try XCTUnwrap(presenter.window)
                XCTAssertTrue(model.isPeriodicRefreshActive)
                let shown = await waitUntil { self.recordingsTable(in: window)?.numberOfRows == 3 }
                XCTAssertTrue(shown, "The section appeared and listed its rows")
                window.close()
                XCTAssertFalse(model.isPeriodicRefreshActive)
                // Supersede every refresh the open window started, so only processing can list the next session.
                await model.refresh().value

                let added = try makeSession(in: f.vault, status: .offlineFailed)
                controller.isBusy = true
                controller.phase = .synthesizing
                controller.phase = .offlineFailed
                controller.isBusy = false
                let refreshed = await waitUntil { model.library.entries.contains { $0.id == added } }
                XCTAssertTrue(refreshed, "The list of a closed window still follows processing")
                model.sectionDidAppear()
                await model.refresh().value
                XCTAssertTrue(presenter.window === window)
                XCTAssertFalse(window.isVisible, "Refreshing leaves a closed window closed")
                XCTAssertFalse(window.isMiniaturized)
                XCTAssertFalse(model.isWindowVisible)
                XCTAssertFalse(model.isPeriodicRefreshActive)
            }
        }
    }

    @MainActor
    func testSwitchingToRecordingsInAnOpenWindowRefreshesAtOnce() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
                defer { presenter.window?.close() }
                let model = presenter.recordings
                // Open on a section without the table. The sidebar badge needs the index there too.
                presenter.show(section: .settings)
                let window = try XCTUnwrap(presenter.window)
                XCTAssertTrue(model.isPeriodicRefreshActive)
                XCTAssertTrue(model.library.isLoading, "Opening the window on Settings scans at once for the sidebar badge")
                let loaded = await waitUntil { model.hasLoaded && model.library.entries.count == 3 }
                XCTAssertTrue(loaded)
                let added = try makeSession(in: f.vault, status: .completed)
                presenter.navigation.section = .recordings
                // Well inside the 5 s timer, so only the section appearing can list the new row this soon.
                let listed = await waitUntil(timeout: 2) { self.recordingsTable(in: window)?.numberOfRows == 4 }
                XCTAssertTrue(listed, "Recordings refreshes when it appears")
                XCTAssertTrue(model.library.entries.contains { $0.id == added })
            }
        }
    }

    @MainActor
    func testOpeningTheWindowScansInEverySectionAndRecordingsJoinsThatScan() async throws {
        try await withRecordingsFixture { f in
            // Command-comma on a closed window shows Settings. The sidebar's Recordings badge counts unfinished
            // recordings from the index, so Settings scans at once and keeps following the vault.
            let settingsNavigation = MainNavigation()
            settingsNavigation.section = .settings
            let settingsLoads = CallRecorder()
            let settingsModel = makeRecordingsModel(
                f,
                navigation: settingsNavigation,
                recorder: CallRecorder(),
                manifestLoads: settingsLoads,
                refreshInterval: .milliseconds(50)
            )
            settingsModel.setWindowVisible(true)
            XCTAssertTrue(settingsModel.isPeriodicRefreshActive)
            XCTAssertTrue(settingsModel.library.isLoading, "Becoming visible on Settings scans at once")
            let listedOnSettings = await waitUntil { settingsModel.library.entries.count == 3 }
            XCTAssertTrue(listedOnSettings)
            let crashed = try makeSession(in: f.vault, status: .paused)
            let followed = await waitUntil(timeout: 2) { settingsModel.library.entries.contains { $0.id == crashed } }
            XCTAssertTrue(followed, "While Settings stays on screen the index keeps refreshing")
            XCTAssertEqual(settingsNavigation.section, .settings)
            settingsModel.setWindowVisible(false)
            XCTAssertFalse(settingsModel.isPeriodicRefreshActive)
            XCTAssertGreaterThanOrEqual(settingsLoads.calls.count, 4)
            try FileManager.default.removeItem(at: f.vault.sessionURL(id: crashed))

            let navigation = MainNavigation()
            let loads = CallRecorder()
            let model = makeRecordingsModel(f, navigation: navigation, recorder: CallRecorder(), manifestLoads: loads)

            // The window opens on Recordings, then RecordingsView appears: one scan, each manifest decoded once.
            navigation.section = .recordings
            model.setWindowVisible(true)
            XCTAssertTrue(model.library.isLoading, "Becoming visible on Recordings scans at once")
            await model.sectionDidAppear().value
            XCTAssertEqual(model.library.entries.map(\.id), [f.unfinished, f.completed, f.corrupt])
            _ = await waitUntil(timeout: 0.3) { loads.calls.count > 3 }
            XCTAssertEqual(loads.calls.count, 3, "The section appearing joined the scan the window started")

            // After that scan finished, appearing again scans again and decodes only what is new.
            let added = try makeSession(in: f.vault, status: .completed)
            await model.sectionDidAppear().value
            XCTAssertTrue(model.library.entries.contains { $0.id == added })
            XCTAssertEqual(loads.calls.count, 4)
            model.setWindowVisible(false)
        }
    }

    @MainActor
    func testTheMessageLineBelongsToItsRowAndSupersededExportChecksDoNothing() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            navigation.section = .recordings
            let recorder = CallRecorder()
            let failure = "Claude Code is not installed. Install the claude command, sign in, then try again."
            let model = makeRecordingsModel(f, navigation: navigation, recorder: recorder, handoffFailure: { failure })
            await model.refresh().value
            navigation.selectedSessionId = f.completed
            func exportCalls() -> [String] { recorder.calls.filter { !$0.hasPrefix("claude ") } }

            // A line stays with its row and section.
            XCTAssertTrue(model.perform(.openInClaude, on: f.completed))
            XCTAssertEqual(model.message, failure)
            navigation.selectedSessionId = f.completed
            XCTAssertEqual(model.message, failure, "Selecting the same row keeps it")
            navigation.selectedSessionId = f.unfinished
            XCTAssertNil(model.message, "Another row does not inherit the line")
            XCTAssertTrue(model.perform(.openInClaude, on: f.completed))
            XCTAssertEqual(model.message, failure)
            navigation.section = .overview
            XCTAssertNil(model.message, "Leaving the section clears it")
            navigation.section = .recordings

            // A newer action supersedes an export/ check still running, so an older path never reaches the pasteboard.
            XCTAssertTrue(model.perform(.copyExportPath, on: f.completed))
            let copy = try XCTUnwrap(model.actionTask)
            XCTAssertTrue(model.perform(.revealExport, on: f.completed))
            let reveal = try XCTUnwrap(model.actionTask)
            await copy.value
            await reveal.value
            XCTAssertEqual(exportCalls(), ["revealExport \(f.completed)"])

            // export/ gone: a check that finishes after a newer action, or after the selection changed, shows no line.
            let completed = f.vault.sessionURL(id: f.completed)
            try FileManager.default.moveItem(
                at: completed.appendingPathComponent(ScrumTracePath.export),
                to: completed.appendingPathComponent("export-moved")
            )
            XCTAssertTrue(model.perform(.revealExport, on: f.completed))
            let missing = try XCTUnwrap(model.actionTask)
            XCTAssertTrue(model.perform(.openInClaude, on: f.completed))
            await missing.value
            XCTAssertEqual(model.message, failure, "The older check does not overwrite the newer line")
            XCTAssertTrue(model.perform(.copyExportPath, on: f.completed))
            let hidden = try XCTUnwrap(model.actionTask)
            navigation.selectedSessionId = f.corrupt
            await hidden.value
            XCTAssertNil(model.message, "A line for the previous row does not appear under the new one")
            XCTAssertTrue(model.perform(.copyExportPath, on: f.completed))
            await model.actionTask?.value
            XCTAssertEqual(
                model.message, "The export folder is missing or contains a link, so its path was not copied.",
                "A check nothing interrupted still says why"
            )
            XCTAssertEqual(exportCalls(), ["revealExport \(f.completed)"])
        }
    }

    @MainActor
    func testSpeakerReviewOpensOnTheRequestedSessionAndKeepsItsDefaultOtherwise() {
        func manifest(_ id: String) -> SessionManifest {
            SessionManifest.makeNew(sessionId: id, product: .empty)
        }
        let newest = manifest("2026-09-14-1200-aaa001")
        let last = manifest("2026-09-13-1200-bbb002")
        let older = manifest("2026-01-01-1200-ccc003")
        let recent = [newest, last]
        var loaded: [String] = []
        let load: (String) -> SessionManifest? = { id in
            loaded.append(id)
            return id == older.sessionId ? older : nil
        }
        func ids(_ sessions: [SessionManifest]) -> [String] { sessions.map(\.sessionId) }

        var picker = SpeakerReviewView.pickerSessions(recent: recent, initialSessionId: nil, lastSessionId: last.sessionId, loadManifest: load)
        XCTAssertEqual(ids(picker.sessions), ids(recent))
        XCTAssertEqual(picker.selected, last.sessionId, "Without a request the last session stays the default")
        picker = SpeakerReviewView.pickerSessions(recent: recent, initialSessionId: nil, lastSessionId: nil, loadManifest: load)
        XCTAssertEqual(picker.selected, newest.sessionId, "Else the newest")
        picker = SpeakerReviewView.pickerSessions(recent: [], initialSessionId: nil, lastSessionId: nil, loadManifest: load)
        XCTAssertEqual(picker.selected, "")
        XCTAssertEqual(loaded, [], "Nothing more is read without a request")

        picker = SpeakerReviewView.pickerSessions(recent: recent, initialSessionId: newest.sessionId, lastSessionId: last.sessionId, loadManifest: load)
        XCTAssertEqual(ids(picker.sessions), ids(recent))
        XCTAssertEqual(picker.selected, newest.sessionId, "The requested session wins over the last one")
        XCTAssertEqual(loaded, [], "A listed session is not read again")

        picker = SpeakerReviewView.pickerSessions(recent: recent, initialSessionId: older.sessionId, lastSessionId: last.sessionId, loadManifest: load)
        XCTAssertEqual(ids(picker.sessions), ids(recent) + [older.sessionId], "An older requested session joins the list")
        XCTAssertEqual(picker.selected, older.sessionId)
        XCTAssertEqual(loaded, [older.sessionId])

        picker = SpeakerReviewView.pickerSessions(
            recent: recent, initialSessionId: "2026-02-02-1200-ddd004", lastSessionId: last.sessionId, loadManifest: load
        )
        XCTAssertEqual(ids(picker.sessions), ids(recent))
        XCTAssertEqual(picker.selected, last.sessionId, "A request that cannot be read falls back to the default")
    }

    @MainActor
    func testRecordingsEmptyStateStartWaitsLikeOverviewAndFollowsTheContextWindow() async throws {
        try await withRecordingsFixture { f in
            let recorder = CallRecorder()
            let canChange = MainActorBox(true)
            let preparing = MainActorBox(false)
            let model = makeRecordingsModel(
                f,
                recorder: recorder,
                canChange: { canChange.value },
                isPreparingRecording: { preparing.value },
                startStateInterval: .milliseconds(60),
                preparingInterval: .milliseconds(20),
                // The menu's flow opens the recording-context window.
                onStartRecording: { preparing.value = true }
            )
            XCTAssertTrue(model.canStartRecording)
            XCTAssertNil(model.startUnavailableReason)
            XCTAssertFalse(model.isPreparingFollowActive, "A window never shown follows nothing")

            // Recording or analysis running: disabled with the reason Overview gives.
            canChange.value = false
            model.syncCaptureState()
            XCTAssertFalse(model.canStartRecording)
            XCTAssertEqual(model.startUnavailableReason, RecordingsModel.busyReason)
            XCTAssertEqual(
                model.startUnavailableReason,
                OverviewModel.startUnavailableReason(canChangeSessions: false, isPreparingRecording: false)
            )
            canChange.value = true
            model.syncCaptureState()
            XCTAssertTrue(model.canStartRecording)

            // A visible window reads the capture state at Overview's slower pace.
            model.setWindowVisible(true)
            XCTAssertTrue(model.isPreparingFollowActive)
            XCTAssertEqual(model.preparingFollowInterval, .milliseconds(60))

            // A Start from the status-bar menu or ⌘N opens the context window without publishing anything on the
            // controller or calling this model. The button follows it within the interval, then at the faster pace.
            preparing.value = true
            let followedMenuStart = await waitUntil(timeout: 2) { !model.canStartRecording }
            XCTAssertTrue(followedMenuStart, "A context window opened from the menu or ⌘N disables the empty state's Start")
            XCTAssertEqual(model.startUnavailableReason, OverviewModel.preparingReason)
            XCTAssertEqual(model.preparingFollowInterval, .milliseconds(20), "Faster while the context window shows")
            model.startRecording()
            XCTAssertEqual(recorder.calls, [], "The Start flow would refuse a click while that window shows")
            preparing.value = false
            let followedMenuCancel = await waitUntil(timeout: 2) { model.canStartRecording }
            XCTAssertTrue(followedMenuCancel, "Cancelling that window enables the button again")
            XCTAssertEqual(model.preparingFollowInterval, .milliseconds(60))

            // The Start this button runs opens the context window: the button waits at once, with Overview's reason.
            model.startRecording()
            XCTAssertEqual(recorder.calls, ["startRecording"])
            XCTAssertTrue(model.isPreparingRecording, "Disabled at once, not after the next check")
            XCTAssertFalse(model.canStartRecording)
            XCTAssertEqual(model.startUnavailableReason, OverviewModel.preparingReason)
            XCTAssertEqual(model.preparingFollowInterval, .milliseconds(20))
            model.startRecording()
            XCTAssertEqual(recorder.calls, ["startRecording"], "A second Start waits for the context window")

            // Cancelling the context window changes nothing the controller publishes. The button comes back anyway.
            preparing.value = false
            let enabled = await waitUntil(timeout: 2) { model.canStartRecording }
            XCTAssertTrue(enabled, "The empty state's Start follows the context window closing")
            XCTAssertNil(model.startUnavailableReason)
            XCTAssertEqual(model.preparingFollowInterval, .milliseconds(60), "Back to the slower pace once the context window closed")

            // A hidden window follows nothing. Shown again, it reads the context window at once.
            model.setWindowVisible(false)
            XCTAssertFalse(model.isPreparingFollowActive, "A hidden window does no periodic work")
            XCTAssertNil(model.preparingFollowInterval)
            preparing.value = true
            model.syncCaptureState()
            XCTAssertFalse(model.canStartRecording)
            XCTAssertFalse(model.isPreparingFollowActive, "A hidden window does no periodic work")
            preparing.value = false
            model.setWindowVisible(true)
            XCTAssertTrue(model.canStartRecording, "Shown again, the button is enabled at once")
            XCTAssertEqual(model.preparingFollowInterval, .milliseconds(60))
            model.setWindowVisible(false)
            XCTAssertFalse(model.isPreparingFollowActive)
            XCTAssertEqual(try mainEventRows(in: f).compactMap { $0["event"] }, ["main_start"])
        }
    }

    @MainActor
    func testTheStatusColumnFitsEveryStatusAtTheDefaultWindowSize() async throws {
        try await withRecordingsFixture { f in
            let offline = try makeSession(in: f.vault, status: .offlineFailed)
            try await withFixtureController(f) { controller in
                let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
                defer { presenter.window?.close() }
                presenter.show(section: .recordings)
                let window = try XCTUnwrap(presenter.window)
                window.setContentSize(NSSize(width: 960, height: 640))
                let listed = await waitUntil { self.recordingsTable(in: window)?.numberOfRows == 4 }
                XCTAssertTrue(listed)
                XCTAssertTrue(presenter.recordings.library.entries.contains { $0.id == offline })
                spinRunLoop(for: 0.3)
                let table = try XCTUnwrap(recordingsTable(in: window))
                let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                func textWidth(_ text: String) -> CGFloat {
                    ceil((text as NSString).size(withAttributes: [.font: font]).width)
                }
                let statuses: [PipelineStatus] = [
                    .idle, .recording, .paused, .transcribing, .slicing, .evaluating, .synthesizing, .completed, .offlineFailed
                ]
                // Every status but the offline one may carry the needs-review marker: 4 pt of spacing and the symbol.
                let marker: CGFloat = 4 + 16
                let loaded = statuses.map { textWidth(PipelineStatusOrder.label($0)) + ($0 == .offlineFailed ? 0 : marker) }
                let unreadable = [SessionEntry.decodingFailed, SessionEntry.notReadable, SessionEntry.sessionIdMismatch]
                    .map { textWidth(RecordingRowText.unreadableStatus($0)) }
                let widest = (loaded + unreadable).max() ?? 0
                XCTAssertEqual(widest, textWidth(PipelineStatusOrder.label(.offlineFailed)), "Offline — needs review is the widest")
                // The column as drawn, intercell spacing included, less the cell's inset on each side.
                let column = table.rect(ofColumn: 3).width
                XCTAssertGreaterThanOrEqual(
                    column - 18, widest,
                    "The Status column is \(column) pt for \(widest) pt of text. Columns: \(table.tableColumns.map(\.width))"
                )
            }
        }
    }

    @MainActor
    func testTheDateAndContextColumnsFitAtTheDefaultWindowSize() async throws {
        try await withRecordingsFixture { f in
            _ = try makeSession(in: f.vault, status: .offlineFailed)
            try await withFixtureController(f) { controller in
                let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
                defer { presenter.window?.close() }
                presenter.show(section: .recordings)
                let window = try XCTUnwrap(presenter.window)
                window.setContentSize(NSSize(width: 960, height: 640))
                let listed = await waitUntil { self.recordingsTable(in: window)?.numberOfRows == 4 }
                XCTAssertTrue(listed)
                spinRunLoop(for: 0.3)
                let table = try XCTUnwrap(recordingsTable(in: window))
                let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                func textWidth(_ text: String) -> CGFloat {
                    ceil((text as NSString).size(withAttributes: [.font: digits]).width)
                }
                // The unreadable row's label as SwiftUI lays it out: its symbol, the label spacing and the text.
                let label = NSHostingView(rootView: Label {
                    Text("Unreadable manifest")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                })
                let needed: [(column: Int, name: String, width: CGFloat)] = [
                    // The widest English 24-hour date and time.
                    (0, "Date", textWidth("May 30, 2026 at 23:59")),
                    (1, "Context", ceil(label.fittingSize.width)),
                    (2, "Duration", textWidth("1:23:04")),
                    (4, "Shots", textWidth("999")),
                    (5, "Tasks", textWidth("99 / 99")),
                    (6, "Export", textWidth(RecordingRowText.bytes(MediaBudget.maxZipBytes)))
                ]
                let columns = table.tableColumns.map(\.width)
                for item in needed {
                    // The column as drawn, intercell spacing included, less the cell's inset on each side.
                    let available = table.rect(ofColumn: item.column).width - 18
                    XCTAssertGreaterThanOrEqual(
                        available, item.width,
                        "\(item.name) has \(available) pt for \(item.width) pt of text. Columns: \(columns)"
                    )
                }
            }
        }
    }

    @MainActor
    func testUnreadableRowsShowPlainWordsForTheirReason() {
        let cases: [(reason: String, status: String, explanation: String)] = [
            (SessionEntry.decodingFailed, "Damaged", "Its contents are damaged."),
            (SessionEntry.notReadable, "Could not be read", "It is missing or could not be opened."),
            (SessionEntry.sessionIdMismatch, "Folder name mismatch", "It names a different recording than its folder.")
        ]
        for item in cases {
            XCTAssertEqual(RecordingRowText.unreadableStatus(item.reason), item.status, item.reason)
            XCTAssertEqual(RecordingRowText.unreadableExplanation(item.reason), item.explanation, item.reason)
        }
        // A phrase the index does not produce is never shown either.
        XCTAssertEqual(RecordingRowText.unreadableStatus("errno 13"), "Could not be read")
        XCTAssertEqual(RecordingRowText.unreadableExplanation("errno 13"), "It could not be read.")
        for reason in cases.map({ $0.reason }) + ["errno 13"] {
            let status = RecordingRowText.unreadableStatus(reason)
            XCTAssertFalse(status.localizedCaseInsensitiveContains(reason), "\(reason) stays out of the Status column")
            XCTAssertFalse(RecordingRowText.unreadableExplanation(reason).localizedCaseInsensitiveContains(reason), reason)
            XCTAssertEqual(String(status.prefix(1)), status.prefix(1).uppercased(), "Sentence case, like the other statuses")
        }
    }

    @MainActor
    func testDeleteConfirmationNamesTheRowItCameFromByDateAndContext() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let model = makeRecordingsModel(f, navigation: navigation, recorder: recorder)
            await model.refresh().value
            let completed = try XCTUnwrap(model.entry(id: f.completed))
            let unfinished = try XCTUnwrap(model.entry(id: f.unfinished))
            let corrupt = try XCTUnwrap(model.entry(id: f.corrupt))

            XCTAssertEqual(
                RecordingRowText.deleteTitle(completed),
                "Delete “\(RecordingRowText.date(completed)) · Orbit web / Orbit Checkout”?"
            )
            XCTAssertEqual(RecordingRowText.deleteTitle(unfinished), "Delete “\(RecordingRowText.date(unfinished)) · No context”?")
            XCTAssertNotEqual(RecordingRowText.date(corrupt), "—", "An unreadable row is dated by its folder name")
            XCTAssertEqual(RecordingRowText.deleteTitle(corrupt), "Delete “\(RecordingRowText.date(corrupt)) · Unreadable manifest”?")
            XCTAssertEqual(RecordingRowText.deleteTitle(nil), "Delete this recording?", "A row no longer listed")
            for entry in [completed, unfinished, corrupt] {
                XCTAssertFalse(RecordingRowText.deleteTitle(entry).contains(entry.id), "The title names the row as the table does")
                XCTAssertEqual(
                    RecordingRowText.deleteMessage(entry.id),
                    "Recording \(entry.id) will be removed, including archive/ with the full recording and transcript, and export/ with the brief and session pack. This cannot be undone."
                )
            }

            // Delete… from the context menu of a row that is not selected asks about that row and deletes only it.
            navigation.selectedSessionId = f.completed
            XCTAssertTrue(model.perform(.delete, on: f.unfinished))
            let asked = try XCTUnwrap(model.pendingDelete)
            XCTAssertEqual(asked, f.unfinished)
            XCTAssertEqual(RecordingRowText.deleteTitle(model.entry(id: asked)), RecordingRowText.deleteTitle(unfinished))
            let deletion = try XCTUnwrap(model.confirmDelete(asked))
            await deletion.value
            XCTAssertEqual(recorder.calls, ["deleteSession \(f.unfinished)"])
            XCTAssertEqual(navigation.selectedSessionId, f.completed, "The selection is left alone")
            XCTAssertEqual(model.library.entries.map(\.id), [f.completed, f.corrupt])
        }
    }

    @MainActor
    func testStageProgressAndRowTextComeFromTheSummary() {
        func summary(_ status: PipelineStatus, _ done: [PipelineStatus], context: String? = nil, product: String = "") -> SessionSummary {
            var manifest = SessionManifest.makeNew(
                sessionId: "2026-09-13-1200-abc123",
                product: ProductContext(appName: product, repoURL: "", techStack: "", contextID: context.map { _ in "ctx" }, contextName: context)
            )
            manifest.pipelineStatus = status
            manifest.completedStages = done
            return SessionSummary(manifest: manifest, exportProbe: SessionExportProbe())
        }
        func states(_ summary: SessionSummary) -> [SessionStageStep.State] {
            SessionStageStep.steps(for: summary).map(\.state)
        }
        XCTAssertEqual(SessionStageStep.steps(for: summary(.completed, [])).map(\.stage), PipelineStatusOrder.processingFlow)
        XCTAssertEqual(states(summary(.completed, [])), [.done, .done, .done, .done, .done])
        XCTAssertEqual(states(summary(.transcribing, [])), [.current, .pending, .pending, .pending, .pending])
        XCTAssertEqual(states(summary(.evaluating, [.transcribing, .slicing])), [.done, .done, .current, .pending, .pending])
        XCTAssertEqual(
            states(summary(.offlineFailed, [.transcribing, .slicing])), [.done, .done, .failed, .pending, .pending],
            "An offline failure is its own state, never shown as in progress"
        )
        XCTAssertEqual(states(summary(.recording, [])), [.pending, .pending, .pending, .pending, .pending])

        XCTAssertEqual(RecordingRowText.contextAndProduct(summary(.completed, [], context: "Orbit web", product: "Orbit Checkout")), "Orbit web / Orbit Checkout")
        XCTAssertEqual(RecordingRowText.contextAndProduct(summary(.completed, [], context: "Orbit web")), "Orbit web")
        XCTAssertEqual(RecordingRowText.contextAndProduct(summary(.completed, [])), "No context")
        let unreadable = SessionEntry.unreadable(id: "2020-01-01-0000-bad001", reason: SessionEntry.decodingFailed)
        XCTAssertEqual(RecordingRowText.export(unreadable), "—")
        XCTAssertEqual(RecordingRowText.duration(unreadable), "—")
        XCTAssertEqual(RecordingRowText.tasks(.loaded(summary(.completed, []))), "0 / 0")
        XCTAssertEqual(RecordingRowText.export(.loaded(summary(.completed, []))), "—", "No pack yet")
        XCTAssertFalse(RecordingRowText.needsReviewMarker(summary(.offlineFailed, [])), "The status already says it needs review")
    }

    // MARK: - Overview

    /// An Overview model whose every outside effect is a recorded closure reading `state`. Any update check,
    /// through the model or `UpdateChecker.check()` directly, is recorded as "updateCheck" until teardown.
    @MainActor
    private func makeOverviewModel(
        recordings: RecordingsModel,
        state: OverviewState,
        recorder: CallRecorder,
        preload: @escaping @Sendable (String) async throws -> Void = { _ in },
        evaluationInterval: Duration = OverviewModel.evaluationInterval,
        preparingInterval: Duration = OverviewModel.preparingInterval
    ) -> OverviewModel {
        UpdateChecker.setRequestForTesting {
            recorder.record("updateCheck")
            return .upToDate(current: "1.0.0")
        }
        addTeardownBlock { await UpdateChecker.setRequestForTesting(nil) }
        let dependencies = OverviewDependencies(
            readinessInputs: {
                state.readinessReads += 1
                return state.inputs
            },
            canChangeSessions: { state.canChange },
            isPreparingRecording: { state.preparing },
            isRecordingActive: { state.recordingActive },
            lastError: { state.lastError },
            retentionDays: { state.retentionDays },
            captureAreaSummary: { state.captureArea },
            sessionsFolder: { "~/Movies/ScrumTrace/sessions" },
            updates: OverviewUpdateSource(lastResult: {
                state.updateReads += 1
                return state.update
            }),
            startRecording: { recorder.record("startRecording") },
            askForScreenRecording: { recorder.record("askForScreenRecording") },
            openScreenRecordingSettings: { recorder.record("openScreenRecordingSettings") },
            openMicrophoneSettings: { recorder.record("openMicrophoneSettings") },
            relaunch: { recorder.record("relaunch") },
            preloadSpeechModel: preload,
            revealSessionsFolder: { recorder.record("revealSessionsFolder") },
            openReleasesPage: { recorder.record("openReleasesPage") }
        )
        return OverviewModel(
            recordings: recordings,
            navigation: recordings.navigation,
            dependencies: dependencies,
            evaluationInterval: evaluationInterval,
            preparingInterval: preparingInterval
        )
    }

    /// `main_*` rows so far. `main_readiness` may carry its action and `main_start` its section; every other
    /// `main_*` row the session id only.
    private func overviewEventRows(at log: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: String]] {
        AgentLog.event("overview_test_baseline", [:])
        let rows = try logRows(at: log)
        let baseline = try XCTUnwrap(rows.last { $0["event"] == "overview_test_baseline" }, file: file, line: line)
        let common = Set(baseline.keys)
        let allowed: [String: Set<String>] = ["main_readiness": ["action"], "main_start": ["section"]]
        let main = rows.filter { ($0["event"] ?? "").hasPrefix("main_") }
        for row in main {
            let event = row["event"] ?? ""
            let extra = Set(row.keys).subtracting(common)
            XCTAssertTrue(extra.isSubset(of: allowed[event] ?? ["session"]), "\(event) carries \(extra)", file: file, line: line)
        }
        return main
    }

    /// Scrolls the tallest scroll view to its end, for a snapshot of the lower sections.
    @MainActor
    private func scrollToBottom(in window: NSWindow) {
        guard let content = window.contentView else { return }
        var stack: [NSView] = [content]
        var tallest: NSScrollView?
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (tallest?.documentView?.frame.height ?? 0) {
                tallest = scroll
            }
            stack.append(contentsOf: view.subviews)
        }
        guard let scroll = tallest, let document = scroll.documentView else { return }
        let end = document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @MainActor
    func testOverviewReadinessCoversEachSetupState() throws {
        let ready = OverviewReadiness(inputs: overviewReadinessInputs())
        XCTAssertTrue(ready.allowsStart)
        XCTAssertFalse(ready.requiresRelaunch)
        XCTAssertEqual(ready.headline, "Ready to record")
        XCTAssertEqual(ready.summary, "Start recording asks for the product context, then the capture area.")
        XCTAssertEqual(ready.rows.map(\.item), OverviewReadiness.Item.allCases)
        XCTAssertTrue(ready.rows.allSatisfy { $0.state == .ok && !$0.blocksRecording }, "\(ready.rows)")
        XCTAssertEqual(ready.rows.flatMap(\.actions), [], "Nothing to do when everything is set up")

        // Screen Recording denied: blocked, with the buttons Settings and the Start alert offer.
        let denied = OverviewReadiness(inputs: overviewReadinessInputs(.screenDenied))
        XCTAssertFalse(denied.allowsStart)
        XCTAssertFalse(denied.requiresRelaunch)
        XCTAssertEqual(denied.headline, "Recording is blocked")
        let screen = try XCTUnwrap(denied.row(.screenRecording))
        XCTAssertEqual(screen.state, .actionNeeded)
        XCTAssertEqual(screen.status, "Not allowed")
        XCTAssertEqual(screen.detail, CaptureReadiness.screenDenied.userMessage)
        XCTAssertEqual(screen.actions, [.askScreenRecording, .openScreenRecordingSettings, .relaunch])
        XCTAssertEqual(screen.marker, .blocksRecording)
        XCTAssertEqual(denied.rows.filter(\.blocksRecording).map(\.item), [.screenRecording])
        XCTAssertEqual(
            denied.summary,
            "A recording will not start until Screen Recording is allowed. Nothing else below blocks recording."
        )

        // A first launch: Screen Recording and the microphone denied, the notice not confirmed. The copy names
        // the one blocker, the notice is marked as something to do rather than as a blocker, and only the
        // blocking row offers Relaunch.
        let firstLaunch = OverviewReadiness(inputs: overviewReadinessInputs(.screenDenied, microphoneStatus: "denied", notice: false))
        XCTAssertEqual(firstLaunch.summary, denied.summary)
        XCTAssertEqual(firstLaunch.rows.filter(\.blocksRecording).map(\.item), [.screenRecording])
        XCTAssertEqual(firstLaunch.row(.screenRecording)?.marker, .blocksRecording)
        XCTAssertEqual(firstLaunch.row(.meetingNotice)?.state, .actionNeeded)
        XCTAssertEqual(firstLaunch.row(.meetingNotice)?.marker, .actionNeeded)
        XCTAssertEqual(firstLaunch.row(.microphone)?.marker, .actionNeeded)
        XCTAssertEqual(firstLaunch.row(.microphone)?.actions, [.openMicrophoneSettings, .openCaptureSettings])
        XCTAssertEqual(firstLaunch.rows.filter { $0.actions.contains(.relaunch) }.map(\.item), [.screenRecording])
        XCTAssertEqual(
            OverviewReadiness(inputs: overviewReadinessInputs(.screenGrantedNeedsRelaunch, microphoneStatus: "restricted"))
                .rows.filter { $0.actions.contains(.relaunch) }.map(\.item),
            [.screenRecording]
        )

        // Every button on the card has its own identifier, and Relaunch appears at most once, in every state.
        for capture: CaptureReadiness in [.ready, .screenDenied, .screenGrantedNeedsRelaunch, .microphoneDenied] {
            for enabled in [true, false] {
                for status in ["allowed", "denied", "restricted", "not asked for this process", "not determined"] {
                    let all = OverviewReadiness(inputs: overviewReadinessInputs(
                        capture, microphone: enabled, microphoneStatus: status, accessibility: false,
                        speechReady: false, service: false, key: false, notice: false
                    ))
                    let identifiers = all.rows.flatMap { row in row.actions.map { row.accessibilityIdentifier(for: $0) } }
                    let name = "\(capture) microphone \(enabled) \(status)"
                    XCTAssertEqual(Set(identifiers).count, identifiers.count, "\(name): \(identifiers)")
                    XCTAssertLessThanOrEqual(all.rows.flatMap(\.actions).filter { $0 == .relaunch }.count, 1, name)
                    XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("main.overview.readiness.") }, name)
                }
            }
        }
        XCTAssertEqual(screen.accessibilityIdentifier(for: .relaunch), "main.overview.readiness.screenRecording.relaunch")

        // Granted after launch: a relaunch is required, and the copy says so.
        let relaunch = OverviewReadiness(inputs: overviewReadinessInputs(.screenGrantedNeedsRelaunch))
        XCTAssertFalse(relaunch.allowsStart)
        XCTAssertTrue(relaunch.requiresRelaunch)
        XCTAssertEqual(relaunch.headline, "Relaunch ScrumTrace before recording")
        XCTAssertEqual(
            relaunch.summary,
            "Screen Recording is allowed, but a recording will not start until ScrumTrace relaunches. Nothing else below blocks recording."
        )
        let granted = try XCTUnwrap(relaunch.row(.screenRecording))
        XCTAssertEqual(granted.status, "Relaunch required")
        XCTAssertEqual(granted.detail, CaptureReadiness.screenGrantedNeedsRelaunch.userMessage)
        XCTAssertEqual(granted.actions, [.relaunch])
        XCTAssertTrue(granted.blocksRecording)
        XCTAssertEqual(granted.marker, .blocksRecording)

        // Microphone turned off in Settings: `readiness(requireMicrophone: false)` is ready, and even a denied
        // microphone is not reported as a problem.
        let micOff = OverviewReadiness(inputs: overviewReadinessInputs(.ready, microphone: false, microphoneStatus: "denied"))
        XCTAssertTrue(micOff.allowsStart)
        let off = try XCTUnwrap(micOff.row(.microphone))
        XCTAssertEqual(off.state, .optional)
        XCTAssertEqual(off.status, "Off")
        XCTAssertFalse(off.blocksRecording)
        XCTAssertEqual(off.actions, [.openCaptureSettings])
        XCTAssertFalse(off.detail?.localizedCaseInsensitiveContains("denied") ?? false)
        XCTAssertFalse(micOff.rows.contains { $0.state == .actionNeeded }, "A microphone turned off in Settings is never a problem")

        // Microphone denied while it is recorded: blocked.
        let micDenied = OverviewReadiness(inputs: overviewReadinessInputs(.microphoneDenied, microphoneStatus: "denied"))
        XCTAssertFalse(micDenied.allowsStart)
        XCTAssertEqual(micDenied.headline, "Recording is blocked")
        XCTAssertTrue(micDenied.summary.hasPrefix("A recording will not start until microphone access is allowed"), micDenied.summary)
        XCTAssertEqual(micDenied.row(.screenRecording)?.state, .ok)
        let microphone = try XCTUnwrap(micDenied.row(.microphone))
        XCTAssertEqual(microphone.state, .actionNeeded)
        XCTAssertEqual(microphone.marker, .blocksRecording)
        XCTAssertTrue(microphone.blocksRecording)
        XCTAssertEqual(microphone.detail, CaptureReadiness.microphoneDenied.userMessage)
        // The summary names two fixes: allow the microphone, or turn Record microphone off. The row offers both.
        XCTAssertEqual(microphone.actions, [.openMicrophoneSettings, .openCaptureSettings, .relaunch])
        let notAsked = OverviewReadiness(inputs: overviewReadinessInputs(microphoneStatus: "not asked for this process"))
        XCTAssertTrue(notAsked.allowsStart)
        XCTAssertEqual(notAsked.row(.microphone)?.state, .optional)
        XCTAssertEqual(notAsked.row(.microphone)?.status, "Not asked yet")

        // No AI service: informational, never blocking.
        let noService = OverviewReadiness(inputs: overviewReadinessInputs(service: false, key: false))
        XCTAssertTrue(noService.allowsStart)
        XCTAssertEqual(noService.headline, "Ready to record")
        let ai = try XCTUnwrap(noService.row(.aiService))
        XCTAssertEqual(ai.state, .optional)
        XCTAssertFalse(ai.blocksRecording)
        XCTAssertEqual(ai.status, "No service selected")
        XCTAssertEqual(ai.detail, noService.inputs.aiSummary)
        XCTAssertEqual(ai.actions, [.openAISettings])
        XCTAssertEqual(noService.rows.filter { $0.state != .ok }.map(\.item), [.aiService])
        XCTAssertEqual(OverviewReadiness(inputs: overviewReadinessInputs(key: false)).row(.aiService)?.status, "No saved key")
        XCTAssertEqual(OverviewReadiness(inputs: overviewReadinessInputs(valid: false)).row(.aiService)?.status, "Check settings")

        // Meeting notice not accepted: something to do, but Start recording asks for it, so it does not block.
        let notice = OverviewReadiness(inputs: overviewReadinessInputs(notice: false))
        XCTAssertTrue(notice.allowsStart)
        XCTAssertEqual(notice.headline, "Ready to record")
        XCTAssertEqual(notice.summary, "Start recording first asks you to confirm that you will tell participants.")
        let noticeRow = try XCTUnwrap(notice.row(.meetingNotice))
        XCTAssertEqual(noticeRow.state, .actionNeeded)
        XCTAssertEqual(noticeRow.marker, .actionNeeded, "Marked as something to do, not as a blocker")
        XCTAssertFalse(noticeRow.blocksRecording)
        XCTAssertEqual(noticeRow.actions, [.openGeneralSettings])

        // Optional rows keep their existing buttons.
        let optional = OverviewReadiness(inputs: overviewReadinessInputs(accessibility: false, speechReady: false))
        XCTAssertTrue(optional.allowsStart)
        XCTAssertEqual(optional.row(.accessibility)?.state, .optional)
        XCTAssertEqual(optional.row(.accessibility)?.actions, [.openPermissionsSettings])
        XCTAssertEqual(optional.row(.speechModel)?.status, "Not loaded")
        XCTAssertEqual(optional.row(.speechModel)?.actions, [.preloadSpeechModel])
        let loading = OverviewReadiness(inputs: overviewReadinessInputs(speechReady: false, speechLoading: true))
        XCTAssertEqual(loading.row(.speechModel)?.status, "Loading…")
        XCTAssertEqual(loading.row(.speechModel)?.actions, [])
        XCTAssertEqual(OverviewReadiness(inputs: overviewReadinessInputs(speechModel: " ", speechReady: false)).row(.speechModel)?.actions, [.openSpeechSettings])

        XCTAssertEqual(OverviewReadinessAction.allCases.filter(\.needsIdleCapture), [.askScreenRecording, .relaunch, .preloadSpeechModel])
        XCTAssertEqual(OverviewReadinessAction.openAISettings.settingsTab, .ai)
        XCTAssertEqual(OverviewReadinessAction.openPermissionsSettings.settingsTab, .permissions)
        XCTAssertNil(OverviewReadinessAction.askScreenRecording.settingsTab)
    }

    @MainActor
    func testOverviewStartCardNamesRecordingOrAnalysisAndWaitsForReadiness() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let state = OverviewState()
            state.inputs = overviewReadinessInputs(.screenDenied, speechReady: false)
            let recordings = makeRecordingsModel(f, navigation: navigation, recorder: recorder, canChange: { state.canChange })
            let overview = makeOverviewModel(recordings: recordings, state: state, recorder: recorder)

            // Before readiness is read, the card is checking and Start follows the Start flow alone.
            XCTAssertEqual(overview.startCard.icon, .checking)
            XCTAssertEqual(overview.startCard.headline, OverviewStartCard.checkingHeadline)
            XCTAssertTrue(overview.isStartButtonEnabled)
            XCTAssertNil(overview.startUnavailableReason)

            // Screen Recording denied: the card says recording is blocked, and Start waits with the blocking reason as its
            // help tag instead of opening the flow's alert. The row keeps the buttons that fix it.
            overview.evaluate()
            let blocked = try XCTUnwrap(overview.readiness)
            XCTAssertEqual(overview.startCard.icon, .blocked)
            XCTAssertEqual(overview.startCard.headline, "Recording is blocked")
            XCTAssertEqual(overview.startCard.lines, [blocked.summary])
            XCTAssertTrue(overview.canStartRecording, "The Start flow itself is free")
            XCTAssertFalse(overview.isStartButtonEnabled, "Start waits while readiness blocks recording")
            XCTAssertEqual(overview.startUnavailableReason, blocked.startBlockedReason)
            XCTAssertTrue(overview.startUnavailableReason?.contains("Screen Recording row") == true, overview.startUnavailableReason ?? "")
            XCTAssertTrue(overview.isEnabled(.askScreenRecording), "The blocking row still offers its fix")
            let reasons = [CaptureReadiness.screenDenied, .screenGrantedNeedsRelaunch, .microphoneDenied].compactMap {
                OverviewReadiness(inputs: overviewReadinessInputs($0, microphoneStatus: "denied")).startBlockedReason
            }
            XCTAssertEqual(Set(reasons).count, 3, "Each blocking state says what to do")
            XCTAssertNil(OverviewReadiness(inputs: overviewReadinessInputs(service: false, key: false, notice: false)).startBlockedReason,
                         "Rows that only ask for something never block Start")

            state.inputs = overviewReadinessInputs(speechReady: false)
            overview.evaluate()
            XCTAssertEqual(overview.startCard.icon, .ready)
            XCTAssertEqual(overview.startCard.headline, "Ready to record")
            XCTAssertTrue(overview.isStartButtonEnabled)
            XCTAssertNil(overview.startUnavailableReason)

            // A recording runs: the card names it with a neutral icon and one line about why Start waits, never
            // "Ready to record". Row buttons that wait for it say why; System Settings buttons do not wait.
            state.inputs = overviewReadinessInputs(.screenDenied, speechReady: false)
            overview.evaluate()
            state.canChange = false
            state.recordingActive = true
            overview.syncStartState()
            XCTAssertEqual(overview.startCard.icon, .recording)
            XCTAssertEqual(overview.startCard.headline, OverviewStartCard.recordingHeadline)
            XCTAssertEqual(overview.startCard.lines, [RecordingsModel.busyReason])
            XCTAssertFalse(overview.isStartButtonEnabled)
            XCTAssertEqual(overview.startUnavailableReason, RecordingsModel.busyReason, "Recording is the reason, not readiness")
            for action: OverviewReadinessAction in [.askScreenRecording, .relaunch, .preloadSpeechModel] {
                XCTAssertFalse(overview.isEnabled(action), "\(action)")
                XCTAssertEqual(overview.unavailableReason(action), RecordingsModel.busyReason, "\(action)")
            }
            XCTAssertTrue(overview.isEnabled(.openScreenRecordingSettings))
            XCTAssertNil(overview.unavailableReason(.openScreenRecordingSettings))
            state.inputs = overviewReadinessInputs()
            overview.evaluate()
            XCTAssertNotEqual(overview.startCard.headline, "Ready to record", "Readiness that allows a start is not shown while recording")
            XCTAssertEqual(overview.startCard.icon, .recording)

            // Analysis of that recording.
            state.recordingActive = false
            overview.syncStartState()
            XCTAssertEqual(overview.startCard.icon, .analysis)
            XCTAssertEqual(overview.startCard.headline, OverviewStartCard.analysisHeadline)
            XCTAssertEqual(overview.startCard.lines, [RecordingsModel.busyReason])

            // Idle again while a Start shows its context window: readiness is back, with the line about that window.
            state.canChange = true
            state.preparing = true
            overview.syncStartState()
            XCTAssertEqual(overview.startCard.headline, "Ready to record")
            XCTAssertEqual(overview.startCard.lines, [try XCTUnwrap(overview.readiness).summary, OverviewModel.preparingReason])
            XCTAssertFalse(overview.isStartButtonEnabled)
            XCTAssertEqual(overview.startUnavailableReason, OverviewModel.preparingReason)
            XCTAssertEqual(recorder.calls, [])
        }
    }

    @MainActor
    func testInterruptedRecordingsReadAsInterruptedNotAsUnfinishedAnalysis() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let state = OverviewState()
            let recordings = makeRecordingsModel(
                f,
                navigation: navigation,
                recorder: recorder,
                canChange: { state.canChange },
                activeSessionId: { state.activeSessionId }
            )
            let overview = makeOverviewModel(recordings: recordings, state: state, recorder: recorder)
            let paused = try makeSession(in: f.vault, status: .paused)
            let recording = try makeSession(in: f.vault, status: .recording)
            let offline = try makeSession(in: f.vault, status: .offlineFailed)
            await recordings.refresh().value
            @MainActor func summary(_ id: String) throws -> SessionSummary {
                let found = recordings.library.entries.first { $0.id == id }?.summary
                return try XCTUnwrap(found, id)
            }

            // ScrumTrace stopped during these recordings. Overview says the recording was interrupted, and Retry analysis
            // stays the way to process what was captured.
            for id in [paused, recording] {
                let item = try summary(id)
                XCTAssertTrue(recordings.isInterrupted(item), id)
                XCTAssertEqual(RecordingRowText.unfinishedNote(item), "Recording was interrupted. Retry analysis processes what was captured.", id)
                XCTAssertTrue(overview.attention.unfinished.contains { $0.sessionId == id }, id)
                XCTAssertTrue(recordings.isEnabled(.retryAnalysis, for: .loaded(item)), id)
            }
            // Analysis that did not finish keeps its own sentence and is never shown as interrupted.
            for id in [f.unfinished, offline] {
                let item = try summary(id)
                XCTAssertFalse(recordings.isInterrupted(item), id)
                XCTAssertEqual(RecordingRowText.unfinishedNote(item), "Analysis did not finish.", id)
            }
            XCTAssertFalse(recordings.isInterrupted(try summary(f.completed)))

            // The recording a live capture holds is at the same manifest states and is not interrupted.
            state.canChange = false
            state.activeSessionId = recording.uppercased()
            recordings.syncCaptureState()
            XCTAssertFalse(recordings.isInterrupted(try summary(recording)), "The live recording")
            XCTAssertTrue(recordings.isInterrupted(try summary(paused)), "An older interrupted recording stays interrupted")

            // A start in flight, before the controller names its new session (nothing held yet, or still the last
            // session it recorded). The new manifest is idle until capture runs, so it never reads as interrupted, and
            // the recordings ScrumTrace stopped during still do.
            let starting = try makeSession(in: f.vault, status: .idle)
            await recordings.refresh().value
            for held: String? in [nil, f.completed] {
                state.canChange = false
                state.activeSessionId = held
                recordings.syncCaptureState()
                let label = held ?? "nothing held"
                XCTAssertFalse(recordings.isInterrupted(try summary(starting)), "The session a start just created, \(label)")
                XCTAssertTrue(recordings.isInterrupted(try summary(paused)), "Interrupted while paused, \(label)")
                XCTAssertTrue(recordings.isInterrupted(try summary(recording)), "Interrupted while recording, \(label)")
            }
            XCTAssertEqual(recorder.calls, [])
        }
    }

    @MainActor
    func testSettingsKeepsItsSidesAndFooterBesideTheWidestSidebarAtTheMinimumSize() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            presenter.show(tab: .speech)
            let window = try XCTUnwrap(presenter.window)
            // The live banner takes height from the section.
            controller.phase = .recording

            // Roomy: Settings stretches, so its tab view sits at its own padding from the sidebar, the trailing edge and
            // the bottom edge, with the footer below it.
            window.setContentSize(NSSize(width: 1_200, height: 900))
            XCTAssertTrue(spinRunLoop(until: { self.settingsInsets(in: window) != nil }))
            let split = try XCTUnwrap(sidebarSplitView(in: window))
            let ideal = try XCTUnwrap(split.arrangedSubviews.first).frame.width
            split.setPosition(1_000, ofDividerAt: 0)
            spinRunLoop(for: 0.4)
            let widest = try XCTUnwrap(split.arrangedSubviews.first).frame.width
            XCTAssertGreaterThan(widest, ideal, "The sidebar was dragged wider than its ideal width")
            // macOS 26 draws the sidebar 8 pt wider than its column.
            XCTAssertLessThanOrEqual(widest, MainWindowView.sidebarMaximumWidth + 8, "The sidebar stops at its maximum width")
            let roomy = try XCTUnwrap(settingsInsets(in: window))

            // The minimum size, recording, with the sidebar dragged as wide as it goes: Settings may lose part of its
            // 16 pt padding, never its sides or its footer.
            window.setContentSize(MainWindowPresenter.minimumContentSize)
            spinRunLoop(for: 0.3)
            split.setPosition(1_000, ofDividerAt: 0)
            spinRunLoop(for: 0.4)
            XCTAssertEqual(try XCTUnwrap(split.arrangedSubviews.first).frame.width, widest, accuracy: 0.5)
            let tight = try XCTUnwrap(settingsInsets(in: window))
            let padding: CGFloat = 16
            XCTAssertGreaterThanOrEqual(tight.leading, roomy.leading - padding - 0.5, "Leading side clipped: \(tight), roomy \(roomy)")
            XCTAssertGreaterThanOrEqual(tight.trailing, roomy.trailing - padding - 0.5, "Trailing side clipped: \(tight), roomy \(roomy)")
            XCTAssertGreaterThanOrEqual(tight.bottom, roomy.bottom - padding - 0.5, "Footer clipped: \(tight), roomy \(roomy)")
            writeSnapshot(of: window, named: "settings-minimum-widest-sidebar")
        }
    }

    @MainActor
    func testOverviewListsUnfinishedRecordingsWithRetryAndNotCompletedOnes() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let state = OverviewState()
            let recordings = makeRecordingsModel(
                f,
                navigation: navigation,
                recorder: recorder,
                canChange: { state.canChange },
                activeSessionId: { state.activeSessionId }
            )
            let overview = makeOverviewModel(recordings: recordings, state: state, recorder: recorder)
            let offline = try makeSession(in: f.vault, status: .offlineFailed)
            await recordings.refresh().value
            overview.evaluate()

            var attention = overview.attention
            XCTAssertEqual(attention.unfinished.map(\.sessionId), [offline, f.unfinished], "Newest first")
            XCTAssertFalse(attention.unfinished.contains { $0.sessionId == f.completed }, "A completed recording needs no attention")
            XCTAssertEqual(attention.unreadableIds, [f.corrupt])
            XCTAssertNil(attention.lastError)
            XCTAssertNil(attention.retentionDays)
            XCTAssertNil(attention.availableUpdate)
            XCTAssertEqual(overview.lastRecording?.sessionId, offline, "The newest recording whose manifest was read")
            for summary in attention.unfinished {
                XCTAssertTrue(recordings.isEnabled(.retryAnalysis, for: .loaded(summary)), summary.sessionId)
            }
            XCTAssertTrue(overview.retryAnalysis(f.unfinished))
            XCTAssertEqual(recorder.calls, ["retryAnalysis \(f.unfinished)"])

            // While a recording or analysis runs, the session it holds is in progress, not stuck, and Retry waits.
            state.canChange = false
            state.activeSessionId = offline.uppercased()
            overview.syncStartState()
            recordings.syncCaptureState()
            attention = overview.attention
            XCTAssertEqual(attention.unfinished.map(\.sessionId), [f.unfinished])
            XCTAssertFalse(overview.retryAnalysis(f.unfinished))
            XCTAssertEqual(recorder.calls.count, 1)
            state.canChange = true
            overview.syncStartState()
            recordings.syncCaptureState()
            XCTAssertEqual(overview.attention.unfinished.map(\.sessionId), [offline, f.unfinished], "Once idle it is listed again")

            // The last error, retention and an update found by a check that already ran.
            state.lastError = "Could not encode the Shot PNG."
            state.retentionDays = 30
            state.update = .upToDate(current: "1.0.0")
            overview.evaluate()
            attention = overview.attention
            XCTAssertEqual(attention.lastError, "Could not encode the Shot PNG.")
            XCTAssertEqual(attention.retentionDays, 30)
            XCTAssertNil(attention.availableUpdate, "A check that found nothing new needs no attention")
            XCTAssertTrue(OverviewAttention.retentionLine(days: 30).hasPrefix("Completed recordings older than 30 days are deleted"))
            overview.dismissLastError()
            XCTAssertNil(overview.attention.lastError)
            XCTAssertEqual(overview.lastError, "Could not encode the Shot PNG.", "Dismissing leaves the controller's error alone")
            state.lastError = "Capture ended: the stream stopped."
            overview.syncControllerState()
            XCTAssertEqual(overview.attention.lastError, "Capture ended: the stream stopped.", "A different error shows again")
            // The same text after the controller cleared it, as when the next recording fails the same way.
            overview.dismissLastError()
            XCTAssertNil(overview.attention.lastError)
            state.lastError = nil
            overview.syncControllerState()
            XCTAssertNil(overview.attention.lastError)
            state.lastError = "Capture ended: the stream stopped."
            overview.syncControllerState()
            XCTAssertEqual(overview.attention.lastError, "Capture ended: the stream stopped.", "A dismissed error that happens again shows again")
            state.update = .newerAvailable(current: "1.0.0", latest: "1.2.0")
            state.retentionDays = 0
            overview.evaluate()
            XCTAssertEqual(overview.attention.availableUpdate, .newerAvailable(current: "1.0.0", latest: "1.2.0"))
            XCTAssertNil(overview.attention.retentionDays, "Keeping recordings forever deletes nothing")
            XCTAssertTrue(OverviewAttention.make(entries: [], heldSessionId: nil, lastError: "  ", retentionDays: 0, update: nil).isEmpty)

            // Show in Recordings clears a search that hides the row; Show all filters to unfinished recordings.
            recordings.searchText = f.completed
            overview.showInRecordings(f.corrupt)
            XCTAssertEqual(navigation.section, .recordings)
            XCTAssertEqual(navigation.selectedSessionId, f.corrupt)
            XCTAssertEqual(recordings.searchText, "")
            navigation.section = .overview
            recordings.contextFilter = "ctx-orbit"
            overview.showUnfinishedInRecordings()
            XCTAssertEqual(navigation.section, .recordings)
            XCTAssertEqual(recordings.statusFilter, .unfinished)
            XCTAssertNil(recordings.contextFilter)
            XCTAssertEqual(recordings.visibleEntries.map(\.id), [offline, f.unfinished])

            // Storage: the archive total is measured off the main actor once the section appears.
            navigation.section = .overview
            overview.sectionDidAppear()
            XCTAssertFalse(overview.isEvaluationLoopActive, "No readiness loop while the window is not visible")
            await overview.archiveTotalTask?.value
            XCTAssertGreaterThan(recordings.library.totalArchiveBytes ?? 0, 0)
            // Reveal recordings folder… warns first, like Reveal archive… in Recordings.
            overview.requestRevealSessionsFolder()
            XCTAssertTrue(overview.isConfirmingSessionsReveal)
            overview.cancelRevealSessionsFolder()
            XCTAssertFalse(overview.isConfirmingSessionsReveal)
            XCTAssertEqual(recorder.calls, ["retryAnalysis \(f.unfinished)"], "Nothing is revealed before the warning is confirmed")
            overview.requestRevealSessionsFolder()
            overview.confirmRevealSessionsFolder()
            XCTAssertFalse(overview.isConfirmingSessionsReveal)
            overview.openReleasesPage()
            overview.sectionDidDisappear()
            XCTAssertEqual(recorder.calls, ["retryAnalysis \(f.unfinished)", "revealSessionsFolder", "openReleasesPage"])
            XCTAssertEqual(
                try overviewEventRows(at: f.log).compactMap { $0["event"] },
                ["main_retry", "main_reveal_sessions", "main_open_releases"]
            )
            XCTAssertEqual(try mainEventRows(in: f).first?["session"], f.unfinished)
        }
    }

    @MainActor
    func testOverviewStartButtonWaitsForBusyPausedStartInFlightAndTheContextWindow() throws {
        try withController { controller, log in
            let recorder = CallRecorder()
            let state = OverviewState()
            let navigation = MainNavigation()
            defer { controller.setStartInFlightForTesting(false) }
            let recordings = RecordingsModel(
                library: SessionLibrary(vault: controller.vault),
                navigation: navigation,
                dependencies: .live(controller: controller, startRecording: {})
            )
            var dependencies = OverviewDependencies.live(
                controller: controller,
                startRecording: {
                    recorder.record("startRecording")
                    // The menu's flow opens the recording-context window.
                    state.preparing = true
                },
                isPreparingRecording: { state.preparing }
            )
            dependencies.readinessInputs = {
                state.readinessReads += 1
                return state.inputs
            }
            dependencies.updates = OverviewUpdateSource(lastResult: { nil })
            UpdateChecker.setRequestForTesting {
                recorder.record("updateCheck")
                return .upToDate(current: "1.0.0")
            }
            defer { UpdateChecker.setRequestForTesting(nil) }
            let overview = OverviewModel(
                recordings: recordings,
                navigation: navigation,
                dependencies: dependencies,
                evaluationInterval: .seconds(30),
                preparingInterval: .milliseconds(20)
            )
            overview.observe(controller: controller)
            recordings.observe(controller: controller)
            XCTAssertTrue(overview.canStartRecording)
            XCTAssertNil(overview.startUnavailableReason)

            // Each state reaches the models only through their controller observers: nothing here syncs by hand.
            let states: [(name: String, apply: () -> Void)] = [
                ("busy", { controller.isBusy = true; controller.phase = .transcribing }),
                ("recording", { controller.phase = .recording }),
                ("paused", { controller.phase = .paused }),
                ("start in flight", { controller.setStartInFlightForTesting(true) })
            ]
            for state in states {
                state.apply()
                XCTAssertTrue(
                    spinRunLoop(until: { !overview.canStartRecording && !recordings.canChangeSessions }),
                    "\(state.name): the button follows the controller"
                )
                XCTAssertEqual(overview.startUnavailableReason, RecordingsModel.busyReason, state.name)
                // The app's own controller tells a recording, paused or starting, from analysis.
                XCTAssertEqual(
                    overview.startCard.headline,
                    state.name == "busy" ? OverviewStartCard.analysisHeadline : OverviewStartCard.recordingHeadline,
                    state.name
                )
                XCTAssertFalse(overview.startRecording(), state.name)
                controller.setStartInFlightForTesting(false)
                controller.isBusy = false
                controller.phase = .idle
                XCTAssertTrue(
                    spinRunLoop(until: { overview.canStartRecording && recordings.canChangeSessions }),
                    "\(state.name): enabled again when idle"
                )
            }
            XCTAssertEqual(recorder.calls, [], "A disabled Start runs nothing")

            // The Start this button runs opens the context window: the button waits for it, at the faster pace.
            overview.sectionDidAppear()
            overview.setWindowVisible(true)
            XCTAssertTrue(overview.isEvaluationLoopActive)
            let reads = state.readinessReads
            XCTAssertTrue(overview.startRecording())
            XCTAssertEqual(recorder.calls, ["startRecording"])
            XCTAssertTrue(overview.isPreparingRecording, "Disabled at once, not after the next check")
            XCTAssertFalse(overview.canStartRecording)
            XCTAssertEqual(overview.startUnavailableReason, OverviewModel.preparingReason)
            XCTAssertFalse(overview.startRecording(), "A second Start waits for the context window")
            state.preparing = false
            XCTAssertTrue(
                spinRunLoop(until: { overview.canStartRecording }, timeout: 2),
                "The button follows the context window well inside the 30 s readiness interval"
            )
            XCTAssertEqual(state.readinessReads, reads, "Following the context window does not read readiness again")

            overview.setWindowVisible(false)
            XCTAssertFalse(overview.isEvaluationLoopActive, "A hidden window does no readiness work")
            // While the window was covered, Screen Recording changed and a Start from the menu opened its
            // context window. Coming back shows both at once, not after the 30 s interval.
            state.inputs = overviewReadinessInputs(.screenDenied)
            state.preparing = true
            let hiddenReads = state.readinessReads
            overview.setWindowVisible(true)
            XCTAssertEqual(state.readinessReads, hiddenReads + 1, "Readiness is read as soon as the window is visible")
            XCTAssertEqual(overview.readiness?.allowsStart, false)
            XCTAssertFalse(overview.canStartRecording, "Start waits for the context window opened while hidden")
            XCTAssertEqual(overview.startUnavailableReason, OverviewModel.preparingReason)
            XCTAssertTrue(overview.isEvaluationLoopActive)
            state.preparing = false
            state.inputs = overviewReadinessInputs()
            overview.sectionDidDisappear()
            XCTAssertFalse(overview.isEvaluationLoopActive, "Another section does no readiness work")
            overview.setWindowVisible(false)
            let readsWhileElsewhere = state.readinessReads
            overview.setWindowVisible(true)
            XCTAssertEqual(state.readinessReads, readsWhileElsewhere, "Another section reads nothing when the window shows")
            XCTAssertFalse(overview.isEvaluationLoopActive)

            // A dismissed error shows again when the controller clears it and fails the same way, even when both
            // assignments happen before the main queue runs.
            controller.lastError = "Could not capture the display."
            XCTAssertTrue(spinRunLoop(until: { overview.attention.lastError == "Could not capture the display." }))
            overview.dismissLastError()
            XCTAssertNil(overview.attention.lastError)
            controller.lastError = nil
            controller.lastError = "Could not capture the display."
            XCTAssertTrue(
                spinRunLoop(until: { overview.attention.lastError == "Could not capture the display." }),
                "The repeated failure is shown again"
            )
            XCTAssertEqual(recorder.calls, ["startRecording"], "No update check and nothing else ran")
            let starts = try logRows(at: log).filter { $0["event"] == "main_start" }
            XCTAssertEqual(starts.count, 1)
            XCTAssertEqual(starts.first?["section"], MainSection.overview.rawValue)
        }
    }

    @MainActor
    func testOverviewReadinessButtonsDispatchNavigateAndWaitForIdleCapture() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let preloads = CallRecorder()
            let state = OverviewState()
            state.inputs = overviewReadinessInputs(
                .screenDenied, microphoneStatus: "denied", accessibility: false, speechReady: false,
                service: false, key: false, notice: false
            )
            let recordings = makeRecordingsModel(f, navigation: navigation, recorder: recorder)
            let overview = makeOverviewModel(recordings: recordings, state: state, recorder: recorder, preload: { model in
                preloads.record(model)
            })
            XCTAssertFalse(overview.perform(.askScreenRecording), "Nothing runs before the section read readiness")
            overview.evaluate()
            XCTAssertEqual(Set(overview.readiness?.rows.flatMap(\.actions) ?? []), [
                .askScreenRecording, .openScreenRecordingSettings, .relaunch, .openMicrophoneSettings, .openCaptureSettings,
                .openPermissionsSettings, .preloadSpeechModel, .openAISettings, .openGeneralSettings
            ])
            XCTAssertFalse(overview.isEnabled(.openSpeechSettings), "Only offered actions run")
            XCTAssertNil(overview.unavailableReason(.openSpeechSettings), "An action no row offers has no help tag")
            XCTAssertFalse(overview.perform(.openSpeechSettings))

            // Busy: the Screen Recording request, relaunch and preload wait; System Settings does not.
            // The app's controller observer syncs this; here the test does.
            state.canChange = false
            overview.syncStartState()
            for action: OverviewReadinessAction in [.askScreenRecording, .relaunch, .preloadSpeechModel] {
                XCTAssertFalse(overview.isEnabled(action), "\(action)")
                XCTAssertFalse(overview.perform(action), "\(action)")
            }
            XCTAssertTrue(overview.perform(.openScreenRecordingSettings))
            XCTAssertEqual(recorder.calls, ["openScreenRecordingSettings"])
            state.canChange = true
            overview.syncStartState()

            for action: OverviewReadinessAction in [.askScreenRecording, .openMicrophoneSettings, .relaunch] {
                XCTAssertTrue(overview.perform(action), "\(action)")
            }
            XCTAssertEqual(recorder.calls, ["openScreenRecordingSettings", "askForScreenRecording", "openMicrophoneSettings", "relaunch"])

            let tabs: [(OverviewReadinessAction, SettingsTab)] = [
                (.openPermissionsSettings, .permissions), (.openCaptureSettings, .capture), (.openAISettings, .ai),
                (.openGeneralSettings, .general)
            ]
            for (action, tab) in tabs {
                navigation.section = .overview
                XCTAssertTrue(overview.perform(action), "\(action)")
                XCTAssertEqual(navigation.section, .settings, "\(action)")
                XCTAssertEqual(navigation.settings.selectedTab, tab, "\(action)")
            }
            XCTAssertEqual(recorder.calls.count, 4, "Settings tabs open in the same window")

            navigation.section = .overview
            XCTAssertTrue(overview.perform(.preloadSpeechModel))
            XCTAssertTrue(overview.isPreloadingSpeechModel)
            XCTAssertFalse(overview.perform(.preloadSpeechModel), "One preload at a time")
            XCTAssertEqual(overview.unavailableReason(.preloadSpeechModel), OverviewModel.speechModelLoadingReason)
            await overview.preloadTask?.value
            XCTAssertNil(overview.unavailableReason(.preloadSpeechModel))
            XCTAssertFalse(overview.isPreloadingSpeechModel)
            XCTAssertEqual(overview.preloadLine, "The selected model is ready. No relaunch is needed.")
            XCTAssertEqual(preloads.calls, [WhisperTranscriber.defaultStoredModel])

            let failing = makeOverviewModel(recordings: recordings, state: state, recorder: recorder, preload: { _ in
                throw SettingsValidationError("Choose a speech model before loading it.")
            })
            failing.evaluate()
            XCTAssertTrue(failing.perform(.preloadSpeechModel))
            await failing.preloadTask?.value
            XCTAssertFalse(failing.isPreloadingSpeechModel)
            XCTAssertTrue(failing.preloadLine?.hasPrefix("Could not load Whisper:") == true, failing.preloadLine ?? "")

            XCTAssertEqual(recorder.calls.filter { $0 == "updateCheck" }, [])
            let rows = try overviewEventRows(at: f.log)
            XCTAssertEqual(rows.compactMap { $0["event"] }, Array(repeating: "main_readiness", count: 10))
            XCTAssertEqual(rows.compactMap { $0["action"] }, [
                "openScreenRecordingSettings", "askScreenRecording", "openMicrophoneSettings", "relaunch",
                "openPermissionsSettings", "openCaptureSettings", "openAISettings", "openGeneralSettings",
                "preloadSpeechModel", "preloadSpeechModel"
            ])
        }
    }

    @MainActor
    func testOverviewAppearsWithoutNetworkOrPermissionRequestsAndChecksReadinessOnlyWhileShown() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let navigation = MainNavigation()
                let recorder = CallRecorder()
                let state = OverviewState()
                state.inputs = overviewReadinessInputs(.screenDenied, speechReady: false, service: false, key: false, notice: false)
                state.lastError = "Could not capture the display."
                state.retentionDays = 30
                state.update = .newerAvailable(current: "1.0.0", latest: "1.2.0")
                let recordings = makeRecordingsModel(f, navigation: navigation, recorder: recorder)
                let overview = makeOverviewModel(recordings: recordings, state: state, recorder: recorder, evaluationInterval: .milliseconds(50))
                XCTAssertEqual(navigation.section, .overview)
                // The first frame already has the capture area, folder and retention; permissions wait for the section.
                XCTAssertEqual(overview.captureAreaSummary, "Entire display")
                XCTAssertEqual(overview.sessionsFolder, "~/Movies/ScrumTrace/sessions")
                XCTAssertEqual(overview.retentionDays, 30)
                XCTAssertNil(overview.readiness)
                XCTAssertEqual(state.readinessReads, 0, "Creating the model asks macOS nothing")
                let contexts = ContextsModel(
                    settings: controller.settings,
                    recordings: recordings,
                    dependencies: .live(controller: controller, startRecording: {}, isPreparingRecording: { false })
                )
                let hosting = NSHostingController(rootView: MainWindowView(
                    controller: controller,
                    navigation: navigation,
                    recordings: recordings,
                    overview: overview,
                    contexts: contexts,
                    settingsView: {
                        SettingsView(settings: controller.settings, controller: controller, navigation: navigation.settings)
                    }
                ))
                hosting.sizingOptions = []
                let window = NSWindow(contentViewController: hosting)
                window.isReleasedWhenClosed = false
                window.setContentSize(NSSize(width: 960, height: 640))
                defer { window.close() }
                window.orderFront(nil)
                recordings.setWindowVisible(true)
                overview.setWindowVisible(true)
                defer {
                    recordings.setWindowVisible(false)
                    overview.setWindowVisible(false)
                }

                let appeared = await waitUntil { overview.readiness != nil && overview.isEvaluationLoopActive }
                XCTAssertTrue(appeared, "The section appeared and read readiness")
                let listed = await waitUntil { recordings.library.entries.count == 3 && recordings.library.totalArchiveBytes != nil }
                XCTAssertTrue(listed, "It lists the sessions and measures the archives")
                let reads = state.readinessReads
                let ticked = await waitUntil { state.readinessReads >= reads + 2 }
                XCTAssertTrue(ticked, "Readiness is checked again while the section is shown")
                XCTAssertGreaterThan(state.updateReads, 0, "Only the cached update result is read")
                XCTAssertEqual(overview.attention.availableUpdate, state.update)
                XCTAssertEqual(recorder.calls, [], "Appearing starts no update check, no Screen Recording request and no recording")
                XCTAssertNil(UpdateChecker.lastResult, "No check ran anywhere, so none recorded a result")
                XCTAssertEqual(try logRows(at: f.log).filter { $0["event"] == "screen_request" }.count, 0)

                if ProcessInfo.processInfo.environment["SCRUMTRACE_SNAPSHOT_DIR"] != nil {
                    spinRunLoop(for: 0.2)
                    writeSnapshot(of: window, named: "overview-960-top")
                    scrollToBottom(in: window)
                    spinRunLoop(for: 0.2)
                    writeSnapshot(of: window, named: "overview-960-bottom")
                    window.setContentSize(MainWindowPresenter.minimumContentSize)
                    spinRunLoop(for: 0.3)
                    writeSnapshot(of: window, named: "overview-840-top")
                    scrollToBottom(in: window)
                    spinRunLoop(for: 0.2)
                    writeSnapshot(of: window, named: "overview-840-bottom")
                }

                navigation.section = .settings
                let stopped = await waitUntil { !overview.isEvaluationLoopActive }
                XCTAssertTrue(stopped, "Leaving the section stops the readiness checks")
                let afterLeaving = state.readinessReads
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(state.readinessReads, afterLeaving, "No readiness work while another section is shown")
                navigation.section = .overview
                let back = await waitUntil { overview.isEvaluationLoopActive }
                XCTAssertTrue(back)
                overview.setWindowVisible(false)
                XCTAssertFalse(overview.isEvaluationLoopActive, "A hidden window does no readiness work")
                XCTAssertEqual(recorder.calls, [])
            }
        }
    }

    @MainActor
    func testOpeningTheWindowOnOverviewListsSessionsAndChecksReadinessOnlyWhileVisible() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let checks = CallRecorder()
                UpdateChecker.setRequestForTesting {
                    checks.record("updateCheck")
                    return .upToDate(current: "1.0.0")
                }
                defer { UpdateChecker.setRequestForTesting(nil) }
                // A check from the menu bar or Settings already ran in this launch.
                UpdateChecker.recordLastResult(.newerAvailable(current: "1.0.0", latest: "1.2.0"))
                let starts = MainActorBox(0)
                let preparing = MainActorBox(false)
                let presenter = MainWindowPresenter(
                    controller: controller,
                    frameAutosaveName: nil,
                    isWindowOnScreen: ignoringOcclusion,
                    onStartRecording: {
                        starts.value += 1
                        preparing.value = true
                    },
                    isPreparingRecording: { preparing.value }
                )
                defer { presenter.window?.close() }
                XCTAssertNil(presenter.overview.readiness, "Nothing is read before the window shows the section")
                XCTAssertFalse(presenter.overview.isWindowVisible)

                presenter.show()
                let window = try XCTUnwrap(presenter.window)
                XCTAssertEqual(presenter.navigation.section, .overview)
                XCTAssertTrue(presenter.overview.isWindowVisible)
                XCTAssertTrue(presenter.recordings.isPeriodicRefreshActive)
                let ready = await waitUntil {
                    presenter.overview.readiness != nil
                        && presenter.overview.isEvaluationLoopActive
                        && presenter.recordings.library.entries.count == 3
                }
                XCTAssertTrue(ready, "Opening on Overview reads readiness and lists the sessions")
                XCTAssertEqual(presenter.overview.attention.unfinished.map(\.sessionId), [f.unfinished])
                XCTAssertEqual(presenter.overview.lastRecording?.sessionId, f.unfinished)
                XCTAssertEqual(presenter.overview.attention.unreadableIds, [f.corrupt])
                XCTAssertEqual(
                    presenter.overview.attention.availableUpdate,
                    .newerAvailable(current: "1.0.0", latest: "1.2.0"),
                    "The live source shows the result of the check that already ran"
                )
                XCTAssertEqual(checks.calls, [], "Opening the window starts no update check")
                XCTAssertEqual(UpdateChecker.lastResult, .newerAvailable(current: "1.0.0", latest: "1.2.0"))
                XCTAssertEqual(try logRows(at: f.log).filter { $0["event"] == "screen_request" }.count, 0, "No Screen Recording request")

                // The presenter hands the app's Start flow and its context-window state to the Overview.
                XCTAssertTrue(presenter.overview.startRecording())
                XCTAssertEqual(starts.value, 1)
                XCTAssertTrue(presenter.overview.isPreparingRecording)
                XCTAssertFalse(presenter.overview.canStartRecording)
                preparing.value = false
                presenter.overview.syncStartState()
                XCTAssertTrue(presenter.overview.canStartRecording)

                window.miniaturize(nil)
                XCTAssertTrue(spinRunLoop(until: { !presenter.overview.isEvaluationLoopActive }), "A minimized window does no readiness work")
                window.deminiaturize(nil)
                XCTAssertTrue(spinRunLoop(until: { presenter.overview.isEvaluationLoopActive }))
                window.close()
                XCTAssertFalse(presenter.overview.isEvaluationLoopActive, "A closed window does no readiness work")
                XCTAssertFalse(presenter.recordings.isPeriodicRefreshActive)

                // Showing the closed window again brings the section and its readiness checks back.
                presenter.show()
                XCTAssertTrue(presenter.window === window, "The same window is reused")
                XCTAssertTrue(
                    spinRunLoop(until: { presenter.overview.isSectionShown && presenter.overview.isEvaluationLoopActive }),
                    "Reopened on Overview, readiness is checked again"
                )
                XCTAssertTrue(presenter.recordings.isPeriodicRefreshActive)
                XCTAssertEqual(checks.calls, [])
            }
        }
    }

    @MainActor
    func testAnUpdateCheckRecordsItsResultForTheOverviewToRead() async {
        let checks = CallRecorder()
        UpdateChecker.setRequestForTesting {
            checks.record("updateCheck")
            return .newerAvailable(current: "1.0.0", latest: "1.2.0")
        }
        defer { UpdateChecker.setRequestForTesting(nil) }
        XCTAssertNil(UpdateChecker.lastResult)
        XCTAssertNil(OverviewUpdateSource.live.lastResult())
        let result = await UpdateChecker.check()
        XCTAssertEqual(result, .newerAvailable(current: "1.0.0", latest: "1.2.0"))
        XCTAssertEqual(checks.calls, ["updateCheck"])
        XCTAssertEqual(UpdateChecker.lastResult, result, "The check keeps its result for this launch")
        XCTAssertEqual(OverviewUpdateSource.live.lastResult(), result, "The Overview reads that result")
    }

    @MainActor
    func testOverviewMeasuresArchivesOnlyAfterTheFirstScanListedTheSessions() async throws {
        try await withRecordingsFixture { f in
            let gate = DispatchGroup()
            gate.enter()
            let released = MainActorBox(false)
            defer { if !released.value { gate.leave() } }
            let recorder = CallRecorder()
            let state = OverviewState()
            let recordings = makeRecordingsModel(f, recorder: recorder, manifestLoadGate: gate)
            let overview = makeOverviewModel(recordings: recordings, state: state, recorder: recorder)
            let totals = MainActorBox<[Int?]>([])
            let subscription = recordings.library.$totalArchiveBytes.dropFirst().sink { value in
                MainActor.assumeIsolated { totals.value.append(value) }
            }
            defer { subscription.cancel() }

            overview.sectionDidAppear()
            // The first scan is still reading manifests, so nothing is measured and Private archives keeps
            // saying Measuring… instead of zero bytes.
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(recordings.library.entries.isEmpty)
            XCTAssertNil(recordings.library.totalArchiveBytes)
            XCTAssertEqual(totals.value, [])

            gate.leave()
            released.value = true
            await overview.archiveTotalTask?.value
            XCTAssertEqual(recordings.library.entries.count, 3)
            XCTAssertGreaterThan(recordings.library.totalArchiveBytes ?? 0, 0)
            XCTAssertFalse(totals.value.contains(0), "No zero total was ever published: \(totals.value)")
        }
    }

    @MainActor
    func testOverviewWaitsForTheRefreshThatReplacedTheFirstScanBeforeMeasuringArchives() async throws {
        try await withRecordingsFixture { f in
            let gate = ScanGate()
            defer { gate.openAll() }
            let recorder = CallRecorder()
            let state = OverviewState()
            let recordings = makeRecordingsModel(f, recorder: recorder, beforeManifestLoad: { gate.wait() })
            let overview = makeOverviewModel(recordings: recordings, state: state, recorder: recorder)
            let totals = MainActorBox<[Int?]>([])
            let subscription = recordings.library.$totalArchiveBytes.dropFirst().sink { value in
                MainActor.assumeIsolated { totals.value.append(value) }
            }
            defer { subscription.cancel() }

            // The window became visible on Overview and started a scan; the section appears and joins it.
            let first = recordings.refresh()
            let firstStarted = await waitUntil { gate.firstScanLoads >= 1 }
            XCTAssertTrue(firstStarted, "The first scan is decoding")
            overview.sectionDidAppear()
            // Before it finishes, processing ends or the window is uncovered: a newer refresh replaces that scan.
            let second = recordings.refresh()
            let secondStarted = await waitUntil { gate.laterScanLoads >= 1 }
            XCTAssertTrue(secondStarted, "The newer scan is decoding")

            // The replaced scan finishes and publishes nothing. The total must not measure the empty list.
            gate.openFirstScan()
            await first.value
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(recordings.library.isLoading, "No scan has published yet")
            XCTAssertTrue(recordings.library.entries.isEmpty)
            XCTAssertNil(recordings.library.totalArchiveBytes, "Private archives keeps saying Measuring…")
            XCTAssertEqual(totals.value, [])

            gate.openLaterScans()
            await second.value
            await overview.archiveTotalTask?.value
            XCTAssertEqual(recordings.library.entries.count, 3)
            let measured = try XCTUnwrap(recordings.library.totalArchiveBytes)
            XCTAssertGreaterThan(measured, 0)
            XCTAssertEqual(totals.value, [measured], "One total, never zero bytes")
            overview.sectionDidDisappear()
            XCTAssertEqual(recorder.calls, [])
        }
    }

    @MainActor
    func testOverviewLastRecordingSkipsACaptureInProgressAndShowAllMatchesTheRecordingsFilter() async throws {
        try await withRecordingsFixture { f in
            let navigation = MainNavigation()
            let recorder = CallRecorder()
            let state = OverviewState()
            let recordings = makeRecordingsModel(
                f,
                navigation: navigation,
                recorder: recorder,
                canChange: { state.canChange },
                activeSessionId: { state.activeSessionId }
            )
            let overview = makeOverviewModel(recordings: recordings, state: state, recorder: recorder)
            @MainActor func syncCapture() {
                overview.syncStartState()
                recordings.syncCaptureState()
            }
            XCTAssertEqual(
                [PipelineStatus.idle, .recording, .paused, .transcribing, .slicing, .evaluating, .synthesizing, .completed, .offlineFailed]
                    .filter(OverviewModel.isCapturing),
                [.idle, .recording, .paused]
            )

            let capturing = try makeSession(in: f.vault, status: .recording)
            await recordings.refresh().value
            XCTAssertEqual(overview.lastRecording?.sessionId, capturing, "Idle: a recording that never finished is the newest")

            // Recording: the card keeps the recording before it, as Needs attention leaves the live one out.
            state.canChange = false
            state.activeSessionId = capturing.uppercased()
            syncCapture()
            XCTAssertEqual(overview.heldSessionId, capturing.uppercased())
            XCTAssertEqual(overview.lastRecording?.sessionId, f.unfinished)
            XCTAssertEqual(overview.attention.unfinished.map(\.sessionId), [f.unfinished])

            // Analysis of that recording: the card shows its progress.
            var manifest = try f.vault.loadManifest(id: capturing)
            manifest.pipelineStatus = .transcribing
            try f.vault.write(manifest: &manifest)
            await recordings.refresh().value
            XCTAssertEqual(overview.lastRecording?.sessionId, capturing)
            XCTAssertEqual(overview.lastRecording?.pipelineStatus, .transcribing)

            // Show all counts what the Recordings filter lists, including the recording in progress.
            for _ in 0..<5 {
                _ = try makeSession(in: f.vault, status: .offlineFailed)
            }
            await recordings.refresh().value
            XCTAssertEqual(overview.attention.unfinished.count, 6, "Needs attention leaves out the held recording")
            XCTAssertGreaterThan(overview.attention.unfinished.count, OverviewAttention.unfinishedLimit)
            XCTAssertEqual(overview.unfinishedInRecordingsCount, 7)
            overview.showUnfinishedInRecordings()
            XCTAssertEqual(navigation.section, .recordings)
            XCTAssertEqual(recordings.visibleEntries.count, overview.unfinishedInRecordingsCount)
            XCTAssertEqual(recorder.calls, [])
        }
    }
}

/// Readiness inputs for tests: everything set up unless an argument says otherwise.
private func overviewReadinessInputs(
    _ capture: CaptureReadiness = .ready,
    microphone: Bool = true,
    microphoneStatus: String = "allowed",
    accessibility: Bool = true,
    speechModel: String = WhisperTranscriber.defaultStoredModel,
    speechReady: Bool = true,
    speechLoading: Bool = false,
    service: Bool = true,
    key: Bool = true,
    valid: Bool = true,
    notice: Bool = true
) -> OverviewReadiness.Inputs {
    let summary: String
    if !service {
        summary = "No service selected. Add one to use AI analysis. Recording and local export remain available."
    } else if !key {
        summary = "No saved key for this service. Recording and local export remain available."
    } else {
        summary = "Configured locally. Key validity and model availability have not been checked online."
    }
    return OverviewReadiness.Inputs(
        capture: capture,
        microphoneEnabled: microphone,
        microphoneStatus: microphoneStatus,
        accessibilityTrusted: accessibility,
        speechModel: speechModel,
        speechModelReady: speechReady,
        speechModelLoading: speechLoading,
        aiServiceSelected: service,
        aiKeySaved: key,
        aiConfigurationValid: valid,
        aiSummary: summary,
        meetingNoticeAccepted: notice
    )
}

/// What the injected Overview closures read while a test changes it, and how often readiness and the cached
/// update result were read.
@MainActor
private final class OverviewState {
    var inputs = overviewReadinessInputs()
    var canChange = true
    var preparing = false
    /// A recording starts, runs or is paused. While `canChange` is false and this is false, analysis runs.
    var recordingActive = false
    var activeSessionId: String?
    var lastError: String?
    var retentionDays = 0
    var captureArea = "Entire display"
    var update: UpdateChecker.Result?
    var readinessReads = 0
    var updateReads = 0
}

/// Records calls from injected closures, including the delete that runs off the main actor.
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ call: String) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }
}

/// Holds detail loads for chosen rows, off the main actor, until `release()`, and records which of them had been
/// cancelled by the time they were let through.
private final class DetailLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let held: Set<String>
    private let group = DispatchGroup()
    private var isHolding = true
    private var cancelledIds: [String] = []

    init(holding ids: Set<String>) {
        held = ids
        group.enter()
    }

    var cancelled: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancelledIds
    }

    func pass(_ id: String) {
        guard held.contains(id) else { return }
        group.wait()
        guard Task.isCancelled else { return }
        lock.lock()
        cancelledIds.append(id)
        lock.unlock()
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard isHolding else { return }
        isHolding = false
        group.leave()
    }
}

/// The controller's session id as a test changes it.
@MainActor
private final class ActiveSessionBox {
    var id: String?

    init(_ id: String?) {
        self.id = id
    }
}

/// A value an injected main-actor closure reads while a test changes it.
@MainActor
private final class MainActorBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Holds manifest loads per scan: the scan that loads a manifest first waits for `openFirstScan()`, every
/// other scan for `openLaterScans()`. A scan decodes synchronously on one thread, which tells scans apart.
private final class ScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstScan = DispatchGroup()
    private let laterScans = DispatchGroup()
    private var firstThread: pthread_t?
    private var firstLoads = 0
    private var laterLoads = 0
    private var isFirstOpen = false
    private var areLaterOpen = false

    init() {
        firstScan.enter()
        laterScans.enter()
    }

    var firstScanLoads: Int {
        lock.lock()
        defer { lock.unlock() }
        return firstLoads
    }

    var laterScanLoads: Int {
        lock.lock()
        defer { lock.unlock() }
        return laterLoads
    }

    func wait() {
        let thread = pthread_self()
        lock.lock()
        let first = firstThread ?? thread
        firstThread = first
        let isFirst = pthread_equal(first, thread) != 0
        if isFirst {
            firstLoads += 1
        } else {
            laterLoads += 1
        }
        lock.unlock()
        _ = (isFirst ? firstScan : laterScans).wait(timeout: .now() + 10)
    }

    func openFirstScan() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFirstOpen else { return }
        isFirstOpen = true
        firstScan.leave()
    }

    func openLaterScans() {
        lock.lock()
        defer { lock.unlock() }
        guard !areLaterOpen else { return }
        areLaterOpen = true
        laterScans.leave()
    }

    func openAll() {
        openFirstScan()
        openLaterScans()
    }
}

// MARK: - Dock presence, keyboard and window state

extension MainWindowTests {
    /// Rows of the listed events. Beyond the fields every row carries, each carries only the fields listed for it.
    private func technicalRows(
        at log: URL,
        allowing fields: [String: Set<String>],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [[String: String]] {
        AgentLog.event("dock_test_baseline", [:])
        let rows = try logRows(at: log)
        let baseline = try XCTUnwrap(rows.last { $0["event"] == "dock_test_baseline" }, file: file, line: line)
        let common = Set(baseline.keys)
        let listed = rows.filter { fields[$0["event"] ?? ""] != nil }
        for row in listed {
            let event = row["event"] ?? ""
            let extra = Set(row.keys).subtracting(common)
            XCTAssertTrue(extra.isSubset(of: fields[event] ?? []), "\(event) carries \(extra)", file: file, line: line)
        }
        return listed
    }

    @MainActor
    private func mainMenuItems() throws -> [NSMenuItem] {
        func items(in menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
        }
        return items(in: try XCTUnwrap(NSApp.mainMenu))
    }

    @MainActor
    func testDockTileShowsWhileTheWindowIsOpenAndFollowsThePreference() throws {
        try withController { controller, log in
            let settings = controller.settings
            XCTAssertTrue(settings.showInDockWhileWindowOpen, "On by default")
            let fake = FakeActivation()
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion, activation: fake.seam)
            defer {
                // No app to give focus back to, so nothing runs after the test.
                fake.frontmost = nil
                presenter.window?.close()
            }
            XCTAssertEqual(fake.policyChanges, [], "Creating the presenter changes nothing")

            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            XCTAssertTrue(presenter.isWindowOpen)
            XCTAssertEqual(fake.policy, .regular, "An open window gives ScrumTrace a Dock tile and a place in Command-Tab")
            // The first-run order, the main window before the permissions window, is checked on the launch code in
            // testHotkeysAndTheHUDNeverOpenOrActivateTheMainWindow.

            presenter.show(section: .recordings)
            presenter.show(tab: .general)
            XCTAssertEqual(fake.policyChanges, [.regular], "Showing an open window again changes nothing")

            // macOS 15 finishes ordering in, minimizing and restoring asynchronously; wait for each state
            // instead of reading it at once.
            XCTAssertTrue(spinRunLoop(until: { window.isVisible && !window.isMiniaturized }, timeout: 5))
            window.miniaturize(nil)
            XCTAssertTrue(spinRunLoop(until: { window.isMiniaturized }, timeout: 5))
            XCTAssertEqual(fake.policy, .regular, "A minimized window is still open")
            window.deminiaturize(nil)
            XCTAssertTrue(spinRunLoop(until: { !window.isMiniaturized && window.isVisible }, timeout: 5))

            // The Settings toggle applies at once while the window is open.
            settings.showInDockWhileWindowOpen = false
            XCTAssertEqual(fake.policy, .accessory)
            settings.showInDockWhileWindowOpen = true
            XCTAssertEqual(fake.policy, .regular)

            window.close()
            XCTAssertFalse(presenter.isWindowOpen)
            XCTAssertEqual(fake.policy, .accessory, "Closing returns ScrumTrace to the menu bar")
            XCTAssertEqual(fake.policyChanges, [.regular, .accessory, .regular, .accessory])

            // While the window is closed, the preference waits for the next show.
            settings.showInDockWhileWindowOpen = false
            settings.showInDockWhileWindowOpen = true
            settings.showInDockWhileWindowOpen = false
            XCTAssertEqual(fake.policyChanges.count, 4)

            // Off: ScrumTrace stays an accessory throughout.
            presenter.show(section: .settings)
            XCTAssertTrue(spinRunLoop(until: { window.isVisible && !window.isMiniaturized }, timeout: 5))
            XCTAssertEqual(fake.policy, .accessory)
            window.miniaturize(nil)
            XCTAssertTrue(spinRunLoop(until: { window.isMiniaturized }, timeout: 5))
            presenter.show()
            XCTAssertTrue(
                spinRunLoop(until: { !window.isMiniaturized && window.isVisible }, timeout: 5),
                "show() restores a minimized window"
            )
            window.close()
            XCTAssertEqual(fake.policy, .accessory)
            XCTAssertEqual(fake.policyChanges.count, 4, "With the preference off the policy never changes")

            let policies = try technicalRows(at: log, allowing: ["main_dock": ["policy"]]).compactMap { $0["policy"] }
            XCTAssertEqual(policies, ["regular", "accessory", "regular", "accessory"])
        }
    }

    @MainActor
    func testShowInDockPreferenceIsStoredUnderItsKey() throws {
        let suite = "ScrumTrace.MainWindowTests.Dock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, keyStore: .empty)
        XCTAssertTrue(settings.showInDockWhileWindowOpen)
        XCTAssertNil(defaults.object(forKey: "scrumtrace.showInDock"))
        settings.showInDockWhileWindowOpen = false
        XCTAssertEqual(defaults.object(forKey: "scrumtrace.showInDock") as? Bool, false)
        XCTAssertFalse(AppSettings(defaults: defaults, keyStore: .empty).showInDockWhileWindowOpen)
    }

    @MainActor
    func testClosingTheWindowGivesFocusBackToTheAppThatWasInFront() throws {
        try withController { controller, log in
            let fake = FakeActivation()
            fake.frontmost = 111
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion, activation: fake.seam)
            defer {
                fake.frontmost = nil
                presenter.window?.close()
            }
            let own = FakeActivation.ownProcessIdentifier

            XCTAssertEqual(fake.followerCount, 1, "App switches are followed from the moment the presenter exists")
            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            XCTAssertEqual(presenter.focusReturnProcessIdentifier, 111)
            fake.appDidActivate(own)
            presenter.show(section: .contexts)
            XCTAssertEqual(presenter.focusReturnProcessIdentifier, 111, "ScrumTrace itself is never the app to go back to")
            XCTAssertEqual(fake.followerCount, 1)

            window.close()
            XCTAssertEqual(fake.followerCount, 1, "App switches are still followed with the window closed")
            XCTAssertTrue(
                spinRunLoop(until: { fake.activated == [111] }),
                "ScrumTrace was still in front after the switch, so the previous app gets focus back"
            )
            XCTAssertNil(presenter.pendingFocusReturn)

            // The last other app activated while the window was open is the one to go back to.
            fake.appDidActivate(own)
            presenter.show()
            XCTAssertEqual(presenter.focusReturnProcessIdentifier, 111, "Shown while ScrumTrace was in front: the app before it")
            fake.appDidActivate(222)
            fake.appDidActivate(own)
            XCTAssertEqual(presenter.focusReturnProcessIdentifier, 222)
            window.close()
            XCTAssertTrue(spinRunLoop(until: { fake.activated == [111, 222] }))

            // Closed while another app is in front: nothing to give back.
            fake.frontmost = 333
            presenter.show()
            window.close()
            XCTAssertTrue(spinRunLoop(until: { presenter.pendingFocusReturn == nil }))
            XCTAssertEqual(fake.activated, [111, 222])

            // Another ScrumTrace window, such as the first-run permissions window, keeps the keyboard.
            presenter.show()
            fake.appDidActivate(own)
            fake.anotherWindowIsKey = true
            window.close()
            XCTAssertTrue(spinRunLoop(until: { presenter.pendingFocusReturn == nil }))
            XCTAssertEqual(fake.activated, [111, 222])
            fake.anotherWindowIsKey = false

            // With the Dock tile turned off, focus still goes back.
            controller.settings.showInDockWhileWindowOpen = false
            fake.frontmost = 444
            presenter.show()
            fake.appDidActivate(own)
            window.close()
            XCTAssertTrue(spinRunLoop(until: { fake.activated == [111, 222, 444] }))

            // The previous app quit meanwhile.
            fake.frontmost = 555
            presenter.show()
            fake.appDidActivate(own)
            fake.canActivate = false
            window.close()
            XCTAssertTrue(spinRunLoop(until: { presenter.pendingFocusReturn == nil }))
            XCTAssertEqual(fake.activated, [111, 222, 444])

            let returns = try technicalRows(at: log, allowing: ["main_dock": ["policy"], "main_focus_return": ["activated"]])
                .filter { $0["event"] == "main_focus_return" }
                .compactMap { $0["activated"] }
            XCTAssertEqual(returns, ["1", "1", "1", "0"])
        }
    }

    @MainActor
    func testShowingTheWindowAgainCancelsAPendingFocusReturn() throws {
        try withController { controller, _ in
            let fake = FakeActivation()
            fake.frontmost = 111
            fake.focusReturnDelay = .milliseconds(300)
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion, activation: fake.seam)
            defer {
                fake.frontmost = nil
                presenter.window?.close()
            }
            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            fake.appDidActivate(FakeActivation.ownProcessIdentifier)
            window.close()
            let pending = try XCTUnwrap(presenter.pendingFocusReturn, "The focus return first waits for AppKit")
            presenter.show()
            XCTAssertNil(presenter.pendingFocusReturn)
            XCTAssertTrue(pending.isCancelled)
            spinRunLoop(for: 0.5)
            XCTAssertEqual(fake.activated, [], "Reopening within the delay keeps ScrumTrace in front")
            XCTAssertEqual(fake.policy, .regular)
            XCTAssertTrue(window.isVisible)
        }
    }

    @MainActor
    func testSectionSelectionSearchAndFiltersSurviveClosingAndReopeningTheWindow() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
                defer { presenter.window?.close() }
                let model = presenter.recordings
                presenter.show(sessionId: f.completed)
                let window = try XCTUnwrap(presenter.window)
                let listed = await waitUntil { self.recordingsTable(in: window)?.numberOfRows == 3 }
                XCTAssertTrue(listed)
                model.searchText = "Orbit"
                model.statusFilter = .completed
                model.contextFilter = "ctx-orbit"
                let filtered = await waitUntil {
                    let table = self.recordingsTable(in: window)
                    return table?.numberOfRows == 1 && table?.selectedRow == 0
                }
                XCTAssertTrue(filtered)

                @MainActor
                func assertKept(_ step: String) async {
                    XCTAssertEqual(presenter.navigation.section, .recordings, step)
                    XCTAssertEqual(presenter.navigation.selectedSessionId, f.completed, step)
                    XCTAssertEqual(model.searchText, "Orbit", step)
                    XCTAssertEqual(model.statusFilter, .completed, step)
                    XCTAssertEqual(model.contextFilter, "ctx-orbit", step)
                    let restored = await waitUntil {
                        let table = self.recordingsTable(in: window)
                        return table?.numberOfRows == 1 && table?.selectedRow == 0
                            && MainWindowPresenter.searchToolbarItem(in: window)?.searchField.stringValue == "Orbit"
                    }
                    XCTAssertTrue(restored, "\(step): the table is still filtered, with the same row selected")
                }

                window.close()
                spinRunLoop(for: 0.2)
                XCTAssertFalse(window.isVisible)
                presenter.show()
                XCTAssertTrue(presenter.window === window)
                await assertKept("Closed and reopened")

                // Another section in between, then the icon and Command-2.
                presenter.show(section: .contexts)
                spinRunLoop(for: 0.1)
                window.close()
                presenter.show()
                XCTAssertEqual(presenter.navigation.section, .contexts)
                presenter.show(section: .recordings)
                await assertKept("Reopened on Contexts, then Recordings")
            }
        }
    }

    @MainActor
    func testRecordingsBadgeCountsUnfinishedRecordingsThatNeedAttention() async throws {
        try await withRecordingsFixture { f in
            let library = SessionLibrary(vault: f.vault)
            await library.refresh().value
            let entries = library.entries
            XCTAssertEqual(entries.count, 3)
            // The transcribing recording counts; the completed one and the unreadable manifest do not.
            XCTAssertEqual(MainSidebarBadge.unfinishedCount(entries: entries, canChangeSessions: true, activeSessionId: nil), 1)
            XCTAssertEqual(
                MainSidebarBadge.unfinishedCount(entries: entries, canChangeSessions: false, activeSessionId: f.unfinished.uppercased()),
                0,
                "The recording a running capture or analysis holds is in progress, not waiting"
            )
            XCTAssertEqual(
                MainSidebarBadge.unfinishedCount(entries: entries, canChangeSessions: true, activeSessionId: f.unfinished),
                1,
                "Once capture and analysis end, the controller's last recording counts again"
            )

            let offline = try makeSession(in: f.vault, status: .offlineFailed)
            _ = try makeSession(in: f.vault, status: .paused)
            _ = try makeSession(in: f.vault, status: .completed)
            await library.refresh().value
            let more = library.entries
            XCTAssertEqual(more.count, 6)
            XCTAssertEqual(MainSidebarBadge.unfinishedCount(entries: more, canChangeSessions: true, activeSessionId: nil), 3)
            XCTAssertEqual(MainSidebarBadge.unfinishedCount(entries: more, canChangeSessions: false, activeSessionId: offline), 2)
            XCTAssertEqual(
                MainSidebarBadge.unfinishedCount(entries: more, canChangeSessions: true, activeSessionId: nil),
                OverviewAttention.make(entries: more, heldSessionId: nil, lastError: "Failed", retentionDays: 30, update: nil).unfinished.count,
                "The badge counts what Overview lists under Needs attention"
            )

            XCTAssertEqual(MainSidebarBadge.help(unfinishedCount: 0), "")
            XCTAssertEqual(MainSidebarBadge.help(unfinishedCount: 1), "1 unfinished recording")
            XCTAssertEqual(MainSidebarBadge.help(unfinishedCount: 4), "4 unfinished recordings")
        }
    }

    func testHotkeysAndTheHUDNeverOpenOrActivateTheMainWindow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        for path in ["ScrumTrace/UI/HotkeyManager.swift", "ScrumTrace/UI/RecordingHUDWindow.swift"] {
            let text = try source(path)
            let forbidden = [
                "MainWindowPresenter", "mainPresenter", "showMainWindow", "showSettingsWindow", "showSettingsFromCommand", "showAgentLogWindow",
                "findRecordings", "showRecordingsSearch", "applicationShouldHandleReopen", "AppDelegate", "NSApp.delegate",
                "NSApp.activate", "setActivationPolicy"
            ]
            for forbidden in forbidden {
                XCTAssertFalse(text.contains(forbidden), "\(path) must not use \(forbidden)")
            }
        }

        let app = try source("ScrumTrace/App/AppDelegate.swift")
        XCTAssertTrue(app.contains("activation: .live"), "The app's presenter manages the Dock tile")
        XCTAssertEqual(app.components(separatedBy: "NSApp.activate(").count - 1, 1, "One place activates ScrumTrace")
        let show = try XCTUnwrap(app.range(of: "    func show() {"))
        let afterShow = app[show.upperBound...]
        let showBody = afterShow[..<(afterShow.range(of: "\n    }\n")?.lowerBound ?? afterShow.endIndex)]
        XCTAssertTrue(showBody.contains("NSApp.activate("), "It is the presenter's show()")
        XCTAssertFalse(try source("ScrumTrace/UI/MainWindow.swift").contains("NSApp.activate("))

        let launch = try XCTUnwrap(app.components(separatedBy: "func applicationDidFinishLaunching").last?
            .components(separatedBy: "func applicationWillTerminate").first)
        XCTAssertTrue(launch.contains("NSApp.setActivationPolicy(.accessory)"), "Launch still starts as a menu-bar accessory")
        let launchWindow = try XCTUnwrap(launch.range(of: "showMainWindow(source: .launch)"))
        let onboarding = try XCTUnwrap(launch.range(of: "OnboardingWindow.presentIfNeeded()"))
        XCTAssertLessThan(launchWindow.lowerBound, onboarding.lowerBound, "First run: the main window opens behind the permissions window")
    }

    @MainActor
    func testRecordingsKeyboardRevealsDeletesAndClearsTheSearch() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let navigation = MainNavigation()
                navigation.section = .recordings
                let recorder = CallRecorder()
                let recordings = makeRecordingsModel(f, navigation: navigation, recorder: recorder)
                let hosting = NSHostingController(rootView: MainWindowView(
                    controller: controller,
                    navigation: navigation,
                    recordings: recordings,
                    overview: OverviewModel(
                        recordings: recordings,
                        navigation: navigation,
                        dependencies: .live(controller: controller, startRecording: {}, isPreparingRecording: { false })
                    ),
                    contexts: ContextsModel(
                        settings: controller.settings,
                        recordings: recordings,
                        dependencies: .live(controller: controller, startRecording: {}, isPreparingRecording: { false })
                    ),
                    settingsView: {
                        SettingsView(settings: controller.settings, controller: controller, navigation: navigation.settings)
                    }
                ))
                hosting.sizingOptions = []
                hosting.sceneBridgingOptions = [.toolbars]
                let window = KeyWindowForTesting(
                    contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.contentViewController = hosting
                window.isReleasedWhenClosed = false
                window.setContentSize(NSSize(width: 960, height: 640))
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                await recordings.refresh().value
                navigation.selectedSessionId = f.completed
                let selected = await waitUntil { (self.recordingsTable(in: window)?.selectedRow ?? -1) >= 0 }
                XCTAssertTrue(selected)
                let windowNumber = window.windowNumber
                func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: windowNumber,
                        context: nil,
                        characters: characters,
                        charactersIgnoringModifiers: characters,
                        isARepeat: false,
                        keyCode: keyCode
                    ))
                }

                // Command-R reveals the selected recording's export folder.
                NSApp.sendEvent(try key("r", keyCode: 15, modifiers: .command))
                let revealed = await waitUntil { recorder.calls == ["revealExport \(f.completed)"] }
                XCTAssertTrue(revealed, "Command-R: \(recorder.calls)")

                // Delete in the table asks first.
                let table = try XCTUnwrap(recordingsTable(in: window))
                XCTAssertTrue(window.makeFirstResponder(table))
                // SwiftUI follows the first responder on its next pass.
                spinRunLoop(for: 0.3)
                NSApp.sendEvent(try key("\u{7F}", keyCode: 51))
                let asked = await waitUntil { recordings.pendingDelete == f.completed }
                XCTAssertTrue(asked, "Delete asks to confirm deleting the selected recording")
                XCTAssertFalse(recorder.calls.contains { $0.hasPrefix("deleteSession") }, "Nothing is deleted before confirming")
                recordings.cancelDelete()
                spinRunLoop(for: 0.3)

                // Escape in the table clears the search and keeps the filters.
                recordings.statusFilter = .completed
                recordings.searchText = "Orbit"
                let filtered = await waitUntil { self.recordingsTable(in: window)?.numberOfRows == 1 }
                XCTAssertTrue(filtered)
                XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(recordingsTable(in: window))))
                spinRunLoop(for: 0.3)
                NSApp.sendEvent(try key("\u{1B}", keyCode: 53))
                let cleared = await waitUntil { recordings.searchText.isEmpty }
                XCTAssertTrue(cleared, "Escape in the table clears the search")
                XCTAssertEqual(recordings.statusFilter, .completed, "Escape keeps the status filter")

                // Escape in the search field clears it too.
                let item = try XCTUnwrap(MainWindowPresenter.searchToolbarItem(in: window))
                recordings.searchText = "Orbit"
                spinRunLoop(for: 0.2)
                XCTAssertTrue(window.makeFirstResponder(item.searchField))
                XCTAssertTrue(MainWindowPresenter.isEditingSearch(item, in: window))
                spinRunLoop(for: 0.2)
                NSApp.sendEvent(try key("\u{1B}", keyCode: 53))
                let clearedInField = await waitUntil { recordings.searchText.isEmpty }
                XCTAssertTrue(clearedInField, "Escape in the search field clears the search")
            }
        }
    }

    @MainActor
    func testFindRecordingsShowsRecordingsWithTheSearchFieldFocused() async throws {
        try await withRecordingsFixture { f in
            try await withFixtureController(f) { controller in
                let find = try mainMenuItems().filter {
                    $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
                }
                XCTAssertEqual(find.map(\.title), ["Find Recordings…"], "Command-F is in the Edit menu")

                let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
                defer { presenter.window?.close() }
                let delegate = AppDelegate()
                delegate.setMainPresenterForTesting(presenter)
                // The hosted test app is never active; Command-F arrives while ScrumTrace is, from its main window.
                delegate.isActiveApp = { true }
                delegate.currentKeyWindow = { presenter.window }
                presenter.show(section: .overview)
                let window = try XCTUnwrap(presenter.window)

                delegate.findRecordings(nil)
                XCTAssertEqual(presenter.navigation.section, .recordings)
                XCTAssertTrue(window.isVisible)
                let focused = await waitUntil {
                    MainWindowPresenter.searchToolbarItem(in: window).map { MainWindowPresenter.isEditingSearch($0, in: window) } ?? false
                }
                XCTAssertTrue(focused, "Typing goes to the recordings search")
                let opens = try logRows(at: f.log).filter { $0["event"] == "main_open" }
                XCTAssertEqual(opens.last?["source"], "command")
                XCTAssertEqual(opens.last?["section"], "recordings")

                // A sheet keeps its section and the keyboard.
                presenter.show(tab: .general)
                let sheet = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                sheet.isReleasedWhenClosed = false
                window.beginSheet(sheet, completionHandler: nil)
                defer { if window.attachedSheet != nil { window.endSheet(sheet) } }
                XCTAssertTrue(spinRunLoop(until: { window.attachedSheet === sheet }))
                presenter.showRecordingsSearch()
                spinRunLoop(for: 0.2)
                XCTAssertEqual(presenter.navigation.section, .settings)
                window.endSheet(sheet)
            }
        }
    }

    @MainActor
    func testMainMenuCommandsWaitForScrumTraceToBeActiveAndFindStaysWithTheWindowInFront() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("ScrumTrace/App/ScrumTraceApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("appDelegate.showSettingsFromCommand()"), "Command-comma goes through the command check")
        XCTAssertFalse(app.contains("showSettingsWindow("), "Command-comma never opens Settings directly")
        XCTAssertTrue(app.contains("appDelegate.findRecordings(nil)"))
        XCTAssertTrue(app.contains("appDelegate.showMainWindow(section: section, source: .command)"))

        try withController { controller, log in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            let delegate = AppDelegate()
            delegate.setMainPresenterForTesting(presenter)
            let focus = FakeCommandFocus()
            delegate.isActiveApp = { focus.isActive }
            delegate.currentKeyWindow = { focus.keyWindow }
            // Stands in for the Shot note: a non-activating panel that has the keyboard while another app is active.
            let shotNote = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.titled, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            shotNote.isReleasedWhenClosed = false
            defer { shotNote.close() }

            @MainActor
            func typeEveryCommand() {
                delegate.showSettingsFromCommand()
                delegate.findRecordings(nil)
                for section in MainSection.allCases {
                    delegate.showMainWindow(section: section, source: .command)
                }
            }

            // A presentation is in front and the Shot note has the keyboard.
            focus.keyWindow = shotNote
            typeEveryCommand()
            XCTAssertNil(presenter.window, "No command opens the window while another app is active")

            // The menu bar item does not activate ScrumTrace first and still opens the window.
            delegate.showMainWindow(source: .menu)
            let window = try XCTUnwrap(presenter.window)
            XCTAssertTrue(window.isVisible)
            typeEveryCommand()
            XCTAssertEqual(presenter.navigation.section, .overview, "An open window keeps its section too")
            window.close()
            typeEveryCommand()
            XCTAssertFalse(window.isVisible, "A closed window stays closed")

            // ScrumTrace is active, but another of its windows has the keyboard: Find belongs to that window.
            focus.isActive = true
            delegate.findRecordings(nil)
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(presenter.navigation.section, .overview)

            // Typing in the Settings → Logs filter keeps Command-F there.
            delegate.showMainWindow(section: .settings, source: .command)
            XCTAssertTrue(window.isVisible)
            presenter.show(tab: .logs)
            focus.keyWindow = window
            @MainActor
            func filterField() -> NSTextField? {
                @MainActor
                func fields(in view: NSView) -> [NSTextField] {
                    let own = (view as? NSTextField).map { [$0] } ?? []
                    return own + view.subviews.flatMap { fields(in: $0) }
                }
                return window.contentView.flatMap { fields(in: $0).first { $0.placeholderString == "Filter log entries" } }
            }
            XCTAssertTrue(spinRunLoop(until: { filterField() != nil }), "Settings → Logs shows its filter field")
            XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(filterField())))
            XCTAssertTrue(spinRunLoop(until: { (window.firstResponder as? NSTextView)?.isEditable == true }))
            XCTAssertFalse(presenter.acceptsFindCommand(keyWindow: window))
            delegate.findRecordings(nil)
            spinRunLoop(for: 0.2)
            XCTAssertEqual(presenter.navigation.section, .settings, "The field being typed in keeps Command-F")
            XCTAssertEqual(presenter.navigation.settings.selectedTab, .logs)

            // A sheet on the main window has the keyboard: nothing changes.
            window.makeFirstResponder(nil)
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet, completionHandler: nil)
            defer { if window.attachedSheet != nil { window.endSheet(sheet) } }
            XCTAssertTrue(spinRunLoop(until: { window.attachedSheet === sheet }))
            XCTAssertFalse(presenter.acceptsFindCommand(keyWindow: sheet))
            XCTAssertFalse(presenter.acceptsFindCommand(keyWindow: window), "A sheet on the main window keeps Command-F")
            window.endSheet(sheet)
            XCTAssertTrue(spinRunLoop(until: { window.attachedSheet == nil }))

            // Nothing typed in the main window: Command-F goes to the recordings search, and pressing it again there
            // keeps the search.
            delegate.findRecordings(nil)
            XCTAssertEqual(presenter.navigation.section, .recordings)
            @MainActor
            func editingSearch() -> Bool {
                MainWindowPresenter.searchToolbarItem(in: window).map { MainWindowPresenter.isEditingSearch($0, in: window) } ?? false
            }
            XCTAssertTrue(spinRunLoop(until: { editingSearch() }), "Typing goes to the recordings search")
            XCTAssertTrue(presenter.acceptsFindCommand(keyWindow: window))
            delegate.findRecordings(nil)
            XCTAssertTrue(spinRunLoop(until: { editingSearch() }))
            focus.keyWindow = nil
            XCTAssertTrue(presenter.acceptsFindCommand(keyWindow: nil), "With no ScrumTrace window key, Find opens Recordings")

            let opens = try logRows(at: log).filter { $0["event"] == "main_open" }.map { $0["source"] ?? "" }
            XCTAssertEqual(opens, ["menu", "command", "command", "command"], "Ignored commands log nothing")
        }
    }

    @MainActor
    func testOpeningFromTheAppIconGivesFocusBackToTheAppTheUserCameFrom() throws {
        try withController { controller, log in
            let fake = FakeActivation()
            let own = FakeActivation.ownProcessIdentifier
            let loginWindow: pid_t = 900
            let spotlight: pid_t = 901
            fake.withoutDockTile = [loginWindow, spotlight]
            // The icon, Finder and Spotlight activate ScrumTrace before they ask it to reopen, and that reopen can
            // create the presenter. An active accessory leaves the previous app's menu bar on screen.
            fake.frontmost = own
            fake.menuBarOwner = 777
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion, activation: fake.seam)
            defer {
                fake.frontmost = nil
                presenter.window?.close()
            }
            let delegate = AppDelegate()
            delegate.setMainPresenterForTesting(presenter)

            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
            let window = try XCTUnwrap(presenter.window)
            XCTAssertEqual(presenter.focusReturnProcessIdentifier, 777, "Nothing followed yet: the app whose menu bar is on screen")
            window.close()
            XCTAssertTrue(spinRunLoop(until: { fake.activated == [777] }))

            // With the window closed the user works in another app, then clicks the ScrumTrace icon.
            fake.appDidActivate(111)
            fake.appDidActivate(own)
            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
            XCTAssertEqual(presenter.focusReturnProcessIdentifier, 111, "ScrumTrace was already in front; the app before it gets focus back")

            // The screen locks and unlocks while the window is open.
            fake.appDidActivate(loginWindow)
            fake.appDidActivate(own)
            XCTAssertEqual(presenter.focusReturnProcessIdentifier, 111, "loginwindow has no Dock tile")
            window.close()
            XCTAssertTrue(spinRunLoop(until: { fake.activated == [777, 111] }))

            // Opened from Spotlight, whose panel is still frontmost when the window shows.
            fake.appDidActivate(222)
            fake.frontmost = spotlight
            presenter.show()
            XCTAssertEqual(presenter.focusReturnProcessIdentifier, 222, "Spotlight has no Dock tile")
            fake.appDidActivate(own)
            window.close()
            XCTAssertTrue(spinRunLoop(until: { fake.activated == [777, 111, 222] }))

            let returns = try technicalRows(
                at: log,
                allowing: ["main_dock": ["policy"], "main_focus_return": ["activated"], "main_open": ["source"]]
            )
            .filter { $0["event"] == "main_focus_return" }
            .compactMap { $0["activated"] }
            XCTAssertEqual(returns, ["1", "1", "1"])
        }
    }

    @MainActor
    func testTheDockTileStaysUntilTheLastScrumTraceWindowCloses() throws {
        try withController { controller, _ in
            let fake = FakeActivation()
            let own = FakeActivation.ownProcessIdentifier
            fake.frontmost = 111
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion, activation: fake.seam)
            defer {
                fake.frontmost = nil
                fake.anotherWindowIsOpen = false
                presenter.window?.close()
            }
            // Stand-ins for other ScrumTrace windows. Never shown, only passed to the close followers.
            @MainActor
            func standIn() -> NSWindow {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.isReleasedWhenClosed = false
                return window
            }
            let permissions = standIn()
            let hud = standIn()

            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            fake.appDidActivate(own)
            XCTAssertEqual(fake.policy, .regular)

            // First run: the permissions window is still open, with the keyboard, when the main window closes.
            fake.anotherWindowIsOpen = true
            fake.anotherWindowIsKey = true
            window.close()
            XCTAssertFalse(presenter.isWindowOpen)
            XCTAssertTrue(presenter.isWaitingForOtherWindows)
            XCTAssertEqual(fake.closeFollowerCount, 1)
            XCTAssertEqual(fake.policy, .regular, "The permissions window keeps the Dock tile and its Command-Tab entry")
            XCTAssertNil(presenter.pendingFocusReturn, "Focus stays with the permissions window")

            // A panel closing while the permissions window stays changes nothing.
            fake.windowWillClose(hud)
            XCTAssertTrue(presenter.isWaitingForOtherWindows)
            XCTAssertEqual(fake.policy, .regular)

            // The last one closes: back to the menu bar, and the previous app gets focus back.
            fake.anotherWindowIsOpen = false
            fake.anotherWindowIsKey = false
            fake.windowWillClose(permissions)
            XCTAssertFalse(presenter.isWaitingForOtherWindows)
            XCTAssertEqual(fake.closeFollowerCount, 0)
            XCTAssertEqual(fake.policy, .accessory)
            XCTAssertTrue(spinRunLoop(until: { fake.activated == [111] }))

            // Showing the window again ends a wait and keeps the tile.
            presenter.show()
            fake.appDidActivate(own)
            fake.anotherWindowIsOpen = true
            window.close()
            XCTAssertTrue(presenter.isWaitingForOtherWindows)
            presenter.show()
            XCTAssertFalse(presenter.isWaitingForOtherWindows)
            XCTAssertEqual(fake.closeFollowerCount, 0)
            XCTAssertEqual(fake.policy, .regular)

            // With the preference off the policy stays, and focus still waits for the last window.
            controller.settings.showInDockWhileWindowOpen = false
            XCTAssertEqual(fake.policy, .accessory)
            window.close()
            XCTAssertTrue(presenter.isWaitingForOtherWindows)
            spinRunLoop(for: 0.1)
            XCTAssertEqual(fake.activated, [111])
            fake.anotherWindowIsOpen = false
            fake.windowWillClose(permissions)
            XCTAssertTrue(spinRunLoop(until: { fake.activated == [111, 111] }))
            XCTAssertEqual(fake.policyChanges, [.regular, .accessory, .regular, .accessory])
        }
    }

    @MainActor
    func testLiveActivationGivesFocusOnlyToAppsWithADockTileAndCountsOnlyTitledWindows() throws {
        let live = MainWindowActivation.live
        XCTAssertEqual(live.ownProcessIdentifier, ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(live.canReceiveFocus(-1), "No such process")
        for bundle in ["com.apple.loginwindow", "com.apple.dock"] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                XCTAssertFalse(live.canReceiveFocus(app.processIdentifier), "\(bundle) has no Dock tile")
            }
        }
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            XCTAssertTrue(live.canReceiveFocus(finder.processIdentifier))
        }

        let baseline = live.anotherWindowIsOpen(nil)
        let frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        let panel = NSPanel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        let overlay = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let titled = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let windows = [panel, overlay, titled]
        windows.forEach { $0.isReleasedWhenClosed = false }
        defer { windows.forEach { $0.close() } }
        panel.orderFront(nil)
        overlay.orderFront(nil)
        XCTAssertTrue(panel.isVisible && overlay.isVisible)
        XCTAssertEqual(live.anotherWindowIsOpen(nil), baseline, "Panels such as the HUD and borderless overlays do not count")
        titled.orderFront(nil)
        XCTAssertTrue(live.anotherWindowIsOpen(nil), "A titled window such as the permissions window counts")
        XCTAssertEqual(live.anotherWindowIsOpen(titled), baseline, "The window that is closing does not count")
    }

    /// PNG bytes of the Recordings row in the sidebar, as drawn.
    @MainActor
    private func recordingsSidebarRow(in window: NSWindow) -> Data? {
        guard let content = window.contentView,
              let row = MainSection.allCases.firstIndex(of: .recordings) else { return nil }
        content.layoutSubtreeIfNeeded()
        func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
        guard let sidebar = tables(in: content).first(where: {
            $0.numberOfRows == MainSection.allCases.count && $0.convert($0.bounds, to: nil).minX < 100
        }) else { return nil }
        let rect = sidebar.rect(ofRow: row)
        guard !rect.isEmpty, let bitmap = sidebar.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        sidebar.cacheDisplay(in: rect, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    @MainActor
    func testRecordingsSidebarRowShowsTheUnfinishedCountInEverySection() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil, isWindowOnScreen: ignoringOcclusion)
            defer { presenter.window?.close() }
            let recordings = presenter.recordings
            // Command-comma in a new launch: the window has not shown Recordings, Overview or Contexts yet.
            presenter.show(section: .settings)
            let window = try XCTUnwrap(presenter.window)
            XCTAssertTrue(spinRunLoop(until: { recordings.hasLoaded }), "Opening on Settings scans the index")
            spinRunLoop(for: 0.3)
            let noBadge = try XCTUnwrap(recordingsSidebarRow(in: window))

            window.close()
            let unfinished = try makeSession(in: controller.vault, status: .transcribing)
            presenter.show(section: .settings)
            XCTAssertTrue(spinRunLoop(until: { recordings.library.entries.count == 1 }), "Reopening on Settings scans again")
            XCTAssertTrue(
                spinRunLoop(until: { self.recordingsSidebarRow(in: window).map { $0 != noBadge } ?? false }),
                "The Recordings row shows the unfinished recording without visiting Recordings"
            )
            spinRunLoop(for: 0.3)
            XCTAssertNotEqual(recordingsSidebarRow(in: window), noBadge, "The badge stays")
            XCTAssertEqual(presenter.navigation.section, .settings)

            // Analysis finishes, so nothing is unfinished and the badge goes.
            var manifest = try controller.vault.loadManifest(id: unfinished)
            manifest.pipelineStatus = .completed
            try controller.vault.write(manifest: &manifest)
            recordings.refresh()
            XCTAssertTrue(
                spinRunLoop(until: { self.recordingsSidebarRow(in: window) == noBadge }),
                "Without unfinished recordings the row has no badge"
            )
        }
    }
}

/// Stands in for `NSApp`, `NSWorkspace` and other apps, so nothing reaches the test host's activation policy
/// or another running app.
@MainActor
private final class FakeActivation {
    static let ownProcessIdentifier: pid_t = 4_242

    var policy: NSApplication.ActivationPolicy = .accessory
    private(set) var policyChanges: [NSApplication.ActivationPolicy] = []
    var frontmost: pid_t?
    var menuBarOwner: pid_t?
    /// Apps without a Dock tile, such as loginwindow or a keychain prompt.
    var withoutDockTile: Set<pid_t> = []
    var anotherWindowIsKey = false
    var anotherWindowIsOpen = false
    var canActivate = true
    private(set) var activated: [pid_t] = []
    var focusReturnDelay: Duration = .zero
    private var followers: [Int: @MainActor (pid_t) -> Void] = [:]
    private var closeFollowers: [Int: @MainActor (NSWindow) -> Void] = [:]
    private var nextFollower = 0

    var followerCount: Int { followers.count }
    var closeFollowerCount: Int { closeFollowers.count }

    /// Another app, or ScrumTrace under its own id, became active.
    func appDidActivate(_ pid: pid_t) {
        frontmost = pid
        for follower in followers.values { follower(pid) }
    }

    /// A ScrumTrace window is about to close.
    func windowWillClose(_ window: NSWindow) {
        for follower in closeFollowers.values { follower(window) }
    }

    var seam: MainWindowActivation {
        MainWindowActivation(
            ownProcessIdentifier: Self.ownProcessIdentifier,
            activationPolicy: { self.policy },
            setActivationPolicy: { policy in
                self.policy = policy
                self.policyChanges.append(policy)
            },
            frontmostProcessIdentifier: { self.frontmost },
            menuBarOwnerProcessIdentifier: { self.menuBarOwner },
            canReceiveFocus: { !self.withoutDockTile.contains($0) },
            anotherWindowIsKey: { _ in self.anotherWindowIsKey },
            anotherWindowIsOpen: { _ in self.anotherWindowIsOpen },
            activateApplication: { pid in
                guard self.canActivate else { return false }
                self.activated.append(pid)
                self.appDidActivate(pid)
                return true
            },
            followActivations: { follower in
                let id = self.nextFollower
                self.nextFollower += 1
                self.followers[id] = follower
                return { self.followers[id] = nil }
            },
            followWindowCloses: { follower in
                let id = self.nextFollower
                self.nextFollower += 1
                self.closeFollowers[id] = follower
                return { self.closeFollowers[id] = nil }
            },
            focusReturnDelay: focusReturnDelay
        )
    }
}

/// Whether ScrumTrace is active and which window has the keyboard, as the app delegate's command checks see them.
@MainActor
private final class FakeCommandFocus {
    var isActive = false
    var keyWindow: NSWindow?
}

/// SwiftUI sends keyboard shortcuts only to the key window, and the hosted test app is never active, so this
/// window reports itself key.
private final class KeyWindowForTesting: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Hosted tests follow whether the window is shown and not minimized, not whether other apps cover it, so their
/// refresh and readiness loops do not depend on what else is on the test Mac's screen.
@MainActor
private func ignoringOcclusion(_ window: NSWindow) -> Bool {
    window.isVisible && !window.isMiniaturized
}
