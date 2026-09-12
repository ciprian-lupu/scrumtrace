import Foundation

enum ClaudeCLIHandoffError: LocalizedError, Equatable {
    case sessionUnusable
    case exportMissing
    case claudeMissing

    var errorDescription: String? {
        switch self {
        case .sessionUnusable:
            return "That session folder is not a usable export."
        case .exportMissing:
            return "This session has no export yet. Stop & process first."
        case .claudeMissing:
            return "Claude Code CLI is not installed, or the claude command is missing. Install Claude Code, then confirm `claude` runs in Terminal."
        }
    }
}

/// Opens the session export in an interactive Claude Code CLI Terminal.
/// Never points at archive/. Interactive only; no print-mode flag.
enum ClaudeCLIHandoff {
    static let documentRelatives = [
        ScrumTracePath.agentContext,
        ScrumTracePath.sessionBrief
    ]

    static let appleScriptSource = """
    on run argv
      set exportDir to item 1 of argv
      set claudeBin to item 2 of argv
      tell application "Terminal"
        activate
        do script "cd " & quoted form of exportDir & " && exec " & quoted form of claudeBin
      end tell
    end run
    """

    static func exportDirectory(sessionURL: URL) -> URL? {
        guard ExportRel.isUsableSessionRoot(sessionURL) else { return nil }
        if (try? sessionURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        if ExportRel.containsSymlinkComponent(ScrumTracePath.export, sessionURL: sessionURL) {
            return nil
        }
        let export = sessionURL.appendingPathComponent(ScrumTracePath.export, isDirectory: true)
        guard let revealed = ExportRel.unfollowedDirectoryURL(export),
              revealed.lastPathComponent == ScrumTracePath.export else {
            return nil
        }
        if (try? revealed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        let sessionRoot = sessionURL.standardizedFileURL
        guard revealed.deletingLastPathComponent().standardizedFileURL.path == sessionRoot.path else {
            return nil
        }
        if PackBudget.exportStillContainsSymlink(exportDir: export) {
            return nil
        }
        if revealed.pathComponents.contains("archive") {
            return nil
        }
        guard hasHandoffDocument(sessionURL: sessionURL) else { return nil }
        return revealed
    }

    static func invocation(exportDir: URL, claude: URL) -> (executable: URL, arguments: [String]) {
        (
            URL(fileURLWithPath: "/usr/bin/osascript"),
            ["-e", appleScriptSource, "--", exportDir.path, claude.path]
        )
    }

    static func open(sessionURL: URL) throws {
        guard let exportDir = exportDirectory(sessionURL: sessionURL) else {
            throw ClaudeCLIHandoffError.exportMissing
        }
        guard let claude = claudeExecutable() else {
            throw ClaudeCLIHandoffError.claudeMissing
        }
        let plan = invocation(exportDir: exportDir, claude: claude)
        #if os(macOS)
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        try process.run()
        #else
        throw ClaudeCLIHandoffError.claudeMissing
        #endif
    }

    static func claudeExecutable() -> URL? {
        var candidates: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append(
                    URL(fileURLWithPath: String(directory), isDirectory: true)
                        .appendingPathComponent("claude")
                )
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func hasHandoffDocument(sessionURL: URL) -> Bool {
        documentRelatives.contains { relative in
            guard ExportRel.isUnderExport(relative) else { return false }
            guard let contained = ExportRel.existingSessionFile(relative, sessionURL: sessionURL) else {
                return false
            }
            guard ExportRel.isUnderExport(contained) else { return false }
            let url = sessionURL.appendingPathComponent(contained)
            guard ExportRel.isReadableSessionFile(url, sessionRoot: sessionURL) else { return false }
            return !url.pathComponents.contains("archive")
        }
    }
}
