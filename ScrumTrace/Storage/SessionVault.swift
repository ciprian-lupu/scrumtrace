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
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
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
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        for folder in [
            ScrumTracePath.archive,
            ScrumTracePath.export,
            ScrumTracePath.shots,
            ScrumTracePath.exportShots,
            ScrumTracePath.media,
            ScrumTracePath.mediaWork
        ] {
            try fileManager.createDirectory(
                at: url.appendingPathComponent(folder),
                withIntermediateDirectories: true
            )
        }
        var manifest = SessionManifest.makeNew(sessionId: id, product: product)
        try write(manifest: &manifest)
        return (url, manifest)
    }

    func loadManifest(id: String) throws -> SessionManifest {
        guard Self.isValidSessionId(id) else {
            throw SessionVaultError.sessionMissing(id)
        }
        let session = sessionURL(id: id)
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.sessionMissing(id)
        }
        let url = session.appendingPathComponent(ScrumTracePath.manifest)
        guard ExportRel.isContainedRegularFile(url, sessionRoot: session) else {
            throw SessionVaultError.sessionMissing(id)
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(SessionManifest.self, from: data)
    }

    func write(manifest: inout SessionManifest) throws {
        guard Self.isValidSessionId(manifest.sessionId) else {
            throw SessionVaultError.writeFailed("invalid session id")
        }
        let dir = sessionURL(id: manifest.sessionId)
        if (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        let url = dir.appendingPathComponent(ScrumTracePath.manifest)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try fileManager.removeItem(at: url)
        }
        let tmp = url.appendingPathExtension("tmp")
        if (try? tmp.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try fileManager.removeItem(at: tmp)
        }
        let data = try encoder.encode(manifest)
        try data.write(to: tmp, options: .atomic)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try fileManager.removeItem(at: url)
        }
        try ExportRel.removeItemIfRegularFile(url, sessionRoot: dir)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try? fileManager.removeItem(at: tmp)
            throw SessionVaultError.writeFailed(ScrumTracePath.manifest)
        }
        do {
            try fileManager.moveItem(at: tmp, to: url)
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
        guard ExportRel.isContainedRegularFile(url, sessionRoot: dir) else {
            throw SessionVaultError.writeFailed(ScrumTracePath.manifest)
        }
    }

    func appendEvent(_ event: SessionEvent, sessionId: String) throws {
        guard Self.isValidSessionId(sessionId) else {
            throw SessionVaultError.writeFailed("invalid session id")
        }
        let session = sessionURL(id: sessionId)
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed("session folder")
        }
        let url = session.appendingPathComponent(ScrumTracePath.events)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try fileManager.removeItem(at: url)
        }
        guard ExportRel.containedRelative(ScrumTracePath.events, sessionURL: session) == ScrumTracePath.events else {
            throw SessionVaultError.writeFailed("events.jsonl")
        }
        var data = try eventEncoder.encode(event)
        data.append(contentsOf: [0x0A])
        if ExportRel.isContainedRegularFile(url, sessionRoot: session) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try ExportRel.writeContainedData(data, relative: ScrumTracePath.events, sessionURL: session)
        }
    }

    func recentSessions(limit: Int = 12) -> [SessionManifest] {
        guard let ids = try? fileManager.contentsOfDirectory(atPath: rootURL.path) else { return [] }
        let loaded: [SessionManifest] = ids.compactMap { id in
            guard Self.isValidSessionId(id) else { return nil }
            return try? loadManifest(id: id)
        }
        return Array(loaded.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func nextShotIndex(sessionId: String) -> Int {
        guard Self.isValidSessionId(sessionId) else { return 1 }
        let session = sessionURL(id: sessionId)
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
        let names = (try? fileManager.contentsOfDirectory(atPath: shots.path)) ?? []
        let numbers = names.compactMap { name -> Int? in
            let stem = (name as NSString).deletingPathExtension
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

    private func events(sessionId: String) -> [SessionEvent] {
        guard Self.isValidSessionId(sessionId) else { return [] }
        let session = sessionURL(id: sessionId)
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return []
        }
        let url = session.appendingPathComponent(ScrumTracePath.events)
        guard ExportRel.isContainedRegularFile(url, sessionRoot: session) else { return [] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SessionEvent.self, from: data)
        }
    }

    func revealInFinder(sessionId: String) {
        #if os(macOS)
        guard Self.isValidSessionId(sessionId) else { return }
        let session = sessionURL(id: sessionId)
        if (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return
        }
        let export = session.appendingPathComponent(ScrumTracePath.export)
        let values = try? export.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { return }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: export.path, isDirectory: &isDir), isDir.boolValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([export])
        #endif
    }

    private static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
