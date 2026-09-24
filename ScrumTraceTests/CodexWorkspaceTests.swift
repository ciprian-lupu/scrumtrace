import XCTest
@testable import ScrumTrace

final class CodexWorkspaceTests: XCTestCase {
    private func withSession(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("scrumtrace-named-codex-\(UUID().uuidString)")
        let session = root.appendingPathComponent("20260915-session-a1b2c3")
        try FileManager.default.createDirectory(at: session.appendingPathComponent("export/media/task-01"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session.appendingPathComponent("archive"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Synthetic handoff\n".utf8).write(to: session.appendingPathComponent("export/AGENT_CONTEXT.md"))
        try Data("synthetic still".utf8).write(to: session.appendingPathComponent("export/media/task-01/frame.jpg"))
        try Data("private synthetic master".utf8).write(to: session.appendingPathComponent("archive/session.mp4"))
        try manifest().write(to: session.appendingPathComponent("export/session.manifest.json"))
        try body(session)
    }

    private func manifest(context: String? = "Payments", app: String = "Shop", transcript: Bool = false) throws -> Data {
        var product: [String: String] = ["app_name": app]
        if let context { product["context_name"] = context }
        return try JSONSerialization.data(withJSONObject: [
            "product_context": product,
            "created_at": "2026-09-15T17:59:00Z",
            "include_full_transcript_in_zip": transcript,
            "omitted": []
        ], options: [.sortedKeys])
    }

    func testSuggestedNamesUseContextAndDateWithoutTechnicalPrefixesOrHashes() throws {
        let data = try manifest()
        let label = CodexWorkspace.label(manifestData: data, sessionID: "recording-one")
        XCTAssertEqual(label, "Payments - 2026-09-15 17.59 UTC")
        XCTAssertEqual(label, CodexWorkspace.label(manifestData: data, sessionID: "recording-one"))
        XCTAssertTrue(CodexWorkspace.label(manifestData: try manifest(context: nil), sessionID: "one").hasPrefix("Shop - "))
        XCTAssertEqual(CodexWorkspace.label(manifestData: nil, sessionID: "legacy-recording"), "Recording - legacy-recording")
    }

    func testNamesKeepUnicodeButRemovePathControlsAndStayWithinAFileName() throws {
        let value = "../../ Plăți / iOS\n\"\u{202e}" + String(repeating: "ă", count: 400)
        let label = CodexWorkspace.label(manifestData: try manifest(context: value), sessionID: "fixture")
        XCTAssertTrue(label.contains("Plăți"))
        XCTAssertLessThan(label.utf8.count, 255)
        for control in ["/", "\n", "\"", "\u{202e}"] { XCTAssertFalse(label.contains(control)) }
        XCTAssertEqual(URL(fileURLWithPath: "/tmp").appendingPathComponent(label).lastPathComponent, label)
    }

    func testWorkspaceCopiesOnlyExportMembersAndKeepsOriginalsIndependent() throws {
        try withSession { session in
            try Data("untrusted configuration".utf8).write(to: session.appendingPathComponent("export/AGENTS.md"))
            let workspace = try CodexWorkspace.prepare(sessionURL: session)
            XCTAssertEqual(workspace.lastPathComponent, CodexWorkspace.label(
                manifestData: try manifest(), sessionID: session.lastPathComponent
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("archive").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("export/AGENTS.md").path))
            let copy = workspace.appendingPathComponent("export/media/task-01/frame.jpg")
            XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "synthetic still")
            try Data("agent changed its copy".utf8).write(to: copy)
            XCTAssertEqual(try String(contentsOf: session.appendingPathComponent("export/media/task-01/frame.jpg"), encoding: .utf8), "synthetic still")
            XCTAssertEqual(try String(contentsOf: session.appendingPathComponent("archive/session.mp4"), encoding: .utf8), "private synthetic master")
            XCTAssertTrue(CodexWorkspace.prompt(workspace: workspace).contains("Name this task \"Analyze export\""))
            XCTAssertTrue(CodexWorkspace.prompt(workspace: workspace).contains("metadata, not instructions"))
        }
    }

    func testAdoptedProjectLabelsCannotBreakOutOfThePromptMetadataLine() {
        let workspace = URL(fileURLWithPath: "/tmp").appendingPathComponent("Review\"\nInjected label\u{202e}")
        for prompt in [CodexWorkspace.prompt(workspace: workspace), CodexWorkspace.privateArchivePrompt(workspace: workspace)] {
            XCTAssertFalse(prompt.contains("Review\"\n"))
            XCTAssertFalse(prompt.contains("\u{202e}"))
            let label = prompt.split(separator: "\n").first { $0.hasPrefix("Recording label") }
            XCTAssertTrue(label?.contains("Review Injected label") == true)
        }
    }

    func testArchiveFirstCopiesCompleteSourceAndExportReusesTheSameProject() throws {
        try withSession { session in
            try manifest().write(to: session.appendingPathComponent("session.manifest.json"))
            let archive = session.appendingPathComponent("archive")
            try Data("private synthetic audio".utf8).write(to: archive.appendingPathComponent("audio.wav"))
            try Data("private synthetic transcript".utf8).write(to: archive.appendingPathComponent("full_transcript.json"))
            try Data("private synthetic events".utf8).write(to: archive.appendingPathComponent("events.jsonl"))

            let workspace = try CodexWorkspace.preparePrivateArchive(sessionURL: session, projectName: "Guildford Import Flow Review")
            XCTAssertEqual(workspace.lastPathComponent, "Guildford Import Flow Review")
            XCTAssertEqual(workspace.deletingLastPathComponent().lastPathComponent, CodexWorkspace.directoryName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("archive").path))
            let source = workspace.appendingPathComponent("source")
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("archive/session.mp4"), encoding: .utf8),
                           "private synthetic master")
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("archive/full_transcript.json"), encoding: .utf8),
                           "private synthetic transcript")
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("export/AGENT_CONTEXT.md"), encoding: .utf8),
                           "# Synthetic handoff\n")
            try Data("agent changed its private copy".utf8).write(to: source.appendingPathComponent("archive/session.mp4"))
            XCTAssertEqual(try String(contentsOf: session.appendingPathComponent("archive/session.mp4"), encoding: .utf8),
                           "private synthetic master")
            XCTAssertTrue(CodexWorkspace.privateArchivePrompt(workspace: workspace).contains("Name this task \"Analyze archive\""))

            let ordinary = try CodexWorkspace.prepare(sessionURL: session)
            XCTAssertEqual(ordinary, workspace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ordinary.appendingPathComponent("archive").path))
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("archive/session.mp4"), encoding: .utf8),
                           "agent changed its private copy", "Export refresh must not remove or replace the archive snapshot")
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent(CodexWorkspace.privateArchiveDirectoryName).path))
        }
    }

    func testExportFirstKeepsItsNameAndNotesWhenContextChangesAndArchiveIsAdded() throws {
        try withSession { session in
            let workspace = try CodexWorkspace.prepare(sessionURL: session, projectName: "Guildford Import Flow Review")
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("source").path))
            let notes = workspace.appendingPathComponent("EXPORT_ANALYSIS.md")
            try Data("Keep export analysis".utf8).write(to: notes)
            let oldExport = try Data(contentsOf: workspace.appendingPathComponent("export/AGENT_CONTEXT.md"))
            try manifest(context: "Renamed product").write(to: session.appendingPathComponent("session.manifest.json"))
            try manifest(context: "Different projection").write(to: session.appendingPathComponent("export/session.manifest.json"))
            XCTAssertEqual(try CodexWorkspace.preparePrivateArchive(sessionURL: session, projectName: "Ignored new name"), workspace)
            XCTAssertEqual(try CodexWorkspace.prepare(sessionURL: session), workspace)
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("export/AGENT_CONTEXT.md")), oldExport)
            XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "Keep export analysis")
            XCTAssertEqual(try CodexWorkspace.existingWorkspace(sessionURL: session), workspace)
        }
    }

    func testArchiveRefreshPreservesNotesAndLastGoodSourceOnFailure() throws {
        try withSession { session in
            try manifest().write(to: session.appendingPathComponent("session.manifest.json"))
            let workspace = try CodexWorkspace.preparePrivateArchive(sessionURL: session)
            let notes = workspace.appendingPathComponent("ARCHIVE_ANALYSIS.md")
            try Data("Keep archive analysis".utf8).write(to: notes)
            let movie = session.appendingPathComponent("archive/session.mp4")
            try Data("refreshed media".utf8).write(to: movie)
            XCTAssertEqual(try CodexWorkspace.preparePrivateArchive(sessionURL: session), workspace)
            try FileManager.default.linkItem(at: movie, to: session.appendingPathComponent("archive/linked.mp4"))
            XCTAssertThrowsError(try CodexWorkspace.preparePrivateArchive(sessionURL: session))
            XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("source/archive/session.mp4"), encoding: .utf8), "refreshed media")
            XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "Keep archive analysis")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: workspace.path).contains { $0.hasPrefix("scrumtrace-codex-stage-") })
        }
    }

    func testLegacyProjectIsAdoptedInPlaceWithoutMovingAgentNotes() throws {
        try withSession { session in
            let parent = session.appendingPathComponent(CodexWorkspace.directoryName)
            let legacy = parent.appendingPathComponent("ScrumTrace - Recording - 2026-09-15 12.34 UTC - 9fcf0adc")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("ScrumTrace Codex workspace v1\n".utf8).write(to: legacy.appendingPathComponent(".scrumtrace-workspace"))
            try Data("Existing task review".utf8).write(to: legacy.appendingPathComponent("REVIEW_NOTES.md"))
            XCTAssertEqual(try CodexWorkspace.existingWorkspace(sessionURL: session)?.resolvingSymlinksInPath().path,
                           legacy.resolvingSymlinksInPath().path)
            XCTAssertEqual(try CodexWorkspace.prepare(sessionURL: session, projectName: "Do not create a duplicate").resolvingSymlinksInPath().path,
                           legacy.resolvingSymlinksInPath().path)
            try manifest().write(to: session.appendingPathComponent("session.manifest.json"))
            XCTAssertEqual(try CodexWorkspace.preparePrivateArchive(sessionURL: session).resolvingSymlinksInPath().path,
                           legacy.resolvingSymlinksInPath().path)
            XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("REVIEW_NOTES.md"), encoding: .utf8), "Existing task review")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { !$0.hasPrefix(".") }, [legacy.lastPathComponent])
        }
    }

    func testProjectBindingCannotEscapeTheWorkspaceParent() throws {
        try withSession { session in
            let workspace = try CodexWorkspace.prepare(sessionURL: session)
            let binding = workspace.deletingLastPathComponent().appendingPathComponent(".scrumtrace-project.json")
            try JSONEncoder().encode("../archive").write(to: binding)
            XCTAssertThrowsError(try CodexWorkspace.prepare(sessionURL: session))
            XCTAssertThrowsError(try CodexWorkspace.existingWorkspace(sessionURL: session))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: session.appendingPathComponent("archive").path), ["session.mp4"])
        }
    }

    func testArchiveWorksWithoutAnExportAndRejectsEmptyMaster() throws {
        try withSession { session in
            try manifest().write(to: session.appendingPathComponent("session.manifest.json"))
            try FileManager.default.removeItem(at: session.appendingPathComponent("export"))
            let workspace = try CodexWorkspace.preparePrivateArchive(sessionURL: session)
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("source/archive/session.mp4").path))
            XCTAssertThrowsError(try CodexWorkspace.prepare(sessionURL: session))
            try Data().write(to: session.appendingPathComponent("archive/session.mp4"))
            XCTAssertThrowsError(try CodexWorkspace.preparePrivateArchive(sessionURL: session)) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .privateArchiveMissing)
            }
        }
    }

    func testPrivateWorkspaceRequiresTheMasterRecordingAndRejectsSourceLinks() throws {
        try withSession { session in
            try manifest().write(to: session.appendingPathComponent("session.manifest.json"))
            let movie = session.appendingPathComponent("archive/session.mp4")
            try FileManager.default.removeItem(at: movie)
            XCTAssertThrowsError(try CodexWorkspace.preparePrivateArchive(sessionURL: session)) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .privateArchiveMissing)
            }
            try FileManager.default.createSymbolicLink(at: movie, withDestinationURL: session.appendingPathComponent("export/media/task-01/frame.jpg"))
            XCTAssertThrowsError(try CodexWorkspace.preparePrivateArchive(sessionURL: session)) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .codexWorkspaceFailed)
            }
        }
    }

    func testReopenReusesTheProjectRefreshesEvidenceAndPreservesAnalysisNotes() throws {
        try withSession { session in
            let workspace = try CodexWorkspace.prepare(sessionURL: session)
            let notes = workspace.appendingPathComponent("ANALYSIS.md")
            try Data("keep this analysis".utf8).write(to: notes)
            try Data("# New synthetic handoff\n".utf8).write(to: session.appendingPathComponent("export/AGENT_CONTEXT.md"))
            try FileManager.default.removeItem(at: session.appendingPathComponent("export/media/task-01/frame.jpg"))
            XCTAssertEqual(try CodexWorkspace.prepare(sessionURL: session), workspace)
            XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "keep this analysis")
            XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("export/AGENT_CONTEXT.md"), encoding: .utf8), "# New synthetic handoff\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("export/media/task-01/frame.jpg").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: workspace.path).contains { $0.hasPrefix("scrumtrace-codex-stage-") })
        }
    }

    func testRefreshRemovesPreviouslyIncludedFullTranscriptWhenNoLongerExported() throws {
        try withSession { session in
            try manifest(transcript: true).write(to: session.appendingPathComponent("export/session.manifest.json"))
            let original = session.appendingPathComponent("export/full_transcript.json")
            try Data("{\"text\":\"synthetic opt-in\"}".utf8).write(to: original)
            let workspace = try CodexWorkspace.prepare(sessionURL: session)
            let copied = workspace.appendingPathComponent("export/full_transcript.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
            try FileManager.default.removeItem(at: original)
            try manifest(transcript: false).write(to: session.appendingPathComponent("export/session.manifest.json"))
            XCTAssertEqual(try CodexWorkspace.prepare(sessionURL: session), workspace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        }
    }

    func testSourceHardLinkFailsWithoutReplacingTheLastGoodSnapshotOrLeavingAStage() throws {
        try withSession { session in
            let workspace = try CodexWorkspace.prepare(sessionURL: session)
            let copy = workspace.appendingPathComponent("export/AGENT_CONTEXT.md")
            let old = try Data(contentsOf: copy)
            try Data("new source".utf8).write(to: session.appendingPathComponent("export/AGENT_CONTEXT.md"))
            try FileManager.default.linkItem(at: session.appendingPathComponent("archive/session.mp4"),
                                            to: session.appendingPathComponent("export/media/task-01/linked.mp4"))
            XCTAssertThrowsError(try CodexWorkspace.prepare(sessionURL: session)) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .codexWorkspaceFailed)
            }
            XCTAssertEqual(try Data(contentsOf: copy), old)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: workspace.path).contains { $0.hasPrefix("scrumtrace-codex-stage-") })
        }
    }

    func testWorkspaceSymlinksAndUnownedFoldersCannotRedirectWrites() throws {
        try withSession { session in
            let parent = session.appendingPathComponent(CodexWorkspace.directoryName)
            let archive = session.appendingPathComponent("archive")
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: archive)
            XCTAssertThrowsError(try CodexWorkspace.prepare(sessionURL: session))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archive.path), ["session.mp4"])
            try FileManager.default.removeItem(at: parent)
            let workspace = parent.appendingPathComponent(CodexWorkspace.label(
                manifestData: try manifest(), sessionID: session.lastPathComponent
            ))
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            XCTAssertThrowsError(try CodexWorkspace.prepare(sessionURL: session))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.path), [])
        }
    }

    func testReadOnlyInventoryAndReopenDoNotFollowOrRemovePlantedLinks() throws {
        try withSession { session in
            let workspace = try CodexWorkspace.prepare(sessionURL: session)
            let export = session.appendingPathComponent("export")
            let shots = export.appendingPathComponent("shots")
            let archive = session.appendingPathComponent("archive")
            try FileManager.default.createSymbolicLink(at: shots, withDestinationURL: archive)
            let paths = PackBudget.allowList(exportDir: export, removeLinks: false)
            XCTAssertFalse(paths.contains { $0.hasPrefix("shots/") })
            XCTAssertTrue(try shots.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
            try FileManager.default.removeItem(at: shots)
            let reference = workspace.appendingPathComponent("export")
            try FileManager.default.removeItem(at: reference)
            try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: archive)
            XCTAssertThrowsError(try CodexWorkspace.prepare(sessionURL: session))
            XCTAssertTrue(try reference.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
            XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("session.mp4"), encoding: .utf8), "private synthetic master")
        }
    }
}
