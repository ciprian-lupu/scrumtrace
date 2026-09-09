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
}
