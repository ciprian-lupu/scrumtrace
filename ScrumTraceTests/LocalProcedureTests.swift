import CryptoKit
import AVFoundation
import XCTest
@testable import ScrumTrace

private final class LocalOnlyCallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var factories = 0
    private var providerCalls = 0
    private var transcriberLoads = 0

    func recordFactory() { lock.lock(); factories += 1; lock.unlock() }
    func recordProviderCall() { lock.lock(); providerCalls += 1; lock.unlock() }
    func recordTranscriberLoad() { lock.lock(); transcriberLoads += 1; lock.unlock() }

    func counts() -> (factories: Int, providerCalls: Int, transcriberLoads: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (factories, providerCalls, transcriberLoads)
    }
}

final class LocalExportReplayTests: XCTestCase {
    private func exportContentHashes(sessionURL: URL) throws -> [String: String] {
        let exportURL = sessionURL.appendingPathComponent("export", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: exportURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SessionRecorderError.writerFailed("Replay export folder is unavailable.")
        }
        var hashes: [String: String] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw SessionRecorderError.writerFailed("Replay export contains a non-regular member.")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw SessionRecorderError.writerFailed("Replay export contains a non-regular member.")
            }
            if fileURL.lastPathComponent == "session-pack.zip" { continue }
            let relative = String(fileURL.path.dropFirst(exportURL.path.count + 1))
            hashes[relative] = SHA256.hash(data: try Data(contentsOf: fileURL))
                .map { String(format: "%02x", $0) }
                .joined()
        }
        return hashes
    }

    func testExistingSessionCopiesReplayLocallyAndRepeatIdentically() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let configuredRoot = environment["TEST_RUNNER_SCRUMTRACE_REPLAY_SESSIONS_ROOT"]
                ?? environment["SCRUMTRACE_REPLAY_SESSIONS_ROOT"] else {
            throw XCTSkip("Explicit private local-export replay harness only")
        }
        let sessionsRoot = URL(fileURLWithPath: configuredRoot, isDirectory: true).standardizedFileURL
        let runRoot = sessionsRoot.deletingLastPathComponent().deletingLastPathComponent()
        let privateTempPrefix = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/scrumtrace-local-export-review-"
        let resolvedSessionsPath = sessionsRoot.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(resolvedSessionsPath.hasPrefix(privateTempPrefix))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionsRoot.appendingPathComponent(".scrumtrace-replay-sessions").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runRoot.appendingPathComponent(".scrumtrace-local-export-review").path))
        XCTAssertNotEqual(sessionsRoot.path, URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/ScrumTrace/sessions").path)
        AgentLog.setFileURLForTesting(runRoot.appendingPathComponent("replay-agent.jsonl"))
        defer { AgentLog.setFileURLForTesting(nil) }

        let vault = SessionVault(rootURL: sessionsRoot)
        let sessionIDs = try FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { folder in
            (try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true
                && (try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink) != true
                && ExportRel.existingSessionFile(ScrumTracePath.manifest, sessionURL: folder) != nil
        }.map(\.lastPathComponent).sorted()
        XCTAssertGreaterThanOrEqual(sessionIDs.count, 2)

        let probe = LocalOnlyCallProbe()
        var metrics: [[String: Any]] = []
        var totalPlayableClips = 0
        for sessionID in sessionIDs {
            let sessionURL = vault.sessionURL(id: sessionID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.appendingPathComponent(".scrumtrace-replay-copy").path))
            var manifest = try vault.loadManifest(id: sessionID)
            XCTAssertEqual(manifest.pipelineStatus, .completed)
            XCTAssertTrue(manifest.hasCompleted(.transcribing))
            let transcript = try XCTUnwrap(SpeakerTimeline.load(sessionURL: sessionURL))
            XCTAssertTrue(transcript.hasTimedSegments)
            XCTAssertFalse(transcript.needsTranscriptionRetry)
            let pins = vault.loadPinTimes(sessionId: sessionID)
            let alias = try String(contentsOf: sessionURL.appendingPathComponent(".fixture-alias"), encoding: .utf8)
            XCTAssertTrue(["long-ro", "short-ro", "sub15", "no-window"].contains(alias))

            // Preserve archive inputs; force every derived stage to rebuild in this copy.
            manifest.localProcedure = nil
            manifest.slices = []
            manifest.tasks = []
            manifest.completedStages.removeAll { $0 != .transcribing }
            manifest.pipelineStatus = .transcribing
            manifest.uploadConsent = .denied
            manifest.includeFullTranscriptInZip = false
            manifest.omitted = []
            try vault.write(manifest: &manifest)

            let transcriber = WhisperTranscriber(loadModel: { _ in
                probe.recordTranscriberLoad()
                throw SessionRecorderError.writerFailed("Unexpected model load during local-only replay.")
            })
            let processor = SessionProcessor(vault: vault, transcriber: transcriber, providerFactory: { configuration in
                probe.recordFactory()
                return LocalOnlyProbeProvider(kind: configuration.kind, probe: probe)
            })
            let configuration = AIProviderConfiguration(
                kind: .openaiCompatible,
                baseURL: "https://example.invalid",
                model: "replay-test-model",
                apiKey: "stored-replay-test-key",
                acceptsText: true,
                acceptsImages: true,
                acceptsVideo: true
            )
            let started = Date()
            let first = try await processor.process(
                sessionId: sessionID,
                pinTimes: pins,
                configuration: configuration,
                whisperModel: WhisperTranscriber.defaultStoredModel,
                identifySpeakers: true,
                localOnly: true
            ) { _, _ in }
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertTrue(first.hasCompleted(.completed))
            XCTAssertEqual(first.pipelineStatus, .completed)
            XCTAssertFalse(first.uploadConsent.approved)
            XCTAssertLessThanOrEqual(first.slices.count, MediaBudget.maxCandidateSlices)
            let firstProcedure = try XCTUnwrap(first.localProcedure)
            let hasValidTimedText = transcript.segments.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                    && $0.end > $0.start && $0.end <= manifest.duration.mediaSeconds
            }
            if hasValidTimedText || !first.shots.isEmpty || !pins.isEmpty {
                XCTAssertFalse(firstProcedure.steps.isEmpty)
            } else {
                XCTAssertTrue(firstProcedure.steps.isEmpty)
                XCTAssertTrue(firstProcedure.partial)
                XCTAssertFalse(firstProcedure.exclusions.isEmpty)
            }
            if !hasValidTimedText && transcript.hasUsableText {
                XCTAssertEqual(firstProcedure.transcriptStatus, "untimed_text_review_only")
            }
            XCTAssertFalse(firstProcedure.sizeLimitExceeded)
            XCTAssertLessThanOrEqual(firstProcedure.serializedByteCount, firstProcedure.limits.maxSerializedBytes)
            XCTAssertEqual(firstProcedure.anchors.count, first.shots.count + LocalProcedureBuilder.pinRows(pins).count)
            XCTAssertTrue(first.slices.allSatisfy { $0.analysisStatus == .skipped })

            let timing = try XCTUnwrap(PipelineTiming.load(sessionURL: sessionURL))
            XCTAssertGreaterThan(timing.zipBytes ?? 0, 0, "The ZIP must exist and be measured.")
            XCTAssertLessThanOrEqual(timing.zipBytes ?? Int.max, MediaBudget.maxZipBytes)
            XCTAssertLessThanOrEqual(timing.exportFolderBytes ?? Int.max, MediaBudget.maxZipBytes)
            let capturedTimes = Dictionary(grouping: firstProcedure.evidenceTimes, by: { $0.path })
            for slice in first.slices {
                for item in slice.stillEvidence {
                    XCTAssertTrue(item.actualMedia.isFinite)
                    XCTAssertGreaterThanOrEqual(item.actualMedia, slice.startMedia)
                    XCTAssertLessThanOrEqual(item.actualMedia, slice.endMedia)
                    XCTAssertTrue(capturedTimes[item.path]?.contains(where: { $0.actualMedia == item.actualMedia }) == true)
                }
            }

            var playableClips = 0
            for slice in first.slices {
                guard let clipPath = slice.clipPath,
                      let resolvedClipPath = ExportRel.existingSessionFile(clipPath, sessionURL: sessionURL) else { continue }
                let asset = AVURLAsset(url: sessionURL.appendingPathComponent(resolvedClipPath))
                let duration = try await asset.load(.duration)
                XCTAssertTrue(duration.isValid)
                XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0)
                playableClips += 1
            }
            totalPlayableClips += playableClips

            let fingerprint = firstProcedure.inputFingerprint
            let stepIDs = firstProcedure.steps.map(\.id)
            let anchorIDs = firstProcedure.anchors.map(\.id)
            let sliceIDs = first.slices.map(\.sliceId)
            let firstExportContent = try exportContentHashes(sessionURL: sessionURL)
            let repeated = try await processor.process(
                sessionId: sessionID,
                pinTimes: pins,
                configuration: configuration,
                whisperModel: WhisperTranscriber.defaultStoredModel,
                identifySpeakers: true,
                localOnly: true
            ) { _, _ in }
            let repeatedProcedure = try XCTUnwrap(repeated.localProcedure)
            XCTAssertEqual(repeatedProcedure.inputFingerprint, fingerprint)
            XCTAssertEqual(repeatedProcedure.steps.map(\.id), stepIDs)
            XCTAssertEqual(repeatedProcedure.anchors.map(\.id), anchorIDs)
            XCTAssertEqual(repeated.slices.map(\.sliceId), sliceIDs)
            let repeatedExportContent = try exportContentHashes(sessionURL: sessionURL)
            XCTAssertEqual(repeatedExportContent, firstExportContent)

            metrics.append([
                "alias": alias,
                "media_seconds": manifest.duration.mediaSeconds,
                "transcript_segments": transcript.segments.count,
                "shot_anchors": first.shots.count,
                "pin_anchors": LocalProcedureBuilder.pinRows(pins).count,
                "outline_steps": firstProcedure.steps.count,
                "action_excerpts": firstProcedure.steps.filter { $0.kind == "action_excerpt" }.count,
                "partial": firstProcedure.partial,
                "selected_windows": firstProcedure.selectedWindowCount,
                "clip_count": playableClips,
                "generated_stills": first.slices.reduce(0) { $0 + $1.stillEvidence.count },
                "zip_bytes": timing.zipBytes ?? 0,
                "export_folder_bytes": timing.exportFolderBytes ?? 0,
                "elapsed_seconds": elapsed,
                "repeat_fingerprint_stable": repeatedProcedure.inputFingerprint == fingerprint,
                "repeat_export_content_stable": repeatedExportContent == firstExportContent
            ])
        }
        XCTAssertGreaterThan(totalPlayableClips, 0, "At least one copied real recording must produce a playable selected clip.")
        let counts = probe.counts()
        XCTAssertEqual(counts.factories, 0)
        XCTAssertEqual(counts.providerCalls, 0)
        XCTAssertEqual(counts.transcriberLoads, 0)
        let report = try JSONSerialization.data(withJSONObject: [
            "fixtures": metrics,
            "provider_factories": counts.factories,
            "provider_calls": counts.providerCalls,
            "transcriber_model_loads": counts.transcriberLoads
        ], options: [.prettyPrinted, .sortedKeys])
        try report.write(to: runRoot.appendingPathComponent("private-replay-metrics.json"), options: .atomic)
        print("LOCAL_EXPORT_REPLAY_OK fixtures=\(metrics.count) playable_clips=\(totalPlayableClips) provider_calls=0 transcriber_loads=0")
    }
}

private struct LocalOnlyProbeProvider: AIProvider {
    var kind: AIProviderKind
    var probe: LocalOnlyCallProbe

    func evaluate(request: SliceEvaluationRequest) async throws -> CandidateEvaluationResponse {
        probe.recordProviderCall()
        throw AIProviderError.emptyResponse
    }
}

final class LocalProcedureTests: XCTestCase {
    func testOutlineIsExtractiveBoundedAndIndependentOfTaskCaps() throws {
        var segments: [TranscriptSegment] = []
        for index in 0..<180 {
            let start = Double(index * 40)
            let end = start + 4
            let phrase: String = index.isMultiple(of: 2)
                ? "Apoi deschide pagina și apasă salvează."
                : "Then open the page and click save."
            segments.append(TranscriptSegment(
                start: start,
                end: end,
                text: phrase,
                speaker: nil,
                words: [],
                source: "room"
            ))
        }
        let transcript = FullTranscript(sessionId: "synthetic", language: "ro", segments: segments)
        let shots = (0..<20).map { index in
            ShotRecord(id: "shot-\(index)", tMedia: Double(index * 300), rawPath: "archive/shots/\(index).png", annotatedPath: nil, note: "Observed state \(index)", source: .typed)
        }
        let pins = (0..<18).map { Double($0 * 250 + 10) }
        var slices: [SliceRecord] = []
        for index in 0..<12 {
            let start = Double(index * 500)
            let end = start + 20
            slices.append(SliceRecord(
                sliceId: "slice-\(index)",
                startMedia: start,
                endMedia: end,
                trigger: .keyword,
                associatedShotId: nil,
                clipPath: nil,
                stills: [],
                analysisStatus: .skipped,
                score: 1
            ))
        }
        let procedure = LocalProcedureBuilder.build(transcript: transcript, shots: shots, pins: pins, slices: slices, duration: 7200, context: .empty)

        XCTAssertEqual(procedure.steps.count, 128)
        XCTAssertTrue(procedure.partial)
        XCTAssertEqual(procedure.anchors.filter { $0.kind == "shot" }.count, 20)
        XCTAssertEqual(procedure.anchors.filter { $0.kind == "pin" }.count, 18)
        XCTAssertTrue(procedure.steps.contains { $0.kind == "action_excerpt" && $0.source == "room" })
        XCTAssertTrue(procedure.steps.contains { $0.source == "human_shot_note" && $0.reviewState == "manual_review_required" })
        let excerpts = procedure.steps.map { $0.excerpt }.joined()
        XCTAssertLessThanOrEqual(excerpts.utf8.count, LocalProcedureBuilder.maxQuoteBytes)
        XCTAssertTrue(procedure.chapters.contains { $0.label.contains("chronological navigation") })
        XCTAssertFalse(procedure.steps.contains { $0.reviewState == "confirmed" })
        let reversed = LocalProcedureBuilder.build(transcript: transcript, shots: Array(shots.reversed()), pins: pins.reversed(), slices: slices, duration: 7200, context: .empty)
        XCTAssertEqual(procedure.inputFingerprint, reversed.inputFingerprint)
        XCTAssertEqual(procedure.steps.map { $0.id }, reversed.steps.map { $0.id })
    }

    func testChapterNavigationAcrossSynthetic10To180MinuteSessions() {
        for minutes in [10, 40, 50, 120, 180] {
            let duration = Double(minutes * 60)
            let segments = (0..<Int(duration / 40)).map { index in
                TranscriptSegment(
                    start: Double(index * 40), end: Double(index * 40) + 4,
                    text: index.isMultiple(of: 2) ? "Then open the next page." : "Apoi apasă salvare.",
                    speaker: nil, words: [], source: "synthetic"
                )
            }
            let shots = (0..<20).map { index in
                ShotRecord(
                    id: "shot-\(index)", tMedia: duration * Double(index) / 20,
                    rawPath: "archive/shots/\(index).png", annotatedPath: nil,
                    note: "Observed state \(index)", source: .typed
                )
            }
            let pins = (0..<18).map { duration * Double($0) / 18 }
            let slices = (0..<12).map { index in
                let start = duration * Double(index) / 12
                return SliceRecord(
                    sliceId: "slice-\(index)", startMedia: start,
                    endMedia: min(duration, start + 20), trigger: .keyword,
                    associatedShotId: nil, clipPath: nil, stills: [],
                    analysisStatus: .skipped, score: 1
                )
            }
            let transcript = FullTranscript(sessionId: "synthetic-\(minutes)", language: "ro", segments: segments)
            let procedure = LocalProcedureBuilder.build(
                transcript: transcript, shots: shots, pins: pins, slices: slices,
                duration: duration, context: .empty
            )

            XCTAssertEqual(procedure.candidateCount, segments.count, "\(minutes)-minute source count")
            XCTAssertLessThanOrEqual(procedure.steps.count, LocalProcedureBuilder.maxEntries)
            XCTAssertEqual(procedure.anchors.count, shots.count + pins.count)
            XCTAssertEqual(procedure.chapters.count, min(12, max(1, Int(ceil(duration / 600)))))
            XCTAssertEqual(procedure.chapters.first?.start, 0)
            XCTAssertEqual(procedure.chapters.last?.end, duration)
            XCTAssertTrue(procedure.steps.allSatisfy { step in procedure.chapters.contains { $0.id == step.chapterId } })
            XCTAssertEqual(procedure.steps.map(\.order), Array(1...procedure.steps.count))

            let reordered = LocalProcedureBuilder.build(
                transcript: transcript, shots: shots.reversed(), pins: pins.reversed(),
                slices: slices.reversed(), duration: duration, context: .empty
            )
            XCTAssertEqual(procedure.inputFingerprint, reordered.inputFingerprint)
            XCTAssertEqual(procedure.steps.map(\.id), reordered.steps.map(\.id))
        }
    }

    func testProceduralCommandsAndPrerequisitesKeepMediaCoverage() {
        for offset in [0.0, 47.0] {
            let phases = [30.0, 240, 480, 720, 960, 1200, 1500].map { $0 + offset }
            let statements = [
                "Shot note: import the ticket context before the walkthrough.",
                "Run ./tools/prepare-mapleharbor --dry-run and inspect the output.",
                "Înainte de execuție, coloana account_id trebuie să existe și IMPORT_MODE=local este necesară.",
                "Next execute the local import command and check the batch identifier.",
                "Then verify the spreadsheet column mapping before continuing.",
                "For production, configure the storage job with --environment=production.",
                "Open question: who reviews the follow-up job after deployment?"
            ]
            let segments = zip(phases, statements).map { time, statement in
                TranscriptSegment(start: time, end: time + 8, text: statement, speaker: nil, words: [], source: "room")
            } + [
                TranscriptSegment(start: 1650 + offset, end: 1658 + offset, text: "um um fix fix okay okay", speaker: nil, words: [], source: "room")
            ]
            let transcript = FullTranscript(sessionId: "walkthrough", language: "ro", segments: segments)
            let shot = ShotRecord(id: "shot-context", tMedia: phases[0], rawPath: "archive/shots/001.png", annotatedPath: nil, note: "Import context", source: .typed)
            let procedure = LocalProcedureBuilder.build(
                transcript: transcript, shots: [shot], pins: [], slices: [], duration: 2520, context: .empty
            )
            for phase in phases {
                XCTAssertTrue(procedure.steps.contains { $0.start == phase && $0.kind == "action_excerpt" }, "missing action at \(phase)")
            }
            let slices = MeetingSlicer().slice(shots: [shot], pins: [], transcript: transcript, mediaDuration: 2520)
            XCTAssertLessThanOrEqual(slices.count, MediaBudget.maxCandidateSlices)
            for phase in phases {
                XCTAssertTrue(slices.contains { $0.startMedia <= phase && $0.endMedia >= phase }, "missing media at \(phase)")
            }
        }
    }

    func testShortAndUnsupportedTranscriptStaysReviewOnly() {
        let transcript = FullTranscript(sessionId: "short", language: "fr", segments: [
            TranscriptSegment(start: .nan, end: 1, text: "click", speaker: nil, words: []),
            TranscriptSegment(start: 1, end: 1, text: "invalid", speaker: nil, words: []),
            TranscriptSegment(start: 1, end: 3, text: "bonjour le monde", speaker: nil, words: [])
        ])
        let procedure = LocalProcedureBuilder.build(transcript: transcript, shots: [], pins: [], slices: [], duration: 3, context: .empty)
        XCTAssertEqual(procedure.steps.count, 1)
        XCTAssertEqual(procedure.steps[0].kind, "review_passage")
        XCTAssertTrue(procedure.partial)
        XCTAssertEqual(procedure.transcriptStatus, "timed_transcript")
    }

    func testOutOfBoundsTimedTextIsExcludedInsteadOfReportedAsTimed() {
        let transcript = FullTranscript(sessionId: "out-of-bounds", language: "en", segments: [
            TranscriptSegment(start: 11, end: 12, text: "Then click save.", speaker: nil, words: [])
        ])
        let procedure = LocalProcedureBuilder.build(
            transcript: transcript, shots: [], pins: [], slices: [], duration: 10, context: .empty
        )
        XCTAssertTrue(procedure.steps.isEmpty)
        XCTAssertTrue(procedure.partial)
        XCTAssertEqual(procedure.transcriptStatus, "untimed_text_review_only")
        XCTAssertTrue(procedure.exclusions.contains { $0.reason == "outside_media_bounds" })
    }

    func testSlicerMergesAllAnchorProvenanceAndRanksCoverage() {
        let transcript = FullTranscript(sessionId: "slicer", language: "en", segments: [
            TranscriptSegment(start: 10, end: 14, text: "Then click the save button.", speaker: nil, words: [])
        ])
        let shot = ShotRecord(id: "shot-critical", tMedia: 12, rawPath: "archive/shots/1.png", annotatedPath: nil, note: "", source: .typed)
        let result = MeetingSlicer().slice(shots: [shot], pins: [11], transcript: transcript, mediaDuration: 2400)
        XCTAssertLessThanOrEqual(result.count, MediaBudget.maxCandidateSlices)
        XCTAssertEqual(result, result.sorted { $0.startMedia < $1.startMedia })
        let containing = try! XCTUnwrap(result.first { $0.startMedia <= 11 && $0.endMedia >= 12 })
        XCTAssertEqual(containing.trigger, .shot)
        XCTAssertEqual(containing.score, 100)
        XCTAssertTrue(containing.anchorIds.contains("shot-critical"))
        let pinID = "pin-" + String(SHA256.hash(data: Data("11.000|0".utf8)).prefix(10).map { String(format: "%02x", $0) }.joined())
        XCTAssertTrue(containing.anchorIds.contains(pinID))
        XCTAssertLessThanOrEqual(containing.endMedia - containing.startMedia, MediaBudget.clipMaxDuration)
    }

    func testLegacyManifestDecodesOutlineAsAbsent() throws {
        var manifest = SessionManifest.makeNew(sessionId: "legacy", product: .empty)
        manifest.localProcedure = nil
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(manifest)) as? [String: Any])
        object.removeValue(forKey: "local_procedure")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SessionManifest.self, from: legacy)
        XCTAssertNil(decoded.localProcedure)
    }

    func testGeneratedStillRecordsActualDecodedMediaTime() throws {
        let still = "archive/media-work/slice-1/shot-1.jpg"
        let slice = SliceRecord(
            sliceId: "slice-1",
            startMedia: 9,
            endMedia: 34,
            trigger: .pin,
            associatedShotId: nil,
            clipPath: "archive/media-work/slice-1/clip.mp4",
            stills: [still],
            analysisStatus: .skipped,
            score: 1,
            stillEvidence: [SliceStillEvidence(path: still, requestedMedia: 21.0, actualMedia: 21.117)]
        )
        let procedure = LocalProcedureBuilder.build(
            transcript: FullTranscript(sessionId: "still", language: "en", segments: []),
            shots: [], pins: [21], slices: [slice], duration: 60, context: .empty
        )
        XCTAssertEqual(procedure.evidenceTimes, [
            LocalProcedureEvidenceTime(path: still, requestedMedia: 21.0, actualMedia: 21.117)
        ])

        let encoded = try JSONEncoder().encode(procedure)
        let decoded = try JSONDecoder().decode(LocalProcedure.self, from: encoded)
        XCTAssertEqual(decoded.evidenceTimes.first?.actualMedia, 21.117)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "evidence_times")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertEqual(try JSONDecoder().decode(LocalProcedure.self, from: legacyData).evidenceTimes, [])
    }

    func testLocalOnlyKeepsConsentButDoesNotCreateProviderOrRerunTranscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-only-export-\(UUID().uuidString)")
        defer {
            AgentLog.setFileURLForTesting(nil)
            try? FileManager.default.removeItem(at: root)
        }
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        let vault = SessionVault(rootURL: root)
        let probe = LocalOnlyCallProbe()
        let transcriber = WhisperTranscriber(loadModel: { _ in
            probe.recordTranscriberLoad()
            throw SessionRecorderError.writerFailed("Unexpected transcription model load in local-only mode.")
        })
        let processor = SessionProcessor(vault: vault, transcriber: transcriber, providerFactory: { configuration in
            probe.recordFactory()
            return LocalOnlyProbeProvider(kind: configuration.kind, probe: probe)
        })
        let configuration = AIProviderConfiguration(
            kind: .openaiCompatible,
            baseURL: "https://example.invalid",
            model: "stored-test-model",
            apiKey: "stored-test-key",
            acceptsText: true,
            acceptsImages: true,
            acceptsVideo: true
        )

        let completed = try vault.createSession(product: .empty)
        var completedManifest = completed.manifest
        completedManifest.duration.mediaSeconds = 120
        completedManifest.uploadConsent = UploadConsent(
            approved: true, approvedAt: Date(), provider: "test", endpoint: "https://example.invalid",
            model: "stored-test-model", includesClipAudio: true, includesClipVideo: true,
            includesStills: true
        )
        try vault.write(manifest: &completedManifest)
        try SpeakerTimeline.save(
            FullTranscript(sessionId: completedManifest.sessionId, language: "en", segments: [
                TranscriptSegment(start: 5, end: 8, text: "Then click save.", speaker: nil, words: [], source: "room")
            ]),
            sessionURL: completed.url
        )
        let completedResult = try await processor.process(
            sessionId: completedManifest.sessionId,
            pinTimes: [6],
            configuration: configuration,
            whisperModel: WhisperTranscriber.defaultStoredModel,
            localOnly: true
        ) { _, _ in }
        XCTAssertTrue(completedResult.uploadConsent.approved)
        XCTAssertTrue(completedResult.hasCompleted(.completed))
        XCTAssertNotNil(completedResult.localProcedure)
        XCTAssertTrue(completedResult.slices.allSatisfy { $0.analysisStatus == .skipped })

        let incomplete = try vault.createSession(product: .empty)
        var incompleteManifest = incomplete.manifest
        incompleteManifest.duration.mediaSeconds = 60
        incompleteManifest.uploadConsent = completedManifest.uploadConsent
        try vault.write(manifest: &incompleteManifest)
        try SpeakerTimeline.save(
            FullTranscript(
                sessionId: incompleteManifest.sessionId,
                language: "en",
                segments: [TranscriptSegment(start: 2, end: 4, text: "Open settings.", speaker: nil, words: [])],
                transcriptionAnalysis: [TranscriptionAnalysis(source: "room", status: "failed")]
            ),
            sessionURL: incomplete.url
        )
        let incompleteResult = try await processor.process(
            sessionId: incompleteManifest.sessionId,
            pinTimes: [3],
            configuration: configuration,
            whisperModel: WhisperTranscriber.defaultStoredModel,
            localOnly: true
        ) { _, _ in }
        XCTAssertFalse(incompleteResult.hasCompleted(.transcribing))
        XCTAssertFalse(incompleteResult.hasCompleted(.completed))
        XCTAssertNotNil(incompleteResult.localProcedure)

        let counts = probe.counts()
        XCTAssertEqual(counts.factories, 0)
        XCTAssertEqual(counts.providerCalls, 0)
        XCTAssertEqual(counts.transcriberLoads, 0)
    }
}
