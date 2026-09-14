import AppKit
import XCTest
@testable import ScrumTrace

private actor ComparisonRecorder {
    var requests: [(String, SliceEvaluationRequest)] = []
    var failures: [String: Int] = [:]
    func fail(_ model: String, code: Int) { failures[model] = code }
    func receive(_ model: String, _ request: SliceEvaluationRequest) throws -> CandidateEvaluationResponse {
        requests.append((model, request))
        if let code = failures.removeValue(forKey: model) { throw AIProviderError.httpStatus(code, "fixture") }
        return CandidateEvaluationResponse(candidates: [])
    }
    func recorded() -> [(String, SliceEvaluationRequest)] { requests }
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
        processor = SessionProcessor(vault: vault, transcriber: WhisperTranscriber(), providerFactory: {
            RecordingComparisonProvider(kind: $0.kind, model: $0.model, recorder: recorder)
        })
    }
    override func tearDownWithError() throws {
        AgentLog.setFileURLForTesting(nil)
        try? FileManager.default.removeItem(at: root)
    }
    func service(_ id: String, kind: AIProviderKind = .openaiCompatible, key: String = "fixture-key") -> AIServiceConfiguration {
        AIServiceConfiguration(service: SavedAIConnection(id: id, name: id, provider: kind, baseURL: "https://example.invalid", model: id),
            configuration: AIProviderConfiguration(kind: kind, baseURL: "https://example.invalid", model: id, apiKey: key, acceptsText: true, acceptsImages: true, acceptsVideo: false))
    }
    func run(_ services: [AIServiceConfiguration]) async throws {
        manifest.uploadConsent = UploadConsent(approved: true, approvedAt: Date(), provider: "", endpoint: "", model: "", includesClipAudio: false, includesClipVideo: false, includesStills: true, destinations: services.map(\.destination))
        try await processor.evaluateComparison(manifest: &manifest, transcript: transcript,
            sessionURL: vault.sessionURL(id: manifest.sessionId), services: services) { _, _ in }
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
}
