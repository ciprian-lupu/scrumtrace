import XCTest
@testable import ScrumTrace

final class ContractTests: XCTestCase {
    func testExportRelStripsExportPrefixAndLeavesArchive() {
        XCTAssertEqual(ExportRel.toExportRoot("export/shots/001.jpg"), "shots/001.jpg")
        XCTAssertEqual(ExportRel.toExportRoot("shots/001.jpg"), "shots/001.jpg")
        XCTAssertEqual(ExportRel.sessionPath("shots/001.jpg"), "export/shots/001.jpg")
        XCTAssertEqual(ExportRel.sessionPath("archive/session.mp4"), "archive/session.mp4")
        XCTAssertTrue(ExportRel.isUnderExport("export/media/task-01/clip.mp4"))
        XCTAssertFalse(ExportRel.isUnderExport("archive/session.mp4"))
        XCTAssertEqual(ExportRel.handoffPath("export/shots/001.jpg"), "shots/001.jpg")
        XCTAssertNil(ExportRel.handoffPath("archive/session.mp4"))
        XCTAssertNil(ExportRel.handoffPath("archive/shots/001.png"))
    }

    func testTaskRankingPrefersHumanShotsAndConfirmed() {
        func task(
            id: String,
            status: TaskStatus,
            confidence: Double,
            evidence: [String]
        ) -> TaskRecord {
            TaskRecord(
                taskId: id,
                sourceSliceId: "slice-01",
                kind: .bug,
                status: status,
                title: id,
                observed: "x",
                stated: "",
                inferred: "",
                agentInstructions: "inspect",
                quotes: [],
                evidenceMedia: evidence,
                confidence: confidence
            )
        }
        let keyword = task(id: "TASK-K", status: .confirmed, confidence: 0.99, evidence: ["media/keyword.mp4"])
        let shot = task(id: "TASK-S", status: .needsReview, confidence: 0.2, evidence: ["shots/001.jpg"])
        let extra = (1...8).map { i in
            task(id: "TASK-X\(i)", status: .needsReview, confidence: 0.1, evidence: ["media/task-\(i)/clip.mp4"])
        }
        let selected = TaskRanking.selectForPack([keyword] + extra + [shot], limit: 8)
        XCTAssertEqual(selected.count, 8)
        XCTAssertEqual(selected.first?.title, "TASK-S")
        XCTAssertTrue(selected.contains { $0.title == "TASK-K" })
    }

    func testQuoteMustOverlapTranscriptSegment() {
        let transcript = FullTranscript(
            sessionId: "s",
            language: "en",
            segments: [
                TranscriptSegment(
                    start: 10,
                    end: 14,
                    text: "this does nothing it should store the athlete",
                    speaker: nil,
                    words: []
                )
            ]
        )
        let good = QuoteRecord(
            speaker: "presenter",
            text: "this does nothing",
            tMediaStart: 10.5,
            tMediaEnd: 13
        )
        XCTAssertTrue(EvidenceValidator.quoteMatchesTranscript(good, transcript: transcript))
        let missing = QuoteRecord(
            speaker: "presenter",
            text: "invented passphrase",
            tMediaStart: 10.5,
            tMediaEnd: 13
        )
        XCTAssertFalse(EvidenceValidator.quoteMatchesTranscript(missing, transcript: transcript))
    }

    func testInferredCopiedIntoObservedBlocksConfirm() {
        let candidate = CandidateRecord(
            decision: .keep,
            confidence: 0.9,
            kind: .bug,
            title: "Save",
            observed: "likely a validation bug",
            stated: "it should store",
            inferred: "likely a validation bug",
            agentInstructionsDraft: "draft",
            quotes: [],
            frameReferences: ["archive/shots/001.png"]
        )
        let slice = SliceRecord(
            sliceId: "slice-01",
            startMedia: 0,
            endMedia: 20,
            trigger: .shot,
            associatedShotId: nil,
            clipPath: nil,
            stills: [],
            analysisStatus: .success,
            score: 1
        )
        let issues = EvidenceValidator.canConfirm(
            candidate: candidate,
            slice: slice,
            transcript: FullTranscript(sessionId: "s", language: "en", segments: []),
            sessionURL: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertTrue(issues.contains { $0.reason.contains("inferred") })
    }

    func testStripOmittedDemotesConfirmedWithoutEvidence() {
        var manifest = SessionManifest.makeNew(sessionId: "s", product: .empty)
        manifest.tasks = [
            TaskRecord(
                taskId: "TASK-01",
                sourceSliceId: "slice-01",
                kind: .bug,
                status: .confirmed,
                title: "Save",
                observed: "x",
                stated: "",
                inferred: "",
                agentInstructions: "inspect",
                quotes: [],
                evidenceMedia: ["media/keyword.mp4"],
                confidence: 0.9
            )
        ]
        let stripped = PackBudget.stripOmitted(
            [OmittedAsset(path: "media/keyword.mp4", reason: "over cap")],
            from: manifest
        )
        XCTAssertEqual(stripped.tasks[0].status, .needsReview)
        XCTAssertTrue(stripped.tasks[0].evidenceMedia.isEmpty)
    }

    func testMergePinsDedupesHundredths() {
        XCTAssertEqual(
            SessionController.mergePins([10.0, 30.0], [10.004, 20.0]),
            [10.0, 20.0, 30.0]
        )
    }

    func testShouldTranscribeMovieAvoidsDuplicatingSystemWav() {
        let both = CaptureAudioLayout.both
        XCTAssertTrue(both.shouldTranscribeMovie(wavExists: true, movieExists: true))
        let systemWav = CaptureAudioLayout(microphoneWav: false, systemAudioInMovie: true)
        XCTAssertFalse(systemWav.shouldTranscribeMovie(wavExists: true, movieExists: true))
        XCTAssertTrue(systemWav.shouldTranscribeMovie(wavExists: false, movieExists: true))
        XCTAssertFalse(systemWav.shouldTranscribeMovie(wavExists: false, movieExists: false))
    }

    func testTranscriptMergeCollapsesBleedAndKeepsDistinctSpeech() {
        let room = FullTranscript(
            sessionId: "",
            language: "en",
            segments: [
                TranscriptSegment(start: 1, end: 3, text: "this does nothing", speaker: nil, words: []),
                TranscriptSegment(start: 10, end: 12, text: "restart ingest-worker", speaker: nil, words: [])
            ]
        )
        let system = FullTranscript(
            sessionId: "",
            language: "en",
            segments: [
                TranscriptSegment(start: 1.1, end: 3.1, text: "this does nothing", speaker: nil, words: []),
                TranscriptSegment(start: 4, end: 6, text: "enable TRACE_SYNC", speaker: nil, words: [])
            ]
        )
        let merged = TranscriptQuery.merge(
            [
                TranscriptQuery.SourcePass(speaker: "room", transcript: room),
                TranscriptQuery.SourcePass(speaker: "system", transcript: system)
            ],
            sessionId: "s"
        )
        XCTAssertEqual(merged.sources, ["room", "system"])
        XCTAssertEqual(merged.segments.count, 3)
        XCTAssertTrue(merged.segments.contains { $0.text == "enable TRACE_SYNC" })
        XCTAssertTrue(merged.segments.contains { $0.text == "restart ingest-worker" })
        XCTAssertEqual(merged.segments.filter { EvidenceValidator.normalize($0.text) == "this does nothing" }.count, 1)
    }

    func testPipelineTimingRoundTrip() throws {
        let timing = PipelineTiming(
            whisperWallSeconds: 12.5,
            whisperSources: ["room", "system"],
            zipBytes: 1_048_576,
            omittedCount: 2
        )
        let data = try JSONEncoder().encode(timing)
        let decoded = try JSONDecoder().decode(PipelineTiming.self, from: data)
        XCTAssertEqual(decoded.whisperWallSeconds, 12.5)
        XCTAssertEqual(decoded.whisperSources, ["room", "system"])
        XCTAssertEqual(decoded.zipBytes, 1_048_576)
        XCTAssertEqual(decoded.omittedCount, 2)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("whisper_wall_seconds") == true)
    }

    func testFrameReferenceResolvesBasename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrumtrace-ev-\(UUID().uuidString)")
        let shots = root.appendingPathComponent("archive/shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let file = shots.appendingPathComponent("001.png")
        try Data("png".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            EvidenceValidator.resolvePath("001.png", sessionURL: root),
            "archive/shots/001.png"
        )
        XCTAssertEqual(
            EvidenceValidator.resolvePath("shots/001.png", sessionURL: root),
            "archive/shots/001.png"
        )
        XCTAssertNil(EvidenceValidator.resolvePath("missing.png", sessionURL: root))
    }

    func testMergedSlicesStayWithinClipMax() {
        let shots = [
            ShotRecord(id: "shot-001", tMedia: 10, rawPath: "archive/shots/001.png", annotatedPath: nil, note: "a", source: .typed),
            ShotRecord(id: "shot-002", tMedia: 28, rawPath: "archive/shots/002.png", annotatedPath: nil, note: "b", source: .typed)
        ]
        let slices = MeetingSlicer().slice(
            shots: shots,
            pins: [],
            transcript: FullTranscript(sessionId: "s", language: "en", segments: []),
            mediaDuration: 120
        )
        XCTAssertFalse(slices.isEmpty)
        for slice in slices {
            XCTAssertLessThanOrEqual(slice.endMedia - slice.startMedia, MediaBudget.clipMaxDuration + 0.001)
        }
    }

    func testSlicerDoesNotInventMissingStills() {
        let slices = MeetingSlicer().slice(
            shots: [],
            pins: [12],
            transcript: FullTranscript(sessionId: "s", language: "en", segments: []),
            mediaDuration: 60
        )
        XCTAssertEqual(slices.count, 1)
        XCTAssertTrue(slices[0].stills.isEmpty)
        XCTAssertEqual(slices[0].clipPath, "archive/media-work/task-01/clip.mp4")
    }

    func testWithExistingMediaDropsMissingClipAndStills() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrumtrace-media-\(UUID().uuidString)")
        let shots = root.appendingPathComponent("archive/shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: shots.appendingPathComponent("001.png"))
        defer { try? FileManager.default.removeItem(at: root) }
        let slice = SliceRecord(
            sliceId: "slice-01",
            startMedia: 0,
            endMedia: 20,
            trigger: .pin,
            associatedShotId: nil,
            clipPath: "archive/media-work/task-01/clip.mp4",
            stills: ["archive/shots/001.png", "archive/media-work/task-01/shot-1.jpg"],
            analysisStatus: .pending,
            score: 80
        )
        let kept = slice.withExistingMedia(sessionURL: root)
        XCTAssertNil(kept.clipPath)
        XCTAssertEqual(kept.stills, ["archive/shots/001.png"])
    }

    func testConsentRepromptOnlyWhenNeverAskedOrDestinationOrPayloadChanges() {
        let empty = UploadConsent.denied
        XCTAssertTrue(
            empty.needsReprompt(
                provider: "openai_compatible",
                endpoint: "https://api.openai.com",
                model: "gpt-4o",
                acceptsVideo: false
            )
        )
        let askedLocal = UploadConsent(
            approved: false,
            approvedAt: Date(),
            provider: "openai_compatible",
            endpoint: "https://api.openai.com",
            model: "gpt-4o",
            includesClipAudio: false,
            includesStills: false
        )
        XCTAssertFalse(
            askedLocal.needsReprompt(
                provider: "openai_compatible",
                endpoint: "https://api.openai.com",
                model: "gpt-4o",
                acceptsVideo: false
            )
        )
        XCTAssertTrue(
            askedLocal.needsReprompt(
                provider: "openai_compatible",
                endpoint: "https://api.openai.com",
                model: "gpt-4.1",
                acceptsVideo: false
            )
        )
        let approvedVideo = UploadConsent(
            approved: true,
            approvedAt: Date(),
            provider: "openai_compatible",
            endpoint: "https://api.openai.com",
            model: "gpt-4o",
            includesClipAudio: true,
            includesStills: true
        )
        XCTAssertTrue(
            approvedVideo.needsReprompt(
                provider: "openai_compatible",
                endpoint: "https://api.openai.com",
                model: "gpt-4o",
                acceptsVideo: false
            )
        )
    }

    func testShippedAdaptersNeverAttachMp4() {
        let configuration = AIProviderConfiguration(
            kind: .openaiCompatible,
            baseURL: "https://api.openai.com",
            model: "gpt-4o",
            apiKey: "sk-test",
            acceptsText: true,
            acceptsImages: true,
            acceptsVideo: true
        )
        let request = SliceEvaluationRequest(
            product: .empty,
            slice: SliceRecord(
                sliceId: "slice-01",
                startMedia: 0,
                endMedia: 20,
                trigger: .shot,
                associatedShotId: nil,
                clipPath: "archive/media-work/task-01/clip.mp4",
                stills: [],
                analysisStatus: .pending,
                score: 1
            ),
            transcriptExcerpt: "hello",
            shotNote: "",
            windowContext: "",
            imageURLs: [],
            clipURL: URL(fileURLWithPath: "/tmp/clip.mp4")
        )
        XCTAssertNil(ProviderWireMedia.mp4BodyURL(configuration: configuration, request: request))
        var noVideo = configuration
        noVideo.acceptsVideo = false
        XCTAssertNil(ProviderWireMedia.mp4BodyURL(configuration: noVideo, request: request))
    }

    func testKeywordTaskClipIsDroppedAfterExtraStills() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrumtrace-omit-\(UUID().uuidString)")
        let media = root.appendingPathComponent("export/media/task-01")
        let shots = root.appendingPathComponent("export/shots")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: media.appendingPathComponent("clip.mp4"))
        try Data("still".utf8).write(to: shots.appendingPathComponent("extra.jpg"))
        defer { try? FileManager.default.removeItem(at: root) }

        var manifest = SessionManifest.makeNew(sessionId: "s", product: .empty)
        manifest.slices = [
            SliceRecord(
                sliceId: "slice-01",
                startMedia: 0,
                endMedia: 20,
                trigger: .keyword,
                associatedShotId: nil,
                clipPath: "media/task-01/clip.mp4",
                exportClipPath: "media/task-01/clip.mp4",
                stills: ["shots/extra.jpg"],
                analysisStatus: .success,
                score: 40
            )
        ]
        manifest.tasks = [
            TaskRecord(
                taskId: "TASK-01",
                sourceSliceId: "slice-01",
                kind: .bug,
                status: .confirmed,
                title: "Ingest",
                observed: "x",
                stated: "",
                inferred: "",
                agentInstructions: "inspect",
                quotes: [],
                evidenceMedia: ["media/task-01/clip.mp4"],
                confidence: 0.9
            )
        ]
        let order = PackBudget.omissionOrder(manifest: manifest, sessionURL: root)
        let clipIdx = order.firstIndex(of: "export/media/task-01/clip.mp4")
        let extraIdx = order.firstIndex(of: "export/shots/extra.jpg")
        XCTAssertNotNil(clipIdx)
        XCTAssertNotNil(extraIdx)
        XCTAssertLessThan(extraIdx!, clipIdx!)
    }
}
