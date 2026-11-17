import AppKit
import XCTest
@testable import ScrumTrace

private actor ComparisonRecorder {
    var requests: [(String, SliceEvaluationRequest)] = []
    var failures: [String: (code: Int, left: Int)] = [:]
    var progressReporter: ProcessingProgressReporter?
    var observedFractions: [Double?] = []
    func observeProgress(_ reporter: ProcessingProgressReporter) { progressReporter = reporter }
    func fractions() -> [Double?] { observedFractions }
    func fail(_ model: String, code: Int, times: Int = 1) { failures[model] = (code: code, left: times) }
    func receive(_ model: String, _ request: SliceEvaluationRequest) throws -> CandidateEvaluationResponse {
        requests.append((model, request))
        if let progressReporter { observedFractions.append(progressReporter.snapshot?.fraction) }
        if let failure = failures[model] {
            if failure.left > 1 {
                failures[model] = (code: failure.code, left: failure.left - 1)
            } else {
                failures[model] = nil
            }
            throw AIProviderError.httpStatus(failure.code, "fixture")
        }
        return CandidateEvaluationResponse(candidates: [])
    }
    func recorded() -> [(String, SliceEvaluationRequest)] { requests }
}

private actor RetrySleepLog {
    var seconds: [TimeInterval] = []
    func add(_ value: TimeInterval) { seconds.append(value) }
    func recorded() -> [TimeInterval] { seconds }
}

private struct RecordingComparisonProvider: AIProvider {
    var kind: AIProviderKind
    var model: String
    var recorder: ComparisonRecorder
    func evaluate(request: SliceEvaluationRequest) async throws -> CandidateEvaluationResponse {
        try await recorder.receive(model, request)
    }
}

final class MultiProviderRunTests: XCTestCase {
    var root: URL!
    var vault: SessionVault!
    var manifest: SessionManifest!
    var transcript: FullTranscript!
    private var recorder: ComparisonRecorder!
    var processor: SessionProcessor!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-tests-\(UUID().uuidString)")
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        vault = SessionVault(rootURL: root)
        manifest = try vault.createSession(product: .empty).manifest
        manifest.slices = (0..<2).map { index in
            SliceRecord(sliceId: "slice-\(index)", startMedia: Double(index * 10), endMedia: Double(index * 10 + 9), trigger: .pin, associatedShotId: nil, clipPath: nil, stills: [], analysisStatus: .pending, score: 1)
        }
        transcript = FullTranscript(sessionId: manifest.sessionId, language: "en", segments: [
            TranscriptSegment(start: 0, end: 8, text: "We should fix this screen.", speaker: "A", words: []),
            TranscriptSegment(start: 10, end: 18, text: "We need a second change.", speaker: "A", words: [])
        ])
        recorder = ComparisonRecorder()
        let recorder = recorder!
        // One attempt per call: these tests pin what a failed pair leaves behind and how Retry Analysis resumes it.
        // The automatic retry inside a run has its own tests at the end of this file.
        processor = SessionProcessor(vault: vault, transcriber: WhisperTranscriber(), retryPolicy: .none, providerFactory: {
            RecordingComparisonProvider(kind: $0.kind, model: $0.model, recorder: recorder)
        })
    }
    private func retryingProcessor(_ policy: ProviderRetryPolicy, sleeps: RetrySleepLog) -> SessionProcessor {
        let recorder: ComparisonRecorder = self.recorder
        return SessionProcessor(vault: vault, transcriber: WhisperTranscriber(), retryPolicy: policy,
            retrySleep: { await sleeps.add($0) },
            providerFactory: { RecordingComparisonProvider(kind: $0.kind, model: $0.model, recorder: recorder) })
    }
    override func tearDownWithError() throws {
        AgentLog.setFileURLForTesting(nil)
        try? FileManager.default.removeItem(at: root)
    }
    func service(_ id: String, kind: AIProviderKind = .openaiCompatible, key: String = "fixture-key") -> AIServiceConfiguration {
        AIServiceConfiguration(service: SavedAIConnection(id: id, name: id, provider: kind, baseURL: "https://example.invalid", model: id),
            configuration: AIProviderConfiguration(kind: kind, baseURL: "https://example.invalid", model: id, apiKey: key, acceptsText: true, acceptsImages: true, acceptsVideo: false))
    }
    func run(_ services: [AIServiceConfiguration], using other: SessionProcessor? = nil) async throws {
        manifest.uploadConsent = UploadConsent(approved: true, approvedAt: Date(), provider: "", endpoint: "", model: "", includesClipAudio: false, includesClipVideo: false, includesStills: true, destinations: services.map(\.destination))
        try await (other ?? processor!).evaluateComparison(manifest: &manifest, transcript: transcript,
            sessionURL: vault.sessionURL(id: manifest.sessionId), services: services) { _, _ in }
    }

    func testSubscriptionServiceIsEvaluatedWithoutAPIKey() async throws {
        var local = service("local", kind: .codexSubscription, key: "")
        local.service.baseURL = AIProviderKind.codexSubscription.defaultBaseURL
        local.configuration.baseURL = local.service.baseURL
        try await run([local])
        let calls = await recorder.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(manifest.slices.allSatisfy { $0.serviceEvaluations.first?.status == .success })
    }

    @MainActor
    func testComparisonPercentageCountsCompletedRequestsAndExcludesCachedSuccesses() async throws {
        try await run([service("cached")])
        let services = [service("cached"), service("new-a"), service("new-b")]
        manifest.uploadConsent.destinations = services.map(\.destination)
        let reporter = ProcessingProgressReporter()
        await recorder.observeProgress(reporter)
        try await processor.evaluateComparison(manifest: &manifest, transcript: transcript,
            sessionURL: vault.sessionURL(id: manifest.sessionId), services: services,
            onProgress: { message, fraction in
                let id = reporter.begin(message)
                reporter.update(id, fraction: fraction)
            }, onStatus: { _, _ in })
        let fractions = await recorder.fractions()
        XCTAssertEqual(fractions, [0, 0.25, 0.5, 0.75], "A request is counted only after its result is saved")
        XCTAssertEqual(reporter.snapshot?.fraction, 1)
    }

    func testIdenticalInputsAcrossProvidersAndUniqueFindingsAcrossSlices() async throws {
        try await run([service("gpt"), service("claude-sonnet-4-20250514", kind: .anthropic), service("gemini", kind: .google)])
        let calls = await recorder.recorded()
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls.map { $0.1.slice.sliceId }, ["slice-0", "slice-1", "slice-0", "slice-1", "slice-0", "slice-1"])
        XCTAssertEqual(calls[0].1.preparedInput, calls[2].1.preparedInput)
        XCTAssertEqual(calls[0].1.preparedInput, calls[4].1.preparedInput)
        XCTAssertTrue(calls.allSatisfy { $0.1.clipURL == nil })
        XCTAssertEqual(Set(manifest.tasks.map(\.taskId)).count, manifest.tasks.count)
        XCTAssertEqual(manifest.slices[0].serviceEvaluations.count, 3)
        XCTAssertEqual(Set(manifest.slices[0].serviceEvaluations.compactMap(\.inputFingerprint)).count, 1)
    }

    func testRetryResumesOnlyFailedPairsAndPersistsSuccesses() async throws {
        await recorder.fail("second", code: 500)
        let services = [service("first"), service("second")]
        try await run(services)
        manifest = try vault.loadManifest(id: manifest.sessionId)
        try await run(services)
        let calls = await recorder.recorded()
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(calls.last?.0, "second")
        XCTAssertEqual(calls.last?.1.slice.sliceId, "slice-0")
        XCTAssertTrue(manifest.slices.allSatisfy { $0.serviceEvaluations.allSatisfy { $0.status == .success } })
    }

    func testMissingKeyDoesNotEraseSuccessAndInvalidServiceDoesNotBlockOthers() async throws {
        try await run([service("first"), service("second", key: "")])
        try await run([service("first", key: ""), service("second")])
        let calls = await recorder.recorded()
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(manifest.slices.allSatisfy { $0.serviceEvaluations.allSatisfy { $0.status == .success } })
    }

    func testAuthenticationFailureStopsAllRemainingUploads() async throws {
        for code in [401, 403] {
            for index in manifest.slices.indices { manifest.slices[index].serviceEvaluations = [] }
            let before = await recorder.recorded().count
            await recorder.fail("first", code: code)
            try await run([service("first"), service("second")])
            let after = await recorder.recorded().count
            XCTAssertEqual(after - before, 1)
        }
    }

    func testChangedInputIsRefusedBeforeSendingToNewService() async throws {
        try await run([service("first")])
        manifest.productContext.appName = "Revised context"
        try await run([service("first"), service("second")])
        let calls = await recorder.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(manifest.slices[0].serviceEvaluations.last?.status, .offlineFailed)
    }

    func testChangedModelInvalidatesOnlyThatService() async throws {
        try await run([service("first"), service("second")])
        var changed = service("second")
        changed.service.model = "second-revised"
        changed.configuration.model = "second-revised"
        try await run([service("first"), changed])
        let calls = await recorder.recorded()
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls.suffix(2).map(\.0), ["second-revised", "second-revised"])
    }

    func testDecliningRetryPreservesSuccessesWithoutGlobalRanking() async throws {
        let services = (0..<8).map { service("model-\($0)") }
        await recorder.fail("model-7", code: 500)
        try await run(services)
        let successful = manifest.tasks.filter { task in
            manifest.slices.first { $0.sliceId == task.sourceSliceId }!.serviceEvaluations.contains {
                $0.serviceId == task.serviceId && $0.status == .success
            }
        }
        XCTAssertEqual(successful.count, 15)
        processor.abandonEvaluate(manifest: &manifest, failedStatus: .skipped, markOffline: false)
        XCTAssertEqual(manifest.tasks, successful)
    }

    func testMissingConsentCannotReachProvider() async throws {
        manifest.uploadConsent = .denied
        do {
            try await processor.evaluateComparison(manifest: &manifest, transcript: transcript,
                sessionURL: vault.sessionURL(id: manifest.sessionId), services: [service("first")]) { _, _ in }
            XCTFail("Consent must be checked at execution")
        } catch { }
        let calls = await recorder.recorded()
        XCTAssertTrue(calls.isEmpty)
    }

    func testInvalidEndpointAndRetiredModelSkipOnlyThoseServices() async throws {
        var invalid = service("invalid")
        invalid.service.baseURL = "http://example.invalid"
        invalid.configuration.baseURL = invalid.service.baseURL
        let retired = service("claude-3-5-sonnet-20241022", kind: .anthropic)
        try await run([invalid, retired, service("valid")])
        let calls = await recorder.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.0 == "valid" })
    }

    func testExportsRenderSeparateSourcesAndFingerprintIncludingNoFindings() async throws {
        var first = service("first")
        first.service.name = "<script>|Service"
        try await run([first, service("second")])
        let url = vault.sessionURL(id: manifest.sessionId)
        let html = SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: url)
        let markdown = AgentContextRenderer().render(manifest: manifest, sessionURL: url)
        let fingerprint = try XCTUnwrap(manifest.slices.first?.serviceEvaluations.first?.inputFingerprint)
        XCTAssertTrue(html.contains("Model comparison"))
        XCTAssertTrue(html.contains("&lt;script&gt;|Service"))
        XCTAssertFalse(html.contains("<script>|Service"))
        XCTAssertTrue(html.contains(fingerprint))
        XCTAssertTrue(markdown.contains(fingerprint))
        XCTAssertTrue(markdown.contains("second"))
        XCTAssertFalse(html.contains("Highlights from the selected evidence"))
        manifest.tasks = []
        XCTAssertTrue(SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: url).contains(fingerprint))
    }

    func testCanonicalJPEGIsFrozenAndByteChangesChangeDigest() async throws {
        let sessionURL = vault.sessionURL(id: manifest.sessionId)
        let imageURL = sessionURL.appendingPathComponent("export/test.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<64 { for y in 0..<64 { rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        try rep.representation(using: .png, properties: [:])!.write(to: imageURL)
        var request = SliceEvaluationRequest(product: .empty, slice: manifest.slices[0], transcriptExcerpt: "fixture", shotNote: "", windowContext: "", imageURLs: [imageURL], clipURL: nil, sessionURL: sessionURL)
        let original = ComparisonInput(request: request)
        XCTAssertEqual(original.images.count, 1)
        request.preparedInput = original
        for x in 0..<64 { for y in 0..<64 { rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: x, y: y) } }
        try rep.representation(using: .png, properties: [:])!.write(to: imageURL)
        XCTAssertEqual(request.imagePayloads, original.images)
        request.preparedInput = nil
        XCTAssertNotEqual(try ComparisonInput(request: request).fingerprint(), try original.fingerprint())
    }

    // MARK: - Automatic retry inside a run

    func testATransientFailureIsRetriedInsideTheSameRun() async throws {
        let sleeps = RetrySleepLog()
        await recorder.fail("second", code: 503)
        try await run([service("first"), service("second")], using: retryingProcessor(.standard, sleeps: sleeps))
        let calls = await recorder.recorded()
        XCTAssertEqual(calls.map(\.0), ["first", "first", "second", "second", "second"], "The failed call is repeated at once")
        XCTAssertEqual(calls[2].1.slice.sliceId, "slice-0")
        XCTAssertEqual(calls[3].1.slice.sliceId, "slice-0")
        XCTAssertTrue(manifest.slices.allSatisfy { $0.serviceEvaluations.allSatisfy { $0.status == .success } })
        XCTAssertNotEqual(manifest.pipelineStatus, .offlineFailed, "No manual Retry Analysis is needed")
        let waited = await sleeps.recorded()
        XCTAssertEqual(waited, [2])
    }

    func testRetriesStopAtTheAttemptLimitAndAtTheRunBudget() async throws {
        let sleeps = RetrySleepLog()
        await recorder.fail("down", code: 500, times: 100)
        let policy = ProviderRetryPolicy(maxAttempts: 3, delays: [2, 6], runBudget: 3)
        try await run([service("down")], using: retryingProcessor(policy, sleeps: sleeps))
        let calls = await recorder.recorded()
        XCTAssertEqual(calls.map { $0.1.slice.sliceId }, ["slice-0", "slice-0", "slice-0", "slice-1", "slice-1"],
            "Three attempts for the first slice, then the run's budget of three extra attempts ends the second one early")
        XCTAssertTrue(manifest.slices.allSatisfy { $0.serviceEvaluations.first?.status == .offlineFailed })
        XCTAssertEqual(manifest.pipelineStatus, .offlineFailed, "An outage still ends in a manual Retry Analysis")
        let waited = await sleeps.recorded()
        XCTAssertEqual(waited, [2, 6, 2])
    }

    func testSignInAndPermanentFailuresAreNeverRetried() async throws {
        let sleeps = RetrySleepLog()
        let retrying = retryingProcessor(.standard, sleeps: sleeps)
        await recorder.fail("auth", code: 401, times: 100)
        try await run([service("auth")], using: retrying)
        let afterAuth = await recorder.recorded().count
        XCTAssertEqual(afterAuth, 1, "A sign-in failure stops the run after one call")

        for index in manifest.slices.indices { manifest.slices[index].serviceEvaluations = [] }
        await recorder.fail("bad-request", code: 400, times: 100)
        try await run([service("bad-request")], using: retrying)
        let afterPermanent = await recorder.recorded().count
        XCTAssertEqual(afterPermanent - afterAuth, 2, "One call per slice")
        let waited = await sleeps.recorded()
        XCTAssertEqual(waited, [])
    }

    func testOnlyTransientFailuresCountAsRetryable() {
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(ProviderRetryPolicy.isTransient(AIProviderError.httpStatus(code, "")), "HTTP \(code)")
        }
        for code in [400, 401, 403, 404, 422] {
            XCTAssertFalse(ProviderRetryPolicy.isTransient(AIProviderError.httpStatus(code, "")), "HTTP \(code)")
        }
        XCTAssertTrue(ProviderRetryPolicy.isTransient(LocalAgentError.failed))
        XCTAssertFalse(ProviderRetryPolicy.isTransient(LocalAgentError.timedOut), "A three-minute local timeout is not repeated")
        XCTAssertFalse(ProviderRetryPolicy.isTransient(LocalAgentError.signInRequired))
        XCTAssertFalse(ProviderRetryPolicy.isTransient(LocalAgentError.notInstalled))
        XCTAssertFalse(ProviderRetryPolicy.isTransient(LocalAgentError.unsupported))
        XCTAssertTrue(ProviderRetryPolicy.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(ProviderRetryPolicy.isTransient(URLError(.timedOut)))
        XCTAssertFalse(ProviderRetryPolicy.isTransient(URLError(.badURL)))
        XCTAssertFalse(ProviderRetryPolicy.isTransient(AIProviderError.missingAPIKey))
        XCTAssertFalse(ProviderRetryPolicy.isTransient(AIProviderError.decoding("fixture")))
        XCTAssertFalse(ProviderRetryPolicy.isTransient(CancellationError()))
    }

    func testRetryDelaysFollowThePolicyAndRepeatTheLastValue() {
        let policy = ProviderRetryPolicy.standard
        XCTAssertEqual(policy.delay(beforeAttempt: 1), 0)
        XCTAssertEqual(policy.delay(beforeAttempt: 2), 2)
        XCTAssertEqual(policy.delay(beforeAttempt: 3), 6)
        XCTAssertEqual(policy.delay(beforeAttempt: 9), 6)
        XCTAssertEqual(ProviderRetryPolicy.none.delay(beforeAttempt: 2), 0)
        XCTAssertEqual(ProviderRetryPolicy.none.maxAttempts, 1)
    }
}
