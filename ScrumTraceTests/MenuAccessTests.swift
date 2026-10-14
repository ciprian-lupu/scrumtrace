import AppKit
import XCTest
@testable import ScrumTrace

final class MenuAccessTests: XCTestCase {
    @MainActor
    func testRecordingOutcomesDistinguishInactiveStagesAndAvailableExports() throws {
        try withController { controller in
            var manifest = try controller.vault.createSession(product: .empty).manifest
            for status in [PipelineStatus.transcribing, .slicing, .evaluating, .synthesizing] {
                manifest.pipelineStatus = status
                XCTAssertTrue(MenuBarController.recordingLabel(manifest).hasSuffix("Incomplete · retry"))
                XCTAssertTrue(MenuBarController.recordingLabel(manifest, isActive: true).hasSuffix(PipelineStatusOrder.label(status)))
            }
            for status in [PipelineStatus.recording, .paused] {
                XCTAssertEqual(RecordingStatusText.label(status), "Interrupted")
                XCTAssertEqual(RecordingStatusText.label(status, isActive: true), PipelineStatusOrder.label(status))
            }
            manifest.pipelineStatus = .offlineFailed
            manifest.markCompleted(.synthesizing)
            try controller.vault.write(manifest: &manifest)
            let missing = SessionSummary(manifest: manifest, exportProbe: SessionExportProbe())
            XCTAssertEqual(RecordingStatusText.label(missing), "Needs attention")
            XCTAssertFalse(RecordingRowText.unfinishedNote(missing).contains("export is ready"))
            let ready = SessionSummary(manifest: manifest, exportProbe: SessionExportProbe(hasAgentContext: true, hasBrief: true))
            XCTAssertEqual(RecordingStatusText.label(ready), "Export ready · AI failed")
            XCTAssertTrue(RecordingRowText.unfinishedNote(ready).contains("local export is ready"))
            manifest.completedStages = []
            XCTAssertEqual(RecordingStatusText.label(SessionSummary(manifest: manifest,
                exportProbe: SessionExportProbe(hasAgentContext: true, hasBrief: true))), "Needs attention")

            let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {})
            @MainActor func recentTitle() throws -> String {
                menuBar.menuWillOpen(menuBar.menu)
                return try XCTUnwrap(menuBar.menu.item(withTitle: "Recent recordings")?.submenu?.items.first?.title)
            }
            XCTAssertTrue(try recentTitle().hasSuffix("Needs attention"))
            let url = controller.vault.sessionURL(id: manifest.sessionId)
            for relative in [ScrumTracePath.agentContext, ScrumTracePath.sessionBrief] {
                try ExportRel.writeContainedData(Data("fixture".utf8), relative: relative, sessionURL: url)
            }
            XCTAssertTrue(try recentTitle().hasSuffix("Export ready · AI failed"))
            XCTAssertEqual(RecordingStatusText.label(.completed), "Completed")
        }
    }

    @MainActor
    private func withController(_ body: (SessionController) throws -> Void) throws {
        let id = "ScrumTrace.MenuAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: SessionVault(rootURL: root))
        try body(controller)
    }

    func testUpdateCheckDistinguishesUnpublishedAndFailedReleases() {
        let payload = Data(#"{"tag_name":"v1.2.0"}"#.utf8)
        XCTAssertEqual(UpdateChecker.interpret(data: Data(), statusCode: 404, current: "1.0.0"), .noPublishedReleases(current: "1.0.0"))
        XCTAssertEqual(UpdateChecker.interpret(data: payload, statusCode: 200, current: "1.0.0"), .newerAvailable(current: "1.0.0", latest: "1.2.0"))
        XCTAssertEqual(UpdateChecker.interpret(data: payload, statusCode: 200, current: "1.2.0"), .upToDate(current: "1.2.0"))
        guard case .failed = UpdateChecker.interpret(data: payload, statusCode: 403, current: "1.0.0") else {
            return XCTFail("A failed HTTP request must not claim the app is current")
        }
    }

    @MainActor
    func testSettingsAndLogsActionsOpenAndReuseTheWindow() throws {
        try withController { controller in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
            defer { presenter.window?.close() }
            let menuBar = MenuBarController(
                controller: controller,
                openSettings: { presenter.show(section: .settings) },
                openLogs: { presenter.show(tab: .logs) }
            )
            let menu = menuBar.menu
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Settings…"))
            let window = try XCTUnwrap(presenter.window)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(presenter.navigation.section, .settings)
            XCTAssertEqual(presenter.navigation.settings.selectedTab, .speech)
            window.close()
            XCTAssertFalse(window.isVisible)
            let diagnostics = try XCTUnwrap(menu.item(withTitle: "Diagnostics")?.submenu)
            diagnostics.performActionForItem(at: diagnostics.indexOfItem(withTitle: "View logs…"))
            XCTAssertTrue(presenter.window === window)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(presenter.navigation.section, .settings)
            XCTAssertEqual(presenter.navigation.settings.selectedTab, .logs)
            // macOS 15 finishes ordering in, minimizing and restoring asynchronously; wait for each state
            // instead of reading it at once.
            let settleDeadline = Date().addingTimeInterval(5)
            while (!window.isVisible || window.isMiniaturized) && Date() < settleDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            window.miniaturize(nil)
            let miniaturizeDeadline = Date().addingTimeInterval(5)
            while !window.isMiniaturized && Date() < miniaturizeDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(window.isMiniaturized, "The window must be miniaturized before show()")
            presenter.show()
            let restoreDeadline = Date().addingTimeInterval(5)
            while (window.isMiniaturized || !window.isVisible) && Date() < restoreDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            XCTAssertFalse(window.isMiniaturized, "show() restores a minimized window")
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(presenter.navigation.section, .settings)
            XCTAssertEqual(presenter.navigation.settings.selectedTab, .logs)
        }
    }

    @MainActor
    func testAllSixSettingsTabsRemainInTheSameWindow() throws {
        try withController { controller in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
            defer { presenter.window?.close() }
            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            XCTAssertEqual(SettingsTab.allCases.count, 6)
            for tab in SettingsTab.allCases {
                presenter.show(tab: tab)
                XCTAssertEqual(presenter.navigation.section, .settings)
                XCTAssertEqual(presenter.navigation.settings.selectedTab, tab)
                XCTAssertTrue(presenter.window === window)
                XCTAssertTrue(window.isVisible)
            }
        }
    }

    @MainActor
    func testAppKitCannotReenableBusyActions() throws {
        try withController { controller in
            controller.isBusy = true
            controller.lastSessionId = "test-session"
            let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {})
            let menu = menuBar.menu
            menu.update()
            XCTAssertFalse(menu.autoenablesItems)
            XCTAssertFalse(try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Start recording") })).isEnabled)
            let last = try XCTUnwrap(menu.item(withTitle: "Last recording")?.submenu)
            last.update()
            XCTAssertFalse(last.autoenablesItems)
            XCTAssertFalse(try XCTUnwrap(last.item(withTitle: "Retry analysis")).isEnabled)
            XCTAssertFalse(try XCTUnwrap(last.item(withTitle: "Compare transcriptions")).isEnabled)
            XCTAssertFalse(try XCTUnwrap(last.item(withTitle: "Open archive in Codex…")).isEnabled)
            let area = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Capture area:") })?.submenu)
            area.update()
            XCTAssertFalse(area.autoenablesItems)
            XCTAssertFalse(try XCTUnwrap(area.item(withTitle: "Select area on screen…")).isEnabled)
            let diagnostics = try XCTUnwrap(menu.item(withTitle: "Diagnostics")?.submenu)
            diagnostics.update()
            XCTAssertFalse(diagnostics.autoenablesItems)
            XCTAssertFalse(try XCTUnwrap(diagnostics.item(withTitle: "Relaunch ScrumTrace")).isEnabled)
            XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Settings…")).isEnabled)
            XCTAssertTrue(try XCTUnwrap(diagnostics.item(withTitle: "View logs…")).isEnabled)
            let retrySession = controller.lastSessionId
            controller.retryAnalysis(sessionId: "another-session")
            XCTAssertEqual(controller.lastSessionId, retrySession)
            controller.isBusy = false
            menuBar.menuWillOpen(menu)
            XCTAssertTrue(try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Start recording") })).isEnabled)
            menuBar.menuDidClose(menu)
        }
    }

    @MainActor
    func testPausedCaptureDisablesNewEvidenceAndRelaunch() throws {
        try withController { controller in
            controller.phase = .paused
            let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {})
            let menu = menuBar.menu
            menu.update()
            XCTAssertFalse(controller.canChangeCaptureSettings)
            XCTAssertFalse(try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Shot  ") })).isEnabled)
            XCTAssertFalse(try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Pin  ") })).isEnabled)
            XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Stop & process")).isEnabled)
            let diagnostics = try XCTUnwrap(menu.item(withTitle: "Diagnostics")?.submenu)
            diagnostics.update()
            XCTAssertFalse(try XCTUnwrap(diagnostics.item(withTitle: "Relaunch ScrumTrace")).isEnabled)
        }
    }

    @MainActor
    func testCompactMenuKeepsAdvancedActionsGroupedAndLibraryAccessibleWhenEmpty() throws {
        try withController { controller in
            var openedLibrary = 0
            let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {},
                openRecordings: { openedLibrary += 1 })
            let menu = menuBar.menu
            XCTAssertLessThanOrEqual(menu.items.filter { !$0.isSeparatorItem }.count, 11)
            XCTAssertNil(menu.item(withTitle: "Retry analysis"))
            XCTAssertNil(menu.item(withTitle: "Compare transcriptions"))
            XCTAssertNil(menu.item(withTitle: "Export diagnostic bundle"))
            XCTAssertNil(menu.item(withTitle: "Settings Window…"))
            XCTAssertNotNil(menu.item(withTitle: "Settings…")?.action)
            XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Last recording")).isEnabled)
            let recent = try XCTUnwrap(menu.item(withTitle: "Recent recordings")?.submenu)
            XCTAssertNotNil(recent.item(withTitle: "No recordings yet"))
            recent.performActionForItem(at: recent.indexOfItem(withTitle: "Show all recordings…"))
            XCTAssertEqual(openedLibrary, 1)
        }
    }

    @MainActor
    func testRecentRecordingsUseOnlyMetadataAndBindActionsToTheRightRecording() throws {
        try withController { controller in
            var sessions: [SessionManifest] = []
            for index in 0..<6 {
                var manifest = try controller.vault.createSession(product: .empty).manifest
                manifest.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60))
                manifest.duration.mediaSeconds = 125
                manifest.productContext.appName = "PRIVATE-CONTEXT-NOT-FOR-MENU"
                try controller.vault.write(manifest: &manifest)
                sessions.append(manifest)
            }
            controller.lastSessionId = sessions.last?.sessionId
            let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {})
            let recent = try XCTUnwrap(menuBar.menu.item(withTitle: "Recent recordings")?.submenu)
            let rows = recent.items.filter { $0.submenu != nil }
            XCTAssertEqual(rows.count, 5)
            for (row, session) in zip(rows, sessions.reversed()) {
                XCTAssertTrue(row.title.contains("02:05"))
                XCTAssertFalse(row.title.contains(session.sessionId))
                XCTAssertFalse(row.title.contains(session.productContext.appName))
                let submenu = try XCTUnwrap(row.submenu)
                XCTAssertFalse(submenu.autoenablesItems)
                for item in submenu.items where item.action != nil {
                    XCTAssertEqual(item.representedObject as? String, session.sessionId)
                }
            }
            var invalid = sessions[0]
            invalid.duration.mediaSeconds = .infinity
            XCTAssertTrue(MenuBarController.recordingLabel(invalid).contains(" · — · "))
        }
    }

    @MainActor
    func testBriefActionUsesExportAndRejectsArchiveLinks() throws {
        try withController { controller in
            let session = try controller.vault.createSession(product: .empty)
            let id = session.manifest.sessionId
            controller.lastSessionId = id
            try ExportRel.writeContainedData(Data("<html>fixture</html>".utf8), relative: ScrumTracePath.sessionBrief, sessionURL: session.url)
            let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {})
            var opened: [URL] = []
            menuBar.openBriefURL = { opened.append($0); return true }
            let last = try XCTUnwrap(menuBar.menu.item(withTitle: "Last recording")?.submenu)
            XCTAssertTrue(try XCTUnwrap(last.item(withTitle: "Open brief")).isEnabled)
            last.performActionForItem(at: last.indexOfItem(withTitle: "Open brief"))
            XCTAssertEqual(opened, [session.url.appendingPathComponent(ScrumTracePath.sessionBrief)])
            let brief = session.url.appendingPathComponent(ScrumTracePath.sessionBrief)
            try FileManager.default.removeItem(at: brief)
            try FileManager.default.createSymbolicLink(at: brief, withDestinationURL: session.url.appendingPathComponent("archive/private.html"))
            menuBar.menuWillOpen(menuBar.menu)
            let refreshed = try XCTUnwrap(menuBar.menu.item(withTitle: "Last recording")?.submenu)
            XCTAssertFalse(try XCTUnwrap(refreshed.item(withTitle: "Open brief")).isEnabled)
            menuBar.menuDidClose(menuBar.menu)
        }
    }

    @MainActor
    func testProgressUpdatesInPlaceWhileSubmenusAreOpen() throws {
        try withController { controller in
            controller.isBusy = true
            controller.phase = .slicing
            controller.lastSessionId = "fixture"
            controller.reportProcessingProgress("Generating clips", fraction: 0.25)
            let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {})
            let menu = menuBar.menu
            menuBar.menuWillOpen(menu)
            let status = try XCTUnwrap(menu.items.first)
            let last = try XCTUnwrap(menu.item(withTitle: "Last recording"))
            controller.reportProcessingProgress("Generating clips", fraction: 0.5)
            let deadline = Date().addingTimeInterval(2)
            while !status.title.contains("50%") && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(status.title.contains("50%"))
            XCTAssertTrue(menu.items.first === status)
            XCTAssertTrue(menu.item(withTitle: "Last recording") === last)
            menuBar.menuDidClose(menu)
        }
    }
}
