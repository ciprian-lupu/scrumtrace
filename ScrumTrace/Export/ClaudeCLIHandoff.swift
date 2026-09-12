import Darwin
import Foundation

enum ClaudeCLIHandoffError: LocalizedError, Equatable {
    case sessionUnusable
    case exportMissing
    case claudeMissing
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .sessionUnusable:
            return "That session folder is not a usable export."
        case .exportMissing:
            return "This session has no export yet. Stop & process first."
        case .claudeMissing:
            return "Claude Code CLI is not installed, or the claude command is missing. Install Claude Code, then confirm `claude` runs in Terminal."
        case .launchFailed:
            return "Could not open Terminal to start Claude."
        }
    }
}

/// Opens the session export in an interactive Claude Code CLI Terminal.
/// Never points at archive/. Interactive only; no print-mode flag.
///
/// Terminal does not `cd` by path. It re-execs this binary with
/// `--claude-cli-exec`, which opens `export/` with `O_NOFOLLOW`, `fchdir`s
/// that fd, then `exec`s `claude` (C2).
enum ClaudeCLIHandoff {
    static let execFlag = "--claude-cli-exec"

    static let appleScriptSource = """
    on run argv
      set exe to item 1 of argv
      set flag to item 2 of argv
      set sessionId to item 3 of argv
      set claudeBin to item 4 of argv
      tell application "Terminal"
        activate
        do script (quoted form of exe & " " & quoted form of flag & " " & quoted form of sessionId & " " & quoted form of claudeBin)
      end tell
    end run
    """

    static func exportDirectory(sessionURL: URL) -> URL? {
        guard let fd = openValidatedExportFd(sessionURL: sessionURL) else { return nil }
        defer { ExportRel.closeDescriptor(fd) }
        return pathOfDirectoryFd(fd)
    }

    /// Caller closes. Nil if `export/` is missing, a symlink, or not a handoff.
    static func openValidatedExportFd(sessionURL: URL) -> Int32? {
        guard ExportRel.isUsableSessionRoot(sessionURL) else { return nil }
        if (try? sessionURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        if ExportRel.containsSymlinkComponent(ScrumTracePath.export, sessionURL: sessionURL) {
            return nil
        }
        let export = sessionURL.appendingPathComponent(ScrumTracePath.export, isDirectory: true)
        guard let fd = ExportRel.openUnfollowedDirectory(export) else { return nil }
        guard let revealed = pathOfDirectoryFd(fd),
              revealed.lastPathComponent == ScrumTracePath.export,
              revealed.deletingLastPathComponent().standardizedFileURL.path
                == sessionURL.standardizedFileURL.path else {
            ExportRel.closeDescriptor(fd)
            return nil
        }
        if PackBudget.exportStillContainsSymlink(exportDir: revealed) || exportFdLooksLikeArchive(fd) {
            ExportRel.closeDescriptor(fd)
            return nil
        }
        guard exportFdHasHandoffDocument(fd) else {
            ExportRel.closeDescriptor(fd)
            return nil
        }
        return fd
    }

    static func invocation(executable: URL, sessionId: String, claude: URL) -> (executable: URL, arguments: [String]) {
        (
            URL(fileURLWithPath: "/usr/bin/osascript"),
            ["-e", appleScriptSource, "--", executable.path, execFlag, sessionId, claude.path]
        )
    }

    static func open(sessionURL: URL, sessionId: String) throws {
        guard SessionVault.isValidSessionId(sessionId) else {
            throw ClaudeCLIHandoffError.sessionUnusable
        }
        if let fd = openValidatedExportFd(sessionURL: sessionURL) {
            ExportRel.closeDescriptor(fd)
        } else {
            throw ClaudeCLIHandoffError.exportMissing
        }
        guard let claude = claudeExecutable() else {
            throw ClaudeCLIHandoffError.claudeMissing
        }
        guard let executable = Bundle.main.executableURL else {
            throw ClaudeCLIHandoffError.launchFailed
        }
        let plan = invocation(executable: executable, sessionId: sessionId, claude: claude)
        #if os(macOS)
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClaudeCLIHandoffError.launchFailed
        }
        #else
        throw ClaudeCLIHandoffError.claudeMissing
        #endif
    }

    /// Used when Terminal re-launches this binary. `execv` does not return.
    @discardableResult
    static func tryExecFromArguments(_ arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: execFlag) else { return false }
        let sessionIndex = arguments.index(after: index)
        let claudeIndex = arguments.index(after: sessionIndex)
        guard sessionIndex < arguments.endIndex, claudeIndex < arguments.endIndex else {
            FileHandle.standardError.write(Data("ScrumTrace: missing Claude CLI exec arguments\n".utf8))
            exit(1)
        }
        let sessionId = arguments[sessionIndex]
        let claude = URL(fileURLWithPath: arguments[claudeIndex])
        do {
            try execReplacingCurrentProcess(sessionId: sessionId, claude: claude)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
        return true
    }

    static func execReplacingCurrentProcess(sessionId: String, claude: URL) throws {
        guard SessionVault.isValidSessionId(sessionId) else {
            throw ClaudeCLIHandoffError.sessionUnusable
        }
        let vault = SessionVault()
        let session = vault.sessionURL(id: sessionId)
        guard let fd = openValidatedExportFd(sessionURL: session) else {
            throw ClaudeCLIHandoffError.exportMissing
        }
        let bound = Darwin.fchdir(fd) == 0
        ExportRel.closeDescriptor(fd)
        guard bound else { throw ClaudeCLIHandoffError.sessionUnusable }
        guard FileManager.default.isExecutableFile(atPath: claude.path) else {
            throw ClaudeCLIHandoffError.claudeMissing
        }
        try claude.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr else { throw ClaudeCLIHandoffError.claudeMissing }
            let argv0 = strdup(ptr)
            var argv: [UnsafeMutablePointer<CChar>?] = [argv0, nil]
            Darwin.execv(ptr, &argv)
            if let argv0 { free(argv0) }
            throw ClaudeCLIHandoffError.claudeMissing
        }
    }

    static func claudeExecutable() -> URL? {
        var candidates: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/mise/shims/claude"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".asdf/shims/claude"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".volta/bin/claude")
        ]
        var searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extra = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")).path
        ]
        for directory in extra where !searchPath.split(separator: ":").map(String.init).contains(directory) {
            searchPath += ":" + directory
        }
        for directory in searchPath.split(separator: ":") {
            candidates.append(
                URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent("claude")
            )
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func pathOfDirectoryFd(_ fd: Int32) -> URL? {
        var pathBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let rc = pathBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.fcntl(fd, F_GETPATH, base)
        }
        guard rc == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: pathBuf), isDirectory: true)
    }

    private static func exportFdHasHandoffDocument(_ fd: Int32) -> Bool {
        ["AGENT_CONTEXT.md", "SESSION_BRIEF.html"].contains { name in
            isRegularFileAt(name, directoryFd: fd, minimumBytes: 1)
        }
    }

    private static func exportFdLooksLikeArchive(_ fd: Int32) -> Bool {
        ["session.mp4", "audio.wav", "full_transcript.json"].contains { name in
            isRegularFileAt(name, directoryFd: fd, minimumBytes: 0)
        }
    }

    private static func isRegularFileAt(_ name: String, directoryFd: Int32, minimumBytes: off_t) -> Bool {
        let child = name.withCString { Darwin.openat(directoryFd, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard child >= 0 else { return false }
        defer { Darwin.close(child) }
        var info = stat()
        guard Darwin.fstat(child, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_size >= minimumBytes
    }
}
