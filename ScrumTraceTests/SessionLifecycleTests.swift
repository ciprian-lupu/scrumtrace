import XCTest
@testable import ScrumTrace

/// Every transition and classification of a Session's lifecycle, without a vault or temp folder.
final class SessionLifecycleTests: XCTestCase {
    private typealias Stage = SessionLifecycle.Stage
    private let allStatuses: [PipelineStatus] = [
        .idle, .recording, .paused, .transcribing, .slicing, .evaluating, .synthesizing, .completed, .offlineFailed
    ]

    private func lifecycle(_ status: PipelineStatus, done: [PipelineStatus] = []) -> SessionLifecycle {
        SessionLifecycle(status: status, completedStages: done)
    }

    // MARK: - Transitions

    func testANewSessionIsIdleWithNothingDone() {
        XCTAssertEqual(SessionLifecycle.new, lifecycle(.idle))
    }

    func testRecordCaptureSavesTheLivePhase() {
        for (phase, status) in [(CapturePhase.idle, PipelineStatus.idle), (.recording, .recording), (.paused, .paused)] {
            var value = lifecycle(.transcribing, done: [.transcribing])
            value.recordCapture(phase)
            XCTAssertEqual(value, lifecycle(status, done: [.transcribing]))
        }
    }

    func testCapturePhaseOnlyExistsForCaptureStatuses() {
        for status in allStatuses {
            let phase = CapturePhase(status)
            switch status {
            case .idle, .recording, .paused: XCTAssertEqual(phase?.status, status)
            default: XCTAssertNil(phase, "\(status)")
            }
        }
    }

    func testStopLeavesProcessingToDo() {
        var value = lifecycle(.paused)
        value.recordStop()
        XCTAssertEqual(value.status, .transcribing)
    }

    func testQuitStatusDependsOnWhatWasCapturedAndWhetherItClosed() {
        let table: [(hasMedia: Bool, captureClosed: Bool, expected: PipelineStatus)] = [
            (false, false, .idle),
            (false, true, .idle),
            (true, false, .recording),
            (true, true, .transcribing)
        ]
        for row in table {
            var value = lifecycle(.recording)
            value.recordQuit(hasMedia: row.hasMedia, captureClosed: row.captureClosed)
            XCTAssertEqual(value.status, row.expected, "hasMedia=\(row.hasMedia) closed=\(row.captureClosed)")
        }
    }

    func testBeginSetsTheStatusAndLeavesDoneStages() {
        for stage in [Stage.transcribing, .slicing, .evaluating, .synthesizing] {
            var value = lifecycle(.idle, done: [.transcribing])
            value.begin(stage)
            XCTAssertEqual(value, lifecycle(stage.status, done: [.transcribing]))
        }
    }

    func testCompleteAppendsOnceInOrderAndKeepsTheStatus() {
        var value = lifecycle(.slicing)
        value.complete(.transcribing)
        value.complete(.slicing)
        value.complete(.transcribing)
        XCTAssertEqual(value, lifecycle(.slicing, done: [.transcribing, .slicing]))
        XCTAssertTrue(value.isDone(.slicing))
        XCTAssertFalse(value.isDone(.evaluating))
    }

    func testInvalidateDropsTheStageAndEveryLaterOneButNotTheStatus() {
        let all: [PipelineStatus] = [.transcribing, .slicing, .evaluating, .synthesizing, .completed]
        let table: [(from: Stage, kept: [PipelineStatus])] = [
            (.transcribing, []),
            (.slicing, [.transcribing]),
            (.evaluating, [.transcribing, .slicing]),
            (.synthesizing, [.transcribing, .slicing, .evaluating]),
            (.completed, [.transcribing, .slicing, .evaluating, .synthesizing])
        ]
        for row in table {
            var value = lifecycle(.completed, done: all)
            value.invalidate(from: row.from)
            XCTAssertEqual(value, lifecycle(.completed, done: row.kept), "from \(row.from)")
        }
    }

    func testInvalidateKeepsSavedOrderAndValuesOutsideTheStages() {
        var value = lifecycle(.evaluating, done: [.slicing, .recording, .transcribing, .evaluating])
        value.invalidate(from: .evaluating)
        XCTAssertEqual(value.completedStages, [.slicing, .recording, .transcribing])
        XCTAssertFalse(value.isDone(.evaluating))
    }

    func testFinishCompletesInSavedOrderAndReportsAnyOfflineFailure() {
        var clean = lifecycle(.synthesizing, done: [.transcribing, .slicing, .evaluating])
        clean.finish(offlineFailed: false)
        XCTAssertEqual(clean, lifecycle(.completed, done: [.transcribing, .slicing, .evaluating, .synthesizing, .completed]))

        var failed = lifecycle(.synthesizing, done: [.transcribing, .synthesizing])
        failed.finish(offlineFailed: true)
        XCTAssertEqual(failed, lifecycle(.offlineFailed, done: [.transcribing, .synthesizing, .completed]))
    }

    func testMarkOfflineFailedKeepsDoneStages() {
        var value = lifecycle(.evaluating, done: [.transcribing, .slicing])
        value.markOfflineFailed()
        XCTAssertEqual(value, lifecycle(.offlineFailed, done: [.transcribing, .slicing]))
    }

    func testTakeStatusCopiesOnlyTheStatus() {
        var disk = lifecycle(.transcribing, done: [.transcribing])
        disk.takeStatus(from: lifecycle(.paused, done: []))
        XCTAssertEqual(disk, lifecycle(.paused, done: [.transcribing]))
    }

    // MARK: - Classifications

    func testStatusOnlyClassifications() {
        for status in allStatuses {
            let value = lifecycle(status)
            XCTAssertEqual(value.isUnfinished, status != .idle && status != .completed, "unfinished \(status)")
            XCTAssertEqual(value.isInterrupted, status == .recording || status == .paused, "interrupted \(status)")
            XCTAssertEqual(value.isPrunable, status == .completed, "prunable \(status)")
        }
    }

    func testExportReadyNeedsSynthesizingDoneAndBothDocuments() {
        let synthesized = lifecycle(.offlineFailed, done: [.transcribing, .synthesizing])
        let notSynthesized = lifecycle(.offlineFailed, done: [.transcribing])
        let both = ArchiveFacts(hasBrief: true, hasAgentContext: true)
        XCTAssertTrue(synthesized.isExportReady(both))
        XCTAssertFalse(notSynthesized.isExportReady(both))
        XCTAssertFalse(synthesized.isExportReady(ArchiveFacts(hasBrief: true, hasAgentContext: false)))
        XCTAssertFalse(synthesized.isExportReady(ArchiveFacts(hasBrief: false, hasAgentContext: true)))
    }

    func testNeedsAttentionIsOfflineFailedWithoutAReadyExport() {
        let ready = ArchiveFacts(hasBrief: true, hasAgentContext: true)
        for status in allStatuses {
            let value = lifecycle(status, done: [.synthesizing])
            XCTAssertEqual(value.needsAttention(ArchiveFacts()), status == .offlineFailed, "\(status)")
            XCTAssertFalse(value.needsAttention(ready), "\(status)")
        }
    }

    func testResumableIsAProcessingStatusUnlessTheLastPassFailed() {
        let failedPass = ArchiveFacts(lastTranscriptionPassFailed: true)
        for status in allStatuses {
            let processing = [.transcribing, .slicing, .evaluating, .synthesizing].contains(status)
            XCTAssertEqual(lifecycle(status).isResumable(ArchiveFacts()), processing, "\(status)")
        }
        XCTAssertFalse(lifecycle(.transcribing).isResumable(failedPass))
        XCTAssertTrue(lifecycle(.transcribing, done: [.transcribing]).isResumable(failedPass),
                      "a completed transcription stays resumable despite older failed timing")
        XCTAssertTrue(lifecycle(.slicing).isResumable(failedPass))
    }

    func testAwaitsTranscriptionRetryOnlyForAFinishedFailedPass() {
        let failedPass = ArchiveFacts(lastTranscriptionPassFailed: true)
        XCTAssertTrue(lifecycle(.transcribing).awaitsTranscriptionRetry(failedPass))
        XCTAssertFalse(lifecycle(.transcribing).awaitsTranscriptionRetry(ArchiveFacts()))
        XCTAssertFalse(lifecycle(.transcribing, done: [.transcribing]).awaitsTranscriptionRetry(failedPass))
        XCTAssertFalse(lifecycle(.slicing).awaitsTranscriptionRetry(failedPass))
    }
}
