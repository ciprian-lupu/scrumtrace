import XCTest
import SwiftUI
@preconcurrency import AVKit
@preconcurrency import AVFoundation
@testable import ScrumTrace

final class SpeakerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("scrumtrace-speaker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
    }
    override func tearDownWithError() throws {
        AgentLog.setFileURLForTesting(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private func segment(_ start: Double, _ end: Double, _ text: String, source: String = "room", words: [TranscriptWord] = []) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, speaker: source, words: words, source: source)
    }
    private func transcript(_ segments: [TranscriptSegment]) -> FullTranscript {
        FullTranscript(sessionId: "fixture", language: "ro", segments: segments)
    }
    private func assigned() -> FullTranscript {
        SpeakerTimeline.assigning(transcript([segment(1, 2, "Primul"), segment(3, 4, "Al doilea")]), intervals: [SpeakerInterval(start: 1, end: 2, speakerID: "alpha"), SpeakerInterval(start: 3, end: 4, speakerID: "beta")], source: "room")
    }

    @MainActor
    func testSpeakerReviewRendersNativeVideoControlsForASavedTranscript() async throws {
        let vault = SessionVault(rootURL: root.appendingPathComponent("sessions"))
        let session = try vault.createSession(product: .empty)
        var manifest = session.manifest
        manifest.pipelineStatus = .completed
        manifest.completedStages = [.transcribing, .completed]
        try vault.write(manifest: &manifest)
        var saved = assigned()
        saved.sessionId = session.manifest.sessionId
        try SpeakerTimeline.save(saved, sessionURL: session.url)
        let suite = "ScrumTrace.SpeakerReviewRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: vault)
        let hosting = NSHostingController(rootView: SpeakerReviewView(controller: controller))
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        // Exercise the full onAppear/task/render path that crashed in the installed app.
        try await Task.sleep(for: .milliseconds(300))
        hosting.view.layoutSubtreeIfNeeded()
        func playerView(in view: NSView) -> AVPlayerView? {
            if let player = view as? AVPlayerView { return player }
            return view.subviews.lazy.compactMap { playerView(in: $0) }.first
        }
        let player = try XCTUnwrap(playerView(in: hosting.view))
        XCTAssertEqual(player.controlsStyle, .inline)
        XCTAssertTrue(player.showsFullScreenToggleButton)
        XCTAssertTrue(window.isVisible)
    }

    func testOldTranscriptStillDecodesWithSourceOnlyLabels() throws {
        let old = #"{"session_id":"old","language":"en","segments":[{"start":0,"end":1,"text":"hello","speaker":"room","words":[]}],"sources":["room"]}"#
        let decoded = try JSONDecoder().decode(FullTranscript.self, from: Data(old.utf8))
        XCTAssertNil(decoded.speakers)
        XCTAssertNil(decoded.speakerAnalysis)
        XCTAssertEqual(SpeakerTimeline.displaySpeaker(decoded.segments[0], in: decoded), "Room microphone · speaker unclear")
    }

    func testTwoPeopleOnOneMicrophoneAreDistinctAndStable() {
        let result = assigned()
        XCTAssertEqual(result.speakers?.map(\.id), ["room_speaker_1", "room_speaker_2"])
        XCTAssertEqual(result.segments.map(\.speaker), ["room_speaker_1", "room_speaker_2"])
        XCTAssertTrue(result.segments.allSatisfy { $0.speakerAttribution == .estimated })
    }

    func testRoomAndCallNumberingNeverConflatesSources() {
        var input = assigned()
        input.segments.append(segment(1, 2, "Remote", source: "system"))
        let result = SpeakerTimeline.assigning(input, intervals: [SpeakerInterval(start: 1, end: 2, speakerID: "alpha")], source: "system")
        XCTAssertEqual(result.speakers?.count, 3)
        XCTAssertEqual(result.segments.first { $0.text == "Remote" }?.speaker, "system_speaker_1")
        XCTAssertEqual(result.segments.first { $0.text == "Primul" }?.speaker, "room_speaker_1")
    }

    func testSpeakerChangesInsideASentenceSplitAtWordBoundaries() {
        let words = [TranscriptWord(start: 1, end: 1.4, text: " Salut"), TranscriptWord(start: 2, end: 2.3, text: " Bună"), TranscriptWord(start: 2.3, end: 2.6, text: " ziua!")]
        let result = SpeakerTimeline.assigning(transcript([segment(1, 3, "Salut Bună ziua!", words: words)]), intervals: [SpeakerInterval(start: 1, end: 1.5, speakerID: "a"), SpeakerInterval(start: 2, end: 3, speakerID: "b")], source: "room")
        XCTAssertEqual(result.segments.map(\.text), ["Salut", "Bună ziua!"])
        XCTAssertEqual(result.segments.map(\.speaker), ["room_speaker_1", "room_speaker_2"])
        XCTAssertEqual(result.segments[1].start, 2)
        XCTAssertEqual(result.segments[1].end, 2.6)
    }

    func testOverlappingVoicesDoNotDuplicateOrAssignWords() {
        let result = SpeakerTimeline.assigning(transcript([segment(1, 2, "Cuvânt")]), intervals: [SpeakerInterval(start: 1, end: 2, speakerID: "a"), SpeakerInterval(start: 1.2, end: 2, speakerID: "b")], source: "room")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertNil(result.segments[0].speaker)
        XCTAssertEqual(result.segments[0].speakerAttribution, .overlap)
        XCTAssertEqual(result.segments[0].speakerCandidates?.count, 2)
    }

    func testSequentialSpeakersWithoutWordTimestampsAreUncertain() {
        let result = SpeakerTimeline.assigning(transcript([segment(0, 10, "mixed sentence")]), intervals: [SpeakerInterval(start: 0, end: 7, speakerID: "a"), SpeakerInterval(start: 7, end: 10, speakerID: "b")], source: "room")
        XCTAssertNil(result.segments[0].speaker)
        XCTAssertEqual(result.segments[0].speakerAttribution, .uncertain)
    }

    func testDuplicateIntervalsCannotInflateConfidence() {
        let result = SpeakerTimeline.assigning(transcript([segment(0, 10, "uncertain")]), intervals: [SpeakerInterval(start: 0, end: 3, speakerID: "a"), SpeakerInterval(start: 0, end: 3, speakerID: "a")], source: "room")
        XCTAssertNil(result.segments[0].speaker)
        XCTAssertEqual(result.segments[0].speakerAttribution, .uncertain)
    }

    func testInvalidIntervalsAndNoSpeechLeaveWordsUnattributed() {
        let result = SpeakerTimeline.assigning(transcript([segment(1, 2, "keep me")]), intervals: [SpeakerInterval(start: .nan, end: 2, speakerID: "bad"), SpeakerInterval(start: 5, end: 1, speakerID: "bad")], source: "room")
        XCTAssertEqual(result.segments[0].text, "keep me")
        XCTAssertNil(result.segments[0].speaker)
        XCTAssertTrue(result.speakers?.isEmpty == true)
    }

    func testClipBoundaryDoesNotExportWordsOutsideWindow() {
        let input = transcript([segment(0, 5, "secret selected private", words: [TranscriptWord(start: 0, end: 1, text: "secret"), TranscriptWord(start: 2, end: 3, text: " selected"), TranscriptWord(start: 4, end: 5, text: " private")]), segment(0, 5, "no word timing")])
        let turns = SpeakerTimeline.turns(in: input, start: 1.5, end: 3.5)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "selected")
        XCTAssertEqual(turns[0].start, 2)
        XCTAssertEqual(turns[0].end, 3)
        XCTAssertEqual(TranscriptQuery.excerpt(from: input, start: 1.5, end: 3.5), "selected", "Plain-text excerpts sent to a provider or shown on task cards obey the same boundary")
    }

    func testNamesAreSessionLocalBoundedAndClearable() throws {
        let result = SpeakerTimeline.names(["room_speaker_1": "  Ana\nPop ", "room_speaker_2": String(repeating: "b", count: 120)], appliedTo: assigned())
        XCTAssertEqual(result.speakers?[0].name, "Ana Pop")
        XCTAssertEqual(result.speakers?[1].name?.count, 80)
        XCTAssertNil(SpeakerTimeline.names(["room_speaker_1": " "], appliedTo: result).speakers?[0].name)
        let saved = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(saved.lowercased().contains("embedding"))
        XCTAssertEqual(assigned().speakers?[0].name, nil)
    }

    func testManualCorrectionPersistsAndRejectsOtherSourceOrMissingSpeaker() throws {
        let result = try SpeakerTimeline.correcting([0: "room_speaker_2"], in: assigned())
        XCTAssertEqual(result.segments[0].speaker, "room_speaker_2")
        XCTAssertEqual(result.segments[0].speakerAttribution, .manual)
        XCTAssertTrue(SpeakerTimeline.displaySpeaker(result.segments[0], in: result).contains("reviewed"))
        XCTAssertThrowsError(try SpeakerTimeline.correcting([0: "system_speaker_1"], in: result))
        XCTAssertThrowsError(try SpeakerTimeline.correcting([90: "room_speaker_1"], in: result))
        XCTAssertNil(try SpeakerTimeline.correcting([0: "unclear"], in: result).segments[0].speaker)
    }

    func testReanalysisResetsOnlyThatSourcesNames() {
        let named = SpeakerTimeline.names(["room_speaker_1": "Ana"], appliedTo: assigned())
        let updated = SpeakerTimeline.assigning(named, intervals: [SpeakerInterval(start: 1, end: 4, speakerID: "new")], source: "room")
        XCTAssertEqual(updated.speakers?.count, 1)
        XCTAssertNil(updated.speakers?.first?.name)
    }

    func testBleedNeverBecomesAnInventedRoomSpeaker() {
        let a = transcript([segment(1, 2, "same words")])
        let b = transcript([segment(1.1, 2.1, "same words", source: "system")])
        let merged = TranscriptQuery.merge([.init(speaker: "room", transcript: a), .init(speaker: "system", transcript: b)], sessionId: "s")
        let result = SpeakerTimeline.assigning(merged, intervals: [.init(start: 1, end: 3, speakerID: "one")], source: "room")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].source, "mixed")
        XCTAssertTrue(SpeakerTimeline.displaySpeaker(result.segments[0], in: result).contains("source unclear"))
    }

    func testQuoteAttributionIgnoresEmptyAndOutOfRangeSegments() {
        var input = assigned()
        input.segments.append(segment(1, 2, ""))
        let quote = QuoteRecord(speaker: "invented", text: "Primul", tMediaStart: 1, tMediaEnd: 2)
        XCTAssertTrue(SpeakerTimeline.quoteSpeaker(quote, transcript: input).contains("Room · Speaker 1"))
        XCTAssertEqual(SpeakerTimeline.quoteSpeaker(QuoteRecord(speaker: "", text: "", tMediaStart: 1, tMediaEnd: 2), transcript: input), "Speaker unclear")
    }

    func testDigitalSilenceOnlyGateAndOffset() throws {
        let silent = root.appendingPathComponent("silence.wav")
        let quiet = root.appendingPathComponent("quiet.wav")
        try writeWav(silent, amplitude: 0)
        try writeWav(quiet, amplitude: 0.0001)
        XCTAssertTrue(try SpeechSignal.isDigitalSilence(silent))
        XCTAssertFalse(try SpeechSignal.isDigitalSilence(quiet))
        let shifted = SpeechSignal.shifted(transcript([segment(1, 2, "a", words: [.init(start: 1, end: 2, text: "a")])]), by: 2.3)
        XCTAssertEqual(shifted.segments[0].start, 3.3, accuracy: 0.0001)
        XCTAssertEqual(shifted.segments[0].words[0].end, 4.3, accuracy: 0.0001)
    }

    func testSilentSourceNeedsNoModelDownload() async throws {
        let silent = root.appendingPathComponent("silence.wav")
        try writeWav(silent, amplitude: 0)
        let engine = SpeakerDiarizer()
        let intervals = try await engine.intervals(audioURL: silent)
        XCTAssertTrue(intervals.isEmpty)
        let ready = await engine.isReady
        XCTAssertFalse(ready)
    }

    func testMissingAudioRetainsTranscriptAndReportsFailedAnalysis() async {
        let result = await SpeakerDiarizer().analyze(assigned(), sessionURL: root)
        XCTAssertEqual(result.segments.map(\.text), assigned().segments.map(\.text))
        XCTAssertEqual(result.speakerAnalysis?.first?.status, "failed")
    }

    func testBriefAndContextShowTimedSpeakersWithoutPrivateBoundarySpeech() throws {
        var manifest = SessionManifest.makeNew(sessionId: "fixture", product: .empty)
        manifest.duration = DurationPair(wallSeconds: 10, mediaSeconds: 10)
        manifest.slices = [SliceRecord(sliceId: "s1", startMedia: 1.5, endMedia: 3.5, trigger: .pin, associatedShotId: nil, clipPath: "archive/media-work/s1/clip.mp4", exportClipPath: "export/media/s1/clip.mp4", stills: [], analysisStatus: .skipped, score: 1)]
        manifest.tasks = [TaskRecord(taskId: "TASK-01", sourceSliceId: "s1", kind: .improvement, status: .needsReview, title: "Fixture", observed: "", stated: "", inferred: "", agentInstructions: "", quotes: [], evidenceMedia: ["export/media/s1/clip.mp4"], confidence: 0)]
        try ExportRel.writeContainedData(Data("fixture-video".utf8), relative: "export/media/s1/clip.mp4", sessionURL: root)
        var input = transcript([segment(0, 5, "PRIVATE_BEFORE selected PRIVATE_AFTER", words: [.init(start: 0, end: 1, text: "PRIVATE_BEFORE"), .init(start: 2, end: 3, text: "selected"), .init(start: 4, end: 5, text: "PRIVATE_AFTER")])])
        input = SpeakerTimeline.assigning(input, intervals: [.init(start: 0, end: 5, speakerID: "one")], source: "room")
        input = SpeakerTimeline.names(["room_speaker_1": "<script>alert(1)</script>"], appliedTo: input)
        try SpeakerTimeline.save(input, sessionURL: root)
        let html = SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: root)
        XCTAssertTrue(html.contains("data-start=\"0.500\""))
        XCTAssertTrue(html.contains("data-clip=\"media/s1/clip.mp4\""))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertFalse(html.contains("PRIVATE_BEFORE"))
        XCTAssertFalse(html.contains("PRIVATE_AFTER"))
        let context = AgentContextRenderer().render(manifest: manifest, sessionURL: root)
        XCTAssertTrue(context.contains("selected"))
        XCTAssertFalse(context.contains("PRIVATE_BEFORE"))
        manifest.omitted = [OmittedAsset(path: "media/s1/clip.mp4", reason: "test")]
        let omittedHTML = SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: root)
        XCTAssertFalse(omittedHTML.contains("data-clip=\"media/s1/clip.mp4\""))
    }

    func testMicrophoneSurvivesClipExportAtItsActualOffset() async throws {
        let movie = root.appendingPathComponent("archive/session.mp4")
        try FileManager.default.createDirectory(at: movie.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await makeMovie(movie)
        try writeWav(root.appendingPathComponent("archive/audio.wav"), amplitude: 0.4, seconds: 3)
        try CaptureAudioLayout(microphoneWav: true, systemAudioInMovie: false, wavStartMediaSeconds: 2).write(sessionURL: root)
        let slice = SliceRecord(sliceId: "s1", startMedia: 1, endMedia: 6, trigger: .pin, associatedShotId: nil, clipPath: "archive/media-work/s1/clip.mp4", stills: [], analysisStatus: .skipped, score: 1)
        let result = try await ClipExporter().export(sessionURL: root, slice: slice, mediaDuration: 6)
        let clip = root.appendingPathComponent(try XCTUnwrap(result.clipPath))
        let values = try await audioEnergy(clip)
        XCTAssertGreaterThan(values.voiced, 0.1, "Room microphone must be audible in the clip")
        XCTAssertLessThan(values.leading, 0.01, "Mic starts at t_media 2, one second into this clip")
        XCTAssertEqual(values.onset, 1, accuracy: 0.08)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
        if let destination = ProcessInfo.processInfo.environment["SCRUMTRACE_BRIEF_FIXTURE"] {
            let fixture = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            try ExportRel.writeContainedData(Data(contentsOf: clip), relative: "export/media/s1/clip.mp4", sessionURL: fixture)
            var manifest = SessionManifest.makeNew(sessionId: "speaker-ui-fixture", product: ProductContext(appName: "Speaker review demo", repoURL: "", techStack: ""))
            manifest.duration = DurationPair(wallSeconds: 6, mediaSeconds: 6)
            var linked = slice; linked.exportClipPath = "export/media/s1/clip.mp4"
            manifest.slices = [linked]
            manifest.tasks = [TaskRecord(taskId: "TASK-01", sourceSliceId: "s1", kind: .improvement, status: .needsReview, title: "Speaker playback check", observed: "Generated video and test tone. This is a UI fixture, not a real meeting.", stated: "", inferred: "", agentInstructions: "", quotes: [], evidenceMedia: ["export/media/s1/clip.mp4"], confidence: 0)]
            var sample = assigned()
            sample = SpeakerTimeline.names(["room_speaker_1": "Ana (example)", "room_speaker_2": "Vlad (example)"], appliedTo: sample)
            try SpeakerTimeline.save(sample, sessionURL: fixture)
            try ExportRel.writeExportText(SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: fixture), relative: ScrumTracePath.sessionBrief, sessionURL: fixture)
        }
    }

    func testNameUpdateRebuildsPackWithoutTranscribingOrProviderCall() async throws {
        let vault = SessionVault(rootURL: root.appendingPathComponent("sessions"))
        var created = try vault.createSession(product: .empty)
        created.manifest.pipelineStatus = .completed
        created.manifest.completedStages = [.transcribing, .slicing, .evaluating, .synthesizing, .completed]
        try vault.write(manifest: &created.manifest)
        var input = assigned(); input.sessionId = created.manifest.sessionId
        try SpeakerTimeline.save(input, sessionURL: created.url)
        let transcriber = WhisperTranscriber(loadModel: { _ in XCTFail("Names must not reload Whisper"); throw SettingsValidationError("Unexpected Whisper call") })
        let processor = SessionProcessor(vault: vault, transcriber: transcriber)
        let saved = try await processor.updateSpeakers(sessionId: input.sessionId, names: ["room_speaker_1": "Ana"], reanalyze: false) { _, _ in }
        XCTAssertEqual(saved.speakers?.first?.name, "Ana")
        XCTAssertTrue(ExportRel.existingSessionFile(ScrumTracePath.sessionBrief, sessionURL: created.url) != nil)
        let bytes = ExportRel.regularFileByteCount(created.url.appendingPathComponent(ScrumTracePath.packZip), sessionRoot: created.url) ?? 0
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThanOrEqual(bytes, MediaBudget.maxZipBytes)
    }

    private func makeMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixel)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<24 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 4)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 6, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private func audioEnergy(_ url: URL) async throws -> (leading: Double, voiced: Double, onset: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var leading: Double = 0; var voiced: Double = 0; var onset: Double = .infinity
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for (index, value) in samples.enumerated() {
                let time = start + Double(index) / 16_000
                if time < 0.8 { leading = max(leading, Double(abs(value))) }
                if time > 1.2 && time < 2.8 { voiced = max(voiced, Double(abs(value))) }
                if abs(value) > 0.05 { onset = min(onset, time) }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return (leading, voiced, onset)
    }

    func testQuoteCanSpanSpeakerTurnsWithoutInventingAQuoteAcrossSources() {
        let input = assigned()
        let quote = QuoteRecord(speaker: "unknown", text: "Primul Al doilea", tMediaStart: 1, tMediaEnd: 4)
        XCTAssertTrue(EvidenceValidator.quoteMatchesTranscript(quote, transcript: input))
        var mixed = input
        mixed.segments[1].source = "system"
        XCTAssertFalse(EvidenceValidator.quoteMatchesTranscript(quote, transcript: mixed))
    }

    /// Runs the full local pipeline only on an explicitly supplied review copy.
    func testExistingSessionReviewCopyProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SCRUMTRACE_REVIEW_COPY"] else { throw XCTSkip("Explicit review-copy probe only") }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard url.path.contains("speakers-review-2026-09-12/processed-sample/sessions/") else { return XCTFail("Probe requires a review copy, never the live session") }
        let vault = SessionVault(rootURL: url.deletingLastPathComponent())
        var manifest = try vault.loadManifest(id: url.lastPathComponent)
        manifest.uploadConsent = .denied
        manifest.completedStages = []
        manifest.pipelineStatus = .transcribing
        manifest.tasks = []
        try vault.write(manifest: &manifest)
        let transcriber = WhisperTranscriber()
        transcriber.setLanguage(.romanian)
        let processor = SessionProcessor(vault: vault, transcriber: transcriber)
        let configuration = AIProviderConfiguration(kind: .openaiCompatible, baseURL: "https://example.invalid", model: "unused", apiKey: "", acceptsText: true, acceptsImages: false, acceptsVideo: false)
        let result = try await processor.process(sessionId: manifest.sessionId, pinTimes: vault.loadPinTimes(sessionId: manifest.sessionId), configuration: configuration, whisperModel: WhisperTranscriber.defaultStoredModel, identifySpeakers: true) { _, _ in }
        XCTAssertEqual(result.pipelineStatus, .completed)
        let saved = try XCTUnwrap(SpeakerTimeline.load(sessionURL: url))
        XCTAssertFalse(saved.segments.isEmpty)
        XCTAssertFalse(saved.speakers?.isEmpty ?? true)
        XCTAssertFalse(saved.segments.contains { $0.text.contains("<|") })
        XCTAssertFalse(result.uploadConsent.approved)
        XCTAssertTrue(ExportRel.existingSessionFile(ScrumTracePath.packZip, sessionURL: url) != nil)
    }

    private func writeWav(_ url: URL, amplitude: Float, seconds: Double = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for n in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][n] = amplitude * sin(Float(n) * 2 * .pi * 440 / 16_000) }
        try file.write(from: buffer)
    }

    /// Explicit probe only: no model downloads during the normal test suite.
    func testLocalSpeakerModelProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SCRUMTRACE_SPEAKER_PROBE_AUDIO"] else { throw XCTSkip("Set TEST_RUNNER_SCRUMTRACE_SPEAKER_PROBE_AUDIO for the explicit local model probe.") }
        let intervals = try await SpeakerDiarizer.shared.intervals(audioURL: URL(fileURLWithPath: path))
        XCTAssertFalse(intervals.isEmpty)
        XCTAssertTrue(intervals.allSatisfy { $0.start.isFinite && $0.end > $0.start })
        if let result = env["SCRUMTRACE_SPEAKER_PROBE_RESULT"] {
            try JSONEncoder().encode(intervals).write(to: URL(fileURLWithPath: result))
        }
    }
}
