import XCTest
@testable import ScrumTrace

final class ClaudeCLIHandoffTests: XCTestCase {
    private func withSession(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrumtrace-claude-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func writeHandoff(at session: URL) throws {
        let export = session.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Data("# ctx\n".utf8).write(to: export.appendingPathComponent("AGENT_CONTEXT.md"))
        try Data("<html></html>".utf8).write(to: export.appendingPathComponent("SESSION_BRIEF.html"))
    }

    func testExportDirectoryReturnsExportWhenDocumentsExist() throws {
        try withSession { session in
            try writeHandoff(at: session)
            let export = try XCTUnwrap(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
            XCTAssertEqual(export.lastPathComponent, ScrumTracePath.export)
            XCTAssertFalse(export.pathComponents.contains("archive"))
            XCTAssertEqual(
                export.deletingLastPathComponent().standardizedFileURL.path,
                session.standardizedFileURL.path
            )
        }
    }

    func testExportDirectoryRequiresAgentContextNotBriefAlone() throws {
        try withSession { session in
            let export = session.appendingPathComponent("export", isDirectory: true)
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: export.appendingPathComponent("SESSION_BRIEF.html"))
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
            try Data("# ctx\n".utf8).write(to: export.appendingPathComponent("AGENT_CONTEXT.md"))
            XCTAssertNotNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
        }
    }

    func testClaudeArgumentsAreInteractiveAndNeverArchiveOrPrintMode() {
        let argv = ClaudeCLIHandoff.claudeArguments(executable: URL(fileURLWithPath: "/usr/local/bin/claude"))
        XCTAssertEqual(argv.first, "claude")
        XCTAssertEqual(argv.dropFirst(), [ClaudeCLIHandoff.startupPrompt])
        XCTAssertTrue(ClaudeCLIHandoff.startupPrompt.contains("AGENT_CONTEXT.md first"))
        XCTAssertFalse(argv.contains("-p"))
        XCTAssertFalse(argv.contains("--print"))
        XCTAssertFalse(argv.contains(where: { $0.contains("archive") }))
        XCTAssertFalse(ClaudeCLIHandoff.startupPrompt.contains("-p"))
    }

    func testExportDirectoryRequiresAHandoffDocument() throws {
        try withSession { session in
            try FileManager.default.createDirectory(
                at: session.appendingPathComponent("export", isDirectory: true),
                withIntermediateDirectories: true
            )
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
        }
    }

    func testExportDirectoryRefusesExportSymlink() throws {
        try withSession { session in
            let archive = session.appendingPathComponent("archive", isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: archive.appendingPathComponent("session.mp4"))
            try FileManager.default.createSymbolicLink(
                at: session.appendingPathComponent("export"),
                withDestinationURL: archive
            )
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
        }
    }

    func testExportDirectoryRefusesSessionSymlink() throws {
        try withSession { real in
            try writeHandoff(at: real)
            let parent = real.deletingLastPathComponent()
            let alias = parent.appendingPathComponent("claude-cli-session-alias-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
            defer { try? FileManager.default.removeItem(at: alias) }
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: alias))
        }
    }

    func testExportDirectoryRefusesDocumentSymlinkIntoArchive() throws {
        try withSession { session in
            let export = session.appendingPathComponent("export", isDirectory: true)
            let archive = session.appendingPathComponent("archive", isDirectory: true)
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            let secret = archive.appendingPathComponent("full_transcript.json")
            try Data("do-not-open".utf8).write(to: secret)
            try FileManager.default.createSymbolicLink(
                at: export.appendingPathComponent("AGENT_CONTEXT.md"),
                withDestinationURL: secret
            )
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
        }
    }

    func testInvocationReexecsThisBinaryAndNeverCdsByPath() throws {
        let executable = URL(fileURLWithPath: "/Applications/ScrumTrace.app/Contents/MacOS/ScrumTrace")
        let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
        let sessionId = "20260101-abcdef"
        let plan = ClaudeCLIHandoff.invocation(executable: executable, sessionId: sessionId, claude: claude)
        XCTAssertEqual(plan.executable.path, "/usr/bin/osascript")
        XCTAssertEqual(plan.arguments.first, "-e")
        XCTAssertTrue(plan.arguments.contains("--"))
        XCTAssertTrue(ClaudeCLIHandoff.appleScriptSource.contains("quoted form of"))
        XCTAssertTrue(ClaudeCLIHandoff.appleScriptSource.contains("tell application \"Terminal\""))
        XCTAssertTrue(ClaudeCLIHandoff.appleScriptSource.contains(ClaudeCLIHandoff.execFlag))
        XCTAssertFalse(ClaudeCLIHandoff.appleScriptSource.contains("cd "))
        XCTAssertFalse(ClaudeCLIHandoff.appleScriptSource.contains(" -p"))
        XCTAssertFalse(ClaudeCLIHandoff.appleScriptSource.contains("--print"))
        XCTAssertFalse(ClaudeCLIHandoff.appleScriptSource.contains("archive"))
        guard let dash = plan.arguments.firstIndex(of: "--") else {
            return XCTFail("osascript argv must be passed after --")
        }
        let forwarded = Array(plan.arguments[(dash + 1)...])
        XCTAssertEqual(
            forwarded,
            [executable.path, ClaudeCLIHandoff.execFlag, sessionId, LocalCodingCLI.claude.rawValue, claude.path]
        )
        XCTAssertFalse(forwarded.contains(where: { $0.contains("/export") }))
        XCTAssertFalse(forwarded.contains(where: { $0.split(separator: "/").contains("archive") }))
    }

    func testChatGPTInvocationUsesCodexAndNeverExecOrPrintMode() {
        let executable = URL(fileURLWithPath: "/Applications/ScrumTrace.app/Contents/MacOS/ScrumTrace")
        let codex = URL(fileURLWithPath: "/usr/local/bin/codex")
        let sessionId = "20260101-abcdef"
        let plan = ClaudeCLIHandoff.invocation(
            executable: executable,
            sessionId: sessionId,
            cli: .chatGPT,
            binary: codex
        )
        guard let dash = plan.arguments.firstIndex(of: "--") else {
            return XCTFail("osascript argv must be passed after --")
        }
        let forwarded = Array(plan.arguments[(dash + 1)...])
        XCTAssertEqual(
            forwarded,
            [executable.path, ClaudeCLIHandoff.execFlag, sessionId, LocalCodingCLI.chatGPT.rawValue, codex.path]
        )
        let argv = ClaudeCLIHandoff.cliArguments(executable: codex, cli: .chatGPT)
        XCTAssertEqual(argv, ["codex", ClaudeCLIHandoff.startupPrompt])
        XCTAssertFalse(argv.contains("exec"))
        XCTAssertFalse(argv.contains("-p"))
        XCTAssertTrue(ClaudeCLIHandoff.isAllowedExecutable(codex, cli: .chatGPT))
        XCTAssertFalse(
            ClaudeCLIHandoff.isAllowedExecutable(URL(fileURLWithPath: "/usr/bin/yes"), cli: .chatGPT)
        )
        XCTAssertFalse(
            ClaudeCLIHandoff.isAllowedExecutable(URL(fileURLWithPath: "/usr/local/bin/claude"), cli: .chatGPT)
        )
    }

    func testOpenValidatedExportFdFailsAfterExportIsSwappedForArchiveLink() throws {
        try withSession { session in
            try writeHandoff(at: session)
            let first = ClaudeCLIHandoff.openValidatedExportFd(sessionURL: session)
            XCTAssertNotNil(first)
            if let first { ExportRel.closeDescriptor(first) }
            let export = session.appendingPathComponent("export")
            let archive = session.appendingPathComponent("archive", isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: archive.appendingPathComponent("session.mp4"))
            try FileManager.default.removeItem(at: export)
            try FileManager.default.createSymbolicLink(at: export, withDestinationURL: archive)
            XCTAssertNil(ClaudeCLIHandoff.openValidatedExportFd(sessionURL: session))
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
        }
    }

    func testVaultRefusesInvalidSessionId() throws {
        try withSession { root in
            let vault = SessionVault(rootURL: root)
            XCTAssertThrowsError(try vault.openExportInClaude(sessionId: "../escape")) { error in
                guard let handoff = error as? ClaudeCLIHandoffError else {
                    return XCTFail("expected ClaudeCLIHandoffError")
                }
                XCTAssertEqual(handoff, .sessionUnusable)
            }
        }
    }

    @MainActor
    func testOpenInClaudeWithoutSessionSetsStatus() throws {
        let id = "ScrumTrace.ClaudeCLI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionController(
            settings: AppSettings(defaults: defaults, keyStore: .empty),
            vault: SessionVault(rootURL: root)
        )
        controller.openInClaude()
        XCTAssertEqual(controller.statusLine, "No session to open in Claude.")
        controller.openInChatGPT()
        XCTAssertEqual(controller.statusLine, "No session to open in ChatGPT.")
    }

    @MainActor
    func testMenuExposesClaudeHandoff() throws {
        let id = "ScrumTrace.ClaudeCLIMenu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionController(
            settings: AppSettings(defaults: defaults, keyStore: .empty),
            vault: SessionVault(rootURL: root)
        )
        controller.lastSessionId = "20260101-abcdef"
        let menuBar = MenuBarController(controller: controller, openSettings: {}, openLogs: {})
        let menu = menuBar.menu
        menu.update()
        XCTAssertNotNil(menu.item(withTitle: "Open last session in Claude"))
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Open last session in Claude")).isEnabled)
        XCTAssertNotNil(menu.item(withTitle: "Open last session in ChatGPT"))
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Open last session in ChatGPT")).isEnabled)
        XCTAssertNil(menu.item(withTitle: "Open last session in Cursor"))
    }
}
