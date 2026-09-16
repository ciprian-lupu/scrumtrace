import XCTest
@testable import ScrumTrace

final class LocalExportOutlineTests: XCTestCase {
    private func segment(_ start: TimeInterval, _ text: String, source: String = "room") -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 8, text: text, speaker: nil, words: [], source: source)
    }

    private func walkthrough(offset: TimeInterval = 0, renamed: Bool = false) -> FullTranscript {
        let name = renamed ? "OrionLedger" : "MapleHarbor"
        return FullTranscript(
            sessionId: "synthetic-walkthrough",
            language: "ro",
            segments: [
                segment(30 + offset, "Shot note: import (name) ticket context before the walkthrough."),
                segment(240 + offset, "First run ./tools/prepare-(name.lowercased()) --dry-run, then verify the output reports no pending changes."),
                segment(480 + offset, "Înainte de execuție, coloana account_id trebuie să existe în schema de import și variabila IMPORT_MODE=local este necesară."),
                segment(720 + offset, "Next execute the local import command and check that the result contains the generated batch identifier."),
                segment(960 + offset, "Then verify the spreadsheet column mapping; do not continue if the required column is missing."),
                segment(1200 + offset, "For production, configure the storage job with --environment=production and confirm the observable result in the job log."),
                segment(1500 + offset, "Open question: who reviews the follow-up job and the reviewer pool after deployment?"),
                segment(1650 + offset, "um um fix fix should fix, okay okay"),
                segment(1680 + offset, "room echo room echo room echo room echo")
            ],
            transcriptionAnalysis: [.init(source: "room", status: "transcribed")],
            sources: ["room"]
        )
    }

    func testLaterHigherPriorityShotStaysInMergedNativeWindow() {
        let first = SliceRecord(sliceId: "first", startMedia: 0, endMedia: 20, trigger: .pin,
                                associatedShotId: nil, clipPath: nil, stills: ["archive/shots/001.png"], analysisStatus: .pending, score: 80)
        let laterShot = SliceRecord(sliceId: "later", startMedia: 18, endMedia: 38, trigger: .shot,
                                    associatedShotId: "shot-002", clipPath: nil, stills: ["archive/shots/002.png"], analysisStatus: .pending, score: 100)
        let merged = MeetingSlicer.mergeOverlapping([first, laterShot], mediaDuration: 120)
        let window = try! XCTUnwrap(merged.only)
        XCTAssertLessThanOrEqual(window.endMedia - window.startMedia, MediaBudget.clipMaxDuration)
        XCTAssertTrue(window.startMedia <= 28 && window.endMedia >= 28)
        XCTAssertEqual(window.associatedShotId, "shot-002")
        XCTAssertEqual(Set(window.stills), Set(["archive/shots/001.png", "archive/shots/002.png"]))
    }

    func testPlannerCoversSyntheticWalkthroughAndMovedRenamedVariant() {
        for (transcript, expected) in [
            (walkthrough(), [30.0, 240, 480, 720, 960, 1200, 1500]),
            (walkthrough(offset: 47, renamed: true), [77.0, 287, 527, 767, 1007, 1247, 1547])
        ] {
            let slices = MeetingSlicer().slice(
                shots: [ShotRecord(id: "shot-001", tMedia: expected[0], rawPath: "archive/shots/001.png", annotatedPath: nil, note: "Import context", source: .typed)],
                pins: [],
                transcript: transcript,
                mediaDuration: 2_520
            )
            XCTAssertLessThanOrEqual(slices.count, MediaBudget.maxCandidateSlices)
            for phase in expected {
                XCTAssertTrue(slices.contains { $0.startMedia <= phase && $0.endMedia >= phase }, "missing synthetic phase at \(phase)")
            }
        }
    }

    func testLocalBriefIsBoundedExtractiveAndDoesNotExposeUnselectedSentinel() throws {
        var manifest = SessionManifest.makeNew(sessionId: "synthetic", product: .empty)
        manifest.duration = DurationPair(wallSeconds: 2_000, mediaSeconds: 2_000)
        manifest.slices = [SliceRecord(sliceId: "slice-01", startMedia: 200, endMedia: 280, trigger: .keyword,
                                       associatedShotId: nil, clipPath: nil, stills: [], analysisStatus: .skipped, score: 50)]
        let transcript = FullTranscript(
            sessionId: "synthetic", language: "en",
            segments: [
                segment(210, "First run --dry-run, then verify the generated result before deployment."),
                segment(900, "UNSELECTED_PRIVATE_TRANSCRIPT_SENTINEL")
            ],
            transcriptionAnalysis: [.init(source: "room", status: "transcribed")], sources: ["room"]
        )
        manifest.handoffBrief = LocalBriefBuilder().build(manifest: manifest, transcript: transcript)
        let encoded = try JSONEncoder().encode(manifest.handoffBrief)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("--dry-run"))
        XCTAssertFalse(text.contains("UNSELECTED_PRIVATE_TRANSCRIPT_SENTINEL"))
        XCTAssertLessThanOrEqual(encoded.count, LocalBriefBuilder.maxEncodedBytes)
        XCTAssertEqual(manifest.handoffBrief?.sections.first?.evidenceState, .transcriptOnly)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
