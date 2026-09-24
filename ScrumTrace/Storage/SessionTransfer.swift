import CryptoKit
import Darwin
import Foundation

/// Saved at capture time, not inferred from the computer that later exports an old recording.
struct SessionEnvironment: Codable, Sendable, Hashable {
    var computer: String
    var macOS: String
    var appVersion: String
    var appBuild: String
    var architecture: String

    static func current() -> SessionEnvironment {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return SessionEnvironment(
            computer: String((Host.current().localizedName ?? "Mac").prefix(120)),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            architecture: architecture
        )
    }
}

enum SessionTransferScope: String, Codable, CaseIterable, Sendable {
    case evidence
    case complete

    var title: String { self == .complete ? "Complete recording" : "Export evidence only" }
}

struct SessionImportOrigin: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case imported, analysisCopy }
    var kind: Kind
    var originalSessionID: String
    var importedAt: Date
    var exportedFrom: SessionEnvironment?
    var transferID: String
    var scope: SessionTransferScope
    /// Checksums establish consistency with the supplied index, not the identity of its author.
    var integrityVerified: Bool
    var parentSessionID: String?
    var retranscribed: Bool? = nil
}

struct SessionTransferIndex: Codable, Sendable {
    struct File: Codable, Sendable, Equatable {
        var path: String
        var bytes: Int
        var sha256: String
    }

    var version = 1
    var transferID: String
    var sourceSessionID: String
    var exportedAt: Date
    var exportedFrom: SessionEnvironment
    var scope: SessionTransferScope
    var files: [File]
}

enum SessionTransferError: LocalizedError, Equatable {
    case invalidPackage, unsupportedVersion, unsafePath, changedFile, checksumMismatch
    case destinationExists, insufficientSpace, privateConsentRequired, busy
    case duplicate(String), missingSources, copyFailed

    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Choose a ScrumTrace transfer package, a session folder, or an export folder containing session.manifest.json."
        case .unsupportedVersion: return "This transfer needs a newer version of ScrumTrace."
        case .unsafePath: return "The transfer contains an unsafe path, a link, or a special file."
        case .changedFile: return "A source file changed during the transfer. Stop recording and processing, then export again."
        case .checksumMismatch: return "A file does not match its transfer checksum. Copy the package again from the source Mac."
        case .destinationExists: return "An item already exists at that destination. Choose a new name."
        case .insufficientSpace: return "There is not enough free space for this transfer."
        case .privateConsentRequired: return "Confirm that this transfer may include the private recording, complete transcript and raw events."
        case .busy: return "Wait until recording, processing and the current transfer finish."
        case .duplicate(let id): return "This exact transfer is already imported as \(id)."
        case .missingSources: return "The required recording or transcript is missing. Import a complete recording to run this analysis."
        case .copyFailed: return "The transfer could not be written. Check the destination and available space."
        }
    }
}

/// A Finder package with ordinary files and a versioned SHA-256 index. No shell extraction,
/// executable content, credentials, host settings or automatic provider calls.
struct SessionTransfer {
    static let packageExtension = "scrumtrace"
    static let indexName = "transfer.json"
    static let baselineManifest = "archive/transfer-baseline/session.manifest.json"
    static let baselineTiming = "archive/transfer-baseline/pipeline-timing.json"
    static let baselineTranscript = "archive/transfer-baseline/full_transcript.json"
    static let diagnosticPath = "archive/transfer-diagnostics.jsonl"
    static let maximumFiles = 50_000
    static let metadataLimit = 16 * 1024 * 1024
    typealias Progress = @Sendable (Int, Int) -> Void

    let vault: SessionVault

    func export(
        id: String, to destination: URL, scope: SessionTransferScope,
        includePrivate: Bool, environment: SessionEnvironment,
        progress: Progress = { _, _ in }
    ) throws -> SessionTransferIndex {
        guard scope != .complete || includePrivate else { throw SessionTransferError.privateConsentRequired }
        try rejectLiveRecording(id)
        let source = vault.sessionURL(id: id)
        let original = try vault.loadManifest(id: id)
        guard original.sessionId == id else { throw SessionTransferError.invalidPackage }
        let sourceManifest = try read(ScrumTracePath.manifest, in: source)
        let paths: [String]
        if scope == .complete {
            paths = try inventory(source, excludingTopLevel: [CodexWorkspace.directoryName, CodexWorkspace.privateArchiveDirectoryName])
                .filter { $0 != Self.indexName && Self.isSessionPath($0) }
        } else {
            let exportRoot = source.appendingPathComponent(ScrumTracePath.export)
            _ = try inventory(exportRoot)
            paths = PackBudget.allowList(
                exportDir: exportRoot, includeFullTranscript: original.includeFullTranscriptInZip
            ).filter { $0 != "session-pack.zip" }.map { "export/" + $0 }
            guard paths.contains(ScrumTracePath.exportManifest) else { throw SessionTransferError.missingSources }
        }
        let parent = destination.deletingLastPathComponent()
        try ensureSpace(paths: paths, source: source, destination: parent)
        let stage = try makeStage(in: parent)
        defer { ExportRel.removeOwnedSessionFolder(sessionURL: stage, sessionsRoot: parent) }
        var files: [SessionTransferIndex.File] = []
        for (index, path) in paths.sorted().enumerated() {
            try Task.checkCancellation()
            let target = scope == .evidence ? String(path.dropFirst("export/".count)) : path
            files.append(try copy(path, from: source, to: target, in: stage))
            progress(index + 1, paths.count)
        }
        guard try read(ScrumTracePath.manifest, in: source) == sourceManifest else {
            throw SessionTransferError.changedFile
        }
        if scope == .complete, let diagnostics = diagnostics(for: id), !diagnostics.isEmpty,
           !files.contains(where: { $0.path == Self.diagnosticPath }) {
            try write(diagnostics, to: Self.diagnosticPath, in: stage)
            files.append(.init(path: Self.diagnosticPath, bytes: diagnostics.count, sha256: digest(diagnostics)))
        }
        let index = SessionTransferIndex(
            transferID: UUID().uuidString.lowercased(), sourceSessionID: id,
            exportedAt: Date(), exportedFrom: environment, scope: scope,
            files: files.sorted { $0.path < $1.path }
        )
        try write(try Self.encoder().encode(index), to: Self.indexName, in: stage)
        try install(stage, at: destination)
        return index
    }

    /// Also accepts ordinary session/export folders from older app versions. Such imports say
    /// "No source checksums" and never fabricate the computer that originally captured the session.
    func importRecording(from source: URL, progress: Progress = { _, _ in }) throws -> String {
        let paths = try inventory(source)
        guard paths.contains(ScrumTracePath.manifest) else { throw SessionTransferError.invalidPackage }
        let indexed = paths.contains(Self.indexName)
        let index: SessionTransferIndex?
        if indexed {
            let decoded = try Self.decoder().decode(SessionTransferIndex.self, from: read(Self.indexName, in: source))
            guard decoded.version == 1 else { throw SessionTransferError.unsupportedVersion }
            guard UUID(uuidString: decoded.transferID) != nil,
                  SessionVault.isValidSessionId(decoded.sourceSessionID),
                  decoded.files.count <= Self.maximumFiles else { throw SessionTransferError.invalidPackage }
            let names = decoded.files.map(\.path)
            guard Set(names).count == names.count,
                  Set(names) == Set(paths.filter { $0 != Self.indexName }),
                  decoded.files.allSatisfy({ Self.isSafePath($0.path) && $0.bytes >= 0
                    && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) }) else {
                throw SessionTransferError.invalidPackage
            }
            index = decoded
        } else {
            index = nil
        }
        let scope = index?.scope ?? (paths.contains(where: { $0.hasPrefix("archive/") }) ? .complete : .evidence)
        let originalData = try read(ScrumTracePath.manifest, in: source)
        var manifest = try Self.decoder().decode(SessionManifest.self, from: originalData)
        guard manifest.manifestVersion == MediaBudget.manifestVersion,
              SessionVault.isValidSessionId(manifest.sessionId),
              index == nil || index?.sourceSessionID == manifest.sessionId else {
            throw SessionTransferError.invalidPackage
        }
        let members = paths.filter { $0 != Self.indexName }
        guard members.allSatisfy({ scope == .complete ? Self.isSessionPath($0) : Self.isEvidencePath($0) }) else {
            throw SessionTransferError.unsafePath
        }
        try vault.ensureRoot()
        try ensureSpace(paths: members, source: source, destination: vault.rootURL)
        let stage = try makeStage(in: vault.rootURL)
        defer { ExportRel.removeOwnedSessionFolder(sessionURL: stage, sessionsRoot: vault.rootURL) }
        var copied: [SessionTransferIndex.File] = []
        let expected = Dictionary(uniqueKeysWithValues: (index?.files ?? []).map { ($0.path, $0) })
        for (number, path) in members.sorted().enumerated() {
            try Task.checkCancellation()
            let target = scope == .evidence ? "export/" + path : path
            var file = try copy(path, from: source, to: target, in: stage)
            file.path = path
            if let required = expected[path], file != required { throw SessionTransferError.checksumMismatch }
            copied.append(file)
            progress(number + 1, members.count)
        }
        guard try read(scope == .evidence ? ScrumTracePath.exportManifest : ScrumTracePath.manifest, in: stage) == originalData else {
            throw SessionTransferError.changedFile
        }
        let contentID = digest(try Self.encoder().encode(copied))
        let transferID = index?.transferID ?? contentID
        if let existing = vault.sessionEntries().compactMap(\.summary).first(where: { row in
            guard let origin = try? vault.loadManifest(id: row.sessionId).importOrigin else { return false }
            return origin.kind == .imported && origin.transferID == transferID
        }) {
            throw SessionTransferError.duplicate(existing.sessionId)
        }
        let originalID = manifest.sessionId
        let localID = vault.makeSessionID()
        manifest.sessionId = localID
        manifest.uploadConsent = .denied
        manifest.importOrigin = SessionImportOrigin(
            kind: .imported, originalSessionID: originalID, importedAt: Date(),
            exportedFrom: index?.exportedFrom, transferID: transferID, scope: scope,
            integrityVerified: indexed, parentSessionID: nil
        )
        // Baselines are private and never part of the coding-agent export allow-list.
        try write(originalData, to: Self.baselineManifest, in: stage, replace: true)
        for (original, baseline) in [(ScrumTracePath.pipelineTiming, Self.baselineTiming),
                                      (ScrumTracePath.fullTranscript, Self.baselineTranscript)] {
            if (try? fileSize(original, in: stage)) != nil {
                _ = try copy(original, from: stage, to: baseline, in: stage, replace: true)
            }
        }
        if scope == .evidence {
            // A projection's paths are export-relative. Keep that coordinate system; the existing
            // ExportRel accessor resolves it. Full reprocessing is disabled for evidence-only imports.
            manifest.completedStages = []
        }
        try write(try Self.encoder().encode(manifest), to: ScrumTracePath.manifest, in: stage, replace: true)
        try updateTranscriptID(in: stage, id: localID)
        try SessionTransferReviewReport.writeIfItFits(manifest: manifest, sessionURL: stage)
        try install(stage, at: vault.sessionURL(id: localID))
        return localID
    }

    /// Preserve the imported session and its prior results. Only the newly created copy is processed.
    func analysisCopy(id: String, retranscribe: Bool, progress: Progress = { _, _ in }) throws -> String {
        try rejectLiveRecording(id)
        let source = vault.sessionURL(id: id)
        var manifest = try vault.loadManifest(id: id)
        let assessment = SessionTransferAssessment.load(vault: vault, id: id)
        guard manifest.importOrigin?.scope != .evidence,
              retranscribe ? assessment.hasRecording : (assessment.hasRecording || assessment.hasTimedTranscript) else {
            throw SessionTransferError.missingSources
        }
        let paths = try inventory(source, excludingTopLevel: [CodexWorkspace.directoryName, CodexWorkspace.privateArchiveDirectoryName])
            .filter(Self.isSessionPath)
        try ensureSpace(paths: paths, source: source, destination: vault.rootURL)
        let stage = try makeStage(in: vault.rootURL)
        defer { ExportRel.removeOwnedSessionFolder(sessionURL: stage, sessionsRoot: vault.rootURL) }
        for (number, path) in paths.enumerated() {
            try Task.checkCancellation()
            _ = try copy(path, from: source, to: path, in: stage)
            progress(number + 1, paths.count)
        }
        try write(try Self.encoder().encode(manifest), to: Self.baselineManifest, in: stage, replace: true)
        for (original, baseline) in [(ScrumTracePath.pipelineTiming, Self.baselineTiming),
                                      (ScrumTracePath.fullTranscript, Self.baselineTranscript)] {
            if (try? fileSize(original, in: stage)) != nil {
                _ = try copy(original, from: stage, to: baseline, in: stage, replace: true)
            }
        }
        let localID = vault.makeSessionID()
        let previous = manifest.importOrigin
        manifest.sessionId = localID
        manifest.uploadConsent = .denied
        manifest.importOrigin = .init(
            kind: .analysisCopy, originalSessionID: previous?.originalSessionID ?? id, importedAt: Date(),
            exportedFrom: previous?.exportedFrom, transferID: previous?.transferID ?? UUID().uuidString.lowercased(),
            scope: .complete, integrityVerified: previous?.integrityVerified ?? false, parentSessionID: id
        )
        manifest.importOrigin?.retranscribed = retranscribe
        manifest.tasks = []
        manifest.completedStages.removeAll { retranscribe || [.evaluating, .synthesizing, .completed].contains($0) }
        for i in manifest.slices.indices {
            manifest.slices[i].analysisStatus = .pending
            manifest.slices[i].serviceEvaluations = []
        }
        if retranscribe {
            manifest.slices = []
            for path in [ScrumTracePath.fullTranscript, TranscriptionRunStore.primaryPath, ScrumTracePath.pipelineTiming] {
                if ExportRel.existingSessionFile(path, sessionURL: stage) != nil {
                    try ExportRel.removeItemIfRegularFile(stage.appendingPathComponent(path), sessionRoot: stage)
                }
            }
        }
        manifest.pipelineStatus = manifest.hasCompleted(.transcribing) ? .evaluating : .transcribing
        try write(try Self.encoder().encode(manifest), to: ScrumTracePath.manifest, in: stage, replace: true)
        try updateTranscriptID(in: stage, id: localID)
        try SessionTransferReviewReport.writeIfItFits(manifest: manifest, sessionURL: stage)
        try install(stage, at: vault.sessionURL(id: localID))
        return localID
    }

    private func updateTranscriptID(in root: URL, id: String) throws {
        if var transcript = SpeakerTimeline.load(sessionURL: root) {
            transcript.sessionId = id
            try SpeakerTimeline.save(transcript, sessionURL: root)
        }
    }

    private func rejectLiveRecording(_ id: String) throws {
        if AgentLog.liveRecordingLock()?.sessionId == id { throw SessionTransferError.busy }
    }

    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024,
              let parts = ExportRel.normalizedComponents(path),
              parts.joined(separator: "/") == path, parts.count <= 16,
              parts.allSatisfy({ !$0.hasPrefix(".") && !$0.contains(":")
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { return false }
        return true
    }

    static func isSessionPath(_ path: String) -> Bool {
        isSafePath(path) && (path == ScrumTracePath.manifest || path.hasPrefix("archive/") || path.hasPrefix("export/"))
    }

    static func isEvidencePath(_ path: String) -> Bool {
        guard isSafePath(path) else { return false }
        if ["session.manifest.json", "SESSION_BRIEF.html", "AGENT_CONTEXT.md", "AGENT_PROMPT.txt",
            "OMITTED.md", "full_transcript.json", "session-pack.zip", "COMPARISON.md", "TRANSFER_REVIEW.md"].contains(path) { return true }
        return (path.hasPrefix("shots/") || path.hasPrefix("media/"))
            && ["png", "jpg", "jpeg", "mp4", "json", "txt"].contains((path as NSString).pathExtension.lowercased())
    }

    private func inventory(_ root: URL, excludingTopLevel: Set<String> = []) throws -> [String] {
        guard ExportRel.unfollowedDirectoryURL(root) != nil else { throw SessionTransferError.invalidPackage }
        var result: [String] = []
        func walk(_ relative: String, depth: Int) throws {
            guard depth <= 16 else { throw SessionTransferError.unsafePath }
            let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
            let items = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            for name in items.sorted() {
                if name == ".DS_Store" { continue }
                // Agent workspaces are derived copies and may contain agent-created files.
                // Canonical export / reanalysis never traverses them. Import remains strict.
                if relative.isEmpty, excludingTopLevel.contains(name) { continue }
                let path = relative.isEmpty ? name : relative + "/" + name
                guard Self.isSafePath(path) else { throw SessionTransferError.unsafePath }
                let url = root.appendingPathComponent(path)
                var info = stat()
                guard url.withUnsafeFileSystemRepresentation({ $0.map { Darwin.lstat($0, &info) } ?? -1 }) == 0 else {
                    throw SessionTransferError.unsafePath
                }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    // Open every parent without following links before descending.
                    let fd = try openFile(path, in: root, directory: true)
                    Darwin.close(fd)
                    try walk(path, depth: depth + 1)
                case S_IFREG:
                    guard info.st_nlink == 1 else { throw SessionTransferError.unsafePath }
                    result.append(path)
                    guard result.count <= Self.maximumFiles else { throw SessionTransferError.invalidPackage }
                default: throw SessionTransferError.unsafePath
                }
            }
        }
        try walk("", depth: 0)
        return result
    }

    private func openFile(_ path: String, in root: URL, directory: Bool = false) throws -> Int32 {
        guard Self.isSafePath(path) else { throw SessionTransferError.unsafePath }
        var fd = root.withUnsafeFileSystemRepresentation {
            $0.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard fd >= 0 else { throw SessionTransferError.unsafePath }
        let parts = path.split(separator: "/")
        for (number, part) in parts.enumerated() {
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                | ((number < parts.count - 1 || directory) ? O_DIRECTORY : 0)
            let next = String(part).withCString { Darwin.openat(fd, $0, flags) }
            Darwin.close(fd)
            guard next >= 0 else { throw SessionTransferError.unsafePath }
            fd = next
        }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else {
            Darwin.close(fd)
            throw SessionTransferError.unsafePath
        }
        return fd
    }

    private func read(_ path: String, in root: URL) throws -> Data {
        let handle = FileHandle(fileDescriptor: try openFile(path, in: root), closeOnDealloc: true)
        guard try fileSize(path, in: root) <= Self.metadataLimit else { throw SessionTransferError.invalidPackage }
        let data = try handle.read(upToCount: Self.metadataLimit + 1) ?? Data()
        guard data.count <= Self.metadataLimit else { throw SessionTransferError.invalidPackage }
        return data
    }

    private func fileSize(_ path: String, in root: URL) throws -> Int {
        let fd = try openFile(path, in: root)
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_size >= 0 else { throw SessionTransferError.invalidPackage }
        return Int(info.st_size)
    }

    private func copy(_ path: String, from source: URL, to target: String, in root: URL, replace: Bool = false) throws -> SessionTransferIndex.File {
        let fd = try openFile(path, in: source)
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat()
        guard Darwin.fstat(fd, &before) == 0 else { throw SessionTransferError.changedFile }
        let output = try create(target, in: root, replace: replace)
        defer { try? output.close() }
        var hasher = SHA256()
        var count = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            hasher.update(data: data)
            count += data.count
            guard count <= before.st_size else { throw SessionTransferError.changedFile }
        }
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0, count == before.st_size,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw SessionTransferError.changedFile }
        try output.synchronize()
        return .init(path: target, bytes: count, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func create(_ path: String, in root: URL, replace: Bool) throws -> FileHandle {
        guard Self.isSafePath(path), ExportRel.unfollowedDirectoryURL(root) != nil else { throw SessionTransferError.unsafePath }
        let parts = path.split(separator: "/").map(String.init)
        var fd = root.withUnsafeFileSystemRepresentation {
            $0.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard fd >= 0 else { throw SessionTransferError.unsafePath }
        for part in parts.dropLast() {
            _ = part.withCString { Darwin.mkdirat(fd, $0, 0o700) }
            let next = part.withCString { Darwin.openat(fd, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            Darwin.close(fd)
            guard next >= 0 else { throw SessionTransferError.unsafePath }
            fd = next
        }
        defer { Darwin.close(fd) }
        let name = parts.last!
        if replace { _ = name.withCString { Darwin.unlinkat(fd, $0, 0) } }
        let output = name.withCString { Darwin.openat(fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard output >= 0 else { throw SessionTransferError.copyFailed }
        return FileHandle(fileDescriptor: output, closeOnDealloc: true)
    }

    private func write(_ data: Data, to path: String, in root: URL, replace: Bool = false) throws {
        let output = try create(path, in: root, replace: replace)
        defer { try? output.close() }
        try output.write(contentsOf: data)
        try output.synchronize()
    }

    private func makeStage(in parent: URL) throws -> URL {
        guard ExportRel.unfollowedDirectoryURL(parent) != nil else { throw SessionTransferError.unsafePath }
        var template = Array(parent.appendingPathComponent("ScrumTrace-transfer-XXXXXX").path.utf8CString)
        guard template.withUnsafeMutableBufferPointer({ Darwin.mkdtemp($0.baseAddress!) != nil }) else {
            throw SessionTransferError.copyFailed
        }
        return URL(fileURLWithPath: String(cString: template), isDirectory: true)
    }

    private func install(_ stage: URL, at destination: URL) throws {
        try Task.checkCancellation()
        guard ExportRel.unfollowedDirectoryURL(destination.deletingLastPathComponent()) != nil else {
            throw SessionTransferError.unsafePath
        }
        let result = stage.path.withCString { src in
            destination.path.withCString { dst in Darwin.renamex_np(src, dst, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else {
            throw Darwin.errno == EEXIST ? SessionTransferError.destinationExists : SessionTransferError.copyFailed
        }
    }

    private func ensureSpace(paths: [String], source: URL, destination: URL) throws {
        var total = 0
        for path in paths {
            let size = try fileSize(path, in: source)
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { throw SessionTransferError.insufficientSpace }
            total = sum.partialValue
        }
        let free = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let required = Int64(total).addingReportingOverflow(64 * 1024 * 1024)
        if required.overflow || (free.map { $0 < required.partialValue } ?? false) {
            throw SessionTransferError.insufficientSpace
        }
    }

    private func diagnostics(for id: String) -> Data? {
        guard let data = try? Data(contentsOf: AgentLog.fileURL), data.count <= 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let rows = text.split(whereSeparator: \.isNewline).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
        }
        let runs = Set(rows.filter { $0["session"] == id }.compactMap { $0["run_id"] })
        let keys: Set<String> = ["ts", "event", "session", "run_id", "macos", "cdhash", "sign_id",
            "sign_kind", "adhoc", "screen_at_launch", "screen_now", "mic", "ax", "readiness",
            "status", "phase", "bytes", "omitted", "seconds", "frames", "samples", "reason"]
        var output = Data()
        for row in rows where row["session"] == id || (row["event"] == "launch" && runs.contains(row["run_id"] ?? "")) {
            let safe = row.filter { keys.contains($0.key) }
            if let encoded = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]) {
                output.append(encoded)
                output.append(10)
            }
        }
        return output
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Measured metadata only. Availability and counts do not assert transcript accuracy or hardware gates.
struct SessionTransferAssessment: Sendable, Equatable {
    var hasRecording = false
    var hasTimedTranscript = false
    var timedSegments = 0
    var missingEvidence = 0
    var sourceStatus: String?
    var currentStatus: String?
    var sourceWhisperSeconds: Double?
    var currentWhisperSeconds: Double?
    var sourceTaskCount: Int?
    var currentTaskCount = 0

    static func load(vault: SessionVault, id: String) -> SessionTransferAssessment {
        load(sessionURL: vault.sessionURL(id: id), manifest: try? vault.loadManifest(id: id))
    }

    static func load(sessionURL session: URL, manifest: SessionManifest?) -> SessionTransferAssessment {
        var result = SessionTransferAssessment()
        result.hasRecording = [ScrumTracePath.sessionMovie, ScrumTracePath.audioWav].contains {
            ExportRel.existingSessionFile($0, sessionURL: session) != nil
        }
        let transcript = SpeakerTimeline.load(sessionURL: session) ?? ExportRel.readContainedData(
            relative: "export/full_transcript.json", sessionURL: session
        ).flatMap { try? JSONDecoder().decode(FullTranscript.self, from: $0) }
        result.hasTimedTranscript = transcript?.hasTimedSegments ?? false
        result.timedSegments = transcript?.segments.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count ?? 0
        if let current = manifest {
            result.currentStatus = current.pipelineStatus.rawValue
            result.currentTaskCount = current.tasks.count
            let references = Set(current.tasks.flatMap(\.evidenceMedia))
            result.missingEvidence = references.filter {
                ExportRel.existingSessionFile(ExportRel.sessionPath($0), sessionURL: session) == nil
            }.count
        }
        if let data = ExportRel.readContainedData(relative: SessionTransfer.baselineManifest, sessionURL: session),
           let source = try? SessionTransfer.decoder().decode(SessionManifest.self, from: data) {
            result.sourceStatus = source.pipelineStatus.rawValue
            result.sourceTaskCount = source.tasks.count
        }
        if let data = ExportRel.readContainedData(relative: SessionTransfer.baselineTiming, sessionURL: session),
           let timing = try? JSONDecoder().decode(PipelineTiming.self, from: data) {
            result.sourceWhisperSeconds = timing.whisperWallSeconds
        }
        result.currentWhisperSeconds = PipelineTiming.load(sessionURL: session)?.whisperWallSeconds
        if let manifest,
           manifest.importOrigin?.kind == .analysisCopy,
           manifest.importOrigin?.retranscribed != true {
            result.currentWhisperSeconds = nil
        }
        return result
    }
}

/// Safe technical handoff for investigating the transfer and comparing measured outcomes.
/// No computer name, transcript, raw event payload, credential, or private path is included.
enum SessionTransferReviewReport {
    static let path = "export/TRANSFER_REVIEW.md"

    static func render(manifest: SessionManifest, sessionURL: URL) -> String? {
        guard let origin = manifest.importOrigin else { return nil }
        let facts = SessionTransferAssessment.load(sessionURL: sessionURL, manifest: manifest)
        func count(_ value: Int?) -> String { value.map(String.init) ?? "Not recorded" }
        func seconds(_ value: Double?) -> String {
            guard let value, value.isFinite, value >= 0 else { return "Not measured in this run" }
            return String(format: "%.2f s", value)
        }
        let status = origin.kind == .imported ? "Imported recording" : "Separate analysis copy"
        var lines = [
            "# Transfer review",
            "",
            "- Origin: \(status)",
            "- Contents: \(origin.scope.title)",
            "- Transfer consistency: \(origin.integrityVerified ? "all indexed files matched their SHA-256 checksums at import" : "legacy folder; source checksums unavailable")",
            "- Original capture media available here: \(facts.hasRecording ? "yes" : "no")",
            "- Timed transcript passages available: \(facts.timedSegments)",
            "- Missing referenced evidence files: \(facts.missingEvidence)",
            "",
            "## Recorded outcomes",
            "",
            "| Measurement | Before | Current |",
            "| --- | --- | --- |",
            "| Processing status | \(facts.sourceStatus ?? "Not recorded") | \(facts.currentStatus ?? "Not recorded") |",
            "| Task count | \(count(facts.sourceTaskCount)) | \(facts.currentTaskCount) |",
        ]
        if origin.kind == .analysisCopy {
            lines.append("| Transcription wall time | \(seconds(facts.sourceWhisperSeconds)) | \(seconds(facts.currentWhisperSeconds)) |")
        }
        lines += ["", "## What to investigate", ""]
        if facts.missingEvidence > 0 {
            lines.append("- Referenced evidence is missing. Recover the original package before treating those findings as confirmed.")
        }
        if !facts.hasRecording {
            lines.append("- Original media is unavailable. A new transcription or capture-quality check requires a complete transfer.")
        }
        if !facts.hasTimedTranscript {
            lines.append("- No usable timed transcript is available. Inspect the transcription stage before judging quote accuracy.")
        }
        if facts.currentStatus == PipelineStatus.offlineFailed.rawValue {
            lines.append("- Processing is incomplete. Review the failed stage and selected service before comparing final results.")
        }
        lines += [
            "", "## Limits", "",
            "Checksums establish transfer consistency, not the authenticity or correctness of the source data.",
            "An imported brief and its findings are the source Mac's saved results. Importing them is not a new analysis or an independent validation.",
            "More tasks do not establish higher quality. Review matched evidence and transcription errors before claiming an improvement.",
            "A speed comparison needs identical media, models and settings, and comparable warm-up conditions. A reused transcript has no new transcription timing.",
            "This report does not establish A/V drift, permission behavior on the source Mac, or any hardware-gate PASS.",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Import preserves the source export. A report is optional when it would exceed the
    /// existing 35 MB folder budget. Normal processing includes it before measuring its pack.
    static func writeIfItFits(manifest: SessionManifest, sessionURL: URL) throws {
        guard let text = render(manifest: manifest, sessionURL: sessionURL) else { return }
        let previous = ExportRel.regularFileByteCount(relative: path, sessionURL: sessionURL) ?? 0
        let current = PackBudget.exportFolderBytes(sessionURL: sessionURL)
        guard current - previous + text.utf8.count <= MediaBudget.maxZipBytes else { return }
        try ExportRel.writeExportText(text, relative: path, sessionURL: sessionURL)
    }
}
