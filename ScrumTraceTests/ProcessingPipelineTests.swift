import AVFoundation
import WhisperKit
import XCTest
@testable import ScrumTrace

/// The processing panel's feed: the processor's stage events and real progress, Finish later ending a run at a
/// stage boundary without touching the recording, and the speech model load that outlives the wait.
final class ProcessingPipelineTests: XCTestCase {
    private struct Bench {
        let vault: SessionVault
        let defaults: UserDefaults
        let log: URL
        let root: URL
    }

    /// A model load that waits until the test opens it, standing in for the ten-minute CoreML compile.
    private final class LoadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var loads = 0

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                loads += 1
                if opened {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }

        func open() {
            lock.lock()
            opened = true
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    @MainActor
    private func withBench(_ body: (Bench) async throws -> Void) async throws {
        let id = "ScrumTrace.ProcessingPipelineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let log = root.appendingPathComponent("agent.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AgentLog.setFileURLForTesting(log)
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let vault = SessionVault(rootURL: root.appendingPathComponent("sessions"))
        try await body(Bench(vault: vault, defaults: defaults, log: log, root: root))
    }

    /// A recording that stopped mid-pipeline: a manifest at `transcribing`, two seconds of room audio, no movie.
    private func makeAudioSession(in vault: SessionVault, seconds: Double = 2) throws -> String {
        var manifest = try vault.createSession(product: .empty).manifest
        manifest.pipelineStatus = .transcribing
        manifest.duration = DurationPair(wallSeconds: seconds, mediaSeconds: seconds)
        try vault.write(manifest: &manifest)
        let sessionURL = vault.sessionURL(id: manifest.sessionId)
        let wav = sessionURL.appendingPathComponent(ScrumTracePath.audioWav)
        try FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: wav, settings: settings)
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = 0.3 * sin(Float(frame) * 2 * .pi * 440 / 16_000)
        }
        try file.write(from: buffer)
        try CaptureAudioLayout(microphoneWav: true, systemAudioInMovie: false).write(sessionURL: sessionURL)
        return manifest.sessionId
    }

    private func fakeTranscriber(gate: LoadGate? = nil, fraction: Double? = nil, decodeGate: LoadGate? = nil) -> WhisperTranscriber {
        WhisperTranscriber(loadModel: { _ in
            if let gate { await gate.wait() }
            return WhisperTranscriber.LoadedModel(
                transcribe: { _, _ in
                    if let decodeGate { await decodeGate.wait() }
                    try Task.checkCancellation()
                    return [TranscriptionResult(
                        text: " hello there",
                        segments: [TranscriptionSegment(id: 0, seek: 0, start: 0, end: 1.5, text: " hello there")],
                        language: "en",
                        timings: TranscriptionTimings()
                    )]
                },
                fraction: { fraction }
            )
        })
    }

    private func logRows(at url: URL) throws -> [[String: String]] {
        _ = AgentLog.snapshotFieldsForTesting()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Paths and modification dates of everything in the session folder, so a deferral can be shown to write nothing.
    private func snapshot(of folder: URL) throws -> [String: Date] {
        var result: [String: Date] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            // Files only: a folder's own date moves when a file is created inside it.
            guard values.isRegularFile == true else { continue }
            result[url.path] = values.contentModificationDate
        }
        return result
    }

    private var localConfiguration: AIProviderConfiguration {
        AIProviderConfiguration(
            kind: .openaiCompatible,
            baseURL: "https://example.invalid",
            model: "none",
            apiKey: "",
            acceptsText: true,
            acceptsImages: true,
            acceptsVideo: false
        )
    }

    // MARK: - Processor events

    @MainActor
    func testTheProcessorReportsEveryStageAndRealProgress() async throws {
        try await withBench { bench in
            let id = try makeAudioSession(in: bench.vault)
            let transcriber = fakeTranscriber(fraction: 0.5)
            let processor = SessionProcessor(vault: bench.vault, transcriber: transcriber)
            var events: [ProcessingEvent] = []
            let result = try await processor.process(
                sessionId: id,
                pinTimes: [],
                configuration: localConfiguration,
                whisperModel: WhisperTranscriber.defaultStoredModel,
                onStatus: { _, _ in },
                onEvent: { events.append($0) }
            )
            XCTAssertEqual(result.pipelineStatus, .completed)
            let stages = events.filter {
                if case .progress = $0 { return false }
                return true
            }
            XCTAssertEqual(stages, [
                .stage(.loadingModel),
                .stage(.transcribing),
                .stage(.slicing),
                .skipped(.evaluating, reason: "consent"),
                .stage(.packaging)
            ])
            XCTAssertTrue(events.contains(.progress(.audioSeconds(done: 2, total: 2, passes: 1))), "The pass ends at the full duration: \(events)")
            XCTAssertTrue(events.contains { event in
                if case let .progress(.audioSeconds(done, total, passes)) = event { return done == 0 && total == 2 && passes == 1 }
                return false
            }, "Progress starts at zero")
            let clipCounts = events.compactMap { event -> (Int, Int)? in
                if case let .progress(.count(done, total, unit)) = event, unit == "clips" { return (done, total) }
                return nil
            }
            XCTAssertFalse(clipCounts.isEmpty)
            XCTAssertEqual(clipCounts.last?.0, clipCounts.last?.1, "Every clip reported")
            let timing = try XCTUnwrap(PipelineTiming.load(sessionURL: bench.vault.sessionURL(id: id)))
            XCTAssertGreaterThan(timing.whisperLoadSeconds ?? -1, 0)
            for stage in [ProcessingStage.loadingModel, .transcribing, .slicing, .packaging] {
                XCTAssertNotNil(timing.stageSeconds[stage.rawValue], stage.rawValue)
            }
            XCTAssertNil(timing.stageSeconds[ProcessingStage.evaluating.rawValue], "A skipped stage has no seconds")

            // The same session again: the transcript is already on disk, so the speech stages are reported as done.
            events = []
            _ = try await processor.process(
                sessionId: id,
                pinTimes: [],
                configuration: localConfiguration,
                whisperModel: WhisperTranscriber.defaultStoredModel,
                onStatus: { _, _ in },
                onEvent: { events.append($0) }
            )
            XCTAssertEqual(events.prefix(2).map { $0 }, [
                .skipped(.loadingModel, reason: "already_done"),
                .skipped(.transcribing, reason: "already_done")
            ])
            let rows = try logRows(at: bench.log)
            XCTAssertEqual(rows.filter { $0["event"] == "whisper_prepare_begin" }.count, 1, "One load for both runs")
        }
    }

    @MainActor
    func testACancelledDecodeLeavesTheRecordingUntouched() async throws {
        try await withBench { bench in
            let id = try makeAudioSession(in: bench.vault)
            let sessionURL = bench.vault.sessionURL(id: id)
            let decodeGate = LoadGate()
            let transcriber = fakeTranscriber(decodeGate: decodeGate)
            try await transcriber.prepare()
            let processor = SessionProcessor(vault: bench.vault, transcriber: transcriber)
            let before = try snapshot(of: sessionURL)
            let run = Task {
                try await processor.process(
                    sessionId: id,
                    pinTimes: [],
                    configuration: localConfiguration,
                    whisperModel: WhisperTranscriber.defaultStoredModel,
                    onStatus: { _, _ in }
                )
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            run.cancel()
            decodeGate.open()
            let outcome = await run.result
            guard case let .failure(error) = outcome else { return XCTFail("A cancelled run throws") }
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertEqual(try bench.vault.loadManifest(id: id).pipelineStatus, .transcribing)
            XCTAssertFalse(try bench.vault.loadManifest(id: id).hasCompleted(.transcribing))
            XCTAssertNil(ExportRel.existingSessionFile(ScrumTracePath.fullTranscript, sessionURL: sessionURL), "No transcript was written")
            // The run clears the previous pass's incomplete flag in the timing file before any slow work (develop's
            // incomplete-session recovery); the cancelled pass itself records nothing.
            let timing = PipelineTiming.load(sessionURL: sessionURL)
            XCTAssertEqual(timing?.whisperIncomplete, false)
            XCTAssertNil(timing?.whisperLoadSeconds)
            XCTAssertTrue(timing?.stageSeconds.isEmpty ?? true, "No stage of the cancelled run was recorded")
            let after = try snapshot(of: sessionURL)
            // The manifest is rewritten with the same status and the timing flag is reset when the run starts; nothing
            // else changes.
            let changed = Set(before.keys).symmetricDifference(after.keys)
            XCTAssertTrue(changed.allSatisfy { $0.hasSuffix("pipeline-timing.json") }, "No other file added or removed: \(changed)")
            for (path, date) in before where !path.hasSuffix(ScrumTracePath.manifest) && !path.hasSuffix("pipeline-timing.json") {
                XCTAssertEqual(after[path], date, path)
            }
        }
    }

    // MARK: - The model load outlives the wait

    @MainActor
    func testACancelledPrepareReturnsAtOnceAndTheLoadIsReused() async throws {
        try await withBench { bench in
            let gate = LoadGate()
            let transcriber = fakeTranscriber(gate: gate)
            let waiter = Task { try await transcriber.prepare() }
            let started = await waitUntil { transcriber.isPreparing }
            XCTAssertTrue(started)
            try await Task.sleep(nanoseconds: 100_000_000)
            let cancelledAt = Date()
            waiter.cancel()
            let outcome = await waiter.result
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1, "The caller is released while the load goes on")
            guard case let .failure(error) = outcome else { return XCTFail("The wait ends with CancellationError") }
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertTrue(transcriber.isPreparing, "The load was not cancelled")
            XCTAssertFalse(transcriber.isReady)

            gate.open()
            let ready = await waitUntil { transcriber.isReady }
            XCTAssertTrue(ready)
            XCTAssertFalse(transcriber.isPreparing)
            try await transcriber.prepare()
            XCTAssertEqual(gate.loads, 1, "The next prepare reuses the load")
            let rows = try logRows(at: bench.log)
            XCTAssertEqual(rows.filter { $0["event"] == "whisper_prepare_begin" }.count, 1)
            XCTAssertEqual(rows.filter { $0["event"] == "whisper_prepare_ok" && $0["reuse"] == "1" }.count, 1)
            XCTAssertTrue(rows.contains { $0["event"] == "whisper_prepare_fail" } == false, "A released wait is not a failed load")

            // A second caller that waits on a load in flight is released the same way.
            let secondGate = LoadGate()
            let second = fakeTranscriber(gate: secondGate)
            let first = Task { try await second.prepare() }
            _ = await waitUntil { second.isPreparing }
            let follower = Task { try await second.prepare() }
            try await Task.sleep(nanoseconds: 100_000_000)
            follower.cancel()
            guard case let .failure(followerError) = await follower.result else { return XCTFail("The follower is released") }
            XCTAssertTrue(followerError is CancellationError)
            secondGate.open()
            _ = try await first.value
            XCTAssertTrue(second.isReady)
        }
    }

    @MainActor
    func testEveryStartedLoadIsRecordedForTheExpectations() async throws {
        try await withBench { bench in
            let transcriber = fakeTranscriber()
            transcriber.setModelLoadSink { seconds in
                ProcessingTimingHistory.recordModelLoad(seconds: max(seconds, 0.001), defaults: bench.defaults)
            }
            try await transcriber.prepare()
            try await transcriber.prepare()
            XCTAssertEqual(ProcessingTimingHistory.storedModelLoads(defaults: bench.defaults).count, 1, "Only the load that ran, not the reuse")
        }
    }

    // MARK: - Finish later through the controller

    @MainActor
    func testFinishLaterDefersALaunchResumeWhileTheModelKeepsLoading() async throws {
        try await withBench { bench in
            let stuck = try makeAudioSession(in: bench.vault)
            let sessionURL = bench.vault.sessionURL(id: stuck)
            let gate = LoadGate()
            let transcriber = fakeTranscriber(gate: gate)
            let controller = SessionController(settings: AppSettings(defaults: bench.defaults, keyStore: .empty), vault: bench.vault, transcriber: transcriber)
            XCTAssertNil(controller.processing)
            XCTAssertTrue(controller.hudShouldShow == false)
            let before = try snapshot(of: sessionURL)

            XCTAssertTrue(controller.resumeInterruptedSession())
            let loading = await waitUntil { controller.processing?.current == .loadingModel }
            XCTAssertTrue(loading, "The panel reaches Loading speech model: \(String(describing: controller.processing))")
            let status = try XCTUnwrap(controller.processing)
            XCTAssertEqual(status.sessionId, stuck)
            XCTAssertEqual(status.origin, .launchResume)
            XCTAssertNotNil(status.recordedAt)
            XCTAssertEqual(status.mediaSeconds, 2)
            XCTAssertEqual(status.record(for: .resuming)?.isOpen, false, "Resuming ended when the model load began")
            XCTAssertTrue(controller.canFinishLater)
            XCTAssertTrue(controller.processingPanelShouldShow)
            XCTAssertFalse(controller.hudShouldShow, "The panel stands in for the pill")
            XCTAssertFalse(controller.canChangeCaptureSettings)
            let panel = ProcessingPanelState.make(status, modelStillLoading: transcriber.isPreparing)
            XCTAssertEqual(panel.rows[0].title, "Resuming last recording")
            XCTAssertEqual(panel.rows[1].state, .active)
            XCTAssertTrue(panel.showsFinishLater)

            controller.finishLater()
            let released = await waitUntil { !controller.isBusy }
            XCTAssertTrue(released, "Finish later returns within seconds while the load is stuck")
            XCTAssertEqual(controller.processing?.outcome, .deferred)
            XCTAssertFalse(controller.canFinishLater)
            XCTAssertTrue(controller.canChangeCaptureSettings, "Start recording is available again")
            XCTAssertTrue(controller.processingPanelShouldShow, "The deferred status stays until Close")
            XCTAssertEqual(controller.lastSessionId, stuck, "The menu's Retry analysis still names it")
            XCTAssertEqual(controller.statusLine, "Finish later — Retry analysis finishes this recording")
            XCTAssertEqual(try bench.vault.loadManifest(id: stuck).pipelineStatus, .transcribing, "Still resumable")
            XCTAssertTrue(transcriber.isPreparing, "The model keeps loading in the background")
            XCTAssertEqual(
                ProcessingPanelState.make(try XCTUnwrap(controller.processing), modelStillLoading: transcriber.isPreparing).footer,
                ProcessingPanelState.deferredModelFooter
            )
            let after = try snapshot(of: sessionURL)
            // The manifest and the timing file's incomplete flag are written when the run starts, before any slow work.
            let changed = Set(before.keys).symmetricDifference(after.keys)
            XCTAssertTrue(changed.allSatisfy { $0.hasSuffix("pipeline-timing.json") }, "Nothing else added or removed: \(changed)")
            for (path, date) in before where !path.hasSuffix(ScrumTracePath.manifest) && !path.hasSuffix("pipeline-timing.json") {
                XCTAssertEqual(after[path], date, path)
            }
            XCTAssertNil(PipelineTiming.load(sessionURL: sessionURL)?.whisperLoadSeconds, "The deferred load recorded nothing")

            let rows = try logRows(at: bench.log)
            let first = try XCTUnwrap(rows.first { $0["event"] == "processing_stage" })
            XCTAssertEqual(first["stage"], "resuming")
            XCTAssertEqual(first["origin"], "launch_resume")
            XCTAssertEqual(first["session"], stuck)
            let second = try XCTUnwrap(rows.first { $0["event"] == "processing_stage" && $0["stage"] == "loading_model" })
            XCTAssertEqual(second["prev"], "resuming")
            XCTAssertNotNil(Int(second["prev_seconds"] ?? ""))
            XCTAssertTrue(rows.contains { $0["event"] == "processing_defer" && $0["stage"] == "loading_model" && $0["session"] == stuck })
            XCTAssertTrue(rows.contains { $0["event"] == "processor_deferred" && $0["session"] == stuck })
            XCTAssertFalse(rows.contains { $0["event"] == "processor_fail" })
            // Every row carries the same diagnostics (`run_id`, `pid`, signing fields, …); the stage rows add only these.
            let baseline = try XCTUnwrap(rows.first { $0["event"] == "retry_begin" })
            let commonKeys = Set(baseline.keys)
            for row in rows where row["event"] == "processing_stage" {
                let extras = Set(row.keys).subtracting(commonKeys)
                XCTAssertTrue(extras.isSubset(of: ["stage", "prev", "prev_seconds", "origin"]), "\(extras)")
            }

            // The load finishes in the background; the local export run reuses it and ends Done, which clears itself.
            gate.open()
            let ready = await waitUntil { transcriber.isReady }
            XCTAssertTrue(ready)
            controller.processingDoneAutoClearSeconds = 0.2
            controller.regenerateLocalExport(sessionId: stuck)
            let finished = await waitUntil(timeout: 20) { !controller.isBusy }
            XCTAssertTrue(finished)
            let outcome = controller.processing?.outcome
            if case .incomplete = outcome {
                // A local export with no transcript on disk hands off incompletely and keeps Retry.
                XCTAssertTrue(ProcessingPanelState.make(try XCTUnwrap(controller.processing)).showsRetry)
            } else {
                XCTFail("A local-only run without a transcript is incomplete, not \(String(describing: outcome))")
            }
            XCTAssertEqual(gate.loads, 1, "No second model load")
            let skips = try logRows(at: bench.log).filter { $0["event"] == "processing_skip" }
            XCTAssertTrue(skips.contains { $0["stage"] == "transcribing" && $0["reason"] == "local_only" })
            controller.dismissProcessing()
            XCTAssertNil(controller.processing)
            XCTAssertTrue(try logRows(at: bench.log).contains { $0["event"] == "panel_close" && $0["session"] == stuck })
        }
    }

    @MainActor
    func testADoneRunClearsItselfAndAFailedOneKeepsRetry() async throws {
        try await withBench { bench in
            let id = try makeAudioSession(in: bench.vault)
            let transcriber = fakeTranscriber()
            try await transcriber.prepare()
            let controller = SessionController(settings: AppSettings(defaults: bench.defaults, keyStore: .empty), vault: bench.vault, transcriber: transcriber)
            controller.processingDoneAutoClearSeconds = 0.2
            // A session folder that is a symbolic link is refused by the processor before anything is written.
            let sessionURL = bench.vault.sessionURL(id: id)
            let aside = bench.root.appendingPathComponent("session-aside")
            try FileManager.default.moveItem(at: sessionURL, to: aside)
            try FileManager.default.createSymbolicLink(at: sessionURL, withDestinationURL: aside)
            controller.retryAnalysis(sessionId: id)
            let ended = await waitUntil(timeout: 20) { !controller.isBusy }
            XCTAssertTrue(ended)
            let status = try XCTUnwrap(controller.processing)
            guard case let .failed(reason) = status.outcome else {
                return XCTFail("A symlinked archive fails the run: \(status.outcome)")
            }
            XCTAssertEqual(reason, controller.lastError)
            XCTAssertEqual(status.origin, .retry)
            XCTAssertTrue(ProcessingPanelState.make(status).showsRetry)
            XCTAssertTrue(ProcessingPanelState.make(status).showsClose)
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertNotNil(controller.processing, "A failed run never clears itself")
            XCTAssertTrue(try logRows(at: bench.log).contains { $0["event"] == "processor_fail" && $0["session"] == id })

            // Retry from the panel is the same Retry analysis, logged.
            try FileManager.default.removeItem(at: sessionURL)
            try FileManager.default.moveItem(at: aside, to: sessionURL)
            controller.retryFromProcessingPanel()
            let begun = await waitUntil { controller.processing?.isRunning == true || !controller.isBusy }
            XCTAssertTrue(begun)
            XCTAssertTrue(try logRows(at: bench.log).contains { $0["event"] == "panel_retry" && $0["session"] == id })
            controller.finishLater()
            _ = await waitUntil(timeout: 20) { !controller.isBusy }
        }
    }

    @MainActor
    func testThePillAndThePanelShareTheScreenByTurns() async throws {
        try await withBench { bench in
            let controller = SessionController(settings: AppSettings(defaults: bench.defaults, keyStore: .empty), vault: bench.vault, transcriber: fakeTranscriber())
            var running = ProcessingStatus(sessionId: "s", recordedAt: Date(), mediaSeconds: 23, origin: .retry)
            running.enter(.transcribing)
            controller.setProcessingForTesting(running)
            controller.isBusy = true
            XCTAssertFalse(controller.hudShouldShow, "A pipeline run shows the panel, not the pill")
            XCTAssertTrue(controller.processingPanelShouldShow)
            XCTAssertFalse(controller.canFinishLater, "No inner task is running in this test, so nothing can be deferred")

            var ended = running
            ended.finish(.deferred)
            controller.setProcessingForTesting(ended)
            controller.isBusy = false
            XCTAssertFalse(controller.hudShouldShow)
            XCTAssertTrue(controller.processingPanelShouldShow, "A deferred status stays")
            XCTAssertTrue(controller.beginSessionTransfer())
            XCTAssertTrue(controller.hudShouldShow, "A transfer keeps today's pill")
            XCTAssertFalse(controller.processingPanelShouldShow, "and the ended status steps aside while it runs")
            controller.endSessionTransfer()
            XCTAssertTrue(controller.processingPanelShouldShow)

            controller.suppressHUD = true
            XCTAssertFalse(controller.processingPanelShouldShow, "A Shot hides the panel like the pill")
            controller.suppressHUD = false
            controller.setProcessingForTesting(nil)
            controller.isBusy = true
            XCTAssertTrue(controller.hudShouldShow, "Busy without a run is the pill")
            XCTAssertFalse(controller.processingPanelShouldShow)
            controller.isBusy = false
        }
    }
}
