import AppKit
import XCTest
@testable import ScrumTrace

final class MenuAccessTests: XCTestCase {
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
            let presenter = SettingsWindowPresenter(controller: controller)
            defer { presenter.window?.close() }
            let menuBar = MenuBarController(
                controller: controller,
                openSettings: { presenter.show() },
                openLogs: { presenter.show(tab: .logs) }
            )
            let settings = try XCTUnwrap(menuBar.menu.item(withTitle: "Settings")?.submenu)
            settings.performActionForItem(at: settings.indexOfItem(withTitle: "Settings Window…"))
            let window = try XCTUnwrap(presenter.window)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(presenter.navigation.selectedTab, .speech)
            window.close()
            XCTAssertFalse(window.isVisible)
            settings.performActionForItem(at: settings.indexOfItem(withTitle: "Agent Log…"))
            XCTAssertTrue(presenter.window === window)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(presenter.navigation.selectedTab, .logs)
            window.miniaturize(nil)
            presenter.show()
            XCTAssertFalse(window.isMiniaturized)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(presenter.navigation.selectedTab, .logs)
        }
    }

    @MainActor
    func testAllSixSettingsTabsRemainInTheSameWindow() throws {
        try withController { controller in
            let presenter = SettingsWindowPresenter(controller: controller)
            defer { presenter.window?.close() }
            presenter.show()
            let window = try XCTUnwrap(presenter.window)
            XCTAssertEqual(SettingsTab.allCases.count, 6)
            for tab in SettingsTab.allCases {
                presenter.show(tab: tab)
                XCTAssertEqual(presenter.navigation.selectedTab, tab)
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
            XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Retry analysis")).isEnabled)
            let area = try XCTUnwrap(menu.items.first(where: { $0.title.hasPrefix("Capture area:") })?.submenu)
            area.update()
            XCTAssertFalse(area.autoenablesItems)
            XCTAssertFalse(try XCTUnwrap(area.item(withTitle: "Select area on screen…")).isEnabled)
            let settings = try XCTUnwrap(menu.item(withTitle: "Settings")?.submenu)
            settings.update()
            XCTAssertFalse(settings.autoenablesItems)
            XCTAssertFalse(try XCTUnwrap(settings.item(withTitle: "Relaunch ScrumTrace")).isEnabled)
            XCTAssertTrue(try XCTUnwrap(settings.item(withTitle: "Settings Window…")).isEnabled)
            XCTAssertTrue(try XCTUnwrap(settings.item(withTitle: "Agent Log…")).isEnabled)
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
            let settings = try XCTUnwrap(menu.item(withTitle: "Settings")?.submenu)
            settings.update()
            XCTAssertFalse(try XCTUnwrap(settings.item(withTitle: "Relaunch ScrumTrace")).isEnabled)
        }
    }
}
