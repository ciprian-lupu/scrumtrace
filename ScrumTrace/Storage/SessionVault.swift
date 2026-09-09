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

    func sessionURL(id: String) -> URL {
        rootURL.appendingPathComponent(id, isDirectory: true)
    }

    func createSession(product: ProductContext) throws -> (url: URL, manifest: SessionManifest) {
        try ensureRoot()
        let id = makeSessionID()
        let url = sessionURL(id: id)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
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
        let url = sessionURL(id: id).appendingPathComponent(ScrumTracePath.manifest)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SessionVaultError.sessionMissing(id)
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(SessionManifest.self, from: data)
    }

    func write(manifest: inout SessionManifest) throws {
        let dir = sessionURL(id: manifest.sessionId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ScrumTracePath.manifest)
        let tmp = url.appendingPathExtension("tmp")
        let data = try encoder.encode(manifest)
        try data.write(to: tmp, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fileManager.moveItem(at: tmp, to: url)
        }
    }

    func appendEvent(_ event: SessionEvent, sessionId: String) throws {
        let url = sessionURL(id: sessionId).appendingPathComponent(ScrumTracePath.events)
        var data = try eventEncoder.encode(event)
        data.append(contentsOf: [0x0A])
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    func recentSessions(limit: Int = 12) -> [SessionManifest] {
        guard let ids = try? fileManager.contentsOfDirectory(atPath: rootURL.path) else { return [] }
        let loaded: [SessionManifest] = ids.compactMap { id in
            try? loadManifest(id: id)
        }
        return Array(loaded.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func nextShotIndex(sessionId: String) -> Int {
        let shots = sessionURL(id: sessionId).appendingPathComponent(ScrumTracePath.shots)
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
        let url = sessionURL(id: sessionId).appendingPathComponent(ScrumTracePath.events)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SessionEvent.self, from: data)
        }
    }

    func revealInFinder(sessionId: String) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([sessionURL(id: sessionId).appendingPathComponent(ScrumTracePath.export)])
        #endif
    }

    private static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
