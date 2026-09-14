import Combine
import Foundation
import XCTest
@testable import ScrumTrace

final class SessionLibraryTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let vault: SessionVault
        /// Newest: transcribing, no export. Its folder name sorts between the other two.
        let unfinished: String
        /// Completed, with export files and captured text in its manifest and transcript. Highest folder name.
        let completed: String
        /// Oldest readable: offline failed, with a planted pack link into archive/. Lowest folder name.
        let offline: String
        /// A session folder whose manifest is not JSON.
        let corrupt: String
        /// A link in sessions/ to a folder outside the vault that holds a valid manifest.
        let symlink: String
        let outside: URL
        let lockURL: URL
    }

    /// Words that exist only in captured text: a Shot note, a task title and full_transcript.json.
    private static let shotNoteWord = "zebracornnote"
    private static let taskTitleWord = "quokkaplantitle"
    private static let transcriptWord = "narwhaltranscript"
    private static let repositoryWord = "orbitrepository"
    private static let corruptMarker = "corruptmanifestmarker"
    private static var transcriptJSON: String { #"{"segments":[{"text":"\#(transcriptWord)"}]}"# }

    // MARK: Fixture

    @MainActor
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrumTrace.SessionLibraryTests.\(UUID().uuidString)", isDirectory: true)
        AgentLog.setFileURLForTesting(base.appendingPathComponent("agent.jsonl"))
        defer {
            AgentLog.setFileURLForTesting(nil)
            try? FileManager.default.removeItem(at: base)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try await body(makeFixture(base: base))
    }

    private func makeFixture(base: URL) throws -> Fixture {
        let vault = SessionVault(rootURL: base.appendingPathComponent("sessions", isDirectory: true))
        let now = Date()

        // createSession names folders by the minute plus a random suffix. Roles follow folder-name
        // order so that createdAt order (unfinished, completed, offline) matches neither ascending
        // nor descending names: only a createdAt sort puts the rows in the expected order.
        let created = try (0..<3)
            .map { _ in try vault.createSession(product: .empty).manifest }
            .sorted { $0.sessionId < $1.sessionId }
        var offline = created[0]
        var unfinished = created[1]
        var completed = created[2]

        completed.productContext = ProductContext(
            appName: "Orbit Checkout",
            repoURL: "https://example.test/\(Self.repositoryWord)",
            techStack: "Swift",
            contextID: "ctx-orbit",
            contextName: "Orbit web"
        )
        completed.createdAt = now.addingTimeInterval(-2 * 86_400)
        completed.pipelineStatus = .completed
        completed.completedStages = [.transcribing, .slicing, .evaluating, .synthesizing, .completed]
        completed.duration = DurationPair(wallSeconds: 700, mediaSeconds: 600)
        completed.pauses = [
            PauseInterval(pauseWall: 10, resumeWall: 20),
            PauseInterval(pauseWall: 30, resumeWall: 45)
        ]
        completed.shots = [ShotRecord(
            id: "001",
            tMedia: 12,
            rawPath: "archive/shots/001.png",
            annotatedPath: nil,
            note: "Checkout \(Self.shotNoteWord) broke",
            source: .typed
        )]
        completed.slices = [slice("slice-01", .success)]
        completed.tasks = [
            task("TASK-01", .confirmed, title: "Fix the \(Self.taskTitleWord) flow"),
            task("TASK-02", .needsReview, title: "Check the coupon field"),
            task("TASK-03", .dropped, title: "Ignore the banner")
        ]
        completed.uploadConsent = UploadConsent(
            approved: true,
            approvedAt: now,
            provider: "anthropic",
            endpoint: "https://api.example.test",
            model: "model",
            includesClipAudio: false,
            includesClipVideo: false,
            includesStills: true
        )
        completed.omitted = [OmittedAsset(path: "archive/media-work/clip.mp4", reason: "over budget")]
        try vault.write(manifest: &completed)
        let completedURL = vault.sessionURL(id: completed.sessionId)
        try write("# Agent context", to: ScrumTracePath.agentContext, in: completedURL)
        try write("<html></html>", to: ScrumTracePath.sessionBrief, in: completedURL)
        try write(Data(repeating: 7, count: 1_234), to: ScrumTracePath.packZip, in: completedURL)
        try write(Self.transcriptJSON, to: ScrumTracePath.fullTranscript, in: completedURL)
        try write(Self.transcriptJSON, to: "export/full_transcript.json", in: completedURL)

        unfinished.productContext = ProductContext(
            appName: "Orbit Admin",
            repoURL: "",
            techStack: "",
            contextID: "ctx-orbit",
            contextName: "Orbit web"
        )
        unfinished.createdAt = now.addingTimeInterval(-3_600)
        unfinished.pipelineStatus = .transcribing
        unfinished.duration = DurationPair(wallSeconds: 90, mediaSeconds: 80)
        try vault.write(manifest: &unfinished)

        offline.productContext = ProductContext(
            appName: "  ",
            repoURL: "",
            techStack: "",
            contextID: "ctx-atlas",
            contextName: "Atlas mobile"
        )
        offline.createdAt = now.addingTimeInterval(-5 * 86_400)
        offline.pipelineStatus = .offlineFailed
        offline.completedStages = [.transcribing, .slicing, .evaluating]
        offline.slices = [slice("slice-01", .offlineFailed), slice("slice-02", .success)]
        try vault.write(manifest: &offline)
        let offlineURL = vault.sessionURL(id: offline.sessionId)
        try write(Data(repeating: 1, count: 4_096), to: ScrumTracePath.sessionMovie, in: offlineURL)
        try FileManager.default.createSymbolicLink(
            at: offlineURL.appendingPathComponent(ScrumTracePath.packZip),
            withDestinationURL: offlineURL.appendingPathComponent(ScrumTracePath.sessionMovie)
        )

        let corrupt = "2020-01-01-0000-bad001"
        try write(
            "{ \"session_id\": \"\(Self.corruptMarker)\", ",
            to: ScrumTracePath.manifest,
            in: vault.rootURL.appendingPathComponent(corrupt, isDirectory: true)
        )

        let symlink = "2020-02-02-0000-link01"
        let outside = base.appendingPathComponent("outside/\(symlink)", isDirectory: true)
        var planted = completed
        planted.sessionId = symlink
        planted.createdAt = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try write(try encoder.encode(planted), to: ScrumTracePath.manifest, in: outside)
        try FileManager.default.createSymbolicLink(
            at: vault.rootURL.appendingPathComponent(symlink),
            withDestinationURL: outside
        )

        return Fixture(
            base: base,
            vault: vault,
            unfinished: unfinished.sessionId,
            completed: completed.sessionId,
            offline: offline.sessionId,
            corrupt: corrupt,
            symlink: symlink,
            outside: outside,
            lockURL: base.appendingPathComponent("recording.lock")
        )
    }

    private func slice(_ id: String, _ status: SliceAnalysisStatus) -> SliceRecord {
        SliceRecord(
            sliceId: id,
            startMedia: 0,
            endMedia: 30,
            trigger: .shot,
            associatedShotId: nil,
            clipPath: nil,
            stills: [],
            analysisStatus: status,
            score: 1
        )
    }

    private func task(_ id: String, _ status: TaskStatus, title: String) -> TaskRecord {
        TaskRecord(
            taskId: id,
            sourceSliceId: "slice-01",
            kind: .bug,
            status: status,
            title: title,
            observed: "Observed on screen",
            stated: "Stated aloud",
            inferred: "",
            agentInstructions: "",
            quotes: [],
            evidenceMedia: [],
            confidence: 0.8
        )
    }

    private func write(_ text: String, to relative: String, in session: URL) throws {
        try write(Data(text.utf8), to: relative, in: session)
    }

    private func write(_ data: Data, to relative: String, in session: URL) throws {
        let url = session.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Folder name stamp as `SessionVault.makeSessionID` writes it, in local time.
    private func folderStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    /// Clears the immutable flag on everything under `root`, so the fixture can be removed.
    private func unlockFiles(under root: URL) {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: Index

    @MainActor
    func testEntriesListReadableAndUnreadableSessionsNewestFirstAndSkipSymlinks() async throws {
        try await withFixture { f in
            let loaded = [f.unfinished, f.completed, f.offline]
            XCTAssertNotEqual(loaded.sorted(), loaded, "Folder names ascending must not match createdAt order")
            XCTAssertNotEqual(loaded.sorted(by: >), loaded, "Folder names descending must not match createdAt order")

            let entries = f.vault.sessionEntries()
            XCTAssertEqual(entries.map(\.id), [f.unfinished, f.completed, f.offline, f.corrupt])
            XCTAssertEqual(entries.compactMap(\.summary).count, 3)
            XCTAssertFalse(entries.contains { $0.id == f.symlink }, "A symlinked session folder is never listed")
            XCTAssertEqual(entries.last, .unreadable(id: f.corrupt, reason: SessionEntry.decodingFailed))
            if case .unreadable(_, let reason) = entries.last {
                XCTAssertFalse(reason.contains(Self.corruptMarker), "The reason never carries file contents")
            }

            let unfinished = try XCTUnwrap(entries[0].summary)
            XCTAssertEqual(unfinished.pipelineStatus, .transcribing)
            XCTAssertTrue(unfinished.isUnfinished)
            XCTAssertEqual(unfinished.mediaSeconds, 80)
            XCTAssertEqual(unfinished.wallSeconds, 90)
            XCTAssertEqual(unfinished.productName, "Orbit Admin")
            XCTAssertFalse(unfinished.hasExportContext)
            XCTAssertFalse(unfinished.hasBrief)
            XCTAssertFalse(unfinished.hasPack)
            XCTAssertNil(unfinished.packBytes)
            XCTAssertFalse(unfinished.hasFullTranscriptArchive)

            let completed = try XCTUnwrap(entries[1].summary)
            XCTAssertEqual(completed.pipelineStatus, .completed)
            XCTAssertEqual(completed.completedStages, [.transcribing, .slicing, .evaluating, .synthesizing, .completed])
            XCTAssertFalse(completed.isUnfinished)
            XCTAssertEqual(completed.mediaSeconds, 600)
            XCTAssertEqual(completed.wallSeconds, 700)
            XCTAssertEqual(completed.pauseCount, 2)
            XCTAssertEqual(completed.contextName, "Orbit web")
            XCTAssertEqual(completed.productName, "Orbit Checkout")
            XCTAssertEqual(completed.contextID, "ctx-orbit")
            XCTAssertEqual(completed.shotCount, 1)
            XCTAssertEqual(completed.sliceCount, 1)
            XCTAssertEqual(completed.offlineFailedSliceCount, 0)
            XCTAssertEqual(completed.taskCounts, SessionTaskCounts(confirmed: 1, needsReview: 1, dropped: 1))
            XCTAssertTrue(completed.consentApproved)
            XCTAssertEqual(completed.omittedCount, 1)
            XCTAssertTrue(completed.hasExportContext)
            XCTAssertTrue(completed.hasBrief)
            XCTAssertTrue(completed.hasPack)
            XCTAssertEqual(completed.packBytes, 1_234)
            XCTAssertTrue(completed.hasFullTranscriptArchive)

            let offline = try XCTUnwrap(entries[2].summary)
            XCTAssertEqual(offline.pipelineStatus, .offlineFailed)
            XCTAssertTrue(offline.isUnfinished)
            XCTAssertEqual(offline.productName, "Atlas mobile", "A blank product name falls back to the context name")
            XCTAssertEqual(offline.contextID, "ctx-atlas")
            XCTAssertEqual(offline.sliceCount, 2)
            XCTAssertEqual(offline.offlineFailedSliceCount, 1)
            XCTAssertFalse(offline.hasPack, "A pack that links into archive/ is not a pack")
            XCTAssertNil(offline.packBytes)
        }
    }

    @MainActor
    func testUnreadableRowsSortByFolderDateAndACopiedFolderNeverPosesAsItsSource() async throws {
        try await withFixture { f in
            // A copy of the completed folder under a name stamped between the completed and offline rows.
            let copy = "\(folderStamp(Date().addingTimeInterval(-3.5 * 86_400)))-copy01"
            try FileManager.default.copyItem(
                at: f.vault.sessionURL(id: f.completed),
                to: f.vault.sessionURL(id: copy)
            )
            let undated = "imported-session"
            try FileManager.default.createDirectory(
                at: f.vault.sessionURL(id: undated),
                withIntermediateDirectories: false
            )

            let entries = f.vault.sessionEntries()
            XCTAssertEqual(entries.map(\.id), [f.unfinished, f.completed, copy, f.offline, f.corrupt, undated])
            XCTAssertEqual(entries[2], .unreadable(id: copy, reason: SessionEntry.sessionIdMismatch))
            XCTAssertEqual(entries[5], .unreadable(id: undated, reason: SessionEntry.notReadable))
            XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "Row ids stay unique")
            XCTAssertEqual(entries.compactMap(\.summary).map(\.sessionId), [f.unfinished, f.completed, f.offline])
        }
    }

    @MainActor
    func testFiltersAndSearchMatchOnlyIdsDatesContextsAndProducts() async throws {
        try await withFixture { f in
            let entries = f.vault.sessionEntries()
            func ids(search: String = "", status: SessionStatusFilter? = nil, context: String? = nil) -> [String] {
                entries.filtered(search: search, status: status, contextID: context).map(\.id)
            }

            XCTAssertEqual(ids(), [f.unfinished, f.completed, f.offline, f.corrupt])
            XCTAssertEqual(ids(search: "   "), [f.unfinished, f.completed, f.offline, f.corrupt])
            XCTAssertEqual(ids(status: .completed), [f.completed])
            XCTAssertEqual(ids(status: .needsReview), [f.completed, f.offline])
            XCTAssertEqual(ids(status: .unfinished), [f.unfinished, f.offline])
            XCTAssertEqual(ids(status: .offlineFailed), [f.offline])
            XCTAssertEqual(ids(context: "ctx-orbit"), [f.unfinished, f.completed])
            XCTAssertEqual(ids(status: .offlineFailed, context: "ctx-atlas"), [f.offline])
            XCTAssertEqual(ids(status: .offlineFailed, context: "ctx-orbit"), [])

            XCTAssertEqual(ids(search: f.offline), [f.offline])
            XCTAssertEqual(ids(search: f.offline.uppercased()), [f.offline])
            XCTAssertEqual(ids(search: "orbit web"), [f.unfinished, f.completed])
            XCTAssertEqual(ids(search: "checkout"), [f.completed])
            XCTAssertEqual(ids(search: "ATLAS"), [f.offline])
            XCTAssertEqual(ids(search: "bad001"), [f.corrupt])
            let completedDate = SessionSummary.formattedDate(try XCTUnwrap(entries[1].summary).createdAt)
            XCTAssertTrue(ids(search: completedDate).contains(f.completed))

            for word in [Self.shotNoteWord, Self.taskTitleWord, Self.transcriptWord, Self.repositoryWord, Self.corruptMarker] {
                XCTAssertEqual(ids(search: word), [], "\(word) exists only in captured or private text")
            }
        }
    }

    func testSummaryStoresOnlyAllowListedMetadataFields() {
        let manifest = SessionManifest.makeNew(
            sessionId: "2026-09-13-1200-abc123",
            product: ProductContext(appName: "Orbit", repoURL: "", techStack: "")
        )
        let summary = SessionSummary(manifest: manifest, exportProbe: SessionExportProbe())
        let fields = Mirror(reflecting: summary).children.map { child in
            (child.label ?? "?", String(describing: type(of: child.value)))
        }
        let expected: [(String, String)] = [
            ("sessionId", "String"),
            ("createdAt", "Date"),
            ("pipelineStatus", "PipelineStatus"),
            ("completedStages", "Array<PipelineStatus>"),
            ("mediaSeconds", "Double"),
            ("wallSeconds", "Double"),
            ("pauseCount", "Int"),
            ("contextName", "Optional<String>"),
            ("productName", "String"),
            ("contextID", "Optional<String>"),
            ("shotCount", "Int"),
            ("sliceCount", "Int"),
            ("offlineFailedSliceCount", "Int"),
            ("taskCounts", "SessionTaskCounts"),
            ("consentApproved", "Bool"),
            ("omittedCount", "Int"),
            ("hasExportContext", "Bool"),
            ("hasBrief", "Bool"),
            ("hasPack", "Bool"),
            ("packBytes", "Optional<Int>"),
            ("hasFullTranscriptArchive", "Bool"),
            ("isUnfinished", "Bool")
        ]
        XCTAssertEqual(
            fields.map(\.0), expected.map(\.0),
            "A new SessionSummary field needs a privacy review (C2): the index holds manifest metadata only"
        )
        XCTAssertEqual(fields.map(\.1), expected.map(\.1))
        let textFields = fields.filter { $0.1.contains("String") }.map(\.0)
        XCTAssertEqual(textFields, ["sessionId", "contextName", "productName", "contextID"])
        let counts = Mirror(reflecting: summary.taskCounts).children
        XCTAssertEqual(counts.compactMap(\.label), ["confirmed", "needsReview", "dropped"])
        XCTAssertTrue(counts.allSatisfy { $0.value is Int })
    }

    // MARK: Deletion

    @MainActor
    func testDeleteSessionRefusesInvalidIdsSymlinksAndLiveLocksAndRemovesARealFolder() async throws {
        try await withFixture { f in
            let library = SessionLibrary(vault: f.vault)
            await library.refresh().value
            XCTAssertEqual(library.entries.map(\.id), [f.unfinished, f.completed, f.offline, f.corrupt])

            // `sessionURL(id:)` maps any invalid id to this valid folder name, so the id guard must refuse
            // before a path is built.
            let fallback = f.vault.rootURL.appendingPathComponent("invalid-session-id", isDirectory: true)
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
            for id in ["", "../outside", ".hidden", "a/b", "x..y", "sessions/../\(f.offline)"] {
                XCTAssertThrowsError(try f.vault.deleteSession(id: id, recordingLockURL: f.lockURL), "invalid id \(id)") { error in
                    guard case SessionVaultError.writeFailed(let what) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(what, "invalid session id")
                }
            }
            XCTAssertTrue(isDirectory(fallback), "An invalid id never reaches the fallback folder")
            try FileManager.default.removeItem(at: fallback)

            let link = f.vault.rootURL.appendingPathComponent(f.symlink)
            XCTAssertThrowsError(try f.vault.deleteSession(id: f.symlink, recordingLockURL: f.lockURL))
            XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.outside.appendingPathComponent(ScrumTracePath.manifest).path))

            XCTAssertThrowsError(try f.vault.deleteSession(id: "2020-03-03-0000-gone01", recordingLockURL: f.lockURL)) { error in
                guard case SessionVaultError.sessionMissing = error else { return XCTFail("\(error)") }
            }

            let pid = ProcessInfo.processInfo.processIdentifier

            // On a case-insensitive volume another spelling of the live id opens the same folder.
            let corruptURL = f.vault.sessionURL(id: f.corrupt)
            let respelled = f.corrupt.uppercased()
            try "\(f.corrupt)\n\(pid)\n".write(to: f.lockURL, atomically: true, encoding: .utf8)
            if isDirectory(f.vault.sessionURL(id: respelled)) {
                XCTAssertThrowsError(try f.vault.deleteSession(id: respelled, recordingLockURL: f.lockURL)) { error in
                    guard case SessionVaultError.writeFailed(let what) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(what, "session is live")
                }
            }
            XCTAssertTrue(isDirectory(corruptURL))

            let offlineURL = f.vault.sessionURL(id: f.offline)
            try "\(f.offline)\n\(pid)\n".write(to: f.lockURL, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try f.vault.deleteSession(id: f.offline, recordingLockURL: f.lockURL)) { error in
                guard case SessionVaultError.writeFailed(let what) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(what, "session is live")
            }
            XCTAssertTrue(isDirectory(offlineURL))

            // A lock left by a process that is gone is stale.
            try "\(f.offline)\n2000000000\n".write(to: f.lockURL, atomically: true, encoding: .utf8)
            try f.vault.deleteSession(id: f.offline, recordingLockURL: f.lockURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: offlineURL.path))
            XCTAssertTrue(isDirectory(f.vault.sessionURL(id: f.completed)))
            XCTAssertTrue(isDirectory(f.vault.sessionURL(id: f.unfinished)))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.vault.rootURL.path)
                .filter { $0.hasPrefix(".scrumtrace-abandoned") }
            XCTAssertEqual(leftovers, [])

            await library.refresh().value
            XCTAssertEqual(library.entries.map(\.id), [f.unfinished, f.completed, f.corrupt])
        }
    }

    @MainActor
    func testDeleteThatCannotRemoveEveryFileThrowsAndKeepsTheFolderListed() async throws {
        try await withFixture { f in
            let completedURL = f.vault.sessionURL(id: f.completed)
            let locked = completedURL.appendingPathComponent("archive/locked.bin")
            try write(Data(count: 10), to: "archive/locked.bin", in: completedURL)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
            defer { unlockFiles(under: f.vault.rootURL) }

            XCTAssertThrowsError(try f.vault.deleteSession(id: f.completed, recordingLockURL: f.lockURL)) { error in
                guard case SessionVaultError.writeFailed(let what) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(what, "session folder")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path), "What remains is back under the session id")
            let hidden = try FileManager.default.contentsOfDirectory(atPath: f.vault.rootURL.path)
                .filter { $0.hasPrefix(".") }
            XCTAssertEqual(hidden, [], "No recording data stays in a hidden folder")
            XCTAssertTrue(f.vault.sessionEntries().contains { $0.id == f.completed }, "The list still shows it")
        }
    }

    func testRecordingLockReaderNeedsASessionLineAndALivePid() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrumTrace.RecordingLock.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("recording.lock")
        let pid = ProcessInfo.processInfo.processIdentifier
        let session = "2026-09-13-1200-abc123"

        XCTAssertNil(AgentLog.liveRecordingLock(at: lock), "No lock file")
        try "\(session)\n\(pid)\n".write(to: lock, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentLog.liveRecordingLock(at: lock), AgentLog.RecordingLock(sessionId: session, pid: pid))
        XCTAssertNil(AgentLog.liveRecordingLock(at: lock, isAlive: { _ in false }), "A dead pid makes the lock stale")
        try "\(session)\n2000000000\n".write(to: lock, atomically: true, encoding: .utf8)
        XCTAssertNil(AgentLog.liveRecordingLock(at: lock))

        XCTAssertTrue(AgentLog.isProcessAlive(pid))
        XCTAssertTrue(AgentLog.isProcessAlive(1), "launchd belongs to root: EPERM still means alive")
        XCTAssertFalse(AgentLog.isProcessAlive(2_000_000_000))
        XCTAssertFalse(AgentLog.isProcessAlive(0))
        XCTAssertFalse(AgentLog.isProcessAlive(-1))

        for text in ["", "abc", "abc\n", "abc\nnot-a-pid\n", "abc\n0\n", "abc\n-4\n"] {
            XCTAssertNil(AgentLog.parseRecordingLock(text), text)
        }
        XCTAssertEqual(AgentLog.parseRecordingLock("\n42\n"), AgentLog.RecordingLock(sessionId: "", pid: 42))

        let real = directory.appendingPathComponent("real.lock")
        let linked = directory.appendingPathComponent("linked.lock")
        try "\(session)\n\(pid)\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        XCTAssertNotNil(AgentLog.liveRecordingLock(at: real))
        XCTAssertNil(AgentLog.liveRecordingLock(at: linked), "A symlinked lock is not followed")
    }

    @MainActor
    func testARecordingLockWhosePidRunsAnotherProgramIsStaleAndNeverBlocksDelete() async throws {
        try await withFixture { f in
            // ScrumTrace crashed while recording and the system gave its pid to another program.
            let other = Process()
            other.executableURL = URL(fileURLWithPath: "/bin/sleep")
            other.arguments = ["30"]
            try other.run()
            defer {
                other.terminate()
                other.waitUntilExit()
            }
            let pid = other.processIdentifier
            XCTAssertTrue(AgentLog.isProcessAlive(pid))
            XCTAssertFalse(AgentLog.isScrumTraceProcess(pid))
            XCTAssertFalse(AgentLog.isRecordingProcess(pid))
            XCTAssertTrue(AgentLog.isRecordingProcess(ProcessInfo.processInfo.processIdentifier), "The test host runs ScrumTrace")
            XCTAssertFalse(AgentLog.isRecordingProcess(1), "launchd is alive but is not ScrumTrace")
            XCTAssertFalse(AgentLog.isScrumTraceProcess(2_000_000_000))

            try "\(f.offline)\n\(pid)\n".write(to: f.lockURL, atomically: true, encoding: .utf8)
            XCTAssertNil(AgentLog.liveRecordingLock(at: f.lockURL), "A live pid that is not ScrumTrace leaves a stale lock")
            try "\(f.offline)\n1\n".write(to: f.lockURL, atomically: true, encoding: .utf8)
            XCTAssertNil(AgentLog.liveRecordingLock(at: f.lockURL))

            try "\(f.offline)\n\(pid)\n".write(to: f.lockURL, atomically: true, encoding: .utf8)
            try f.vault.deleteSession(id: f.offline, recordingLockURL: f.lockURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.vault.sessionURL(id: f.offline).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.lockURL.path), "The reader never deletes the lock")
        }
    }

    // MARK: Search cost

    @MainActor
    func testAnEmptySearchBuildsNoSearchFieldsAndASearchBuildsThemOncePerRow() async throws {
        try await withFixture { f in
            let entries = f.vault.sessionEntries()
            let builds = LoadCounter()
            let fields: (SessionSummary) -> [String] = { summary in
                builds.increment()
                return summary.searchableFields
            }
            XCTAssertEqual(entries.filtered(search: "", status: nil, contextID: nil, searchableFields: fields).count, 4)
            XCTAssertEqual(entries.filtered(search: " \n ", status: nil, contextID: nil, searchableFields: fields).count, 4)
            XCTAssertEqual(
                entries.filtered(search: "", status: .unfinished, contextID: nil, searchableFields: fields).map(\.id),
                [f.unfinished, f.offline]
            )
            XCTAssertEqual(builds.value, 0, "An empty search formats no date")

            XCTAssertEqual(
                entries.filtered(search: "orbit web", status: nil, contextID: nil, searchableFields: fields).map(\.id),
                [f.unfinished, f.completed]
            )
            XCTAssertEqual(builds.value, 3, "Two words over three readable rows build each row's fields once")
            XCTAssertEqual(
                entries.filtered(search: "orbit", status: .completed, contextID: nil, searchableFields: fields).map(\.id),
                [f.completed]
            )
            XCTAssertEqual(builds.value, 4, "A row the status filter hides builds nothing")
        }
    }

    // MARK: Missing manifests

    @MainActor
    func testANewFolderWithoutAManifestWaitsOnePassButAnUnusableManifestIsListedAtOnce() async throws {
        try await withFixture { f in
            final class Removal: @unchecked Sendable {
                private let lock = NSLock()
                private var armed = false
                var isArmed: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return armed
                }
                func arm() {
                    lock.lock()
                    armed = true
                    lock.unlock()
                }
            }
            let removal = Removal()
            let removed = f.completed
            let library = SessionLibrary(vault: f.vault, loadManifest: { vault, id in
                // Finder removes this folder after the scan listed it and before its manifest is read.
                if id == removed, removal.isArmed { try? FileManager.default.removeItem(at: vault.sessionURL(id: id)) }
                return try vault.loadManifest(id: id)
            })
            await library.refresh().value
            XCTAssertEqual(library.entries.map(\.id), [f.unfinished, f.completed, f.offline, f.corrupt])

            // The removed folder's manifest changes, so the next pass reads it again.
            var rewritten = try f.vault.loadManifest(id: removed)
            rewritten.pauses.append(PauseInterval(pauseWall: 50, resumeWall: 60))
            try f.vault.write(manifest: &rewritten)
            removal.arm()
            // A folder the last pass listed loses its manifest, as a delete that could not remove every file leaves it.
            try FileManager.default.removeItem(
                at: f.vault.sessionURL(id: f.offline).appendingPathComponent(ScrumTracePath.manifest)
            )
            // A recording whose folders exist but whose manifest createSession has not written yet.
            let creating = "\(folderStamp(Date()))-new001"
            try FileManager.default.createDirectory(
                at: f.vault.sessionURL(id: creating).appendingPathComponent(ScrumTracePath.archive, isDirectory: true),
                withIntermediateDirectories: true
            )
            // A folder that never gets a manifest, and one with a link in the manifest's place.
            let empty = "2020-02-02-0000-empty1"
            try FileManager.default.createDirectory(at: f.vault.sessionURL(id: empty), withIntermediateDirectories: false)
            let linked = "2020-02-03-0000-link01"
            try FileManager.default.createDirectory(at: f.vault.sessionURL(id: linked), withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: f.vault.sessionURL(id: linked).appendingPathComponent(ScrumTracePath.manifest),
                withDestinationURL: f.vault.sessionURL(id: f.unfinished).appendingPathComponent(ScrumTracePath.manifest)
            )

            await library.refresh().value
            let listed = library.entries.map(\.id)
            XCTAssertFalse(listed.contains(creating), "A recording being created is not an unreadable manifest")
            XCTAssertFalse(listed.contains(removed), "A folder removed between listing and reading is not listed")
            XCTAssertFalse(listed.contains(empty), "A new folder without a manifest waits one pass")
            XCTAssertEqual(
                library.entries.first { $0.id == f.corrupt },
                .unreadable(id: f.corrupt, reason: SessionEntry.decodingFailed),
                "A manifest that does not decode is listed at once"
            )
            XCTAssertEqual(
                library.entries.first { $0.id == linked },
                .unreadable(id: linked, reason: SessionEntry.notReadable),
                "A link in the manifest's place is listed at once"
            )
            XCTAssertEqual(
                library.entries.first { $0.id == f.offline },
                .unreadable(id: f.offline, reason: SessionEntry.notReadable),
                "A folder the last pass listed stays listed when its manifest goes missing"
            )
            XCTAssertEqual(
                f.vault.sessionEntries().first { $0.id == empty },
                .unreadable(id: empty, reason: SessionEntry.notReadable),
                "With no earlier pass to compare, a folder without a manifest is listed at once"
            )

            // createSession writes the manifest before the next pass.
            var manifest = SessionManifest.makeNew(sessionId: creating, product: .empty)
            try f.vault.write(manifest: &manifest)
            await library.refresh().value
            XCTAssertEqual(library.entries.first { $0.id == creating }?.summary?.sessionId, creating)
            XCTAssertFalse(library.entries.contains { $0.id == removed })
            XCTAssertEqual(
                library.entries.first { $0.id == empty },
                .unreadable(id: empty, reason: SessionEntry.notReadable),
                "Still missing on the next pass: listed, so it can be revealed or deleted"
            )
            await library.refresh().value
            XCTAssertEqual(library.entries.first { $0.id == empty }, .unreadable(id: empty, reason: SessionEntry.notReadable))
        }
    }

    @MainActor
    func testALibrarysFirstScanAlsoWaitsOnePassForAFolderWithoutAManifest() async throws {
        try await withFixture { f in
            // The window opens while createSession has made a recording's folders but not written its manifest yet.
            let creating = "\(folderStamp(Date()))-new002"
            try FileManager.default.createDirectory(
                at: f.vault.sessionURL(id: creating).appendingPathComponent(ScrumTracePath.archive, isDirectory: true),
                withIntermediateDirectories: true
            )
            let empty = "2020-02-02-0000-empty2"
            try FileManager.default.createDirectory(at: f.vault.sessionURL(id: empty), withIntermediateDirectories: false)

            let library = SessionLibrary(vault: f.vault)
            await library.refresh().value
            XCTAssertEqual(
                library.entries.map(\.id), [f.unfinished, f.completed, f.offline, f.corrupt],
                "The first scan lists neither folder without a manifest"
            )
            XCTAssertEqual(
                library.entries.last, .unreadable(id: f.corrupt, reason: SessionEntry.decodingFailed),
                "A manifest that does not decode is listed on the first scan"
            )
            XCTAssertEqual(
                f.vault.sessionEntries().first { $0.id == empty },
                .unreadable(id: empty, reason: SessionEntry.notReadable),
                "A one-off listing has no next pass, so it lists the folder at once"
            )

            // createSession writes the manifest before the next scan; the other folder never gets one.
            var manifest = SessionManifest.makeNew(sessionId: creating, product: .empty)
            try f.vault.write(manifest: &manifest)
            await library.refresh().value
            XCTAssertEqual(library.entries.first?.summary?.sessionId, creating)
            XCTAssertEqual(
                library.entries.first { $0.id == empty },
                .unreadable(id: empty, reason: SessionEntry.notReadable),
                "Still missing on the second scan: listed, so it can be revealed or deleted"
            )
        }
    }

    // MARK: Sizes

    @MainActor
    func testExportAndArchiveSizesNeverFollowSymlinks() async throws {
        try await withFixture { f in
            XCTAssertEqual(f.vault.exportSizes(id: f.completed), [
                ScrumTracePath.agentContext: Data("# Agent context".utf8).count,
                ScrumTracePath.sessionBrief: Data("<html></html>".utf8).count,
                ScrumTracePath.packZip: 1_234,
                "export/full_transcript.json": Data(Self.transcriptJSON.utf8).count
            ])
            XCTAssertEqual(f.vault.exportSizes(id: f.offline), [:], "A pack that links into archive/ is not an export file")
            XCTAssertEqual(f.vault.exportSizes(id: f.symlink), [:])
            XCTAssertEqual(f.vault.exportSizes(id: "../outside"), [:])

            let completedURL = f.vault.sessionURL(id: f.completed)
            let unfinishedURL = f.vault.sessionURL(id: f.unfinished)
            try write(Data(count: 100), to: "archive/a.bin", in: unfinishedURL)
            try write(Data(count: 50), to: "archive/nested/b.bin", in: unfinishedURL)
            try FileManager.default.createSymbolicLink(
                at: unfinishedURL.appendingPathComponent("archive/linked-folder"),
                withDestinationURL: f.outside
            )
            try FileManager.default.createSymbolicLink(
                at: unfinishedURL.appendingPathComponent("archive/linked-file"),
                withDestinationURL: completedURL.appendingPathComponent(ScrumTracePath.packZip)
            )
            XCTAssertEqual(f.vault.archiveByteCount(id: f.unfinished), 150)
            XCTAssertEqual(f.vault.archiveByteCount(id: f.offline), 4_096)
            XCTAssertEqual(f.vault.archiveByteCount(id: f.corrupt), 0)
            XCTAssertEqual(f.vault.archiveByteCount(id: f.symlink), 0)
            XCTAssertEqual(f.vault.archiveByteCount(id: "../outside"), 0)

            let movedArchive = completedURL.appendingPathComponent("archive-real")
            try FileManager.default.moveItem(at: completedURL.appendingPathComponent("archive"), to: movedArchive)
            try FileManager.default.createSymbolicLink(
                at: completedURL.appendingPathComponent("archive"),
                withDestinationURL: movedArchive
            )
            XCTAssertEqual(f.vault.archiveByteCount(id: f.completed), 0, "An archive/ that is a link counts as nothing")

            let library = SessionLibrary(vault: f.vault)
            await library.refresh().value
            XCTAssertNil(library.totalArchiveBytes, "Archives are not walked until a view asks")
            await library.loadTotalArchiveBytes().value
            XCTAssertEqual(library.totalArchiveBytes, 150 + 4_096)
        }
    }

    @MainActor
    func testArchiveTotalWalksOnlySessionsWhoseManifestOrArchiveChanged() async throws {
        try await withFixture { f in
            let walks = WalkRecorder()
            let library = SessionLibrary(vault: f.vault, measureArchive: { vault, id in
                walks.record(id)
                return vault.archiveByteCount(id: id)
            })
            let transcriptBytes = Data(Self.transcriptJSON.utf8).count
            await library.refresh().value
            await library.loadTotalArchiveBytes().value
            XCTAssertEqual(library.totalArchiveBytes, transcriptBytes + 4_096)
            XCTAssertEqual(walks.ids.sorted(), [f.unfinished, f.completed, f.offline, f.corrupt].sorted())

            await library.loadTotalArchiveBytes().value
            XCTAssertEqual(walks.ids.count, 4, "Unchanged sessions keep their measured size")

            // A pipeline stage adds a clip under an existing archive/ folder and rewrites the manifest.
            try write(Data(count: 100), to: ScrumTracePath.mediaWork + "/clip.mp4", in: f.vault.sessionURL(id: f.unfinished))
            var manifest = try f.vault.loadManifest(id: f.unfinished)
            manifest.pipelineStatus = .slicing
            manifest.markCompleted(.transcribing)
            try f.vault.write(manifest: &manifest)
            await library.refresh().value
            XCTAssertEqual(library.totalArchiveBytes, transcriptBytes + 4_096 + 100)
            XCTAssertEqual(Array(walks.ids.dropFirst(4)), [f.unfinished], "Only the changed session is walked again")

            try f.vault.deleteSession(id: f.offline, recordingLockURL: f.lockURL)
            await library.refresh().value
            XCTAssertEqual(library.totalArchiveBytes, transcriptBytes + 100)
            XCTAssertEqual(walks.ids.count, 5, "A deleted session drops out without walking the others")
        }
    }

    // MARK: Refresh

    @MainActor
    func testRefreshDecodesOnlyManifestsWhoseSizeOrDateChanged() async throws {
        try await withFixture { f in
            let counter = LoadCounter()
            let library = SessionLibrary(vault: f.vault, loadManifest: { vault, id in
                counter.increment()
                return try vault.loadManifest(id: id)
            })
            await library.refresh().value
            XCTAssertEqual(counter.value, 4, "Three manifests and the corrupt one")
            XCTAssertEqual(library.entries.map(\.id), [f.unfinished, f.completed, f.offline, f.corrupt])
            XCTAssertFalse(library.isLoading)

            await library.refresh().value
            XCTAssertEqual(counter.value, 4, "Unchanged size and modification date reuse the cached rows")
            XCTAssertEqual(library.entries.map(\.id), [f.unfinished, f.completed, f.offline, f.corrupt])

            try write("<html></html>", to: ScrumTracePath.sessionBrief, in: f.vault.sessionURL(id: f.unfinished))
            await library.refresh().value
            XCTAssertEqual(counter.value, 4, "Export files are probed without decoding")
            XCTAssertEqual(library.entries.first?.summary?.hasBrief, true)

            var manifest = try f.vault.loadManifest(id: f.unfinished)
            manifest.pipelineStatus = .slicing
            manifest.markCompleted(.transcribing)
            try f.vault.write(manifest: &manifest)
            await library.refresh().value
            XCTAssertEqual(counter.value, 5, "Only the rewritten manifest is decoded again")
            XCTAssertEqual(library.entries.first?.summary?.pipelineStatus, .slicing)
        }
    }

    @MainActor
    func testAManifestThatCouldNotBeReadIsReadAgainOnTheNextRefresh() async throws {
        try await withFixture { f in
            let counter = LoadCounter()
            let library = SessionLibrary(vault: f.vault, loadManifest: { vault, id in
                counter.increment()
                return try vault.loadManifest(id: id)
            })
            let manifest = f.vault.sessionURL(id: f.completed).appendingPathComponent(ScrumTracePath.manifest)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: manifest.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path) }

            await library.refresh().value
            XCTAssertEqual(counter.value, 4)
            XCTAssertEqual(
                library.entries.first { $0.id == f.completed },
                .unreadable(id: f.completed, reason: SessionEntry.notReadable)
            )

            // chmod keeps the size and modification time, so only the missing cache entry forces a read.
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path)
            await library.refresh().value
            XCTAssertEqual(counter.value, 5, "The manifest that failed to read is read again; decoded rows are reused")
            XCTAssertEqual(library.entries.first { $0.id == f.completed }?.summary?.pipelineStatus, .completed)
        }
    }

    @MainActor
    func testARefreshThatFindsNoChangePublishesNothing() async throws {
        try await withFixture { f in
            let library = SessionLibrary(vault: f.vault)
            let first = library.refresh()
            XCTAssertTrue(library.isLoading, "The first scan shows progress")
            await first.value
            XCTAssertFalse(library.isLoading)
            await library.loadTotalArchiveBytes().value

            let changes = LoadCounter()
            let observation = library.objectWillChange.sink { _ in changes.increment() }
            defer { observation.cancel() }
            let again = library.refresh()
            XCTAssertFalse(library.isLoading, "Later refreshes do not toggle the loading flag")
            await again.value
            await library.loadTotalArchiveBytes().value
            XCTAssertEqual(changes.value, 0, "A periodic refresh over unchanged sessions must not re-render observers")

            try write("<html></html>", to: ScrumTracePath.sessionBrief, in: f.vault.sessionURL(id: f.unfinished))
            await library.refresh().value
            XCTAssertGreaterThan(changes.value, 0, "A real change still publishes")
        }
    }

    @MainActor
    func testAnOlderRefreshCannotOverwriteANewerOne() async throws {
        try await withFixture { f in
            let gate = FirstLoadGate()
            defer { gate.open() }
            let library = SessionLibrary(vault: f.vault, loadManifest: { vault, id in
                gate.enter()
                return try vault.loadManifest(id: id)
            })
            let older = library.refresh()
            let started = await waitUntil { gate.calls >= 1 }
            XCTAssertTrue(started, "The older scan listed the folders and is decoding")

            try f.vault.deleteSession(id: f.offline, recordingLockURL: f.lockURL)
            await library.refresh().value
            XCTAssertEqual(library.entries.map(\.id), [f.unfinished, f.completed, f.corrupt])
            XCTAssertFalse(library.isLoading)

            gate.open()
            await older.value
            XCTAssertEqual(
                library.entries.map(\.id), [f.unfinished, f.completed, f.corrupt],
                "The older scan still listed the deleted session and must be dropped"
            )
            XCTAssertFalse(library.isLoading)
        }
    }

    @MainActor
    func testAnArchiveTotalAskedBeforeAnyScanPublishedWaitsForTheScanThatPublishes() async throws {
        try await withFixture { f in
            let gate = FirstLoadGate()
            defer { gate.open() }
            let walks = WalkRecorder()
            let library = SessionLibrary(
                vault: f.vault,
                loadManifest: { vault, id in
                    gate.enter()
                    return try vault.loadManifest(id: id)
                },
                measureArchive: { vault, id in
                    walks.record(id)
                    return vault.archiveByteCount(id: id)
                }
            )
            let totals = TotalRecorder()
            let observation = library.$totalArchiveBytes.dropFirst().sink { totals.record($0) }
            defer { observation.cancel() }
            let expected = Data(Self.transcriptJSON.utf8).count + 4_096

            // No scan listed the sessions yet, so zero bytes would be wrong: nothing is measured or published.
            await library.loadTotalArchiveBytes().value
            XCTAssertNil(library.totalArchiveBytes)
            XCTAssertEqual(walks.ids, [])

            // A view asks while the first scan is decoding, and a newer refresh replaces that scan.
            let older = library.refresh()
            let started = await waitUntil { gate.calls >= 1 }
            XCTAssertTrue(started, "The older scan is decoding")
            let total = library.loadTotalArchiveBytes()
            let newer = library.refresh()
            await total.value
            XCTAssertEqual(library.entries.count, 4, "The total waited for the newer scan")
            XCTAssertEqual(library.totalArchiveBytes, expected)
            XCTAssertEqual(walks.ids.sorted(), [f.unfinished, f.completed, f.offline, f.corrupt].sorted())
            gate.open()
            await older.value
            await newer.value
            XCTAssertEqual(totals.values, [expected], "One total, and never zero bytes before the sessions were listed")

            // A vault without sessions: the scan that publishes still measures the total that was asked for.
            let emptyRoot = f.base.appendingPathComponent("empty-sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
            let empty = SessionLibrary(vault: SessionVault(rootURL: emptyRoot))
            let scan = empty.refresh()
            await empty.loadTotalArchiveBytes().value
            XCTAssertEqual(empty.entries, [])
            XCTAssertEqual(empty.totalArchiveBytes, 0, "Measured once the empty list was published, not left at Measuring…")
            await scan.value
        }
    }
}

/// Records every archive total a library published, in order.
private final class TotalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int?] = []

    var values: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ value: Int?) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }
}

/// Counts manifest loads from background scans.
private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Records which session archives a background pass walked, in order.
private final class WalkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var ids: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ id: String) {
        lock.lock()
        recorded.append(id)
        lock.unlock()
    }
}

/// Holds the first manifest load until `open()`, so a second refresh can start and finish meanwhile.
private final class FirstLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let opened = DispatchSemaphore(value: 0)
    private var count = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func enter() {
        lock.lock()
        count += 1
        let isFirst = count == 1
        lock.unlock()
        if isFirst {
            _ = opened.wait(timeout: .now() + 10)
        }
    }

    func open() {
        opened.signal()
    }
}
