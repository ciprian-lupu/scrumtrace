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
}
