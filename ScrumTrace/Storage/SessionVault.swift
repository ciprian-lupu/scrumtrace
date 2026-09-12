#if os(macOS)
import AppKit
#endif
import Foundation

enum SessionVaultError: LocalizedError {
    case sessionMissing(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionMissing(let id):
            return "Session \(id) is not on disk."
        case .writeFailed(let path):
            return "Could not write \(path)."
        }
    }
}

/// Folder + manifest manager. `session.manifest.json` is the single source of truth.
final class SessionVault: @unchecked Sendable {
    let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let eventEncoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        self.rootURL = rootURL
            ?? movies.appendingPathComponent("ScrumTrace/sessions", isDirectory: true)
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let eventEncoder = JSONEncoder()
        eventEncoder.dateEncodingStrategy = .iso8601
        self.eventEncoder = eventEncoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func ensureRoot() throws {
        if !ExportRel.isUsableSessionRoot(rootURL) {
            throw SessionVaultError.writeFailed("sessions folder")
        }
        if rootURL.lastPathComponent == "sessions" {
            try ExportRel.ensureSessionsDirectory(sessionsURL: rootURL)
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        if !ExportRel.isUsableSessionRoot(rootURL) {
            throw SessionVaultError.writeFailed("sessions folder")
        }
    }

    func makeSessionID(now: Date = Date()) -> String {
        let stamp = Self.folderStamp.string(from: now)
        let suffix = String(UUID().uuidString.lowercased().prefix(6))
        return "\(stamp)-\(suffix)"
    }

    /// Session folder names are generated ids only. Reject `..` / `/` so Recent
    /// and Retry cannot walk out of `Movies/ScrumTrace/sessions`.
    static func isValidSessionId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 96 else { return false }
        if trimmed.hasPrefix(".") || trimmed.contains("..") { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    func sessionURL(id: String) -> URL {
        let safe = Self.isValidSessionId(id) ? id : "invalid-session-id"
        return rootURL.appendingPathComponent(safe, isDirectory: true)
    }

    func createSession(product: ProductContext) throws -> (url: URL, manifest: SessionManifest) {
        try ensureRoot()
        let id = makeSessionID()
        let url = sessionURL(id: id)
        guard ExportRel.isUsableSessionRoot(rootURL) else {
            throw SessionVaultError.writeFailed("sessions folder")
        }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        try ExportRel.ensureOwnedSessionDirectory(sessionURL: url, sessionsRoot: rootURL)
        // Re-check the sessions folder. mkdirat still needs the parent to stay
        // a real directory (`sessions` → `/tmp` between ensureRoot and create).
        guard ExportRel.isUsableSessionRoot(rootURL) else {
            throw SessionVaultError.writeFailed("sessions folder")
        }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        guard ExportRel.isUsableSessionRoot(url) else {
            throw SessionVaultError.writeFailed("session folder")
        }
        do {
            for folder in [
                ScrumTracePath.archive,
                ScrumTracePath.export,
                ScrumTracePath.shots,
                ScrumTracePath.exportShots,
                ScrumTracePath.media,
                ScrumTracePath.mediaWork
            ] {
                let dest = url.appendingPathComponent(folder)
                if (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    try ExportRel.removeItemIfRegularFile(dest, sessionRoot: url)
                }
                try ExportRel.ensureContainedDirectories(relative: folder, sessionURL: url)
            }
            var manifest = SessionManifest.makeNew(sessionId: id, product: product)
            try write(manifest: &manifest)
            return (url, manifest)
        } catch {
            // Do not `FileManager.removeItem` — a TOCTOU swap of `<id>` for a
            // symlink would delete the target. renameat + O_NOFOLLOW wipe.
            if ExportRel.isUsableSessionRoot(rootURL),
               (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                ExportRel.removeOwnedSessionFolder(sessionURL: url, sessionsRoot: rootURL)
            }
            throw error
        }
    }

    func loadManifest(id: String) throws -> SessionManifest {
        guard Self.isValidSessionId(id) else {
            throw SessionVaultError.sessionMissing(id)
        }
        guard ExportRel.isUsableSessionRoot(rootURL) else {
            throw SessionVaultError.sessionMissing(id)
        }
        let session = sessionURL(id: id)
        guard ExportRel.isUsableSessionRoot(session) else {
            throw SessionVaultError.sessionMissing(id)
        }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.sessionMissing(id)
        }
        guard ExportRel.existingSessionFile(ScrumTracePath.manifest, sessionURL: session) != nil else {
            throw SessionVaultError.sessionMissing(id)
        }
        guard let data = ExportRel.readContainedData(
            relative: ScrumTracePath.manifest,
            sessionURL: session
        ) else {
            throw SessionVaultError.sessionMissing(id)
        }
        return try decoder.decode(SessionManifest.self, from: data)
    }

    func write(manifest: inout SessionManifest) throws {
        guard Self.isValidSessionId(manifest.sessionId) else {
            throw SessionVaultError.writeFailed("invalid session id")
        }
        guard ExportRel.isUsableSessionRoot(rootURL) else {
            throw SessionVaultError.writeFailed("sessions folder")
        }
        let dir = sessionURL(id: manifest.sessionId)
        guard ExportRel.isUsableSessionRoot(dir) else {
            throw SessionVaultError.writeFailed("session folder")
        }
        if (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        try ExportRel.ensureOwnedSessionDirectory(sessionURL: dir, sessionsRoot: rootURL)
        guard ExportRel.isUsableSessionRoot(rootURL) else {
            throw SessionVaultError.writeFailed("sessions folder")
        }
        guard ExportRel.isUsableSessionRoot(dir) else {
            throw SessionVaultError.writeFailed("session folder")
        }
        if (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        let data = try encoder.encode(manifest)
        try ExportRel.writeContainedData(
            data,
            relative: ScrumTracePath.manifest,
            sessionURL: dir
        )
    }

    func appendEvent(_ event: SessionEvent, sessionId: String) throws {
        guard Self.isValidSessionId(sessionId) else {
            throw SessionVaultError.writeFailed("invalid session id")
        }
        guard ExportRel.isUsableSessionRoot(rootURL) else {
            throw SessionVaultError.writeFailed("sessions folder")
        }
        let session = sessionURL(id: sessionId)
        guard ExportRel.isUsableSessionRoot(session) else {
            throw SessionVaultError.writeFailed("session folder")
        }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        let url = session.appendingPathComponent(ScrumTracePath.events)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try ExportRel.removeItemIfRegularFile(url, sessionRoot: session)
        }
        guard ExportRel.containedRelative(ScrumTracePath.events, sessionURL: session) == ScrumTracePath.events else {
            throw SessionVaultError.writeFailed("events.jsonl")
        }
        _ = ExportRel.isContainedRegularFile(url, sessionRoot: session)
        var data = try eventEncoder.encode(event)
        data.append(contentsOf: [0x0A])
        try ExportRel.appendContainedData(data, relative: ScrumTracePath.events, sessionURL: session)
    }

    /// Real session-directory names only. `contentsOfDirectory(atPath:)` plus a
    /// later `isUsableSessionRoot` still briefly treats a planted `<id>` symlink
    /// as a candidate; skip those names here.
    private func listedSessionIds() -> [String] {
        guard ExportRel.isUsableSessionRoot(rootURL) else { return [] }
        let children = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        guard ExportRel.isUsableSessionRoot(rootURL) else { return [] }
        return children.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true {
                return nil
            }
            if values?.isDirectory == false {
                return nil
            }
            let id = url.lastPathComponent
            guard Self.isValidSessionId(id) else { return nil }
            return id
        }
    }

    func recentSessions(limit: Int = 12) -> [SessionManifest] {
        guard ExportRel.isUsableSessionRoot(rootURL) else { return [] }
        let loaded: [SessionManifest] = listedSessionIds().compactMap { id in
            try? loadManifest(id: id)
        }
        return Array(loaded.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func nextShotIndex(sessionId: String) -> Int {
        guard Self.isValidSessionId(sessionId) else { return 1 }
        guard ExportRel.isUsableSessionRoot(rootURL) else { return 1 }
        let session = sessionURL(id: sessionId)
        guard ExportRel.isUsableSessionRoot(session) else { return 1 }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return 1
        }
        let shots = session.appendingPathComponent(ScrumTracePath.shots)
        if ExportRel.containsSymlinkComponent(ScrumTracePath.shots, sessionURL: session) {
            return 1
        }
        if (try? shots.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return 1
        }
        let children = (try? fileManager.contentsOfDirectory(
            at: shots,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        if (try? shots.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return 1
        }
        let numbers = children.compactMap { url -> Int? in
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return nil
            }
            let childRel = "\(ScrumTracePath.shots)/\(url.lastPathComponent)"
            if ExportRel.containsSymlinkComponent(childRel, sessionURL: session) {
                return nil
            }
            let stem = url.deletingPathExtension().lastPathComponent
            let token = stem.split(separator: ".").first.map(String.init) ?? stem
            return Int(token)
        }
        return (numbers.max() ?? 0) + 1
    }

    func loadPinTimes(sessionId: String) -> [TimeInterval] {
        events(sessionId: sessionId).compactMap { event in
            guard event.kind == .pin else { return nil }
            return event.tMedia
        }
    }

    /// Finish-Shot sidecars can land while Whisper is running, after the
    /// processor's initial catalog load. Catalog write can also fail after
    /// the PNG and JSON are on disk (D7).
    func loadShotSidecars(sessionId: String) -> [ShotRecord] {
        guard Self.isValidSessionId(sessionId) else { return [] }
        guard ExportRel.isUsableSessionRoot(rootURL) else { return [] }
        let session = sessionURL(id: sessionId)
        guard ExportRel.isUsableSessionRoot(session) else { return [] }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return []
        }
        let shotsRel = ScrumTracePath.shots
        if ExportRel.containsSymlinkComponent(shotsRel, sessionURL: session) {
            return []
        }
        let shots = session.appendingPathComponent(shotsRel)
        if (try? shots.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return []
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: shots,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        if (try? shots.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return []
        }
        var records: [ShotRecord] = []
        for url in children {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            guard url.pathExtension.lowercased() == "json" else { continue }
            let childRel = "\(shotsRel)/\(url.lastPathComponent)"
            if ExportRel.containsSymlinkComponent(childRel, sessionURL: session) {
                continue
            }
            guard ExportRel.existingSessionFile(childRel, sessionURL: session) != nil,
                  let data = ExportRel.readContainedData(relative: childRel, sessionURL: session),
                  let shot = try? decoder.decode(ShotRecord.self, from: data),
                  !shot.id.isEmpty else {
                continue
            }
            guard Self.isArchiveShotPath(shot.rawPath) else { continue }
            if let annotated = shot.annotatedPath, !Self.isArchiveShotPath(annotated) {
                continue
            }
            records.append(shot)
        }
        return records.sorted { $0.id < $1.id }
    }

    private static func isArchiveShotPath(_ path: String) -> Bool {
        guard let parts = ExportRel.normalizedComponents(path), parts.count >= 3 else { return false }
        return parts[0] == "archive" && parts[1] == "shots"
    }

    func windowContext(sessionId: String, start: TimeInterval, end: TimeInterval) -> String {
        var lines: [String] = []
        for event in events(sessionId: sessionId) {
            guard event.tMedia >= start, event.tMedia <= end else { continue }
            switch event.kind {
            case .window, .url:
                let app = event.payload["app"] ?? ""
                let title = event.payload["title"] ?? ""
                let url = event.payload["url"] ?? ""
                lines.append("t_media=\(String(format: "%.1f", event.tMedia)) app=\(app) title=\(title) url=\(url)")
            case .start, .stop, .pause, .resume, .pin, .shot, .privacyPause, .error:
                continue
            }
        }
        return lines.joined(separator: "\n")
    }

    func pausesRebuiltFromEvents(sessionId: String) -> [PauseInterval] {
        PauseInterval.rebuild(from: events(sessionId: sessionId))
    }

    private func events(sessionId: String) -> [SessionEvent] {
        guard Self.isValidSessionId(sessionId) else { return [] }
        guard ExportRel.isUsableSessionRoot(rootURL) else { return [] }
        let session = sessionURL(id: sessionId)
        guard ExportRel.isUsableSessionRoot(session) else { return [] }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return []
        }
        let url = session.appendingPathComponent(ScrumTracePath.events)
        guard ExportRel.isContainedRegularFile(url, sessionRoot: session),
              ExportRel.isReadableSessionFile(url, sessionRoot: session),
              let data = ExportRel.readContainedData(relative: ScrumTracePath.events, sessionURL: session),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SessionEvent.self, from: data)
        }
    }

    func revealInFinder(sessionId: String) {
        #if os(macOS)
        guard Self.isValidSessionId(sessionId) else { return }
        guard ExportRel.isUsableSessionRoot(rootURL) else { return }
        let session = sessionURL(id: sessionId)
        guard ExportRel.isUsableSessionRoot(session) else { return }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return
        }
        if ExportRel.containsSymlinkComponent(ScrumTracePath.export, sessionURL: session) {
            return
        }
        let export = session.appendingPathComponent(ScrumTracePath.export)
        if (try? export.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return
        }
        // fileExists follows a planted export/ → archive/ link when
        // resourceValues fails. O_NOFOLLOW + F_GETPATH does not (C2, Gate 6).
        guard let revealed = ExportRel.unfollowedDirectoryURL(export) else { return }
        guard revealed.lastPathComponent == ScrumTracePath.export else { return }
        if (try? revealed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return
        }
        if ExportRel.containsSymlinkComponent(ScrumTracePath.export, sessionURL: session) {
            return
        }
        if PackBudget.exportStillContainsSymlink(exportDir: export) {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([revealed])
        #endif
    }

    func openExportInClaude(sessionId: String) throws {
        try openExportInLocalCLI(sessionId: sessionId, cli: .claude)
    }

    func openExportInChatGPT(sessionId: String) throws {
        try openExportInLocalCLI(sessionId: sessionId, cli: .chatGPT)
    }

    func openExportInLocalCLI(sessionId: String, cli: LocalCodingCLI) throws {
        guard Self.isValidSessionId(sessionId) else {
            throw ClaudeCLIHandoffError.sessionUnusable
        }
        guard ExportRel.isUsableSessionRoot(rootURL) else {
            throw ClaudeCLIHandoffError.sessionUnusable
        }
        let session = sessionURL(id: sessionId)
        guard ExportRel.isUsableSessionRoot(session) else {
            throw ClaudeCLIHandoffError.sessionUnusable
        }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ClaudeCLIHandoffError.sessionUnusable
        }
        try ClaudeCLIHandoff.open(sessionURL: session, sessionId: sessionId, cli: cli)
    }

    func revealRootInFinder() {
        #if os(macOS)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([rootURL])
        #endif
    }

    /// Completed sessions older than `days`. 0 means keep forever. Retryable
    /// and unfinished sessions are retained regardless of age.
    func pruneCompletedOlderThan(days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for manifest in recentSessions(limit: 500) where manifest.createdAt < cutoff {
            switch manifest.pipelineStatus {
            case .completed:
                removeAbandonedSession(id: manifest.sessionId)
            case .idle, .recording, .paused, .transcribing, .slicing, .evaluating, .synthesizing, .offlineFailed:
                continue
            }
        }
    }

    /// Capture never started. Do not leave an empty folder in Recent / Retry.
    /// Refuses a session-folder symlink so this cannot delete a planted target.
    func removeAbandonedSession(id: String) {
        guard Self.isValidSessionId(id) else { return }
        guard ExportRel.isUsableSessionRoot(rootURL) else { return }
        let session = sessionURL(id: id)
        guard ExportRel.isUsableSessionRoot(session) else { return }
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return
        }
        ExportRel.removeOwnedSessionFolder(sessionURL: session, sessionsRoot: rootURL)
    }

    /// Next launch: drop folders created for a Start that never captured
    /// (permission sheet, then Quit). Keep anything with a movie, WAV, or Shot.
    func pruneAbandonedStarts() {
        guard ExportRel.isUsableSessionRoot(rootURL) else { return }
        for id in listedSessionIds() {
            guard Self.isValidSessionId(id) else { continue }
            let session = sessionURL(id: id)
            guard ExportRel.isUsableSessionRoot(session) else { continue }
            if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            if ExportRel.existingSessionFile(ScrumTracePath.sessionMovie, sessionURL: session) != nil {
                continue
            }
            if ExportRel.existingSessionFile(ScrumTracePath.audioWav, sessionURL: session) != nil {
                continue
            }
            if archiveHasLiveCaptureResidue(session) {
                continue
            }
            guard let manifest = try? loadManifest(id: id) else {
                if archiveHasShotResidue(session) { continue }
                removeAbandonedSession(id: id)
                continue
            }
            guard manifest.pipelineStatus == .idle,
                  manifest.duration.mediaSeconds == 0,
                  manifest.shots.isEmpty else { continue }
            if archiveHasShotResidue(session) { continue }
            removeAbandonedSession(id: id)
        }
    }

    /// Catalog write can fail after PNG persist (`captureShot`). Missing or
    /// corrupt manifests must also keep a session that already holds Shot files.
    /// A planted `archive/shots` directory symlink is not residue.
    private func archiveHasShotResidue(_ session: URL) -> Bool {
        let shotsRel = ScrumTracePath.shots
        if ExportRel.containsSymlinkComponent(shotsRel, sessionURL: session) {
            return false
        }
        let shots = session.appendingPathComponent(shotsRel)
        if (try? shots.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: shots,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        if (try? shots.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }
        for url in children {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            let childRel = "\(shotsRel)/\(url.lastPathComponent)"
            if ExportRel.containsSymlinkComponent(childRel, sessionURL: session) {
                continue
            }
            if ExportRel.isContainedRegularFile(url, sessionRoot: session) {
                return true
            }
        }
        return false
    }

    /// A Start that created unique live capture files but crashed before
    /// `renameat` onto `session.mp4` / `audio.wav` is not an empty folder.
    private func archiveHasLiveCaptureResidue(_ session: URL) -> Bool {
        let archive = session.appendingPathComponent("archive")
        if (try? archive.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }
        if ExportRel.containsSymlinkComponent("archive", sessionURL: session) {
            return false
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: archive,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        if (try? archive.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }
        for url in children {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            let name = url.lastPathComponent
            guard name.hasPrefix("scrumtrace-live-") else { continue }
            if ExportRel.isContainedRegularFile(url, sessionRoot: session) {
                return true
            }
        }
        return false
    }

    private static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
