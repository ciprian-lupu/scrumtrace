import Foundation
#if os(macOS)
import AppKit
#endif

/// Append-only JSONL the Mac agent loop publishes for cloud-agent debugging.
/// Writes `~/Library/Logs/ScrumTrace/agent.jsonl`. No titles, URLs, notes, or keys.
enum AgentLog {
    static let directoryName = "ScrumTrace"
    private static let queue = DispatchQueue(label: "com.str8minds.ScrumTrace.agentlog")
    private static let maxBytes = 2_000_000

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(directoryName)", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("agent.jsonl")
    }

    static var recordingLockURL: URL {
        directoryURL.appendingPathComponent("recording.lock")
    }

    static func fields(_ extra: [String: String] = [:]) -> [String: String] {
        var merged = CapturePermissions.logFields()
        for (key, value) in extra {
            merged[key] = value
        }
        return merged
    }

    static func event(_ name: String, _ extra: [String: String] = [:]) {
        queue.async {
            writeLocked(name: name, fields: fields(extra))
        }
    }

    static func eventSync(_ name: String, _ extra: [String: String] = [:]) {
        queue.sync {
            writeLocked(name: name, fields: fields(extra))
        }
    }

    static func setRecording(_ active: Bool, sessionId: String?) {
        queue.async {
            if active {
                let body = "\(sessionId ?? "")\n\(ProcessInfo.processInfo.processIdentifier)\n"
                try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try? body.write(to: recordingLockURL, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: recordingLockURL)
            }
        }
    }

    static func readTail(maxLines: Int = 250) -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func exportDiagnosticBundle() throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let dest = directoryURL.appendingPathComponent(
            "scrumtrace-diagnostics-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).txt"
        )
        var parts: [String] = []
        parts.append("ScrumTrace diagnostic bundle")
        parts.append("paths are home-scrubbed. archive/ is never included.")
        parts.append(contentsOf: CapturePermissions.logFields().map { "\($0.key)=\($0.value)" }.sorted())
        parts.append("--- agent.jsonl ---")
        parts.append(readTail(maxLines: 4000))
        let ips = CapturePermissions.pendingCrashReportCount()
        parts.append("--- crash_ips_count=\(ips) ---")
        try parts.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    #if os(macOS)
    static func reveal() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
    #endif

    private static func writeLocked(name: String, fields: [String: String]) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var row = fields
        row["ts"] = ISO8601DateFormatter().string(from: Date())
        row["event"] = name
        row["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        guard JSONSerialization.isValidJSONObject(row),
              let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        NSLog("[ScrumTrace] %@ %@", name, line)
        rotateIfNeeded()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.synchronize()
        } catch {
            return
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxBytes
        else { return }
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(4_000).joined(separator: "\n") + "\n"
        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
