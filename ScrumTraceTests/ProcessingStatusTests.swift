import XCTest
@testable import ScrumTrace

/// The processing panel's model: stages, elapsed per stage, skips, outcomes, expectations and measured history.
final class ProcessingStatusTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(origin: ProcessingOrigin = .launchResume, history: ProcessingTimingHistory = .empty) -> ProcessingStatus {
        ProcessingStatus(
            sessionId: "2026-09-22-1255-8f816e",
            recordedAt: t0.addingTimeInterval(-21 * 24 * 3600),
            mediaSeconds: 23,
            origin: origin,
            history: history,
            startedAt: t0
        )
    }

    func testStagesKeepTheirOrderNamesAndLogValues() {
        XCTAssertEqual(ProcessingStage.allCases, [.resuming, .loadingModel, .transcribing, .slicing, .evaluating, .packaging, .done])
        XCTAssertEqual(ProcessingStage.allCases.map(\.rawValue), ["resuming", "loading_model", "transcribing", "slicing", "evaluating", "packaging", "done"])
        XCTAssertEqual(ProcessingStage.allCases.map(\.title), ["Resuming last recording", "Loading speech model", "Transcribing", "Slicing", "Evaluating", "Packaging", "Done"])
        XCTAssertEqual(ProcessingStage.allCases.filter(\.isSlow), [.loadingModel, .transcribing, .evaluating])
        XCTAssertEqual(ProcessingOrigin.launchResume.resumingTitle, "Resuming last recording")
        XCTAssertEqual(ProcessingOrigin.retry.resumingTitle, "Retrying analysis")
        XCTAssertEqual(ProcessingOrigin.stop.resumingTitle, "Saving recording")
        XCTAssertEqual(ProcessingOrigin.localExport.resumingTitle, "Regenerating local export")
        XCTAssertNil(ProcessingOrigin.stop.subtitle)
        XCTAssertEqual(ProcessingOrigin.launchResume.subtitle, "This recording never finished. ScrumTrace picked it up when it opened.")
    }

    func testEnteringAStageClosesThePreviousOneAndReportsItsSeconds() {
        var run = status()
        XCTAssertEqual(run.current, .resuming)
        XCTAssertTrue(run.isRunning)
        let first = run.enter(.loadingModel, at: t0.addingTimeInterval(2))
        XCTAssertTrue(first.entered)
        XCTAssertEqual(first.previous, .resuming)
        XCTAssertEqual(first.previousSeconds ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(run.current, .loadingModel)
        // Entering the open stage again is a no-op.
        let again = run.enter(.loadingModel, at: t0.addingTimeInterval(5))
        XCTAssertFalse(again.entered)
        XCTAssertNil(again.previous)
        XCTAssertEqual(run.records.count, 2)
        let second = run.enter(.transcribing, at: t0.addingTimeInterval(600))
        XCTAssertEqual(second.previous, .loadingModel)
        XCTAssertEqual(second.previousSeconds ?? -1, 598, accuracy: 0.001)
        run.now = t0.addingTimeInterval(603)
        XCTAssertEqual(run.record(for: .resuming)?.elapsed(at: run.now) ?? -1, 2, accuracy: 0.001, "A closed row keeps its final elapsed")
        XCTAssertEqual(run.record(for: .transcribing)?.elapsed(at: run.now) ?? -1, 3, accuracy: 0.001, "The open row follows now")
        XCTAssertEqual(run.totalElapsed, 603, accuracy: 0.001)
    }

    func testSkippedStagesHaveAReasonAndNoDuration() {
        var run = status()
        let skipped = run.skip(.loadingModel, reason: "already_loaded", at: t0.addingTimeInterval(1))
        XCTAssertEqual(skipped.previous, .resuming)
        XCTAssertNil(run.current, "A skip closes the open row and opens none")
        let entered = run.enter(.transcribing, at: t0.addingTimeInterval(1))
        XCTAssertTrue(entered.entered)
        XCTAssertNil(entered.previous, "Nothing was open")
        XCTAssertEqual(run.current, .transcribing)
        let record = run.record(for: .loadingModel)
        XCTAssertEqual(record?.skipReason, "already_loaded")
        XCTAssertEqual(record?.skipText, "Already loaded")
        XCTAssertFalse(record?.isOpen ?? true)
        XCTAssertEqual(ProcessingStageRecord(stage: .evaluating, startedAt: t0, endedAt: t0, skipReason: "consent").skipText, "Upload not approved")
        XCTAssertEqual(ProcessingStageRecord(stage: .evaluating, startedAt: t0, endedAt: t0, skipReason: "local_only").skipText, "Local export only")
        XCTAssertEqual(ProcessingStageRecord(stage: .evaluating, startedAt: t0, endedAt: t0, skipReason: "key_missing").skipText, "API key missing")
        XCTAssertEqual(ProcessingStageRecord(stage: .slicing, startedAt: t0, endedAt: t0, skipReason: "no_anchors").skipText, "No clips")
        XCTAssertEqual(ProcessingStageRecord(stage: .slicing, startedAt: t0, endedAt: t0, skipReason: "already_done").skipText, "Already done")
        XCTAssertEqual(ProcessingStageRecord(stage: .evaluating, startedAt: t0, endedAt: t0, skipReason: "transcription_incomplete").skipText, "Transcription incomplete")
        XCTAssertNil(ProcessingStageRecord(stage: .evaluating, startedAt: t0, endedAt: t0, skipReason: "free text").skipText, "Only the closed set has words")
        XCTAssertEqual(ProcessingSkipReason.allCases.count, 8)
    }

    func testProgressValuesGiveFractionsAndLabels() {
        XCTAssertNil(ProcessingProgressValue.indeterminate.fraction)
        XCTAssertNil(ProcessingProgressValue.indeterminate.label)
        let audio = ProcessingProgressValue.audioSeconds(done: 5, total: 23)
        XCTAssertEqual(audio.fraction ?? -1, 5.0 / 23.0, accuracy: 0.0001)
        XCTAssertEqual(audio.label, "00:05 of 00:23 of audio")
        XCTAssertEqual(ProcessingProgressValue.audioSeconds(done: 5, total: 46, passes: 2).label, "00:05 of 00:46 of audio (2 passes)")
        XCTAssertEqual(ProcessingProgressValue.audioSeconds(done: 40, total: 23).fraction, 1, "Never past the end")
        XCTAssertNil(ProcessingProgressValue.audioSeconds(done: 1, total: 0).fraction)
        let clips = ProcessingProgressValue.count(done: 3, total: 7, unit: "clips")
        XCTAssertEqual(clips.fraction ?? -1, 3.0 / 7.0, accuracy: 0.0001)
        XCTAssertEqual(clips.label, "3 of 7 clips")
        XCTAssertNil(ProcessingProgressValue.count(done: 0, total: 0, unit: "clips").label)
        var run = status()
        run.enter(.transcribing)
        run.update(progress: audio)
        XCTAssertEqual(run.record(for: .transcribing)?.progress, audio)
    }

    func testOutcomesCloseTheOpenRowAndDoneAddsItsRow() {
        var done = status()
        done.enter(.packaging, at: t0.addingTimeInterval(10))
        done.finish(.done("Session pack ready"), at: t0.addingTimeInterval(12))
        XCTAssertFalse(done.isRunning)
        XCTAssertNil(done.current)
        XCTAssertEqual(done.records.last?.stage, .done)
        XCTAssertEqual(done.record(for: .packaging)?.elapsed(at: t0.addingTimeInterval(99)) ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(done.totalElapsed, 12, accuracy: 0.001, "Frozen at the end")
        XCTAssertNil(done.failedStage)

        var failed = status()
        failed.enter(.transcribing, at: t0.addingTimeInterval(1))
        failed.finish(.failed("Whisper model load timed out after 12 minutes."), at: t0.addingTimeInterval(721))
        XCTAssertEqual(failed.failedStage, .transcribing)
        XCTAssertNil(failed.record(for: .done))

        var deferred = status()
        deferred.enter(.loadingModel, at: t0.addingTimeInterval(1))
        deferred.finish(.deferred, at: t0.addingTimeInterval(30))
        XCTAssertEqual(deferred.outcome, .deferred)
        XCTAssertNil(deferred.failedStage)
        XCTAssertEqual(deferred.record(for: .loadingModel)?.endedAt, t0.addingTimeInterval(30))
        XCTAssertEqual(ProcessingStatus.doneAutoClearSeconds, 8)

        var incomplete = status()
        incomplete.enter(.packaging, at: t0.addingTimeInterval(1))
        incomplete.finish(ProcessingStatus.outcome(forReturned: .transcribing, line: "Transcription is incomplete; the local export is available and Retry Analysis can continue."), at: t0.addingTimeInterval(2))
        XCTAssertEqual(incomplete.outcome, .incomplete("Transcription is incomplete; the local export is available and Retry Analysis can continue."))
        XCTAssertTrue(incomplete.outcome.needsRetry)
        XCTAssertNil(incomplete.record(for: .done), "Not done")
        XCTAssertEqual(ProcessingStatus.outcome(forReturned: .completed, line: "Session pack ready"), .done("Session pack ready"))
        XCTAssertEqual(ProcessingStatus.outcome(forReturned: .offlineFailed, line: "x"), .incomplete("x"))
        XCTAssertFalse(ProcessingOutcome.done("x").needsRetry)
        XCTAssertFalse(ProcessingOutcome.deferred.needsRetry)
        XCTAssertTrue(ProcessingOutcome.failed("x").needsRetry)

        var packaging = status()
        XCTAssertTrue(packaging.canFinishLater)
        packaging.enter(.slicing)
        XCTAssertTrue(packaging.canFinishLater)
        packaging.enter(.packaging)
        XCTAssertFalse(packaging.canFinishLater, "Packaging is never interrupted")
        XCTAssertNotEqual(status().runID, status().runID)
    }

    func testActiveSummaryShowsMeasuredStageProgressWithoutAnOverallEstimate() {
        var run = status()
        run.enter(.transcribing, at: t0.addingTimeInterval(1))
        run.update(progress: .audioSeconds(done: 720, total: 2400))
        run.now = t0.addingTimeInterval(61)
        let state = ProcessingPanelState.make(run)
        XCTAssertEqual(state.activityTitle, "Transcribing · 01:00 elapsed")
        XCTAssertEqual(state.activeRow?.progressSummary, "12:00 of 40:00 of audio · 30%")
        run.enter(.loadingModel)
        let loading = ProcessingPanelState.make(run)
        XCTAssertNil(loading.activeRow?.fraction)
        XCTAssertFalse(loading.activeRow?.progressSummary?.contains("%") ?? true)
        run.finish(.deferred)
        XCTAssertNil(ProcessingPanelState.make(run).activeRow)
        XCTAssertTrue(ProcessingPanelState.finishLaterHelp.contains("restarts the unfinished stage"))
    }

    func testTitleNamesTheRecordingDateAndLength() {
        let run = status()
        XCTAssertTrue(run.title.hasPrefix("Processing the recording from "), run.title)
        XCTAssertTrue(run.title.hasSuffix(" · 00:23 recorded"), run.title)
        XCTAssertTrue(run.title.contains(ProcessingStatus.recordedLabel(run.recordedAt)))
        XCTAssertEqual(ProcessingStatus.recordedLabel(nil), "an unknown date")
        XCTAssertEqual(ProcessingClock.label(23), "00:23")
        XCTAssertEqual(ProcessingClock.label(3723), "1:02:03")
        XCTAssertEqual(ProcessingClock.prose(592), "9 min 52 s")
        XCTAssertEqual(ProcessingClock.prose(600), "10 min")
        XCTAssertEqual(ProcessingClock.prose(4.6), "5 s")
        XCTAssertEqual(ProcessingClock.prose(3720), "1 h 2 min")
    }

    func testPanelRowsFollowTheStatus() {
        var run = status()
        run.skip(.loadingModel, reason: "already_loaded", at: t0.addingTimeInterval(1))
        run.enter(.transcribing, at: t0.addingTimeInterval(1))
        run.update(progress: .audioSeconds(done: 5, total: 23))
        run.now = t0.addingTimeInterval(4)
        let running = ProcessingPanelState.make(run)
        XCTAssertEqual(running.title, run.title)
        XCTAssertEqual(running.subtitle, ProcessingOrigin.launchResume.subtitle)
        XCTAssertEqual(running.rows.map(\.stage), ProcessingStage.allCases)
        XCTAssertEqual(running.rows.map(\.state), [.done, .skipped, .active, .pending, .pending, .pending, .pending])
        XCTAssertEqual(running.rows[0].title, "Resuming last recording")
        XCTAssertEqual(running.rows[0].elapsed, "00:01")
        XCTAssertEqual(running.rows[1].detail, "Already loaded")
        XCTAssertNil(running.rows[1].elapsed)
        XCTAssertEqual(running.rows[2].elapsed, "00:03")
        XCTAssertEqual(running.rows[2].detail, "00:05 of 00:23 of audio")
        XCTAssertEqual(running.rows[2].fraction ?? -1, 5.0 / 23.0, accuracy: 0.0001)
        XCTAssertNil(running.rows[3].elapsed)
        XCTAssertTrue(running.showsFinishLater)
        XCTAssertFalse(running.showsRetry)
        XCTAssertFalse(running.showsClose)
        XCTAssertNil(running.footer)
        XCTAssertEqual(running.totalElapsed, "00:04")

        // Without progress the slow row shows what to expect.
        var loading = status()
        loading.enter(.loadingModel, at: t0.addingTimeInterval(1))
        loading.now = t0.addingTimeInterval(61)
        let loadingRows = ProcessingPanelState.make(loading).rows
        XCTAssertEqual(loadingRows[1].state, .active)
        XCTAssertEqual(loadingRows[1].elapsed, "01:00")
        XCTAssertEqual(loadingRows[1].detail, "The first load after a restart usually takes 5 to 11 minutes on this Mac; later loads take a few seconds.")
        XCTAssertNil(loadingRows[1].fraction)

        var failed = loading
        failed.finish(.failed("session.mp4 is missing."), at: t0.addingTimeInterval(70))
        let failedState = ProcessingPanelState.make(failed)
        XCTAssertEqual(failedState.rows[1].state, .failed)
        XCTAssertEqual(failedState.rows[1].detail, "session.mp4 is missing.")
        XCTAssertEqual(failedState.rows[1].elapsed, "01:09")
        XCTAssertEqual(failedState.footer, "session.mp4 is missing.")
        XCTAssertTrue(failedState.showsRetry)
        XCTAssertTrue(failedState.showsClose)
        XCTAssertFalse(failedState.showsFinishLater)

        var done = run
        done.enter(.slicing, at: t0.addingTimeInterval(5))
        done.update(progress: .count(done: 2, total: 2, unit: "clips"))
        done.skip(.evaluating, reason: "consent", at: t0.addingTimeInterval(6))
        done.enter(.packaging, at: t0.addingTimeInterval(6))
        done.finish(.done("Session pack ready"), at: t0.addingTimeInterval(8))
        let doneState = ProcessingPanelState.make(done)
        XCTAssertEqual(doneState.rows.map(\.state), [.done, .skipped, .done, .done, .skipped, .done, .done])
        XCTAssertEqual(doneState.rows[3].detail, "2 of 2 clips")
        XCTAssertEqual(doneState.rows[4].detail, "Upload not approved")
        XCTAssertEqual(doneState.rows[6].detail, "Session pack ready")
        XCTAssertNil(doneState.rows[6].elapsed)
        XCTAssertEqual(doneState.footer, "Session pack ready · 8 s in all")
        XCTAssertFalse(doneState.showsRetry)
        XCTAssertTrue(doneState.showsClose)

        var deferred = loading
        deferred.finish(.deferred, at: t0.addingTimeInterval(90))
        XCTAssertEqual(ProcessingPanelState.make(deferred).footer, ProcessingPanelState.deferredFooter)
        XCTAssertEqual(ProcessingPanelState.make(deferred, modelStillLoading: true).footer, ProcessingPanelState.deferredModelFooter)
        XCTAssertEqual(ProcessingPanelState.make(deferred).rows[1].state, .done, "The row the run stopped at keeps its elapsed")
        XCTAssertEqual(ProcessingPanelState.make(deferred).rows[1].elapsed, "01:29")
        XCTAssertFalse(ProcessingPanelState.make(deferred).showsFinishLater)
        XCTAssertFalse(ProcessingPanelState.make(deferred).showsRetry)
        XCTAssertTrue(ProcessingPanelState.make(deferred).showsClose)

        var packaging = run
        packaging.enter(.packaging, at: t0.addingTimeInterval(6))
        XCTAssertFalse(ProcessingPanelState.make(packaging).showsFinishLater, "No Finish later once packaging started")
        var incomplete = packaging
        incomplete.finish(.incomplete("Transcription is incomplete; the local export is available and Retry Analysis can continue."), at: t0.addingTimeInterval(7))
        let incompleteState = ProcessingPanelState.make(incomplete)
        XCTAssertEqual(incompleteState.rows[5].state, .failed, "The stage the run returned from is marked, so Retry has a place to point")
        XCTAssertEqual(incompleteState.rows[6].state, .pending)
        XCTAssertTrue(incompleteState.showsRetry)
        XCTAssertTrue(incompleteState.showsClose)
        XCTAssertEqual(incompleteState.footer, "Transcription is incomplete; the local export is available and Retry Analysis can continue.")
    }

    func testExpectationsPreferMeasuredValues() {
        let empty = ProcessingTimingHistory.empty
        XCTAssertEqual(
            ProcessingExpectation.line(stage: .loadingModel, history: empty, mediaSeconds: 23, elapsed: 10),
            "The first load after a restart usually takes 5 to 11 minutes on this Mac; later loads take a few seconds."
        )
        XCTAssertEqual(
            ProcessingExpectation.line(stage: .loadingModel, history: empty, mediaSeconds: 23, elapsed: 12 * 60),
            "Longer than the 12-minute wait. The run will go on without a transcript, the model keeps loading, and Retry analysis can finish the recording."
        )
        let measured = ProcessingTimingHistory(
            modelLoadSeconds: [675.8, 4.6, 592.4, 4.2, 686.5],
            transcribeRates: [20, 30, 25],
            stageSeconds: [.slicing: [3, 5, 4], .evaluating: [40, 60], .packaging: [2]]
        )
        XCTAssertEqual(measured.slowModelLoads, [675.8, 592.4, 686.5])
        XCTAssertEqual(measured.fastModelLoads, [4.6, 4.2])
        XCTAssertEqual(
            ProcessingExpectation.line(stage: .loadingModel, history: measured, mediaSeconds: 23, elapsed: 10),
            "On this Mac a slow load took 9 min 52 s to 11 min 27 s and a fast one about 4 s (5 loads). The first load after a restart is usually the slow kind."
        )
        let slowOnly = ProcessingTimingHistory(modelLoadSeconds: [600], transcribeRates: [], stageSeconds: [:])
        XCTAssertEqual(
            ProcessingExpectation.line(stage: .loadingModel, history: slowOnly, mediaSeconds: 23, elapsed: 10),
            "On this Mac a slow load took 10 min (1 load). The first load after a restart is usually the slow kind."
        )
        let fastOnly = ProcessingTimingHistory(modelLoadSeconds: [4, 6], transcribeRates: [], stageSeconds: [:])
        XCTAssertEqual(
            ProcessingExpectation.line(stage: .loadingModel, history: fastOnly, mediaSeconds: 23, elapsed: 10),
            "Earlier loads on this Mac took about 5 s (2 loads); the first load after a restart can take 5 to 11 minutes."
        )
        XCTAssertEqual(
            ProcessingExpectation.line(stage: .transcribing, history: measured, mediaSeconds: 23, elapsed: 0),
            "About 1 s for this 00:23 recording, judging by 3 earlier recordings."
        )
        XCTAssertEqual(
            ProcessingExpectation.line(stage: .transcribing, history: measured, mediaSeconds: 1800, elapsed: 0),
            "About 1 min 12 s for this 30:00 recording, judging by 3 earlier recordings."
        )
        XCTAssertEqual(
            ProcessingExpectation.line(stage: .transcribing, history: empty, mediaSeconds: 23, elapsed: 0),
            "Usually under a minute for a short recording, and about as long as the recording for a long one."
        )
        XCTAssertEqual(ProcessingExpectation.line(stage: .slicing, history: measured, mediaSeconds: 23, elapsed: 0), "About 4 s, judging by 3 earlier recordings.")
        XCTAssertEqual(ProcessingExpectation.line(stage: .slicing, history: empty, mediaSeconds: 23, elapsed: 0), "Usually a few seconds per clip.")
        XCTAssertEqual(ProcessingExpectation.line(stage: .evaluating, history: measured, mediaSeconds: 23, elapsed: 0), "One call per clip. About 50 s, judging by 2 earlier recordings.")
        XCTAssertEqual(ProcessingExpectation.line(stage: .evaluating, history: empty, mediaSeconds: 23, elapsed: 0), "One call per clip; each usually takes 10 to 60 seconds.")
        XCTAssertEqual(ProcessingExpectation.line(stage: .packaging, history: measured, mediaSeconds: 23, elapsed: 0), "About 2 s, judging by 1 earlier recording.")
        XCTAssertEqual(ProcessingExpectation.line(stage: .packaging, history: empty, mediaSeconds: 23, elapsed: 0), "Usually under a minute.")
        XCTAssertNil(ProcessingExpectation.line(stage: .resuming, history: measured, mediaSeconds: 23, elapsed: 0))
        XCTAssertNil(ProcessingExpectation.line(stage: .done, history: measured, mediaSeconds: 23, elapsed: 0))
        XCTAssertEqual(ProcessingTimingHistory.median([3, 1, 2]), 2)
        XCTAssertEqual(ProcessingTimingHistory.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(ProcessingTimingHistory.median([]))
    }

    func testHistoryReadsTimingFilesAndKeepsTwelveModelLoads() throws {
        let id = "ScrumTrace.ProcessingStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        for load in 1...15 {
            ProcessingTimingHistory.recordModelLoad(seconds: TimeInterval(load), defaults: defaults)
        }
        ProcessingTimingHistory.recordModelLoad(seconds: 0, defaults: defaults)
        ProcessingTimingHistory.recordModelLoad(seconds: .nan, defaults: defaults)
        XCTAssertEqual(ProcessingTimingHistory.storedModelLoads(defaults: defaults), (4...15).map(TimeInterval.init), "The newest twelve stay; zero and NaN are ignored")

        let timings: [(timing: PipelineTiming, mediaSeconds: TimeInterval)] = [
            (PipelineTiming(whisperWallSeconds: 2, whisperLoadSeconds: 585.5, stageSeconds: ["transcribing": 1.0, "slicing": 3, "packaging": 2]), 23),
            (PipelineTiming(whisperWallSeconds: 14.8, stageSeconds: ["transcribing": 60, "slicing": 5, "evaluating": 40, "not_a_stage": 9]), 1800),
            (PipelineTiming(whisperWallSeconds: 602), 0),
        ]
        let history = ProcessingTimingHistory(defaults: defaults, timings: timings)
        XCTAssertEqual(history.modelLoadSeconds, (4...15).map(TimeInterval.init) + [585.5])
        XCTAssertEqual(history.transcribeRates, [23, 30])
        XCTAssertEqual(history.stageSeconds[.slicing], [3, 5])
        XCTAssertEqual(history.stageSeconds[.evaluating], [40])
        XCTAssertEqual(history.stageSeconds[.packaging], [2])
        XCTAssertNil(history.stageSeconds[.resuming])
        XCTAssertEqual(ProcessingTimingHistory.sessionLimit, 20)
    }

    func testPipelineTimingRoundTripsWithAndWithoutStageSeconds() throws {
        let legacy = Data("""
        {"export_folder_bytes":23523,"omitted_count":0,"whisper_incomplete":true,"whisper_sources":["room","system"],"whisper_wall_seconds":1.2281469106674194,"zip_bytes":8792}
        """.utf8)
        let decoded = try JSONDecoder().decode(PipelineTiming.self, from: legacy)
        XCTAssertEqual(decoded.stageSeconds, [:])
        XCTAssertNil(decoded.whisperLoadSeconds)
        XCTAssertEqual(decoded.zipBytes, 8792)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyText = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        XCTAssertFalse(legacyText.contains("stage_seconds"), "An old file gains no empty map")
        XCTAssertFalse(legacyText.contains("whisper_load_seconds"))

        var timing = decoded
        timing.whisperLoadSeconds = 585.5
        timing.stageSeconds = ["loading_model": 585.5, "transcribing": 1.2, "packaging": 0.4]
        let text = String(decoding: try encoder.encode(timing), as: UTF8.self)
        XCTAssertTrue(text.contains("\"stage_seconds\":{\"loading_model\":585.5,\"packaging\":0.4,\"transcribing\":1.2}"), text)
        XCTAssertTrue(text.contains("\"whisper_load_seconds\":585.5"), text)
        let back = try JSONDecoder().decode(PipelineTiming.self, from: Data(text.utf8))
        XCTAssertEqual(back, timing)
    }
}
