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
        XCTAssertEqual(ExportRel.omittedHandoffPath("archive/shots/001.png"), "shots/001.png")
        XCTAssertEqual(ExportRel.omittedHandoffPath("export/media/task-01/clip.mp4"), "media/task-01/clip.mp4")
        XCTAssertFalse(ExportRel.omittedHandoffPath("archive/session.mp4").hasPrefix("archive/"))
        XCTAssertFalse(ExportRel.isUnderExport("export/../archive/session.mp4"))
        XCTAssertFalse(ExportRel.isUnderExport("export/../../etc/passwd"))
        XCTAssertNil(ExportRel.handoffPath("export/../archive/session.mp4"))
        XCTAssertNil(ExportRel.handoffPath("export/../../etc/passwd"))
        XCTAssertNil(ExportRel.handoffPath("/tmp/shots/001.jpg"))
        XCTAssertEqual(ExportRel.sessionPath("export/../shots/001.jpg"), "export/shots/001.jpg")
        XCTAssertEqual(ExportRel.handoffPath("export/../shots/001.jpg"), "shots/001.jpg")
        XCTAssertEqual(ExportRel.sessionPath("export/../archive/session.mp4"), "archive/session.mp4")
        XCTAssertNil(ExportRel.normalizedComponents("export/foo/../../.."))
    }

    func testWhisperKitModelNamePrefixesShortAlias() {
        XCTAssertEqual(
            WhisperTranscriber.whisperKitModelName("large-v3-turbo"),
            "openai_whisper-large-v3-turbo"
        )
        XCTAssertEqual(
            WhisperTranscriber.whisperKitModelName("openai_whisper-large-v3-turbo"),
            "openai_whisper-large-v3-turbo"
        )
        XCTAssertEqual(
            WhisperTranscriber.whisperKitModelName(""),
            "openai_whisper-large-v3-turbo"
        )
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

    func testUnknownKindBlocksConfirm() {
        let candidate = CandidateRecord(
            decision: .keep,
            confidence: 0.9,
            kind: .unknown,
            title: "Save",
            observed: "button is gray",
            stated: "it should store",
            inferred: "validation",
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
        XCTAssertTrue(issues.contains { $0.reason.contains("unknown task kind") })
    }

    func testCandidateDecisionUnknownFallsBackToNeedsReview() throws {
        let json = Data(#""maybe_later""#.utf8)
        let decoded = try JSONDecoder().decode(CandidateDecision.self, from: json)
        XCTAssertEqual(decoded, .needsReview)
        let kind = try JSONDecoder().decode(TaskKind.self, from: Data(#""feature_request""#.utf8))
        XCTAssertEqual(kind, .unknown)
        let status = try JSONDecoder().decode(TaskStatus.self, from: Data(#""maybe""#.utf8))
        XCTAssertEqual(status, .needsReview)
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

    func testMergedOverlappingShotsUnionStills() {
        let shots = [
            ShotRecord(
                id: "shot-001",
                tMedia: 10,
                rawPath: "archive/shots/001.png",
                annotatedPath: nil,
                note: "save control",
                source: .typed
            ),
            ShotRecord(
                id: "shot-002",
                tMedia: 28,
                rawPath: "archive/shots/002.png",
                annotatedPath: "archive/shots/002.annotated.png",
                note: "ingest overlay",
                source: .typed
            )
        ]
        let slices = MeetingSlicer().slice(
            shots: shots,
            pins: [],
            transcript: FullTranscript(sessionId: "s", language: "en", segments: []),
            mediaDuration: 120
        )
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(
            Set(slices[0].stills),
            ["archive/shots/001.png", "archive/shots/002.annotated.png"]
        )
        XCTAssertEqual(slices[0].associatedShotId, "shot-001")
        XCTAssertEqual(
            MeetingSlicer.unionStills(["a.png", "b.png"], ["b.png", "c.png"]),
            ["a.png", "b.png", "c.png"]
        )
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
        XCTAssertFalse(ProviderWireMedia.willUploadClip(configuration: configuration))
        XCTAssertFalse(ProviderWireMedia.adaptersUploadVideo)
        var noVideo = configuration
        noVideo.acceptsVideo = false
        XCTAssertNil(ProviderWireMedia.mp4BodyURL(configuration: noVideo, request: request))
        XCTAssertFalse(ProviderWireMedia.willUploadClip(configuration: noVideo))
    }

    func testApplyExportEvidenceDemotesConfirmedWithoutExportFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrumtrace-export-ev-\(UUID().uuidString)")
        let shots = root.appendingPathComponent("export/shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: shots.appendingPathComponent("001.jpg"))
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = TaskRecord(
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
            evidenceMedia: ["shots/001.jpg"],
            confidence: 0.9
        )
        let missing = TaskRecord(
            taskId: "TASK-02",
            sourceSliceId: "slice-02",
            kind: .bug,
            status: .confirmed,
            title: "Missing still",
            observed: "x",
            stated: "",
            inferred: "",
            agentInstructions: "inspect",
            quotes: [],
            evidenceMedia: ["shots/missing.jpg"],
            confidence: 0.9
        )
        let archiveOnly = TaskRecord(
            taskId: "TASK-03",
            sourceSliceId: "slice-03",
            kind: .bug,
            status: .confirmed,
            title: "Archive only",
            observed: "x",
            stated: "",
            inferred: "",
            agentInstructions: "inspect",
            quotes: [],
            evidenceMedia: ["archive/shots/001.png"],
            confidence: 0.9
        )
        let applied = EvidenceValidator.applyExportEvidence(
            tasks: [kept, missing, archiveOnly],
            sessionURL: root
        )
        XCTAssertEqual(applied[0].status, .confirmed)
        XCTAssertEqual(applied[0].evidenceMedia, ["shots/001.jpg"])
        XCTAssertEqual(applied[1].status, .needsReview)
        XCTAssertTrue(applied[1].evidenceMedia.isEmpty)
        XCTAssertEqual(applied[2].status, .needsReview)
        XCTAssertTrue(applied[2].evidenceMedia.isEmpty)
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

    func testAuthFailureStopsFurtherUploads() {
        XCTAssertTrue(AIProviderError.httpStatus(401, "invalid").isAuthFailure)
        XCTAssertTrue(AIProviderError.httpStatus(403, "forbidden").isAuthFailure)
        XCTAssertTrue(AIProviderError.missingAPIKey.isAuthFailure)
        XCTAssertFalse(AIProviderError.httpStatus(429, "rate").isAuthFailure)
        XCTAssertFalse(AIProviderError.emptyResponse.isAuthFailure)
        XCTAssertTrue(AIProviderError.isAuthFailure(AIProviderError.httpStatus(401, "")))
        XCTAssertFalse(AIProviderError.isAuthFailure(AIProviderError.emptyResponse))
    }

    func testProjectClearsStaleExportArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrumtrace-export-reset-\(UUID().uuidString)")
        let archive = root.appendingPathComponent("archive")
        let export = root.appendingPathComponent("export")
        let orphan = export.appendingPathComponent("media/task-99")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("stale-export-transcript").write(to: export.appendingPathComponent("full_transcript.json"))
        try Data("orphan-clip").write(to: orphan.appendingPathComponent("clip.mp4"))
        try Data("archive-transcript").write(to: archive.appendingPathComponent("full_transcript.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = SessionManifest.makeNew(sessionId: "reset-export", product: .empty)
        _ = try ExportProjector().project(
            sessionURL: root,
            manifest: manifest,
            includeFullTranscript: false
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.appendingPathComponent("full_transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.appendingPathComponent("clip.mp4").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: archive.appendingPathComponent("full_transcript.json").path)
        )

        _ = try ExportProjector().project(
            sessionURL: root,
            manifest: manifest,
            includeFullTranscript: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("full_transcript.json").path))
        XCTAssertEqual(
            try String(contentsOf: export.appendingPathComponent("full_transcript.json"), encoding: .utf8),
            "archive-transcript"
        )
    }

    func testAllowListOmitsTranscriptUnlessOptedIn() throws {
        let export = FileManager.default.temporaryDirectory.appendingPathComponent("scrumtrace-allow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Data("# ctx\n").write(to: export.appendingPathComponent("AGENT_CONTEXT.md"))
        try Data("{}").write(to: export.appendingPathComponent("full_transcript.json"))
        defer { try? FileManager.default.removeItem(at: export) }
        XCTAssertFalse(PackBudget.allowList(exportDir: export, includeFullTranscript: false).contains("full_transcript.json"))
        XCTAssertTrue(PackBudget.allowList(exportDir: export, includeFullTranscript: true).contains("full_transcript.json"))
    }

    func testCanConfirmRequiresKeepDecision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrumtrace-keep-\(UUID().uuidString)")
        let shots = root.appendingPathComponent("export/shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data("jpg").write(to: shots.appendingPathComponent("001.jpg"))
        defer { try? FileManager.default.removeItem(at: root) }
        let slice = SliceRecord(
            sliceId: "slice-01",
            startMedia: 0,
            endMedia: 20,
            trigger: .shot,
            associatedShotId: nil,
            clipPath: nil,
            stills: ["export/shots/001.jpg"],
            analysisStatus: .success,
            score: 100
        )
        let transcript = FullTranscript(sessionId: "s", language: "en", segments: [])
        func candidate(_ decision: CandidateDecision) -> CandidateRecord {
            CandidateRecord(
                decision: decision,
                confidence: 0.9,
                kind: .bug,
                title: "Save",
                observed: "button",
                stated: "said",
                inferred: "maybe",
                agentInstructionsDraft: "",
                quotes: [],
                frameReferences: ["export/shots/001.jpg"]
            )
        }
        let reviewIssues = EvidenceValidator.canConfirm(
            candidate: candidate(.needsReview),
            slice: slice,
            transcript: transcript,
            sessionURL: root
        )
        XCTAssertTrue(reviewIssues.contains { $0.reason == "decision is not keep" })
        let keepIssues = EvidenceValidator.canConfirm(
            candidate: candidate(.keep),
            slice: slice,
            transcript: transcript,
            sessionURL: root
        )
        XCTAssertFalse(keepIssues.contains { $0.reason == "decision is not keep" })
    }

    func testBriefDoesNotExpandTokensInsideTaskText() {
        let html = SessionBriefRenderer.applyReplacements(
            "HEAD{{TASKS_HTML}}MID{{OMITTED_HTML}}TAIL",
            [
                "{{TASKS_HTML}}": "Bug {{OMITTED_HTML}} here",
                "{{OMITTED_HTML}}": "OMITTED-BLOCK"
            ]
        )
        XCTAssertEqual(html, "HEADBug {{OMITTED_HTML}} hereMIDOMITTED-BLOCKTAIL")
    }
}
