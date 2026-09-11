import XCTest
@testable import ScrumTrace

final class TimelineTests: XCTestCase {
    func testSinglePauseMapping() {
        let pauses = [PauseInterval(pauseWall: 190, resumeWall: 205)]
        XCTAssertEqual(TimelineMath.mediaTime(wall: 188, pauses: pauses), 188, accuracy: 0.0001)
        XCTAssertEqual(TimelineMath.mediaTime(wall: 205, pauses: pauses), 190, accuracy: 0.0001)
        XCTAssertEqual(TimelineMath.mediaTime(wall: 220, pauses: pauses), 205, accuracy: 0.0001)
        XCTAssertEqual(TimelineMath.wallTime(media: 188, pauses: pauses), 188, accuracy: 0.0001)
        XCTAssertEqual(TimelineMath.wallTime(media: 190, pauses: pauses), 205, accuracy: 0.0001)
    }

    func testTwoPauses() {
        let pauses = [
            PauseInterval(pauseWall: 10, resumeWall: 20),
            PauseInterval(pauseWall: 50, resumeWall: 80)
        ]
        XCTAssertEqual(TimelineMath.mediaTime(wall: 5, pauses: pauses), 5, accuracy: 0.0001)
        XCTAssertEqual(TimelineMath.mediaTime(wall: 20, pauses: pauses), 10, accuracy: 0.0001)
        XCTAssertEqual(TimelineMath.mediaTime(wall: 50, pauses: pauses), 40, accuracy: 0.0001)
        XCTAssertEqual(TimelineMath.mediaTime(wall: 80, pauses: pauses), 40, accuracy: 0.0001)
        XCTAssertEqual(TimelineMath.mediaTime(wall: 90, pauses: pauses), 50, accuracy: 0.0001)
    }

    func testActivePauseAdvancesDeltaOnly() {
        let pauses = [PauseInterval(pauseWall: 12, resumeWall: nil)]
        XCTAssertEqual(TimelineMath.mediaTime(wall: 12, pauses: pauses), 12, accuracy: 0.0001)
        XCTAssertEqual(TimelineMath.mediaTime(wall: 30, pauses: pauses), 12, accuracy: 0.0001)
    }

    func testEvenCaptureSizeMatchesWriterAndStream() {
        let fullHD = SessionRecorder.evenCaptureSize(width: 1920, height: 1080)
        XCTAssertEqual(fullHD.width, 1920)
        XCTAssertEqual(fullHD.height, 1080)

        let retina = SessionRecorder.evenCaptureSize(width: 3024, height: 1964)
        XCTAssertEqual(retina.width % 2, 0)
        XCTAssertEqual(retina.height % 2, 0)
        XCTAssertEqual(retina.width, 3024)
        XCTAssertEqual(retina.height, 1964)
        XCTAssertLessThanOrEqual(retina.width, MediaBudget.archiveMaxWidth)
        XCTAssertLessThanOrEqual(retina.height, MediaBudget.archiveMaxHeight)

        let fiveK = SessionRecorder.evenCaptureSize(width: 5120, height: 2880)
        XCTAssertEqual(fiveK.width, 3840)
        XCTAssertEqual(fiveK.height, 2160)

        let odd = SessionRecorder.evenCaptureSize(width: 1367, height: 769)
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.height % 2, 0)
        XCTAssertGreaterThanOrEqual(odd.width, 2)
        XCTAssertGreaterThanOrEqual(odd.height, 2)
    }

    func testIsInsidePauseClosedAndOpenIntervals() {
        let pauses = [PauseInterval(pauseWall: 10, resumeWall: 20)]
        XCTAssertFalse(TimelineMath.isInsidePause(wall: 9.99, pauses: pauses))
        XCTAssertTrue(TimelineMath.isInsidePause(wall: 10, pauses: pauses))
        XCTAssertTrue(TimelineMath.isInsidePause(wall: 19.99, pauses: pauses))
        XCTAssertFalse(TimelineMath.isInsidePause(wall: 20, pauses: pauses))
        let open = [PauseInterval(pauseWall: 10, resumeWall: nil)]
        XCTAssertTrue(TimelineMath.isInsidePause(wall: 25, pauses: open))
    }

    func testPausedCaptureStateRefusesNewCapture() {
        XCTAssertTrue(CaptureSessionState.recording.allowsNewCapture)
        XCTAssertFalse(CaptureSessionState.paused.allowsNewCapture)
    }

    func testArchiveBudgetIsFourFpsAndSharp() {
        XCTAssertEqual(MediaBudget.archiveFrameStep, 1)
        XCTAssertEqual(MediaBudget.archiveFrameTimescale, 4)
        XCTAssertEqual(MediaBudget.archiveExpectedFrameRate, 4)
        XCTAssertEqual(MediaBudget.archiveMaxWidth, 3840)
        XCTAssertEqual(MediaBudget.archiveMaxHeight, 2160)
        XCTAssertEqual(MediaBudget.archiveVideoBitrate, 16_000_000)
        XCTAssertGreaterThan(MediaBudget.archiveVideoBitrate, 6_000_000)
        XCTAssertEqual(MediaBudget.archiveKeyFrameInterval, 4)
    }

    func testInPauseWallMapsToPauseStartNotNewMedia() {
        let pauses = [PauseInterval(pauseWall: 10, resumeWall: 20)]
        XCTAssertEqual(TimelineMath.mediaTime(wall: 15, pauses: pauses), 10, accuracy: 0.0001)
        XCTAssertTrue(TimelineMath.isInsidePause(wall: 15, pauses: pauses))
    }

    func testRebuildPausesFromEvents() {
        let events = [
            SessionEvent(tWall: 10, tMedia: 10, kind: .pause, payload: [:]),
            SessionEvent(tWall: 20, tMedia: 10, kind: .resume, payload: [:]),
            SessionEvent(tWall: 40, tMedia: 30, kind: .privacyPause, payload: [:]),
            SessionEvent(tWall: 45, tMedia: 30, kind: .resume, payload: [:])
        ]
        let pauses = PauseInterval.rebuild(from: events)
        XCTAssertEqual(pauses.count, 2)
        XCTAssertEqual(pauses[0].pauseWall, 10, accuracy: 0.0001)
        XCTAssertEqual(pauses[0].resumeWall ?? -1, 20, accuracy: 0.0001)
        XCTAssertEqual(pauses[1].pauseWall, 40, accuracy: 0.0001)
        XCTAssertEqual(pauses[1].resumeWall ?? -1, 45, accuracy: 0.0001)
    }

    func testCaptureAreaPixelSizeAndCrop() {
        XCTAssertTrue(CaptureArea.entireDisplay.isEntireDisplay)
        XCTAssertEqual(CaptureArea.entireDisplay.summary, "Entire display")
        let region = CaptureArea(
            capturesFullDisplay: false,
            displayID: 1,
            originX: 100,
            originY: 40,
            widthPoints: 640,
            heightPoints: 360,
            backingScale: 2
        )
        XCTAssertFalse(region.isEntireDisplay)
        let pixels = region.pixelSize(displayPixelWidth: 3024, displayPixelHeight: 1964)
        XCTAssertEqual(pixels.width, 1280)
        XCTAssertEqual(pixels.height, 720)
        let crop = region.pixelCrop(imageWidth: 3024, imageHeight: 1964)
        XCTAssertEqual(crop.origin.x, 200)
        XCTAssertEqual(crop.origin.y, 80)
        XCTAssertEqual(crop.width, 1280)
        XCTAssertEqual(crop.height, 720)
    }

    func testScrubbedURLDropsQueryAndFragment() {
        let cleaned = MetadataSampler.scrubbedURLString(
            "https://example.com/path?token=SECRETXYZ#frag"
        )
        XCTAssertEqual(cleaned, "https://example.com/path")
        XCTAssertFalse(cleaned.contains("SECRETXYZ"))
    }
}
