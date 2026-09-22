import AppKit
import XCTest
@testable import ScrumTrace

final class RecordingHUDTests: XCTestCase {
    private typealias Layout = RecordingHUDLayout

    @MainActor
    private func withHUD(_ body: (RecordingHUDWindow, UserDefaults) throws -> Void) throws {
        let id = "ScrumTrace.RecordingHUDTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: SessionVault(rootURL: root))
        let hud = RecordingHUDWindow(controller: controller, defaults: defaults)
        hud.isReleasedWhenClosed = false
        defer { hud.orderOut(nil) }
        try body(hud, defaults)
    }

    func testScaleIsClampedToTheAllowedRange() {
        XCTAssertEqual(Layout.scale(forHeight: Layout.baseSize.height), 1, accuracy: 0.0001)
        XCTAssertEqual(Layout.scale(forHeight: Layout.baseSize.height * 2), 2, accuracy: 0.0001)
        XCTAssertEqual(Layout.scale(forHeight: 1), Layout.minScale, accuracy: 0.0001)
        XCTAssertEqual(Layout.scale(forHeight: 10_000), Layout.maxScale, accuracy: 0.0001)
        XCTAssertEqual(Layout.minSize().height, Layout.baseSize.height * Layout.minScale, accuracy: 0.0001)
        XCTAssertEqual(Layout.maxSize().width, Layout.baseSize.width * Layout.maxScale, accuracy: 0.0001)
    }

    func testDefaultFrameSitsAtTheTopCentreOfTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1055)
        let frame = Layout.defaultFrame(on: screen)
        XCTAssertEqual(frame.midX, 960, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, screen.maxY - Layout.topInset, accuracy: 0.5)
        XCTAssertEqual(frame.size, Layout.baseSize)
    }

    func testSavedFrameIsReusedOnlyWhileItIsStillOnAScreen() {
        let main = NSRect(x: 0, y: 0, width: 1920, height: 1055)
        let second = NSRect(x: 1920, y: 0, width: 1440, height: 900)
        let dragged = NSRect(x: 2000, y: 100, width: 720, height: 52)
        XCTAssertEqual(Layout.restoredFrame(saved: dragged, screens: [main, second]), dragged, "A frame on the second display comes back")
        XCTAssertNil(Layout.restoredFrame(saved: dragged, screens: [main]), "Unplugging that display falls back to the default place")
        let mostlyOff = NSRect(x: -700, y: 100, width: 720, height: 52)
        XCTAssertNil(Layout.restoredFrame(saved: mostlyOff, screens: [main]), "A sliver is not enough to grab")
        let edge = NSRect(x: -600, y: 100, width: 720, height: 52)
        XCTAssertNotNil(Layout.restoredFrame(saved: edge, screens: [main]))
        XCTAssertNil(Layout.restoredFrame(saved: nil, screens: [main]))
        XCTAssertNil(Layout.restoredFrame(saved: .zero, screens: [main]))
    }

    func testSavedFrameIsRenormalisedToTheAspectLockedSize() throws {
        let main = NSRect(x: 0, y: 0, width: 1920, height: 1055)
        let stretched = NSRect(x: 100, y: 100, width: 300, height: 104)
        let restored = try XCTUnwrap(Layout.restoredFrame(saved: stretched, screens: [main]))
        XCTAssertEqual(restored.height, 104, accuracy: 0.5)
        XCTAssertEqual(restored.width, Layout.baseSize.width * 2, accuracy: 0.5, "Height wins; width follows the locked ratio")
        let tiny = NSRect(x: 100, y: 100, width: 10, height: 10)
        let clamped = try XCTUnwrap(Layout.restoredFrame(saved: tiny, screens: [main]))
        XCTAssertEqual(clamped.size, Layout.minSize())
    }

    func testMinifiedAndExpandedFramesShareTopEdgeAndCentre() {
        let expanded = NSRect(x: 600, y: 900, width: 720, height: 52)
        let pill = Layout.minifiedFrame(expanded: expanded, width: 150)
        XCTAssertEqual(pill.width, 150)
        XCTAssertEqual(pill.height, expanded.height)
        XCTAssertEqual(pill.midX, expanded.midX, accuracy: 0.5)
        XCTAssertEqual(pill.maxY, expanded.maxY, accuracy: 0.5)
        let moved = pill.offsetBy(dx: -300, dy: -200)
        let back = Layout.expandedFrame(minified: moved, scale: 1)
        XCTAssertEqual(back.size, Layout.baseSize)
        XCTAssertEqual(back.midX, moved.midX, accuracy: 0.5)
        XCTAssertEqual(back.maxY, moved.maxY, accuracy: 0.5)
        let bigger = Layout.expandedFrame(minified: moved, scale: 1.5)
        XCTAssertEqual(bigger.width, Layout.baseSize.width * 1.5, accuracy: 0.5)
    }

    func testFrameEncodingRoundTrips() {
        let frame = NSRect(x: 12.5, y: 700, width: 864, height: 62.4)
        let decoded = Layout.decode(Layout.encode(frame))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.minX ?? 0, frame.minX, accuracy: 0.01)
        XCTAssertEqual(decoded?.height ?? 0, frame.height, accuracy: 0.01)
        XCTAssertNil(Layout.decode(nil))
        XCTAssertNil(Layout.decode(""))
        XCTAssertNil(Layout.decode("garbage"))
    }

    @MainActor
    func testPanelStaysNonActivatingWhileResizableAndDraggable() throws {
        try withHUD { hud, _ in
            XCTAssertTrue(hud.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(hud.styleMask.contains(.resizable), "Edges resize the pill")
            XCTAssertTrue(hud.styleMask.contains(.borderless))
            XCTAssertFalse(hud.canBecomeKey)
            XCTAssertFalse(hud.canBecomeMain)
            XCTAssertFalse(hud.isMovableByWindowBackground, "The content view drags the panel itself so a double-click can minify it")
            XCTAssertEqual(hud.minSize, Layout.minSize())
            XCTAssertEqual(hud.maxSize, Layout.maxSize())
            XCTAssertEqual(hud.aspectRatio, Layout.baseSize, "Resizing keeps the pill's proportions")
            XCTAssertFalse(hud.isMinified)
            XCTAssertEqual(hud.scale, 1, accuracy: 0.0001)
        }
    }

    @MainActor
    func testShowingRestoresTheRememberedFrameAndStartsExpanded() throws {
        try withHUD { hud, defaults in
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                throw XCTSkip("No display")
            }
            let visible = screen.visibleFrame
            let saved = NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 864, height: 62.4)
            defaults.set(Layout.encode(saved), forKey: Layout.frameKey)

            hud.setVisible(true)
            XCTAssertTrue(hud.isVisible)
            XCTAssertEqual(hud.frame.minX, saved.minX, accuracy: 1)
            XCTAssertEqual(hud.frame.minY, saved.minY, accuracy: 1)
            XCTAssertEqual(hud.frame.height, saved.height, accuracy: 1)
            XCTAssertEqual(hud.scale, 1.2, accuracy: 0.01, "Chrome scales with the remembered height")
            XCTAssertFalse(hud.isMinified)

            hud.setMinified(true)
            XCTAssertTrue(hud.isMinified)
            XCTAssertFalse(hud.styleMask.contains(.resizable), "The pill is not resizable while minified")
            XCTAssertLessThan(hud.frame.width, saved.width / 2, "Minified shows the dot and clock only")
            XCTAssertEqual(hud.frame.maxY, saved.maxY, accuracy: 1, "Top edge stays put")
            XCTAssertEqual(hud.frame.midX, saved.midX, accuracy: 1, "Centre stays put")

            // Repeated syncs from the menu-bar timer neither move nor expand it.
            hud.setVisible(true)
            hud.refresh()
            XCTAssertTrue(hud.isMinified)
            XCTAssertLessThan(hud.frame.width, saved.width / 2)

            hud.setMinified(false)
            XCTAssertFalse(hud.isMinified)
            XCTAssertTrue(hud.styleMask.contains(.resizable))
            XCTAssertEqual(hud.frame.width, saved.width, accuracy: 1)
            XCTAssertEqual(hud.frame.minX, saved.minX, accuracy: 1)
            XCTAssertEqual(hud.frame.maxY, saved.maxY, accuracy: 1)
            XCTAssertEqual(Layout.decode(defaults.string(forKey: Layout.frameKey))?.minX ?? -1, saved.minX, accuracy: 1)

            hud.setMinified(true)
            hud.setVisible(false)
            XCTAssertFalse(hud.isVisible)
            hud.setVisible(true)
            XCTAssertFalse(hud.isMinified, "Every recording starts with Stop in reach")
            XCTAssertEqual(hud.frame.width, saved.width, accuracy: 1)
        }
    }

    @MainActor
    func testAnOffScreenMemoryFallsBackToTheTopCentre() throws {
        try withHUD { hud, defaults in
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                throw XCTSkip("No display")
            }
            defaults.set(Layout.encode(NSRect(x: -100_000, y: -100_000, width: 720, height: 52)), forKey: Layout.frameKey)
            hud.setVisible(true)
            let expected = Layout.defaultFrame(on: screen.visibleFrame)
            XCTAssertEqual(hud.frame.midX, expected.midX, accuracy: 1)
            XCTAssertEqual(hud.frame.maxY, expected.maxY, accuracy: 1)
            XCTAssertEqual(hud.frame.size.width, Layout.baseSize.width, accuracy: 1)
        }
    }
}
