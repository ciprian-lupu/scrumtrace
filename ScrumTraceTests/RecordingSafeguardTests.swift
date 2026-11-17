import XCTest
@testable import ScrumTrace

/// Keep-awake and free-disk rules around a recording.
final class RecordingSafeguardTests: XCTestCase {
    private final class ActivityToken: NSObject {}

    /// Counts the activities a `SleepGuard` begins and ends without touching the real power assertions.
    @MainActor
    private final class ActivityProbe {
        var begun: [(options: ProcessInfo.ActivityOptions, reason: String)] = []
        var ended = 0
        func makeGuard() -> SleepGuard {
            SleepGuard(
                begin: { [self] options, reason in
                    begun.append((options: options, reason: reason))
                    return ActivityToken()
                },
                end: { [self] _ in ended += 1 }
            )
        }
    }

    @MainActor
    private func withController(_ body: (SessionController, URL) async throws -> Void) async throws {
        let id = "ScrumTrace.RecordingSafeguardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let log = root.appendingPathComponent("agent.jsonl")
        AgentLog.setFileURLForTesting(log)
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let vault = SessionVault(rootURL: root.appendingPathComponent("sessions"))
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: vault)
        try await body(controller, log)
    }

    private func events(at url: URL) throws -> [String] {
        _ = AgentLog.snapshotFieldsForTesting()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String])?["event"]
        }
    }

    // MARK: - Keep awake

    @MainActor
    func testSleepGuardHoldsOneActivityPerReasonAndEndsIt() {
        let probe = ActivityProbe()
        let sleepGuard = probe.makeGuard()
        XCTAssertTrue(sleepGuard.held.isEmpty)

        sleepGuard.update(recording: true, working: false)
        XCTAssertEqual(sleepGuard.held, [.recording])
        XCTAssertEqual(probe.begun.count, 1)
        XCTAssertTrue(probe.begun[0].options.contains(.idleSystemSleepDisabled), "The system stays awake")
        XCTAssertTrue(probe.begun[0].options.contains(.idleDisplaySleepDisabled), "A recorded display must not sleep")

        sleepGuard.update(recording: true, working: false)
        XCTAssertEqual(probe.begun.count, 1, "Asking again for the same state begins nothing new")

        sleepGuard.update(recording: false, working: true)
        XCTAssertEqual(sleepGuard.held, [.working])
        XCTAssertEqual(probe.begun.count, 2)
        XCTAssertEqual(probe.ended, 1)
        XCTAssertTrue(probe.begun[1].options.contains(.idleSystemSleepDisabled))
        XCTAssertFalse(probe.begun[1].options.contains(.idleDisplaySleepDisabled), "Processing lets the display sleep")

        sleepGuard.update(recording: false, working: false)
        XCTAssertTrue(sleepGuard.held.isEmpty)
        XCTAssertEqual(probe.ended, 2, "Every activity that began has ended")
    }

    @MainActor
    func testTheControllerKeepsTheMacAwakeWhileRecordingAndWhileBusy() async throws {
        try await withController { controller, _ in
            let probe = ActivityProbe()
            controller.sleepGuard = probe.makeGuard()
            XCTAssertTrue(controller.sleepGuard.held.isEmpty, "Idle holds nothing")

            XCTAssertTrue(controller.beginSessionTransfer())
            XCTAssertEqual(controller.sleepGuard.held, [.working], "Busy work keeps the system awake")
            controller.endSessionTransfer()
            XCTAssertTrue(controller.sleepGuard.held.isEmpty)

            controller.phase = .recording
            XCTAssertEqual(controller.sleepGuard.held, [.recording])
            controller.phase = .paused
            XCTAssertEqual(controller.sleepGuard.held, [.recording], "A paused recording is still a recording")
            controller.phase = .transcribing
            controller.isBusy = true
            XCTAssertEqual(controller.sleepGuard.held, [.working], "After Stop the processing hold takes over")
            controller.isBusy = false
            controller.phase = .idle
            XCTAssertTrue(controller.sleepGuard.held.isEmpty)
            XCTAssertEqual(probe.begun.count, probe.ended)
        }
    }

    // MARK: - Free disk space

    func testStartIsRefusedOnlyWhenThereIsNoRoomForAUsefulRecording() {
        XCTAssertNil(RecordingDiskBudget.startRefusal(freeBytes: nil), "An unknown capacity never blocks a recording")
        XCTAssertNil(RecordingDiskBudget.startRefusal(freeBytes: RecordingDiskBudget.minimumFreeBytesToStart))
        XCTAssertNil(RecordingDiskBudget.startRefusal(freeBytes: 250_000_000_000))
        let refusal = RecordingDiskBudget.startRefusal(freeBytes: 1_400_000_000)
        XCTAssertEqual(refusal?.contains("1.4 GB free"), true)
        XCTAssertEqual(refusal?.contains("2.0 GB"), true)
        XCTAssertNotNil(RecordingDiskBudget.startRefusal(freeBytes: 0))
    }

    func testARunningRecordingWarnsThenStopsAsTheDiskFills() {
        XCTAssertEqual(RecordingDiskBudget.level(freeBytes: nil), .enough)
        XCTAssertEqual(RecordingDiskBudget.level(freeBytes: 50_000_000_000), .enough)
        XCTAssertEqual(RecordingDiskBudget.level(freeBytes: RecordingDiskBudget.lowFreeBytes), .enough)
        XCTAssertEqual(RecordingDiskBudget.level(freeBytes: RecordingDiskBudget.lowFreeBytes - 1), .low)
        XCTAssertEqual(RecordingDiskBudget.level(freeBytes: RecordingDiskBudget.stopBelowFreeBytes), .low)
        XCTAssertEqual(RecordingDiskBudget.level(freeBytes: RecordingDiskBudget.stopBelowFreeBytes - 1), .stop)
        XCTAssertEqual(RecordingDiskBudget.level(freeBytes: 0), .stop)
        XCTAssertLessThan(RecordingDiskBudget.stopBelowFreeBytes, RecordingDiskBudget.lowFreeBytes)
    }

    func testFreeSpaceIsDescribedInPlainUnitsAndMinutes() {
        XCTAssertEqual(RecordingDiskBudget.describe(1_400_000_000), "1.4 GB")
        XCTAssertEqual(RecordingDiskBudget.describe(2_000_000_000), "2.0 GB")
        XCTAssertEqual(RecordingDiskBudget.describe(320_000_000), "320 MB")
        XCTAssertEqual(RecordingDiskBudget.describe(-5), "0 MB")
        XCTAssertEqual(RecordingDiskBudget.minutesOfRecording(freeBytes: RecordingDiskBudget.bytesPerSecond * 60 * 10), 10)
        XCTAssertEqual(RecordingDiskBudget.minutesOfRecording(freeBytes: 0), 0)
        XCTAssertGreaterThanOrEqual(RecordingDiskBudget.bytesPerSecond, Int64(MediaBudget.archiveVideoBitrate / 8),
            "The estimate never undercounts the archive movie")
    }

    func testFreeBytesAnswersForAFolderThatDoesNotExistYet() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrumtrace-missing-\(UUID().uuidString)")
            .appendingPathComponent("sessions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let free = try XCTUnwrap(RecordingDiskBudget.freeBytes(at: missing), "The nearest existing folder answers")
        XCTAssertGreaterThan(free, 0)
    }

    @MainActor
    func testALowDiskWarnsOnceAndLeavesTheRecordingRunning() async throws {
        try await withController { controller, log in
            controller.freeDiskBytes = { _ in 1_400_000_000 }
            controller.checkDiskSpaceWhileRecording()
            XCTAssertFalse(try self.events(at: log).contains("disk_low"), "Nothing is checked while idle")

            controller.phase = .recording
            controller.checkDiskSpaceWhileRecording()
            controller.checkDiskSpaceWhileRecording()
            XCTAssertEqual(try self.events(at: log).filter { $0 == "disk_low" }.count, 1, "One warning per recording")
            XCTAssertEqual(controller.statusLine, RecordingDiskBudget.lowMessage(freeBytes: 1_400_000_000))
            XCTAssertTrue(controller.isRecording, "A warning never stops the recording")
            XCTAssertFalse(try self.events(at: log).contains("disk_low_stop"))
            controller.phase = .idle
        }
    }

    // The stop branch (`disk_low_stop`, then the normal Stop) is pinned in scripts/test_contracts.py rather than driven
    // here: Stop ends in `AgentLog.setRecording(false, …)`, which removes the real `recording.lock` in
    // ~/Library/Logs/ScrumTrace, and a unit test must not do that while the installed app may be recording.
}
