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
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
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
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
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
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
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
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
            defer { presenter.window?.close() }
            presenter.show(section: .recordings)
            let window = try XCTUnwrap(presenter.window)
            window.miniaturize(nil)
            XCTAssertTrue(spinRunLoop(until: { window.isMiniaturized }), "The window must be miniaturized before show()")
            presenter.show()
            XCTAssertFalse(window.isMiniaturized)
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(presenter.window === window)
            XCTAssertEqual(presenter.navigation.section, .recordings)
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
        XCTAssertTrue(MainWindowLaunchPolicy.shouldShowOnLaunch(arguments: [executable], environment: [:]))
        XCTAssertTrue(MainWindowLaunchPolicy.shouldShowOnLaunch(arguments: [executable, "-NSDocumentRevisionsDebugMode", "YES"], environment: [:]))
        XCTAssertFalse(MainWindowLaunchPolicy.shouldShowOnLaunch(arguments: [executable, "--background"], environment: [:]))
        XCTAssertFalse(MainWindowLaunchPolicy.shouldShowOnLaunch(
            arguments: [executable],
            environment: ["XCTestConfigurationFilePath": "/tmp/ScrumTrace.xctestconfiguration"]
        ))
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
            controller.statusLine = "Pinned 12:30"
            XCTAssertEqual(MainLiveBannerState(controller: controller, resumeAllowed: false).detail, "Pinned 12:30")

            controller.phase = .paused
            controller.mediaElapsed = 3723
            controller.statusLine = "Paused — nothing is written"
            let paused = MainLiveBannerState(controller: controller, resumeAllowed: false)
            XCTAssertTrue(paused.isVisible)
            XCTAssertTrue(paused.isPaused)
            XCTAssertEqual(paused.title, "Paused")
            XCTAssertEqual(paused.elapsed, "1:02:03")
            XCTAssertEqual(paused.detail, "Paused — nothing is written")
            XCTAssertEqual(paused.pauseTitle, "Resume")
            XCTAssertFalse(paused.canTogglePause, "Resume waits for the sampled privacy gate")
            XCTAssertTrue(MainLiveBannerState(controller: controller, resumeAllowed: true).canTogglePause)
        }
    }

    @MainActor
    func testWindowStaysStableWhileSectionsAndTheBannerChange() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
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
                        NSSize(width: 840, height: 580),
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
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: name)
            defer {
                presenter.window?.close()
                presenter.window?.setFrameAutosaveName("")
            }
            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            XCTAssertEqual(
                window.contentRect(forFrameRect: window.frame).size,
                MainWindowPresenter.minimumContentSize,
                "A saved 500×400 frame opens at the 840×580 minimum, not below it"
            )
        }
    }

    @MainActor
    func testNavigationWaitsWhileASheetIsOpen() throws {
        try withController { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
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
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
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
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
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
            let hosting = NSHostingController(rootView: MainWindowView(
                controller: controller,
                navigation: navigation,
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
}
