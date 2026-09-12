import XCTest
import WhisperKit
@testable import ScrumTrace

final class BriefUsabilityTests: XCTestCase {
    /// Explicit, local-only diagnostic. Never run on a live session.
    func testLocalTranscriptDiagnostic() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRUMTRACE_TRANSCRIPT_REVIEW_COPY"] else {
            throw XCTSkip("Explicit private review-copy diagnostic only")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".scrumtrace-review-copy").path),
              !root.path.contains("/Movies/ScrumTrace/") else { return XCTFail("Requires an explicit review copy") }
        let transcriber = WhisperTranscriber()
        try await transcriber.prepare()
        for language in [SpeechLanguage.automatic, .romanian] {
            transcriber.setLanguage(language)
            let transcript = try await transcriber.transcribeFile(at: root.appendingPathComponent("archive/audio.wav"), sessionURL: root)
            try JSONEncoder().encode(transcript).write(to: root.appendingPathComponent("verified-\(language.rawValue).json"))
            XCTAssertTrue(transcript.hasUsableText)
            XCTAssertFalse(transcript.needsTranscriptionRetry)
            print("TRANSCRIPT_DIAGNOSTIC language=\(language.rawValue) detected=\(transcript.language) segments=\(transcript.segments.count) usable=\(transcript.segments.filter { !$0.text.isEmpty }.count)")
        }
    }
    private func makeTranscript(_ text: String = "Ana will check the recording tomorrow.") -> FullTranscript {
        FullTranscript(sessionId: "brief-demo", language: "en",
            segments: [TranscriptSegment(start: 1, end: 4, text: text, speaker: "room_speaker_1", words: [], source: "room")],
            speakers: [SessionSpeaker(id: "room_speaker_1", source: "room", label: "Speaker 1", name: "Ana")],
            transcriptionAnalysis: [.init(source: "room", status: "transcribed")], sources: ["room"])
    }

    private func makeManifest() -> SessionManifest {
        var manifest = SessionManifest.makeNew(sessionId: "brief-demo", product: .empty)
        manifest.productContext.appName = "ScrumTrace"
        manifest.duration = DurationPair(wallSeconds: 30, mediaSeconds: 30)
        manifest.completedStages = [.transcribing, .slicing, .evaluating, .completed]
        manifest.pipelineStatus = .completed
        manifest.slices = [SliceRecord(sliceId: "s1", startMedia: 0, endMedia: 10, trigger: .pin,
            associatedShotId: nil, clipPath: "media/demo/clip.mp4", stills: [], analysisStatus: .skipped, score: 1)]
        manifest.tasks = [makeTask("TASK-01", kind: .unknown, status: .needsReview)]
        return manifest
    }

    private func makeTask(_ id: String, kind: TaskKind, status: TaskStatus) -> TaskRecord {
        TaskRecord(taskId: id, sourceSliceId: "s1", kind: kind, status: status,
            title: "Check recording controls", observed: "A selected recording window",
            stated: "Ana will check the recording tomorrow.", inferred: "",
            agentInstructions: status == .confirmed ? "Inspect the linked evidence." : "[Requires Manual Review - API Offline] Inspect the evidence.",
            quotes: [], evidenceMedia: ["media/demo/clip.mp4"], confidence: status == .confirmed ? 0.9 : 0)
    }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("scrumtrace-brief-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testEmptyLegacyTranscriptCanBeRetriedButDigitalSilenceCompletes() throws {
        let old = #"{"session_id":"old","language":"und","segments":[],"sources":["room"]}"#
        let transcript = try JSONDecoder().decode(FullTranscript.self, from: Data(old.utf8))
        XCTAssertTrue(transcript.needsTranscriptionRetry)
        var silent = transcript
        silent.transcriptionAnalysis = [.init(source: "room", status: "no_speech")]
        XCTAssertFalse(silent.needsTranscriptionRetry)
        silent.transcriptionAnalysis = [.init(source: "room", status: "unrecognized")]
        XCTAssertTrue(silent.needsTranscriptionRetry)
        var partial = makeTranscript()
        partial.transcriptionAnalysis = [.init(source: "room", status: "transcribed"), .init(source: "system", status: "failed")]
        XCTAssertTrue(partial.hasUsableText)
        XCTAssertTrue(partial.needsTranscriptionRetry)
    }

    func testSilentSystemPassDoesNotReplaceSpokenLanguage() {
        var room = makeTranscript("Salut, acesta este testul.")
        room.language = "ro"
        let system = FullTranscript(sessionId: "", language: "und", segments: [],
            transcriptionAnalysis: [.init(source: "unknown", status: "no_speech")])
        let merged = TranscriptQuery.merge([.init(speaker: "room", transcript: room), .init(speaker: "system", transcript: system)], sessionId: "test")
        XCTAssertEqual(merged.language, "ro")
        XCTAssertEqual(merged.segments.count, 1)
        XCTAssertFalse(merged.needsTranscriptionRetry)
        XCTAssertEqual(merged.transcriptionAnalysis?.map(\.source), ["room", "system"])
    }

    func testEmptyBriefExplainsTranscriptAndConsentAndOpensReview() throws {
        try withRoot { root in
            let manifest = makeManifest()
            try SpeakerTimeline.save(FullTranscript(sessionId: manifest.sessionId, language: "und", segments: []), sessionURL: root)
            let html = SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: root)
            XCTAssertTrue(html.contains("<details open>"))
            XCTAssertTrue(html.contains("No usable transcript"))
            XCTAssertTrue(html.contains("sending evidence for AI analysis was not approved"))
            XCTAssertTrue(html.contains("No transcript excerpts are available"))
            XCTAssertFalse(html.contains("API Offline"))
            XCTAssertFalse(html.contains("Select a transcript passage to play it.</p>"))
            XCTAssertFalse(html.contains("{{"))
            let markdown = AgentContextRenderer().render(manifest: manifest, sessionURL: root)
            XCTAssertFalse(markdown.contains("API Offline"))
        }
    }

    func testOverviewOnlyUsesConfirmedEvidenceAndEscapesContent() throws {
        try withRoot { root in
            var manifest = makeManifest()
            var decision = makeTask("TASK-D", kind: .decision, status: .confirmed)
            decision.title = "Keep <script>alert(1)</script>"
            var question = makeTask("TASK-Q", kind: .openQuestion, status: .confirmed)
            question.title = "Which microphone should we select?"
            var unconfirmed = makeTask("TASK-X", kind: .decision, status: .needsReview)
            unconfirmed.title = "UNCONFIRMED_DECISION"
            manifest.tasks = [decision, question, unconfirmed]
            let presentation = BriefPresentation(manifest: manifest, transcript: makeTranscript(), sessionURL: root)
            XCTAssertTrue(presentation.summaryHTML.contains("Which microphone"))
            XCTAssertTrue(presentation.summaryHTML.contains("&lt;script&gt;"))
            XCTAssertFalse(presentation.summaryHTML.contains("<script>"))
            XCTAssertFalse(presentation.summaryHTML.contains("UNCONFIRMED_DECISION"))
            XCTAssertTrue(presentation.summaryHTML.contains("No actions supported by confirmed evidence"))
        }
    }

    func testDownloadsRespectConsentOmissionsAndExistingFiles() throws {
        try withRoot { root in
            for path in [ScrumTracePath.packZip, ScrumTracePath.agentContext, ScrumTracePath.agentPrompt, "export/full_transcript.json"] {
                try ExportRel.writeContainedData(Data("fixture".utf8), relative: path, sessionURL: root)
            }
            var manifest = makeManifest()
            var html = BriefPresentation(manifest: manifest, transcript: nil, sessionURL: root).downloadsHTML
            XCTAssertTrue(html.contains("href=\"session-pack.zip\""))
            XCTAssertTrue(html.contains("href=\"AGENT_CONTEXT.md\""))
            XCTAssertFalse(html.contains("href=\"full_transcript.json\""))
            manifest.includeFullTranscriptInZip = true
            html = BriefPresentation(manifest: manifest, transcript: nil, sessionURL: root).downloadsHTML
            XCTAssertTrue(html.contains("href=\"full_transcript.json\""))
            manifest.omitted = [.init(path: "session-pack.zip", reason: "over budget"), .init(path: "full_transcript.json", reason: "over budget")]
            html = BriefPresentation(manifest: manifest, transcript: nil, sessionURL: root).downloadsHTML
            XCTAssertFalse(html.contains("href=\"session-pack.zip\""))
            XCTAssertFalse(html.contains("href=\"full_transcript.json\""))
            XCTAssertFalse(html.contains("archive/"))
        }
    }

    func testFullTranscriptIsReadableOnlyWhenIncludedAndNotOmitted() throws {
        try withRoot { root in
            var manifest = makeManifest()
            let full = makeTranscript("FULL_OPTED_IN_TRANSCRIPT")
            try ExportRel.writeContainedData(JSONEncoder().encode(full), relative: "export/full_transcript.json", sessionURL: root)
            var html = SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: root)
            XCTAssertFalse(html.contains("FULL_OPTED_IN_TRANSCRIPT"))
            manifest.includeFullTranscriptInZip = true
            html = SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: root)
            XCTAssertTrue(html.contains("FULL_OPTED_IN_TRANSCRIPT"))
            manifest.omitted = [.init(path: "full_transcript.json", reason: "budget")]
            html = SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: root)
            XCTAssertFalse(html.contains("FULL_OPTED_IN_TRANSCRIPT"))
        }
    }

    func testSpeakerOverviewDoesNotExposeUnselectedNames() throws {
        try withRoot { root in
            var transcript = makeTranscript()
            transcript.speakers?.append(.init(id: "private", source: "room", label: "Private", name: "UNSELECTED_PERSON"))
            transcript.segments.append(.init(start: 25, end: 28, text: "PRIVATE_SPEECH", speaker: "private", words: [], source: "room"))
            let html = BriefPresentation(manifest: makeManifest(), transcript: transcript, sessionURL: root).speakersHTML
            XCTAssertTrue(html.contains("Ana"))
            XCTAssertFalse(html.contains("UNSELECTED_PERSON"))
            XCTAssertFalse(html.contains("PRIVATE_SPEECH"))
        }
    }

    func testReviewTitlesStayShortAndOpenQuestionsDecode() throws {
        XCTAssertEqual(SessionProcessor.reviewTitle("  Hello\n world ", fallback: "fallback"), "Hello world")
        XCTAssertEqual(SessionProcessor.reviewTitle(String(repeating: "a", count: 300), fallback: ""), String(repeating: "a", count: 99) + "…")
        XCTAssertEqual(try JSONDecoder().decode(TaskKind.self, from: Data("\"open_question\"".utf8)), .openQuestion)
    }

    func testProcessingStatusDistinguishesFailureFromNoConsent() throws {
        try withRoot { root in
            var manifest = makeManifest()
            manifest.slices[0].analysisStatus = .offlineFailed
            var partial = makeTranscript()
            partial.transcriptionAnalysis?.append(.init(source: "system", status: "failed"))
            let html = BriefPresentation(manifest: manifest, transcript: partial, sessionURL: root).statusHTML
            XCTAssertTrue(html.contains("Analysis incomplete"))
            XCTAssertTrue(html.contains("Partial transcript"))
            XCTAssertFalse(html.contains("sending evidence for AI analysis was not approved"))
        }
    }

    /// Emit only synthetic data for browser QA; private session content is never served.
    func testSyntheticBriefFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["SCRUMTRACE_BRIEF_FIXTURE_ROOT"] else {
            throw XCTSkip("Explicit synthetic browser fixture only")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        XCTAssertTrue(root.path.hasPrefix("/private/tmp/scrumtrace-brief-ui"))
        for mode in ["local", "analyzed"] {
            let folder = root.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var manifest = makeManifest()
            if mode == "analyzed" {
                manifest.uploadConsent.approved = true
                manifest.slices[0].analysisStatus = .success
                manifest.tasks = [makeTask("TASK-01", kind: .actionItem, status: .confirmed),
                                  makeTask("TASK-02", kind: .decision, status: .confirmed),
                                  makeTask("TASK-03", kind: .openQuestion, status: .confirmed)]
                manifest.tasks[1].title = "Keep context selection before recording"
                manifest.tasks[1].stated = "We agreed to select the product context before recording."
                manifest.tasks[2].title = "Should microphone choice be saved per context?"
                manifest.tasks[2].stated = "We still need to decide how to remember the microphone."
                var transcript = makeTranscript()
                transcript.segments.append(.init(start: 4, end: 6, text: manifest.tasks[1].stated, speaker: "room_speaker_1", words: [], source: "room"))
                transcript.segments.append(.init(start: 7, end: 9, text: manifest.tasks[2].stated, speaker: "room_speaker_1", words: [], source: "room"))
                try SpeakerTimeline.save(transcript, sessionURL: folder)
                manifest.includeFullTranscriptInZip = true
                try ExportRel.writeContainedData(JSONEncoder().encode(transcript), relative: "export/full_transcript.json", sessionURL: folder)
            } else {
                try SpeakerTimeline.save(FullTranscript(sessionId: "brief-demo", language: "und", segments: []), sessionURL: folder)
            }
            for item in [ScrumTracePath.agentContext, ScrumTracePath.agentPrompt] {
                try ExportRel.writeContainedData(Data("Synthetic browser QA fixture".utf8), relative: item, sessionURL: folder)
            }
            let html = SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: folder)
            try ExportRel.writeExportText(html, relative: ScrumTracePath.sessionBrief, sessionURL: folder)
        }
    }

    func testLocalSessionBriefReviewCopy() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRUMTRACE_TRANSCRIPT_REVIEW_COPY"] else {
            throw XCTSkip("Explicit private session recovery only")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard root.path.hasPrefix("/private/tmp/scrumtrace-brief-review/"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".scrumtrace-review-copy").path) else {
            return XCTFail("Requires a private diagnostic copy")
        }
        let vault = SessionVault(rootURL: root.deletingLastPathComponent())
        var manifest = try vault.loadManifest(id: root.lastPathComponent)
        manifest.uploadConsent = .denied
        try vault.write(manifest: &manifest)
        let transcriber = WhisperTranscriber()
        transcriber.setLanguage(.romanian)
        let processor = SessionProcessor(vault: vault, transcriber: transcriber)
        let config = AIProviderConfiguration(kind: .openaiCompatible, baseURL: "https://example.invalid", model: "unused", apiKey: "", acceptsText: true, acceptsImages: false, acceptsVideo: false)
        let result = try await processor.process(sessionId: manifest.sessionId, pinTimes: vault.loadPinTimes(sessionId: manifest.sessionId), configuration: config, whisperModel: WhisperTranscriber.defaultStoredModel, identifySpeakers: true) { _, _ in }
        XCTAssertEqual(result.pipelineStatus, .completed)
        XCTAssertTrue(try XCTUnwrap(SpeakerTimeline.load(sessionURL: root)).hasUsableText)
        XCTAssertFalse(result.uploadConsent.approved)
        let html = try String(contentsOf: root.appendingPathComponent(ScrumTracePath.sessionBrief), encoding: .utf8)
        XCTAssertTrue(html.contains("href=\"session-pack.zip\""))
        XCTAssertFalse(html.contains("API Offline"))
        XCTAssertFalse(html.contains("{{"))
    }

}
