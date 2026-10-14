import AppKit
import XCTest
@testable import ScrumTrace

/// The floating processing panel: the HUD's focus rules, visibility that follows the controller, rows and buttons
/// that follow the status, and a PNG for a visual check when SCRUMTRACE_SNAPSHOT_DIR is set.
final class ProcessingPanelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    private func withPanel(_ body: @MainActor (ProcessingPanelWindow, SessionController, UserDefaults) throws -> Void) throws {
        let id = "ScrumTrace.ProcessingPanelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: SessionVault(rootURL: root))
        let panel = ProcessingPanelWindow(controller: controller, defaults: defaults)
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil) }
        try body(panel, controller, defaults)
    }

    private func loadingStatus() -> ProcessingStatus {
        var status = ProcessingStatus(
            sessionId: "2026-09-22-1255-8f816e",
            recordedAt: t0.addingTimeInterval(-21 * 24 * 3600),
            mediaSeconds: 23,
            origin: .launchResume,
            history: ProcessingTimingHistory(modelLoadSeconds: [592.4, 686.5, 4.6], transcribeRates: [25], stageSeconds: [:]),
            startedAt: t0
        )
        status.enter(.loadingModel, at: t0.addingTimeInterval(1))
        status.now = t0.addingTimeInterval(95)
        return status
    }

    func testLayoutKeepsThePanelOnAScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1055)
        let size = NSSize(width: ProcessingPanelLayout.width, height: 260)
        let frame = ProcessingPanelLayout.defaultFrame(on: screen, size: size)
        XCTAssertEqual(frame.maxX, screen.maxX - ProcessingPanelLayout.sideInset, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, screen.maxY - ProcessingPanelLayout.topInset, accuracy: 0.5)
        let saved = NSRect(x: 100, y: 600, width: ProcessingPanelLayout.width, height: 200)
        let restored = ProcessingPanelLayout.restoredFrame(saved: saved, size: size, screens: [screen])
        XCTAssertEqual(restored?.minX, 100)
        XCTAssertEqual(restored?.maxY ?? 0, saved.maxY, accuracy: 0.5, "The top edge is what is remembered; the height follows the content")
        XCTAssertEqual(restored?.height, 260)
        let offscreen = NSRect(x: 3000, y: 600, width: ProcessingPanelLayout.width, height: 200)
        XCTAssertNil(ProcessingPanelLayout.restoredFrame(saved: offscreen, size: size, screens: [screen]))
        XCTAssertNil(ProcessingPanelLayout.restoredFrame(saved: nil, size: size, screens: [screen]))
        XCTAssertNil(ProcessingPanelLayout.decode("garbage"))
        XCTAssertEqual(ProcessingPanelLayout.decode(ProcessingPanelLayout.encode(saved)), saved)
    }

    @MainActor
    func testPanelFollowsTheHUDFocusRules() throws {
        try withPanel { panel, _, _ in
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(panel.styleMask.contains(.borderless))
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertEqual(panel.sharingType, .none, "Screen sharing never shows the panel")
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertTrue(panel.isFloatingPanel)
            XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
            // `isFloatingPanel` puts the panel at the floating level, as it does the pill; both sit above normal windows.
            XCTAssertGreaterThanOrEqual(panel.level.rawValue, NSWindow.Level.floating.rawValue)
            XCTAssertFalse(panel.isMovableByWindowBackground, "The content view drags the panel itself")
            @MainActor func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let content = try XCTUnwrap(panel.contentView)
            XCTAssertFalse(content.acceptsFirstResponder)
            let buttons = views(content).compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, 3)
            for button in buttons {
                XCTAssertTrue(button.refusesFirstResponder, "\(button.title)")
                XCTAssertTrue(button.acceptsFirstMouse(for: nil))
            }
            for field in views(content).compactMap({ $0 as? NSTextField }) {
                XCTAssertTrue(field.refusesFirstResponder)
                XCTAssertFalse(field.isEditable)
            }
        }
    }

    @MainActor
    func testPanelShowsTheRecordingItsStagesAndTheRightButtons() throws {
        try withPanel { panel, controller, _ in
            XCTAssertFalse(panel.isVisible)
            XCTAssertNil(panel.state)
            controller.setProcessingForTesting(loadingStatus())
            controller.isBusy = true
            panel.setVisible(controller.processingPanelShouldShow)
            XCTAssertTrue(panel.isVisible)
            let state = try XCTUnwrap(panel.state)
            XCTAssertTrue(state.title.hasPrefix("Processing the recording from "))
            XCTAssertTrue(state.title.hasSuffix(" · 00:23 recorded"))
            XCTAssertEqual(state.subtitle, "This recording never finished. ScrumTrace picked it up when it opened.")
            XCTAssertEqual(state.rows.map(\.state), [.done, .active, .pending, .pending, .pending, .pending, .pending])
            XCTAssertEqual(state.rows[1].elapsed, "01:34")
            XCTAssertEqual(state.rows[1].detail, "On this Mac a slow load took 9 min 52 s to 11 min 27 s and a fast one about 5 s (3 loads). The first load after a restart is usually the slow kind.")
            XCTAssertEqual(state.totalElapsed, "01:35")
            @MainActor func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let content = try XCTUnwrap(panel.contentView)
            let buttons = views(content).compactMap { $0 as? NSButton }
            let finishLater = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "processing.finishLater" })
            let retry = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "processing.retry" })
            let close = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "processing.close" })
            XCTAssertFalse(finishLater.isHidden)
            XCTAssertTrue(retry.isHidden)
            XCTAssertTrue(close.isHidden)
            let rows = views(content).compactMap { $0 as? ProcessingPanelRowView }
            XCTAssertEqual(rows.count, 7)
            XCTAssertEqual(rows.compactMap(\.row?.stage), ProcessingStage.allCases, "Rows in pipeline order")
            XCTAssertGreaterThan(panel.frame.height, 200, "The panel fits its rows")
            XCTAssertEqual(panel.frame.width, ProcessingPanelLayout.width)
            XCTAssertEqual(panel.frame.minY + panel.frame.height, panel.frame.maxY)

            // Finish later on the panel is the controller's; with no run to cancel it changes nothing.
            finishLater.performClick(nil)
            XCTAssertEqual(controller.processing?.outcome, .running)

            var failed = loadingStatus()
            failed.finish(.failed("Whisper model load timed out after 12 minutes. Check the network or pick a smaller model in Settings."), at: t0.addingTimeInterval(721))
            controller.setProcessingForTesting(failed)
            controller.isBusy = false
            panel.setVisible(controller.processingPanelShouldShow)
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.state?.rows[1].state, .failed)
            XCTAssertTrue(finishLater.isHidden)
            XCTAssertFalse(retry.isHidden)
            XCTAssertFalse(close.isHidden)
            XCTAssertEqual(panel.state?.footer, "Whisper model load timed out after 12 minutes. Check the network or pick a smaller model in Settings.")

            close.performClick(nil)
            XCTAssertNil(controller.processing, "Close dismisses an ended run")
            panel.setVisible(controller.processingPanelShouldShow)
            XCTAssertFalse(panel.isVisible)
        }
    }

    @MainActor
    func testPanelRemembersWhereItWasPut() throws {
        try withPanel { panel, controller, defaults in
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { throw XCTSkip("No display") }
            let visible = screen.visibleFrame
            let saved = NSRect(x: visible.minX + 60, y: visible.minY + 80, width: ProcessingPanelLayout.width, height: 240)
            defaults.set(ProcessingPanelLayout.encode(saved), forKey: ProcessingPanelLayout.frameKey)
            controller.setProcessingForTesting(loadingStatus())
            controller.isBusy = true
            panel.setVisible(true)
            XCTAssertEqual(panel.frame.minX, saved.minX, accuracy: 1)
            XCTAssertEqual(panel.frame.maxY, saved.maxY, accuracy: 1, "The remembered top edge")
            panel.setVisible(true)
            panel.refresh()
            XCTAssertEqual(panel.frame.minX, saved.minX, accuracy: 1, "Repeated syncs do not move it")
            panel.setFrameOrigin(NSPoint(x: visible.minX + 100, y: visible.minY + 100))
            XCTAssertEqual(ProcessingPanelLayout.decode(defaults.string(forKey: ProcessingPanelLayout.frameKey))?.minX ?? 0, visible.minX + 100, accuracy: 1)
        }
    }

    /// Writes `processing-panel-<state>.png` for a human visual review when SCRUMTRACE_SNAPSHOT_DIR is set.
    @MainActor
    func testRenderPanelStatesForReview() throws {
        guard let path = ProcessInfo.processInfo.environment["SCRUMTRACE_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set SCRUMTRACE_SNAPSHOT_DIR (TEST_RUNNER_SCRUMTRACE_SNAPSHOT_DIR through xcodebuild) to render the processing panel")
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try withPanel { panel, controller, _ in
            var transcribing = loadingStatus()
            transcribing.enter(.transcribing, at: t0.addingTimeInterval(600))
            transcribing.update(progress: .audioSeconds(done: 9, total: 23))
            transcribing.now = t0.addingTimeInterval(604)
            var deferred = loadingStatus()
            deferred.finish(.deferred, at: t0.addingTimeInterval(120))
            var done = transcribing
            done.enter(.slicing, at: t0.addingTimeInterval(606))
            done.update(progress: .count(done: 3, total: 3, unit: "clips"))
            done.skip(.evaluating, reason: "consent", at: t0.addingTimeInterval(609))
            done.enter(.packaging, at: t0.addingTimeInterval(609))
            done.finish(.done("Session pack ready"), at: t0.addingTimeInterval(612))
            var failed = transcribing
            failed.finish(.failed("session.mp4 is missing."), at: t0.addingTimeInterval(605))
            for (name, status, busy) in [("loading", loadingStatus(), true), ("transcribing", transcribing, true), ("deferred", deferred, false), ("done", done, false), ("failed", failed, false)] {
                controller.setProcessingForTesting(status)
                controller.isBusy = busy
                panel.setVisible(true)
                panel.refresh()
                let content = try XCTUnwrap(panel.contentView)
                content.layoutSubtreeIfNeeded()
                if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("processing-panel-\(name).png"))
                }
            }
            controller.isBusy = false
        }
    }
}
