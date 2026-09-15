import Foundation
import XCTest
@testable import ScrumTrace

final class SessionTransferTests: XCTestCase {
    private let sender = SessionEnvironment(computer: "Sender Mac", macOS: "macOS fixture",
                                            appVersion: "1.0", appBuild: "2", architecture: "arm64")

    private func fixture(_ body: (URL, SessionVault, String) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrumTrace.TransferTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = SessionVault(rootURL: base.appendingPathComponent("source/sessions"))
        var manifest = try vault.createSession(product: .empty).manifest
        let id = manifest.sessionId
        let root = vault.sessionURL(id: id)
        manifest.pipelineStatus = .offlineFailed
        manifest.completedStages = [.transcribing, .slicing]
        manifest.uploadConsent = UploadConsent(
            approved: true, approvedAt: Date(), provider: "test", endpoint: "https://example.test",
            model: "model", includesClipAudio: false, includesClipVideo: false, includesStills: true
        )
        manifest.tasks = [
            TaskRecord(taskId: "TASK-01", sourceSliceId: "slice-01", kind: .decision, status: .needsReview,
                       title: "Original result", observed: "", stated: "", inferred: "",
                       agentInstructions: "", quotes: [], evidenceMedia: ["export/shots/001.png"], confidence: 0.5)
        ]
        manifest.slices = [
            SliceRecord(sliceId: "slice-01", startMedia: 0, endMedia: 1, trigger: .shot,
                        associatedShotId: nil, clipPath: nil, stills: ["export/shots/001.png"],
                        analysisStatus: .success, score: 1)
        ]
        try vault.write(manifest: &manifest)
        try ExportRel.writeContainedData(Data(repeating: 42, count: 1024 * 1024 + 7),
                                         relative: ScrumTracePath.audioWav, sessionURL: root)
        let transcript = FullTranscript(sessionId: id, language: "en", segments: [
            TranscriptSegment(start: 0, end: 1, text: "Original transcript", speaker: nil, words: [])
        ])
        try SpeakerTimeline.save(transcript, sessionURL: root)
        try PipelineTiming(whisperWallSeconds: 5).write(sessionURL: root)
        try ExportRel.writeContainedData(Data("fixture".utf8), relative: "export/shots/001.png", sessionURL: root)
        try ExportRel.writeContainedData(Data("# Context".utf8), relative: ScrumTracePath.agentContext, sessionURL: root)
        try ExportRel.writeContainedData(try SessionTransfer.encoder().encode(manifest),
                                         relative: ScrumTracePath.exportManifest, sessionURL: root)
        try body(base, vault, id)
    }

    func testCompleteRoundTripPreservesBytesOriginAndOriginalButResetsUploadConsent() throws {
        try fixture { base, source, id in
            let package = base.appendingPathComponent("recording.scrumtrace")
            let original = try Data(contentsOf: source.sessionURL(id: id).appendingPathComponent(ScrumTracePath.manifest))
            let index = try SessionTransfer(vault: source).export(id: id, to: package, scope: .complete,
                                                                  includePrivate: true, environment: sender)
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            let localID = try SessionTransfer(vault: receiver).importRecording(from: package)
            let imported = try receiver.loadManifest(id: localID)
            XCTAssertNotEqual(localID, id)
            XCTAssertEqual(imported.importOrigin?.originalSessionID, id)
            XCTAssertEqual(imported.importOrigin?.exportedFrom, sender)
            XCTAssertEqual(imported.importOrigin?.transferID, index.transferID)
            XCTAssertEqual(imported.importOrigin?.integrityVerified, true)
            XCTAssertNil(imported.captureEnvironment, "An old capture must not be attributed to its exporter")
            XCTAssertFalse(imported.uploadConsent.approved)
            XCTAssertTrue(imported.uploadConsent.needsReprompt(destinations: [
                UploadDestination(serviceId: "receiver", serviceName: "Receiver AI", provider: "test",
                                  endpoint: "https://example.test", model: "model", includesClipVideo: false)
            ]))
            XCTAssertEqual(imported.tasks.first?.title, "Original result")
            let importedRoot = receiver.sessionURL(id: localID)
            XCTAssertEqual(SpeakerTimeline.load(sessionURL: importedRoot)?.sessionId, localID)
            XCTAssertEqual(try Data(contentsOf: importedRoot.appendingPathComponent(ScrumTracePath.audioWav)),
                           try Data(contentsOf: source.sessionURL(id: id).appendingPathComponent(ScrumTracePath.audioWav)))
            XCTAssertEqual(ExportRel.readContainedData(relative: SessionTransfer.baselineManifest, sessionURL: importedRoot), original)
            XCTAssertEqual(try Data(contentsOf: source.sessionURL(id: id).appendingPathComponent(ScrumTracePath.manifest)), original)
            XCTAssertEqual(receiver.listedSessionIds(), [localID])
        }
    }

    func testCompleteExportRequiresExplicitPrivateConsent() throws {
        try fixture { base, vault, id in
            let destination = base.appendingPathComponent("private.scrumtrace")
            XCTAssertThrowsError(try SessionTransfer(vault: vault).export(
                id: id, to: destination, scope: .complete, includePrivate: false, environment: sender
            )) { XCTAssertEqual($0 as? SessionTransferError, .privateConsentRequired) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testTransferAndReanalysisIgnoreDerivedCodexWorkspaces() throws {
        try fixture { base, vault, id in
            let workspace = try CodexWorkspace.prepare(sessionURL: vault.sessionURL(id: id))
            try FileManager.default.createSymbolicLink(
                at: workspace.appendingPathComponent("agent-created-link"), withDestinationURL: base
            )
            let transfer = SessionTransfer(vault: vault)
            let index = try transfer.export(
                id: id, to: base.appendingPathComponent("with-workspace.scrumtrace"),
                scope: .complete, includePrivate: true, environment: sender
            )
            XCTAssertFalse(index.files.contains { $0.path.hasPrefix(CodexWorkspace.directoryName + "/") })
            let copyID = try transfer.analysisCopy(id: id, retranscribe: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vault.sessionURL(id: copyID)
                .appendingPathComponent(CodexWorkspace.directoryName).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        }
    }

    func testEvidencePackageContainsNoPrivateOriginalAndCannotBeReprocessed() throws {
        try fixture { base, vault, id in
            let package = base.appendingPathComponent("evidence.scrumtrace")
            let index = try SessionTransfer(vault: vault).export(
                id: id, to: package, scope: .evidence, includePrivate: false, environment: sender
            )
            XCTAssertFalse(index.files.contains { $0.path.hasPrefix("archive/") || $0.path == "full_transcript.json" })
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            let transfer = SessionTransfer(vault: receiver)
            let imported = try transfer.importRecording(from: package)
            XCTAssertEqual(try receiver.loadManifest(id: imported).importOrigin?.scope, .evidence)
            XCTAssertNil(ExportRel.existingSessionFile(ScrumTracePath.audioWav, sessionURL: receiver.sessionURL(id: imported)))
            XCTAssertThrowsError(try transfer.analysisCopy(id: imported, retranscribe: false)) {
                XCTAssertEqual($0 as? SessionTransferError, .missingSources)
            }
        }
    }

    func testLegacySessionAndExportFoldersRemainImportableWithoutClaimingVerifiedOrigin() throws {
        try fixture { base, source, id in
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            let transfer = SessionTransfer(vault: receiver)
            let full = try transfer.importRecording(from: source.sessionURL(id: id))
            let partial = try transfer.importRecording(from: source.sessionURL(id: id).appendingPathComponent("export"))
            XCTAssertEqual(try receiver.loadManifest(id: full).importOrigin?.scope, .complete)
            XCTAssertEqual(try receiver.loadManifest(id: partial).importOrigin?.scope, .evidence)
            XCTAssertEqual(try receiver.loadManifest(id: full).importOrigin?.integrityVerified, false)
            XCTAssertNil(try receiver.loadManifest(id: full).importOrigin?.exportedFrom)
            XCTAssertEqual(receiver.listedSessionIds().count, 2)
        }
    }

    func testRepeatedImportIsDetectedWithoutOverwritingAnExistingSession() throws {
        try fixture { base, source, id in
            let package = base.appendingPathComponent("recording.scrumtrace")
            _ = try SessionTransfer(vault: source).export(id: id, to: package, scope: .complete,
                                                         includePrivate: true, environment: sender)
            let transfer = SessionTransfer(vault: source)
            let imported = try transfer.importRecording(from: package)
            XCTAssertThrowsError(try transfer.importRecording(from: package)) {
                XCTAssertEqual($0 as? SessionTransferError, .duplicate(imported))
            }
            XCTAssertEqual(Set(source.listedSessionIds()), Set([id, imported]))
        }
    }

    func testTamperedOrTruncatedFilesAbortImportAndRemoveStaging() throws {
        try fixture { base, source, id in
            let package = base.appendingPathComponent("recording.scrumtrace")
            _ = try SessionTransfer(vault: source).export(id: id, to: package, scope: .complete,
                                                         includePrivate: true, environment: sender)
            try Data("changed".utf8).write(to: package.appendingPathComponent(ScrumTracePath.audioWav))
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            XCTAssertThrowsError(try SessionTransfer(vault: receiver).importRecording(from: package)) {
                XCTAssertEqual($0 as? SessionTransferError, .checksumMismatch)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: receiver.rootURL.path), [])
        }
    }

    func testExtraUnindexedFileAndUnsupportedVersionAreRejected() throws {
        try fixture { base, source, id in
            let package = base.appendingPathComponent("recording.scrumtrace")
            var index = try SessionTransfer(vault: source).export(id: id, to: package, scope: .complete,
                                                                   includePrivate: true, environment: sender)
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            let transfer = SessionTransfer(vault: receiver)
            try Data("extra".utf8).write(to: package.appendingPathComponent("archive/unlisted.txt"))
            XCTAssertThrowsError(try transfer.importRecording(from: package))
            try FileManager.default.removeItem(at: package.appendingPathComponent("archive/unlisted.txt"))
            index.version = 999
            try SessionTransfer.encoder().encode(index).write(to: package.appendingPathComponent(SessionTransfer.indexName))
            XCTAssertThrowsError(try transfer.importRecording(from: package)) {
                XCTAssertEqual($0 as? SessionTransferError, .unsupportedVersion)
            }
        }
    }

    func testLinksAndTraversalAreRejectedBeforeAnySourceContentsAreImported() throws {
        try fixture { base, source, id in
            let root = source.sessionURL(id: id)
            let outside = base.appendingPathComponent("outside.txt")
            try Data("private outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("archive/link.txt"), withDestinationURL: outside)
            XCTAssertThrowsError(try SessionTransfer(vault: source).export(
                id: id, to: base.appendingPathComponent("unsafe.scrumtrace"),
                scope: .complete, includePrivate: true, environment: sender
            )) { XCTAssertEqual($0 as? SessionTransferError, .unsafePath) }
            for bad in ["../outside", "archive/../../outside", "/etc/passwd", "archive/./file", "archive//file",
                        "archive/back\\slash", "archive/.hidden", "archive/new\nline"] {
                XCTAssertFalse(SessionTransfer.isSafePath(bad), bad)
            }
            XCTAssertEqual(try String(contentsOf: outside), "private outside")
        }
    }

    func testExportNeverReplacesAnExistingDestination() throws {
        try fixture { base, source, id in
            let destination = base.appendingPathComponent("existing.scrumtrace")
            try Data("keep".utf8).write(to: destination)
            XCTAssertThrowsError(try SessionTransfer(vault: source).export(
                id: id, to: destination, scope: .complete, includePrivate: true, environment: sender
            )) { XCTAssertEqual($0 as? SessionTransferError, .destinationExists) }
            XCTAssertEqual(try String(contentsOf: destination), "keep")
        }
    }

    func testAnalysisCopyKeepsImportedResultsAndTranscriptWhileInvalidatingOnlyDownstreamWork() throws {
        try fixture { base, source, id in
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            let transfer = SessionTransfer(vault: receiver)
            let imported = try transfer.importRecording(from: source.sessionURL(id: id))
            let copy = try transfer.analysisCopy(id: imported, retranscribe: false)
            let new = try receiver.loadManifest(id: copy)
            XCTAssertEqual(new.importOrigin?.kind, .analysisCopy)
            XCTAssertEqual(new.importOrigin?.parentSessionID, imported)
            XCTAssertFalse(new.uploadConsent.approved)
            XCTAssertTrue(new.hasCompleted(.transcribing))
            XCTAssertTrue(new.hasCompleted(.slicing))
            XCTAssertFalse(new.hasCompleted(.evaluating))
            XCTAssertTrue(new.tasks.isEmpty)
            XCTAssertEqual(new.slices.first?.analysisStatus, .pending)
            XCTAssertEqual(try receiver.loadManifest(id: imported).tasks.first?.title, "Original result")
            XCTAssertEqual(SpeakerTimeline.load(sessionURL: receiver.sessionURL(id: copy))?.sessionId, copy)
            XCTAssertNil(SessionTransferAssessment.load(vault: receiver, id: copy).currentWhisperSeconds,
                         "A reused transcript is not a new speed measurement")
        }
    }

    func testRetranscriptionCopyKeepsBaselineButStartsWithoutAReusablePrimaryOrOldTiming() throws {
        try fixture { base, source, id in
            let transfer = SessionTransfer(vault: source)
            let copy = try transfer.analysisCopy(id: id, retranscribe: true)
            let new = try source.loadManifest(id: copy)
            let root = source.sessionURL(id: copy)
            XCTAssertTrue(new.completedStages.isEmpty)
            XCTAssertTrue(new.slices.isEmpty)
            XCTAssertNil(SpeakerTimeline.load(sessionURL: root))
            XCTAssertNil(PipelineTiming.load(sessionURL: root))
            XCTAssertNotNil(ExportRel.readContainedData(relative: SessionTransfer.baselineTranscript, sessionURL: root))
            XCTAssertNotNil(SpeakerTimeline.load(sessionURL: source.sessionURL(id: id)))
            let assessment = SessionTransferAssessment.load(vault: source, id: copy)
            XCTAssertEqual(assessment.sourceWhisperSeconds, 5)
            XCTAssertNil(assessment.currentWhisperSeconds)
            XCTAssertTrue(assessment.hasRecording)
        }
    }

    func testCaptureMetadataIsBackwardCompatibleAndPrivateInTheAgentProjection() throws {
        try fixture { _, source, id in
            var manifest = try source.loadManifest(id: id)
            XCTAssertNil(manifest.captureEnvironment)
            manifest.captureEnvironment = sender
            manifest.importOrigin = .init(kind: .imported, originalSessionID: id, importedAt: Date(),
                                          exportedFrom: sender, transferID: UUID().uuidString,
                                          scope: .complete, integrityVerified: true, parentSessionID: nil)
            let projection = try ExportProjector().project(sessionURL: source.sessionURL(id: id), manifest: manifest)
            XCTAssertNil(projection.manifest.captureEnvironment)
            XCTAssertNil(projection.manifest.importOrigin?.exportedFrom)
            XCTAssertNotNil(projection.manifest.importOrigin)
        }
    }

    func testImportReviewContainsTechnicalFactsButNoCapturedTextOrComputerName() throws {
        try fixture { base, source, id in
            let package = base.appendingPathComponent("recording.scrumtrace")
            _ = try SessionTransfer(vault: source).export(id: id, to: package, scope: .complete,
                                                         includePrivate: true, environment: sender)
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            let imported = try SessionTransfer(vault: receiver).importRecording(from: package)
            let root = receiver.sessionURL(id: imported)
            let report = try XCTUnwrap(ExportRel.readContainedData(relative: SessionTransferReviewReport.path, sessionURL: root))
            let text = String(decoding: report, as: UTF8.self)
            XCTAssertTrue(text.contains("all indexed files matched"))
            XCTAssertTrue(text.contains("Timed transcript passages available: 1"))
            XCTAssertFalse(text.contains("Original transcript"))
            XCTAssertFalse(text.contains("Original result"))
            XCTAssertFalse(text.contains("Sender Mac"))
            XCTAssertFalse(text.contains("archive/"))
            XCTAssertTrue(PackBudget.allowList(exportDir: root.appendingPathComponent("export")).contains("TRANSFER_REVIEW.md"))
        }
    }

    func testAssessmentResolvesExportRelativeEvidenceAndCountsOnlyUsableTimedPassages() throws {
        try fixture { _, source, id in
            var manifest = try source.loadManifest(id: id)
            manifest.tasks[0].evidenceMedia = ["shots/001.png", "media/missing.jpg"]
            let root = source.sessionURL(id: id)
            var transcript = try XCTUnwrap(SpeakerTimeline.load(sessionURL: root))
            transcript.segments.append(TranscriptSegment(start: 2, end: 2, text: "Untimed", speaker: nil, words: []))
            transcript.segments.append(TranscriptSegment(start: 2, end: 3, text: "  ", speaker: nil, words: []))
            try SpeakerTimeline.save(transcript, sessionURL: root)
            let assessment = SessionTransferAssessment.load(sessionURL: root, manifest: manifest)
            XCTAssertEqual(assessment.timedSegments, 1)
            XCTAssertEqual(assessment.missingEvidence, 1)
        }
    }

    func testImportedCopyCompletesLocalAnalysisAndPacksItsReviewWithoutChangingTheOriginal() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ScrumTrace.TransferPipeline.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = SessionVault(rootURL: base.appendingPathComponent("source/sessions"))
        var original = try source.createSession(product: .empty).manifest
        original.completedStages = [.transcribing, .slicing]
        original.pipelineStatus = .offlineFailed
        try source.write(manifest: &original)
        let transcript = FullTranscript(sessionId: original.sessionId, language: "en", segments: [
            .init(start: 0, end: 1, text: "Synthetic passage for a local processing test.", speaker: nil, words: [])
        ])
        try SpeakerTimeline.save(transcript, sessionURL: source.sessionURL(id: original.sessionId))
        let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
        let transfer = SessionTransfer(vault: receiver)
        let imported = try transfer.importRecording(from: source.sessionURL(id: original.sessionId))
        let importedRoot = receiver.sessionURL(id: imported)
        let before = ExportRel.readContainedData(relative: ScrumTracePath.manifest, sessionURL: importedRoot)
        let copy = try transfer.analysisCopy(id: imported, retranscribe: false)
        let localOnly = AIProviderConfiguration(kind: .openaiCompatible, baseURL: "https://example.invalid",
                                                model: "unused", apiKey: "", acceptsText: true,
                                                acceptsImages: false, acceptsVideo: false)
        let result = try await SessionProcessor(vault: receiver, transcriber: WhisperTranscriber()).process(
            sessionId: copy, pinTimes: [], configuration: localOnly, whisperModel: "unused"
        ) { _, _ in }
        XCTAssertEqual(result.pipelineStatus, .completed)
        XCTAssertEqual(result.importOrigin?.parentSessionID, imported)
        XCTAssertFalse(result.uploadConsent.approved)
        XCTAssertEqual(ExportRel.readContainedData(relative: ScrumTracePath.manifest, sessionURL: importedRoot), before)
        let root = receiver.sessionURL(id: copy)
        let report = String(decoding: try XCTUnwrap(ExportRel.readContainedData(
            relative: SessionTransferReviewReport.path, sessionURL: root)), as: UTF8.self)
        XCTAssertTrue(report.contains("| Processing status | offline_failed | completed |"))
        XCTAssertTrue(report.contains("Not measured in this run"))
        XCTAssertFalse(report.contains(transcript.segments[0].text))
        let context = String(decoding: try XCTUnwrap(ExportRel.readContainedData(
            relative: ScrumTracePath.agentContext, sessionURL: root)), as: UTF8.self)
        XCTAssertTrue(context.contains("analysis copy"))
        let packed = try XCTUnwrap(ExportRel.regularFileByteCount(relative: ScrumTracePath.packZip, sessionURL: root))
        XCTAssertGreaterThan(packed, 0)
        XCTAssertLessThanOrEqual(packed, MediaBudget.maxZipBytes)
        XCTAssertLessThanOrEqual(PackBudget.exportFolderBytes(sessionURL: root), MediaBudget.maxZipBytes)
    }

    func testOldRecordingIsNotPrunedImmediatelyAfterImport() throws {
        try fixture { base, source, id in
            var original = try source.loadManifest(id: id)
            original.createdAt = Date().addingTimeInterval(-365 * 86400)
            original.pipelineStatus = .completed
            try source.write(manifest: &original)
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            let imported = try SessionTransfer(vault: receiver).importRecording(from: source.sessionURL(id: id))
            receiver.pruneCompletedOlderThan(days: 1)
            XCTAssertEqual(receiver.listedSessionIds(), [imported])
            XCTAssertEqual(try receiver.loadManifest(id: imported).createdAt.timeIntervalSince1970,
                           original.createdAt.timeIntervalSince1970, accuracy: 1)
        }
    }

    func testTransferStagingDirectoriesNeverAppearInTheLibrary() throws {
        try fixture { _, source, _ in
            let stage = source.rootURL.appendingPathComponent("ScrumTrace-transfer-ABC123")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            XCTAssertFalse(source.listedSessionIds().contains(stage.lastPathComponent))
            XCTAssertFalse(source.sessionEntries().contains { $0.id == stage.lastPathComponent })
        }
    }

    @MainActor
    func testImportedOriginalCannotBeRetriedInPlaceAndTransferHoldsCapture() throws {
        try fixture { _, source, id in
            var manifest = try source.loadManifest(id: id)
            manifest.importOrigin = .init(kind: .imported, originalSessionID: id, importedAt: Date(),
                                          exportedFrom: sender, transferID: UUID().uuidString,
                                          scope: .complete, integrityVerified: true, parentSessionID: nil)
            try source.write(manifest: &manifest)
            let suite = "ScrumTrace.TransferControllerTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: source)
            controller.retryAnalysis(sessionId: id)
            XCTAssertFalse(controller.isBusy)
            XCTAssertTrue(controller.statusLine.contains("Analyze a copy"))
            XCTAssertTrue(controller.beginSessionTransfer())
            XCTAssertFalse(controller.canChangeCaptureSettings)
            XCTAssertFalse(controller.beginSessionTransfer())
            controller.startRecording()
            XCTAssertFalse(controller.startInFlight)
            controller.endSessionTransfer()
            XCTAssertTrue(controller.canChangeCaptureSettings)
        }
    }

    func testBatchExportAndImportPreservesEverySelectedRecording() throws {
        try fixture { base, source, first in
            let transfer = SessionTransfer(vault: source)
            let second = try transfer.analysisCopy(id: first, retranscribe: false)
            let requests = [first, second].map {
                SessionTransferExportRequest(sessionID: $0, destination: base.appendingPathComponent("\($0).scrumtrace"))
            }
            let exported = try transfer.exportRecordings(requests, scope: .complete, includePrivate: true, environment: sender)
            XCTAssertEqual(exported.successCount, 2)
            XCTAssertEqual(exported.failureCount, 0)
            XCTAssertEqual(exported.exportedURLs, requests.map(\.destination))
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            let imported = SessionTransfer(vault: receiver).importRecordings(from: exported.exportedURLs)
            XCTAssertEqual(imported.successCount, 2)
            XCTAssertEqual(Set(receiver.listedSessionIds()), Set(imported.importedIDs))
            let manifests = try imported.importedIDs.map { try receiver.loadManifest(id: $0) }
            XCTAssertEqual(Set(manifests.compactMap { $0.importOrigin?.originalSessionID }), Set([first, second]))
            XCTAssertTrue(manifests.allSatisfy { !$0.uploadConsent.approved && $0.importOrigin?.integrityVerified == true })
        }
    }

    func testBatchImportReportsDuplicateAndInvalidInputThenImportsTheNextPackage() throws {
        try fixture { base, source, first in
            let transfer = SessionTransfer(vault: source)
            let second = try transfer.analysisCopy(id: first, retranscribe: false)
            let requests = [first, second].map {
                SessionTransferExportRequest(sessionID: $0, destination: base.appendingPathComponent("\($0).scrumtrace"))
            }
            let packages = try transfer.exportRecordings(requests, scope: .complete, includePrivate: true, environment: sender).exportedURLs
            let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
            let importer = SessionTransfer(vault: receiver)
            let existing = try importer.importRecording(from: packages[0])
            let invalid = base.appendingPathComponent("invalid.scrumtrace")
            try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
            let result = importer.importRecordings(from: [packages[0], invalid, packages[1]])
            XCTAssertEqual(result.items.count, 3)
            XCTAssertEqual(result.successCount, 1)
            XCTAssertEqual(result.skippedCount, 1)
            XCTAssertEqual(result.failureCount, 1)
            XCTAssertEqual(result.items[0].outcome, .alreadyImported(existing))
            XCTAssertEqual(result.existingImportIDs, [existing])
            XCTAssertEqual(receiver.listedSessionIds().count, 2)
        }
    }

    func testBatchExportKeepsExistingPackagesAndContinuesPastMissingSessions() throws {
        try fixture { base, source, id in
            let existing = base.appendingPathComponent("existing.scrumtrace")
            try Data("keep existing".utf8).write(to: existing)
            let output = base.appendingPathComponent("new.scrumtrace")
            let result = try SessionTransfer(vault: source).exportRecordings([
                .init(sessionID: id, destination: existing),
                .init(sessionID: "missing-recording", destination: base.appendingPathComponent("missing.scrumtrace")),
                .init(sessionID: id, destination: output)
            ], scope: .complete, includePrivate: true, environment: sender)
            XCTAssertEqual(result.successCount, 1)
            XCTAssertEqual(result.skippedCount, 1)
            XCTAssertEqual(result.failureCount, 1)
            XCTAssertEqual(result.items[0].outcome, .existingDestination)
            XCTAssertEqual(try Data(contentsOf: existing), Data("keep existing".utf8))
            XCTAssertEqual(result.exportedURLs, [output])
        }
    }

    func testBatchCompleteExportRequiresConsentBeforeWritingAnyPackage() throws {
        try fixture { base, source, id in
            let destinations = ["one.scrumtrace", "two.scrumtrace"].map { base.appendingPathComponent($0) }
            let requests = destinations.map { SessionTransferExportRequest(sessionID: id, destination: $0) }
            XCTAssertThrowsError(try SessionTransfer(vault: source).exportRecordings(
                requests, scope: .complete, includePrivate: false, environment: sender
            )) { XCTAssertEqual($0 as? SessionTransferError, .privateConsentRequired) }
            XCTAssertTrue(destinations.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    func testBatchCancellationKeepsCompletedImportsAndRemovesUnfinishedStaging() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ScrumTrace.BatchCancel.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = SessionVault(rootURL: base.appendingPathComponent("source/sessions"))
        var folders: [URL] = []
        for _ in 0..<3 {
            let created = try source.createSession(product: .empty)
            try ExportRel.writeContainedData(Data(repeating: 1, count: 128), relative: ScrumTracePath.audioWav, sessionURL: created.url)
            folders.append(created.url)
        }
        let receiver = SessionVault(rootURL: base.appendingPathComponent("receiver/sessions"))
        let inputs = folders
        let task = Task.detached {
            SessionTransfer(vault: receiver).importRecordings(from: inputs) { state in
                if state.recording == 2, state.files == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let result = await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.successCount, 1)
        XCTAssertEqual(result.items[1].outcome, .cancelled)
        XCTAssertEqual(result.items[2].outcome, .notStarted)
        XCTAssertEqual(receiver.listedSessionIds(), result.importedIDs)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: receiver.rootURL.path), result.importedIDs)
    }

    @MainActor
    func testBatchPanelAndPrivateChoiceApplyToTheFrozenSelection() throws {
        try fixture { _, source, id in
            let panel = SessionTransferModel.importPanel()
            XCTAssertTrue(panel.allowsMultipleSelection)
            XCTAssertTrue(panel.canChooseDirectories)
            XCTAssertTrue(panel.canChooseFiles)
            XCTAssertFalse(panel.treatsFilePackagesAsDirectories)
            let suite = "ScrumTrace.BatchChoice.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: source)
            let model = SessionTransferModel(controller: controller) { _ in }
            model.presentExport(ids: [id, "another-recording", id])
            XCTAssertEqual(model.exportSessionIDs, [id, "another-recording"])
            model.scope = .complete
            model.includePrivate = true
            model.presentExport(ids: [id])
            XCTAssertEqual(model.scope, .evidence)
            XCTAssertFalse(model.includePrivate, "A new selection needs its own private-data choice")
        }
    }
}
