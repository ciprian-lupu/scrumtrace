import AppKit
import XCTest
@testable import ScrumTrace

/// Display selection: identity is the display id, the overlay confirms the screen it covers, and nothing
/// falls back to another display.
final class CaptureDisplayTests: XCTestCase {
    private let builtIn = DisplayCandidate(id: 1, name: "Built-in Retina Display", width: 1728, height: 1117, isMain: true)
    private let dell = DisplayCandidate(id: 2, name: "DELL U2720Q", width: 2560, height: 1440, isMain: false)
    private let dellTwin = DisplayCandidate(id: 3, name: "DELL U2720Q", width: 2560, height: 1440, isMain: false)

    func testResolverMatchesIdsOnly() {
        let all = [builtIn, dell, dellTwin]
        XCTAssertEqual(CaptureDisplayResolver.resolve(.entireDisplay, among: all), .display(1))
        XCTAssertEqual(CaptureDisplayResolver.resolve(.fullDisplay(id: 2, name: "DELL U2720Q"), among: all), .display(2))
        // Same name, different id: a reconnected monitor is never matched by its label.
        XCTAssertEqual(CaptureDisplayResolver.resolve(.fullDisplay(id: 9, name: "DELL U2720Q"), among: all), .missing)
        XCTAssertEqual(CaptureDisplayResolver.resolve(.fullDisplay(id: 2, name: "DELL U2720Q"), among: []), .missing)
        // "Main display" needs a main candidate; there is no "first display" fallback.
        XCTAssertEqual(CaptureDisplayResolver.resolve(.entireDisplay, among: [dell, dellTwin]), .missing)
        let region = CaptureArea(
            capturesFullDisplay: false, displayID: 3, originX: 10, originY: 10,
            widthPoints: 640, heightPoints: 360, backingScale: 2, displayName: "DELL U2720Q"
        )
        XCTAssertEqual(CaptureDisplayResolver.resolve(region, among: all), .display(3))
        XCTAssertEqual(CaptureDisplayResolver.resolve(region, among: [builtIn, dell]), .missing)
    }

    func testPinnedDisplayIDFollowsTheChoice() {
        XCTAssertEqual(CaptureDisplayResolver.pinnedDisplayID(for: .entireDisplay, mainID: 77), 77)
        XCTAssertEqual(CaptureDisplayResolver.pinnedDisplayID(for: .fullDisplay(id: 2, name: "x"), mainID: 77), 2)
    }

    func testCaptureAreaSummariesAndCoding() throws {
        XCTAssertTrue(CaptureArea.entireDisplay.targetsMainDisplay)
        XCTAssertEqual(CaptureArea.entireDisplay.summary, "Main display")
        let named = CaptureArea.fullDisplay(id: 2, name: "DELL U2720Q")
        XCTAssertTrue(named.isEntireDisplay)
        XCTAssertFalse(named.targetsMainDisplay)
        XCTAssertEqual(named.summary, "Display: DELL U2720Q")
        XCTAssertEqual(CaptureArea.fullDisplay(id: 5, name: "").summary, "Display 5")
        // Settings saved before display selection existed carry no display_name and must still decode.
        let legacy = Data("""
        {"captures_full_display":false,"display_id":7,"origin_x":100,"origin_y":40,"width_points":640,"height_points":360,"backing_scale":2}
        """.utf8)
        let decoded = try JSONDecoder().decode(CaptureArea.self, from: legacy)
        XCTAssertEqual(decoded.displayID, 7)
        XCTAssertNil(decoded.displayName)
        XCTAssertEqual(decoded.summary, "640×360 region")
        let roundTrip = try JSONDecoder().decode(CaptureArea.self, from: JSONEncoder().encode(named))
        XCTAssertEqual(roundTrip, named)
    }

    @MainActor
    func testAppSettingsRestoresLegacyCaptureAreaBlob() throws {
        let suite = "ScrumTrace.CaptureDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data("""
        {"captures_full_display":false,"display_id":7,"origin_x":100,"origin_y":40,"width_points":640,"height_points":360,"backing_scale":2}
        """.utf8)
        defaults.set(legacy, forKey: "scrumtrace.captureArea")
        let settings = AppSettings(defaults: defaults, keyStore: .empty)
        XCTAssertEqual(settings.captureArea.displayID, 7, "A legacy blob must not reset to the main display")
        XCTAssertFalse(settings.captureArea.isEntireDisplay)
        settings.connectedDisplays = [builtIn, dell]
        XCTAssertEqual(settings.savedDisplayNotConnected?.displayID, 7)
        settings.selectDisplay(id: 2)
        XCTAssertEqual(settings.captureArea, .fullDisplay(id: 2, name: "DELL U2720Q"))
        XCTAssertNil(settings.savedDisplayNotConnected)
        XCTAssertEqual(settings.selectedDisplayID, 2)
        settings.recordSingleWindow = true
        XCTAssertEqual(settings.selectedDisplayID, 0)
        settings.selectDisplay(id: 0)
        XCTAssertEqual(settings.captureArea, .entireDisplay)
        XCTAssertFalse(settings.recordSingleWindow)
    }

    func testCaptureLayoutDecodesWithoutDisplayFields() throws {
        let old = Data(#"{"microphone_wav":true,"system_audio_in_movie":true}"#.utf8)
        let layout = try JSONDecoder().decode(CaptureAudioLayout.self, from: old)
        XCTAssertTrue(layout.microphoneWav)
        XCTAssertNil(layout.displayID)
        XCTAssertNil(layout.captureWidth)
        let full = CaptureAudioLayout(
            microphoneWav: false, systemAudioInMovie: true, wavStartMediaSeconds: 1.5,
            displayID: 2, displayName: "DELL U2720Q", captureWidth: 2560, captureHeight: 1440
        )
        let back = try JSONDecoder().decode(CaptureAudioLayout.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(back, full)
        // Audio semantics are untouched by the display fields: a system-audio WAV still means no movie pass.
        XCTAssertFalse(back.shouldTranscribeMovie(wavExists: true, movieExists: true))
        XCTAssertTrue(back.shouldTranscribeMovie(wavExists: false, movieExists: true))
    }

    func testLabelsDistinguishIdenticalMonitors() {
        let all = [builtIn, dell, dellTwin]
        XCTAssertEqual(CaptureDisplayResolver.label(for: builtIn, among: all), "Built-in Retina Display (main)")
        XCTAssertEqual(CaptureDisplayResolver.label(for: dell, among: all), "DELL U2720Q 1")
        XCTAssertEqual(CaptureDisplayResolver.label(for: dellTwin, among: all), "DELL U2720Q 2")
        XCTAssertEqual(
            CaptureAreaPicker.screenLabel(name: "DELL U2720Q", width: 2560, height: 1440, duplicateIndex: 2, isMain: false),
            "DELL U2720Q 2 · 2560×1440 pt"
        )
        XCTAssertEqual(
            CaptureAreaPicker.screenLabel(name: "", width: 1728, height: 1117, duplicateIndex: nil, isMain: true),
            "Display · 1728×1117 pt (main)"
        )
    }

    func testOverlayStarterAndMissingNotice() {
        let ids: [UInt32] = [1, 2, 3]
        // A saved region wins, then the saved display, then the main display, then the first screen.
        XCTAssertEqual(CaptureAreaPicker.starterIndex(screenIDs: ids, regionIndex: 2, current: .entireDisplay, mainID: 1), 2)
        XCTAssertEqual(CaptureAreaPicker.starterIndex(screenIDs: ids, regionIndex: nil, current: .fullDisplay(id: 3, name: ""), mainID: 1), 2)
        XCTAssertEqual(CaptureAreaPicker.starterIndex(screenIDs: ids, regionIndex: nil, current: .entireDisplay, mainID: 2), 1)
        XCTAssertEqual(CaptureAreaPicker.starterIndex(screenIDs: ids, regionIndex: nil, current: .fullDisplay(id: 9, name: ""), mainID: 42), 0)
        XCTAssertNil(CaptureAreaPicker.starterIndex(screenIDs: [], regionIndex: nil, current: .entireDisplay, mainID: 1))
        XCTAssertNil(CaptureAreaPicker.missingDisplayNotice(current: .entireDisplay, connectedIDs: []))
        XCTAssertNil(CaptureAreaPicker.missingDisplayNotice(current: .fullDisplay(id: 2, name: "DELL"), connectedIDs: ids))
        XCTAssertEqual(
            CaptureAreaPicker.missingDisplayNotice(current: .fullDisplay(id: 9, name: "DELL U2720Q"), connectedIDs: ids),
            "DELL U2720Q is not connected. Pick a display."
        )
        XCTAssertEqual(
            CaptureAreaPicker.missingDisplayNotice(current: .fullDisplay(id: 9, name: ""), connectedIDs: ids),
            "The saved display is not connected. Pick a display."
        )
    }

    func testMetadataDisplayGate() {
        let display = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
        XCTAssertTrue(MetadataSampler.windowIsOnDisplay(windowFrame: CGRect(x: 2000, y: 100, width: 800, height: 600), displayBounds: display))
        XCTAssertFalse(MetadataSampler.windowIsOnDisplay(windowFrame: CGRect(x: 100, y: 100, width: 800, height: 600), displayBounds: display))
        // Spanning two displays: the one holding the centre.
        XCTAssertTrue(MetadataSampler.windowIsOnDisplay(windowFrame: CGRect(x: 1400, y: 100, width: 800, height: 600), displayBounds: display))
        XCTAssertFalse(MetadataSampler.windowIsOnDisplay(windowFrame: CGRect(x: 1300, y: 100, width: 800, height: 600), displayBounds: display))
        // Centre exactly on the left edge counts as inside; on the right edge it does not (CGRect.contains).
        XCTAssertTrue(MetadataSampler.windowIsOnDisplay(windowFrame: CGRect(x: 1628, y: 0, width: 200, height: 200), displayBounds: display))
        XCTAssertFalse(MetadataSampler.windowIsOnDisplay(windowFrame: CGRect(x: 4188, y: 0, width: 200, height: 200), displayBounds: display))
        XCTAssertFalse(MetadataSampler.windowIsOnDisplay(windowFrame: .zero, displayBounds: display))
        XCTAssertFalse(MetadataSampler.windowIsOnDisplay(windowFrame: CGRect(x: 2000, y: 100, width: 10, height: 10), displayBounds: .zero))
        let bounds: (UInt32) -> CGRect = { $0 == 2 ? display : .zero }
        XCTAssertTrue(MetadataSampler.displayGateAllows(windowFrame: nil, restrictedDisplayID: nil, bounds: bounds))
        XCTAssertFalse(MetadataSampler.displayGateAllows(windowFrame: nil, restrictedDisplayID: 2, bounds: bounds), "No frame, no proof the window is recorded")
        XCTAssertTrue(MetadataSampler.displayGateAllows(windowFrame: CGRect(x: 2000, y: 100, width: 10, height: 10), restrictedDisplayID: 2, bounds: bounds))
        XCTAssertFalse(MetadataSampler.displayGateAllows(windowFrame: CGRect(x: 2000, y: 100, width: 10, height: 10), restrictedDisplayID: 1, bounds: bounds))
        let sampler = MetadataSampler()
        XCTAssertNil(sampler.restrictedDisplayID)
        sampler.restrictedDisplayID = 2
        XCTAssertEqual(sampler.restrictedDisplayID, 2)
    }

    func testShotCropFailsInsteadOfWidening() throws {
        let image = try XCTUnwrap(makeImage(width: 10, height: 10))
        let outside = CaptureArea(
            capturesFullDisplay: false, displayID: 1, originX: 100, originY: 100,
            widthPoints: 4, heightPoints: 4, backingScale: 1
        )
        XCTAssertNil(ScreenSnap.crop(image, to: outside), "A region outside the image is not the whole image")
        let inside = CaptureArea(
            capturesFullDisplay: false, displayID: 1, originX: 2, originY: 2,
            widthPoints: 4, heightPoints: 4, backingScale: 1
        )
        let cropped = try XCTUnwrap(ScreenSnap.crop(image, to: inside))
        XCTAssertEqual(cropped.width, 4)
        XCTAssertEqual(cropped.height, 4)
        XCTAssertEqual(ScreenSnap.crop(image, to: .entireDisplay)?.width, 10)
    }

    @MainActor
    func testMenuListsDisplaysAndSelectionClearsWindowMode() throws {
        let id = "ScrumTrace.CaptureDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: SessionVault(rootURL: root))
        controller.settings.connectedDisplays = [builtIn, dell]
        controller.settings.recordSingleWindow = true
        let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {})
        func areaMenu() throws -> NSMenu {
            // Opening the menu rebuilds it from the current settings, as a click on the status item would.
            menuBar.menuWillOpen(menuBar.menu)
            menuBar.menuDidClose(menuBar.menu)
            let menu = try XCTUnwrap(menuBar.menu.items.first(where: { $0.title.hasPrefix("Capture area:") })?.submenu)
            menu.update()
            return menu
        }
        var area = try areaMenu()
        XCTAssertNil(area.item(withTitle: "Use entire display"))
        let main = try XCTUnwrap(area.item(withTitle: "Main display"))
        let builtInRow = try XCTUnwrap(area.item(withTitle: "Built-in Retina Display (main)"))
        let dellRow = try XCTUnwrap(area.item(withTitle: "DELL U2720Q"))
        XCTAssertTrue(main.isEnabled, "Main display can be chosen while single-window mode is on")
        XCTAssertEqual(main.state, .off)
        XCTAssertEqual(builtInRow.state, .off)
        XCTAssertEqual(dellRow.state, .off)
        area.performActionForItem(at: area.index(of: dellRow))
        XCTAssertEqual(controller.settings.captureArea, .fullDisplay(id: 2, name: "DELL U2720Q"))
        XCTAssertFalse(controller.settings.recordSingleWindow)
        area = try areaMenu()
        XCTAssertEqual(try XCTUnwrap(area.item(withTitle: "DELL U2720Q")).state, .on)
        XCTAssertEqual(try XCTUnwrap(area.item(withTitle: "Main display")).state, .off)
        XCTAssertTrue(try XCTUnwrap(area.item(withTitle: "Main display")).isEnabled, "A named display can be reset to Main")
        let start = try XCTUnwrap(menuBar.menu.item(withTitle: "Start recording…"))
        XCTAssertEqual(start.toolTip, "Start recording — Display: DELL U2720Q")
        XCTAssertNotNil(menuBar.menu.item(withTitle: "Capture area: Display: DELL U2720Q"))
        area.performActionForItem(at: area.index(of: try XCTUnwrap(area.item(withTitle: "Main display"))))
        XCTAssertEqual(controller.settings.captureArea, .entireDisplay)
        area = try areaMenu()
        XCTAssertEqual(try XCTUnwrap(area.item(withTitle: "Main display")).state, .on)
        XCTAssertFalse(try XCTUnwrap(area.item(withTitle: "Main display")).isEnabled)
        // A saved display that is gone is shown greyed, never silently replaced.
        controller.settings.captureArea = .fullDisplay(id: 9, name: "Gone Monitor")
        area = try areaMenu()
        let missing = try XCTUnwrap(area.item(withTitle: "Gone Monitor (not connected)"))
        XCTAssertFalse(missing.isEnabled)
        XCTAssertEqual(missing.state, .on)
        // Busy: no capture change from the menu.
        controller.isBusy = true
        area = try areaMenu()
        XCTAssertFalse(try XCTUnwrap(area.item(withTitle: "DELL U2720Q")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(area.item(withTitle: "Main display")).isEnabled)
        area.performActionForItem(at: area.index(of: try XCTUnwrap(area.item(withTitle: "DELL U2720Q"))))
        XCTAssertEqual(controller.settings.captureArea, .fullDisplay(id: 9, name: "Gone Monitor"))
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}
