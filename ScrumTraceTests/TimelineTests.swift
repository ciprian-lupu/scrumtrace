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
}
