import Combine
import Darwin
import Foundation

// MARK: - Rows

/// Task outcomes of one session. Counts only, never titles or evidence.
struct SessionTaskCounts: Sendable, Hashable {
    var confirmed = 0
    var needsReview = 0
    var dropped = 0
}

extension SessionTaskCounts {
    init(tasks: [TaskRecord]) {
        for task in tasks {
            switch task.status {
            case .confirmed: confirmed += 1
            case .needsReview: needsReview += 1
            case .dropped: dropped += 1
            }
        }
    }
}

/// Which export files a row can offer. Probed on every refresh; no file is read.
struct SessionExportProbe: Sendable, Hashable {
    var hasAgentContext = false
    var hasBrief = false
    var packBytes: Int?
    var hasFullTranscriptArchive = false

    /// `regularFileByteCount` opens every component with `O_NOFOLLOW` and needs a regular file, so a
    /// planted `export/session-pack.zip` link into `archive/` is not a pack (C2, C3). Zero bytes counts
    /// as missing, as in `ExportRel.existingSessionFile`. A few syscalls per file.
    static func probe(sessionURL: URL) -> SessionExportProbe {
        func bytes(_ relative: String) -> Int? {
            guard let count = ExportRel.regularFileByteCount(relative: relative, sessionURL: sessionURL),
                  count > 0 else { return nil }
            return count
        }
        return SessionExportProbe(
            hasAgentContext: bytes(ScrumTracePath.agentContext) != nil,
            hasBrief: bytes(ScrumTracePath.sessionBrief) != nil,
            packBytes: bytes(ScrumTracePath.packZip),
            hasFullTranscriptArchive: bytes(ScrumTracePath.fullTranscript) != nil
        )
    }
}

/// One row of the private session index, mapped from manifest metadata only (C2).
///
/// The context and product names are the only user-written text. Transcript text, Shot notes,
/// task titles and observations, window titles, URLs and provider responses never enter it.
/// `SessionLibraryTests` pins the stored fields against an allow-list.
struct SessionSummary: Sendable, Identifiable, Hashable {
    let sessionId: String
    let createdAt: Date
    let pipelineStatus: PipelineStatus
    let completedStages: [PipelineStatus]
    let mediaSeconds: TimeInterval
    let wallSeconds: TimeInterval
    let pauseCount: Int
    let contextName: String?
    /// The product name, or the context name when the product name is blank (as a saved context snapshot does).
    let productName: String
    let contextID: String?
    let shotCount: Int
    let sliceCount: Int
    /// Slices whose analysis ended offline. Feeds the Needs review filter.
    let offlineFailedSliceCount: Int
    let taskCounts: SessionTaskCounts
    let consentApproved: Bool
    let omittedCount: Int
    /// `export/AGENT_CONTEXT.md` exists.
    private(set) var hasExportContext: Bool
    private(set) var hasBrief: Bool
    private(set) var hasPack: Bool
    private(set) var packBytes: Int?
    /// `archive/full_transcript.json` exists, so speakers can be reviewed.
    private(set) var hasFullTranscriptArchive: Bool
    /// The pipeline status is neither `idle` nor `completed`.
    let isUnfinished: Bool

    var id: String { sessionId }

    init(manifest: SessionManifest, exportProbe: SessionExportProbe) {
        let product = manifest.productContext
        let context = Self.nonBlank(product.contextName)
        sessionId = manifest.sessionId
        createdAt = manifest.createdAt
        pipelineStatus = manifest.pipelineStatus
        completedStages = manifest.completedStages
        mediaSeconds = manifest.duration.mediaSeconds
        wallSeconds = manifest.duration.wallSeconds
        pauseCount = manifest.pauses.count
        contextName = context
        productName = Self.nonBlank(product.appName) ?? context ?? ""
        contextID = Self.nonBlank(product.contextID)
        shotCount = manifest.shots.count
        sliceCount = manifest.slices.count
        offlineFailedSliceCount = manifest.slices.filter { $0.analysisStatus == .offlineFailed }.count
        taskCounts = SessionTaskCounts(tasks: manifest.tasks)
        consentApproved = manifest.uploadConsent.approved
        omittedCount = manifest.omitted.count
        hasExportContext = exportProbe.hasAgentContext
        hasBrief = exportProbe.hasBrief
        hasPack = exportProbe.packBytes != nil
        packBytes = exportProbe.packBytes
        hasFullTranscriptArchive = exportProbe.hasFullTranscriptArchive
        switch manifest.pipelineStatus {
        case .idle, .completed:
            isUnfinished = false
        case .recording, .paused, .transcribing, .slicing, .evaluating, .synthesizing, .offlineFailed:
            isUnfinished = true
        }
    }

    /// The same manifest fields with export availability probed again.
    func updating(exportProbe: SessionExportProbe) -> SessionSummary {
        var copy = self
        copy.hasExportContext = exportProbe.hasAgentContext
        copy.hasBrief = exportProbe.hasBrief
        copy.hasPack = exportProbe.packBytes != nil
        copy.packBytes = exportProbe.packBytes
        copy.hasFullTranscriptArchive = exportProbe.hasFullTranscriptArchive
        return copy
    }

    /// Date text for lists. Search matches this exact text.
    static func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Everything search may match: the id, the formatted date, the context and product names.
    var searchableFields: [String] {
        [sessionId, Self.formattedDate(createdAt), contextName ?? "", productName]
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// A listed session folder. An unreadable manifest is a row, never a crash or a silent omission.
enum SessionEntry: Sendable, Hashable, Identifiable {
    case loaded(SessionSummary)
    /// `reason` is one of the fixed technical phrases below, never file contents.
    case unreadable(id: String, reason: String)

    static let decodingFailed = "decoding failed"
    static let notReadable = "not readable"
    static let sessionIdMismatch = "session id mismatch"

    var id: String {
        switch self {
        case .loaded(let summary): return summary.sessionId
        case .unreadable(let id, _): return id
        }
    }

    var summary: SessionSummary? {
        if case .loaded(let summary) = self { return summary }
        return nil
    }

    /// `createdAt`, or for an unreadable row the local time stamp that starts its folder name.
    var sortDate: Date? {
        switch self {
        case .loaded(let summary): return summary.createdAt
        case .unreadable(let id, _): return Self.folderStamp.date(from: String(id.prefix(15)))
        }
    }

    /// Newest first. Equal or missing dates fall back to the folder name, also descending.
    static func newestFirst(_ entries: [SessionEntry]) -> [SessionEntry] {
        entries.sorted { lhs, rhs in
            let left = lhs.sortDate ?? .distantPast
            let right = rhs.sortDate ?? .distantPast
            if left != right { return left > right }
            return lhs.id > rhs.id
        }
    }

    /// `SessionVault.makeSessionID` starts folder names with this stamp.
    private static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}

/// Status filters for the recordings list. They may overlap: a completed session can need review.
enum SessionStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case completed
    /// Any task needs review, or any slice failed offline.
    case needsReview
    /// `SessionSummary.isUnfinished`, which includes offline-failed sessions.
    case unfinished
    case offlineFailed

    var id: String { rawValue }

    func matches(_ summary: SessionSummary) -> Bool {
        switch self {
        case .completed:
            return summary.pipelineStatus == .completed
        case .needsReview:
            return summary.taskCounts.needsReview > 0 || summary.offlineFailedSliceCount > 0
        case .unfinished:
            return summary.isUnfinished
        case .offlineFailed:
            return summary.pipelineStatus == .offlineFailed
        }
    }
}

extension Array where Element == SessionEntry {
    /// Every whitespace-separated search word must match `SessionSummary.searchableFields`, case and
    /// diacritics ignored. Unreadable rows match by folder name only and are hidden by any status or
    /// context filter.
    func filtered(search: String, status: SessionStatusFilter?, contextID: String?) -> [SessionEntry] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return filter { entry in
            switch entry {
            case .loaded(let summary):
                if let status, !status.matches(summary) { return false }
                if let contextID, summary.contextID != contextID { return false }
                let fields = summary.searchableFields
                return words.allSatisfy { word in
                    fields.contains { $0.localizedStandardContains(word) }
                }
            case .unreadable(let id, _):
                guard status == nil, contextID == nil else { return false }
                return words.allSatisfy { id.localizedStandardContains($0) }
            }
        }
    }
}

// MARK: - Scanning

/// `lstat`, so a last-component symlink is described rather than followed.
private func lstatInfo(_ url: URL) -> stat? {
    var info = stat()
    let status = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
        guard let ptr else { return -1 }
        return Darwin.lstat(ptr, &info)
    }
    return status == 0 ? info : nil
}

/// Loads one manifest for the index. Tests inject a counting loader.
typealias SessionManifestLoader = @Sendable (SessionVault, String) throws -> SessionManifest

/// Manifest size and modification time from `lstat`. An unchanged stamp reuses the cached row.
struct SessionManifestStamp: Sendable, Hashable {
    let byteCount: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    /// Nil unless `session.manifest.json` is a regular file, not a symlink.
    static func read(sessionURL: URL) -> SessionManifestStamp? {
        guard let info = lstatInfo(sessionURL.appendingPathComponent(ScrumTracePath.manifest)),
              (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return SessionManifestStamp(
            byteCount: Int64(info.st_size),
            modifiedSeconds: Int(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec)
        )
    }
}

/// Rows decoded by an earlier scan, keyed by session id. It keeps summaries, never manifests, so no
/// task, Shot or transcript text stays in memory between refreshes.
struct SessionIndexCache: Sendable {
    enum Row: Sendable, Hashable {
        case summary(SessionSummary)
        case unreadable(reason: String)
    }

    struct Item: Sendable {
        let stamp: SessionManifestStamp
        let row: Row
    }

    var items: [String: Item] = [:]
}

/// One listing pass: rows newest first, and the cache the next pass reuses.
struct SessionIndexScan: Sendable {
    let entries: [SessionEntry]
    let cache: SessionIndexCache
}

/// Measures one session's `archive/`. Tests inject a counting walker.
typealias SessionArchiveMeasure = @Sendable (SessionVault, String) -> Int

/// When an `archive/` total is measured again: the manifest changed (every pipeline stage rewrites
/// it), or `archive/` itself did (an entry added, removed or renamed directly inside, or the folder
/// replaced). A file growing deeper inside, as during a recording, waits for the next manifest write.
struct SessionArchiveStamp: Sendable, Hashable {
    struct Folder: Sendable, Hashable {
        let fileType: mode_t
        let device: dev_t
        let inode: ino_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    let manifest: SessionManifestStamp?
    let archive: Folder?

    static func read(sessionURL: URL) -> SessionArchiveStamp {
        let info = lstatInfo(sessionURL.appendingPathComponent(ScrumTracePath.archive, isDirectory: true))
        return SessionArchiveStamp(
            manifest: SessionManifestStamp.read(sessionURL: sessionURL),
            archive: info.map { info in
                Folder(
                    fileType: info.st_mode & S_IFMT,
                    device: info.st_dev,
                    inode: info.st_ino,
                    modifiedSeconds: Int(info.st_mtimespec.tv_sec),
                    modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec)
                )
            }
        )
    }
}

/// `archive/` byte counts from an earlier pass, keyed by session id.
struct SessionArchiveSizeCache: Sendable {
    struct Item: Sendable {
        let stamp: SessionArchiveStamp
        let bytes: Int
    }

    var items: [String: Item] = [:]
}

/// One archive pass: the total, and the cache the next pass reuses.
struct SessionArchiveTotal: Sendable {
    let bytes: Int
    let cache: SessionArchiveSizeCache
}

/// A directory's device and inode, so two spellings of one folder compare equal.
private struct SessionFolderIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(_ info: stat) {
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }

    /// Nil unless `url` is a real directory, not a symlink.
    static func read(_ url: URL) -> SessionFolderIdentity? {
        lstatInfo(url).flatMap(SessionFolderIdentity.init)
    }
}

extension SessionVault {
    /// Export files a session detail may list with sizes, as session-relative paths in display order.
    static let indexedExportFiles = [
        ScrumTracePath.agentContext,
        ScrumTracePath.agentPrompt,
        ScrumTracePath.sessionBrief,
        ScrumTracePath.packZip,
        ScrumTracePath.omitted,
        ScrumTracePath.export + "/full_transcript.json"
    ]

    /// Every listed session folder as an index row, newest first. Same directory rules as
    /// `listedSessionIds`: symlinks, non-directories and invalid ids are skipped.
    func sessionEntries() -> [SessionEntry] {
        scanSessionIndex(reusing: SessionIndexCache()) { vault, id in
            try vault.loadManifest(id: id)
        }.entries
    }

    /// `sessionEntries()` with a cache. A manifest whose size and modification time match the previous
    /// scan is not decoded again. Export availability is probed on every pass.
    func scanSessionIndex(
        reusing previous: SessionIndexCache,
        loadManifest: SessionManifestLoader
    ) -> SessionIndexScan {
        var cache = SessionIndexCache()
        var entries: [SessionEntry] = []
        for id in listedSessionIds() {
            let session = sessionURL(id: id)
            // Stat before decoding: a manifest replaced in between gets a newer stamp next time.
            let stamp = SessionManifestStamp.read(sessionURL: session)
            let row: SessionIndexCache.Row
            if let stamp, let cached = previous.items[id], cached.stamp == stamp {
                row = cached.row
            } else {
                row = indexRow(id: id, loadManifest: loadManifest)
            }
            switch row {
            case .summary(let summary):
                entries.append(.loaded(summary.updating(exportProbe: .probe(sessionURL: session))))
            case .unreadable(let reason):
                entries.append(.unreadable(id: id, reason: reason))
            }
            // A read failure can be transient (permissions, a file being replaced), so try it again next time.
            if let stamp, row != .unreadable(reason: SessionEntry.notReadable) {
                cache.items[id] = SessionIndexCache.Item(stamp: stamp, row: row)
            }
        }
        return SessionIndexScan(entries: SessionEntry.newestFirst(entries), cache: cache)
    }

    private func indexRow(id: String, loadManifest: SessionManifestLoader) -> SessionIndexCache.Row {
        do {
            let manifest = try loadManifest(self, id)
            // A copied folder must not act on another session's id.
            guard manifest.sessionId == id else {
                return .unreadable(reason: SessionEntry.sessionIdMismatch)
            }
            return .summary(SessionSummary(manifest: manifest, exportProbe: SessionExportProbe()))
        } catch is DecodingError {
            return .unreadable(reason: SessionEntry.decodingFailed)
        } catch {
            return .unreadable(reason: SessionEntry.notReadable)
        }
    }

    /// Sizes of the export files that exist, keyed by session-relative path. Contents are never read.
    func exportSizes(id: String) -> [String: Int] {
        guard let session = indexedSessionURL(id: id) else { return [:] }
        var sizes: [String: Int] = [:]
        for path in Self.indexedExportFiles {
            guard let relative = ExportRel.existingSessionFile(path, sessionURL: session),
                  let bytes = ExportRel.regularFileByteCount(relative: relative, sessionURL: session) else {
                continue
            }
            sizes[relative] = bytes
        }
        return sizes
    }

    /// Bytes of the regular files under `archive/`. Symlinks are neither followed nor counted, and a
    /// session whose `archive/` is itself a link counts as zero.
    func archiveByteCount(id: String) -> Int {
        guard let session = indexedSessionURL(id: id),
              !ExportRel.containsSymlinkComponent(ScrumTracePath.archive, sessionURL: session) else { return 0 }
        // Walk the directory an O_NOFOLLOW open resolved, not the constructed path.
        guard let archive = ExportRel.unfollowedDirectoryURL(
            session.appendingPathComponent(ScrumTracePath.archive, isDirectory: true)
        ) else { return 0 }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let keySet = Set(keys)
        guard let walker = FileManager.default.enumerator(
            at: archive,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            // The enumerator lists a directory link without descending into it.
            guard let values = try? url.resourceValues(forKeys: keySet),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        // `archive/` swapped for a link during the walk may have been measured through it.
        if ExportRel.containsSymlinkComponent(ScrumTracePath.archive, sessionURL: session) {
            return 0
        }
        return total
    }

    /// The `archive/` total of `ids`. A session whose `SessionArchiveStamp` matches `previous` keeps its
    /// count, so only new or changed sessions are walked.
    func archiveByteTotal(
        ids: [String],
        reusing previous: SessionArchiveSizeCache,
        measure: SessionArchiveMeasure
    ) -> SessionArchiveTotal {
        var cache = SessionArchiveSizeCache()
        var total = 0
        for id in ids {
            // Stamp before walking: a change during the walk gets a newer stamp next time.
            let stamp = SessionArchiveStamp.read(sessionURL: sessionURL(id: id))
            let bytes: Int
            if let cached = previous.items[id], cached.stamp == stamp {
                bytes = cached.bytes
            } else {
                bytes = measure(self, id)
            }
            cache.items[id] = SessionArchiveSizeCache.Item(stamp: stamp, bytes: bytes)
            total += bytes
        }
        return SessionArchiveTotal(bytes: total, cache: cache)
    }

    /// Deletes one session folder with the guards of `removeAbandonedSession` (valid id, usable sessions
    /// folder, not a symlink, `ExportRel.removeOwnedSessionFolder`), and refuses a session named by a
    /// live `recording.lock`. Callers also refuse the controller's active session. Throws when any of
    /// the folder is left on disk; a partly wiped folder is put back under its id so the list shows it.
    func deleteSession(id: String, recordingLockURL: URL = AgentLog.recordingLockURL) throws {
        guard Self.isValidSessionId(id) else {
            throw SessionVaultError.writeFailed("invalid session id")
        }
        guard ExportRel.isUsableSessionRoot(rootURL) else {
            throw SessionVaultError.writeFailed("sessions folder")
        }
        let session = sessionURL(id: id)
        guard ExportRel.isUsableSessionRoot(session) else {
            throw SessionVaultError.writeFailed("session folder")
        }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        // `isUsableSessionRoot` also accepts a missing path.
        guard let folder = SessionFolderIdentity.read(session) else {
            throw SessionVaultError.sessionMissing(id)
        }
        if isNamedByLiveRecordingLock(folder, id: id, recordingLockURL: recordingLockURL) {
            throw SessionVaultError.writeFailed("session is live")
        }
        ExportRel.removeOwnedSessionFolder(sessionURL: session, sessionsRoot: rootURL)
        let leftBehind = restoreUndeletedFolder(folder, id: id)
        if leftBehind || SessionFolderIdentity.read(session) != nil {
            throw SessionVaultError.writeFailed("session folder")
        }
    }

    /// The lock names this folder by its id or by another spelling of it. The sessions volume is
    /// usually case-insensitive, so `…-ABC123` opens the `…-abc123` folder; compare the folders.
    private func isNamedByLiveRecordingLock(
        _ folder: SessionFolderIdentity,
        id: String,
        recordingLockURL: URL
    ) -> Bool {
        guard let lock = AgentLog.liveRecordingLock(at: recordingLockURL) else { return false }
        if lock.sessionId == id { return true }
        guard Self.isValidSessionId(lock.sessionId) else { return false }
        return SessionFolderIdentity.read(sessionURL(id: lock.sessionId)) == folder
    }

    /// `removeOwnedSessionFolder` renames the folder to a hidden name, then wipes it and ignores
    /// failures, so a file that cannot be unlinked (a locked file, a read-only folder) would leave
    /// the recording hidden but on disk. Finds that folder by identity and renames it back to `id`,
    /// unless the name was taken meanwhile. True when a hidden leftover was found.
    private func restoreUndeletedFolder(_ folder: SessionFolderIdentity, id: String) -> Bool {
        guard let rootFd = ExportRel.openUnfollowedDirectory(rootURL) else { return false }
        defer { ExportRel.closeDescriptor(rootFd) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
        for name in names where name.hasPrefix(".") {
            var info = stat()
            let status = name.withCString { Darwin.fstatat(rootFd, $0, &info, AT_SYMLINK_NOFOLLOW) }
            guard status == 0, SessionFolderIdentity(info) == folder else { continue }
            _ = name.withCString { from in
                id.withCString { to in
                    Darwin.renameatx_np(rootFd, from, rootFd, to, UInt32(RENAME_EXCL))
                }
            }
            return true
        }
        return false
    }

    /// A valid id inside a usable sessions folder whose own folder is not a symlink.
    private func indexedSessionURL(id: String) -> URL? {
        guard Self.isValidSessionId(id), ExportRel.isUsableSessionRoot(rootURL) else { return nil }
        let session = sessionURL(id: id)
        guard ExportRel.isUsableSessionRoot(session) else { return nil }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        return session
    }
}

// MARK: - Library

/// The private session index behind the main window. It lists, searches and sizes sessions from
/// manifest metadata and never reads transcripts, Shot notes, task text or `archive/` contents.
@MainActor
final class SessionLibrary: ObservableObject {
    /// Newest first, unreadable manifests included.
    @Published private(set) var entries: [SessionEntry] = []
    /// True until the first refresh publishes. Later refreshes update rows in place without toggling
    /// it, so a periodic refresh that finds nothing new publishes no change at all.
    @Published private(set) var isLoading = false
    /// Bytes under every listed session's `archive/`. Nil until a total was asked for and measured after a
    /// scan published, so it never reads zero for sessions that were not listed yet.
    @Published private(set) var totalArchiveBytes: Int?

    let vault: SessionVault
    private let loadManifest: SessionManifestLoader
    private let measureArchive: SessionArchiveMeasure
    private var cache = SessionIndexCache()
    private var archiveSizes = SessionArchiveSizeCache()
    private var hasPublishedScan = false
    private var refreshGeneration = 0
    private var archiveGeneration = 0
    private var tracksArchiveBytes = false
    /// The newest refresh. Only it can publish, so a total asked for before the first scan waits for it.
    private var latestRefresh: Task<Void, Never>?
    /// A total was asked for before any scan published. The scan that publishes measures it, even when it
    /// finds no session.
    private var isArchiveTotalWaitingForScan = false

    init(
        vault: SessionVault,
        loadManifest: @escaping SessionManifestLoader = { vault, id in try vault.loadManifest(id: id) },
        measureArchive: @escaping SessionArchiveMeasure = { vault, id in vault.archiveByteCount(id: id) }
    ) {
        self.vault = vault
        self.loadManifest = loadManifest
        self.measureArchive = measureArchive
    }

    /// Lists and decodes off the main actor, then publishes here. A refresh that finishes after a newer
    /// one started is dropped, so a slow scan cannot bring back a row that was just deleted. Once a view
    /// asked for the archive total, the returned task also waits for the total to catch up. The first
    /// scan that publishes measures a total asked for earlier, even when it lists no session.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        refreshGeneration += 1
        let generation = refreshGeneration
        if !hasPublishedScan, !isLoading {
            isLoading = true
        }
        let vault = vault
        let previous = cache
        let loadManifest = loadManifest
        let task = Task { @MainActor [weak self] in
            let scan = await Task.detached(priority: .utility) {
                vault.scanSessionIndex(reusing: previous, loadManifest: loadManifest)
            }.value
            guard let self, generation == self.refreshGeneration else { return }
            self.cache = scan.cache
            self.hasPublishedScan = true
            if self.isLoading {
                self.isLoading = false
            }
            let changed = scan.entries != self.entries
            if changed {
                self.entries = scan.entries
            }
            let totalWaited = self.isArchiveTotalWaitingForScan
            self.isArchiveTotalWaitingForScan = false
            if self.tracksArchiveBytes, changed || totalWaited {
                await self.loadTotalArchiveBytes().value
            }
        }
        latestRefresh = task
        return task
    }

    /// Sums `archive/` sizes off the main actor. Nothing walks archives until a view asks once. After
    /// that, a refresh that changes the list updates the total, walking only the sessions whose
    /// manifest or `archive/` folder changed since they were last measured.
    ///
    /// Before any scan has published there is no list to measure: the returned task waits for the newest
    /// refresh, including one that replaced an earlier scan, and that refresh measures the total.
    @discardableResult
    func loadTotalArchiveBytes() -> Task<Void, Never> {
        tracksArchiveBytes = true
        guard hasPublishedScan else {
            isArchiveTotalWaitingForScan = true
            return Task { @MainActor [weak self] in
                while let self, !self.hasPublishedScan, let running = self.latestRefresh {
                    await running.value
                }
            }
        }
        archiveGeneration += 1
        let generation = archiveGeneration
        let vault = vault
        let ids = entries.map(\.id)
        let previous = archiveSizes
        let measureArchive = measureArchive
        return Task { @MainActor [weak self] in
            let pass = await Task.detached(priority: .utility) {
                vault.archiveByteTotal(ids: ids, reusing: previous, measure: measureArchive)
            }.value
            guard let self, generation == self.archiveGeneration else { return }
            self.archiveSizes = pass.cache
            if self.totalArchiveBytes != pass.bytes {
                self.totalArchiveBytes = pass.bytes
            }
        }
    }

    func filtered(search: String, status: SessionStatusFilter?, contextID: String?) -> [SessionEntry] {
        entries.filtered(search: search, status: status, contextID: contextID)
    }
}
