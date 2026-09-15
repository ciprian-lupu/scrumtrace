import XCTest
@testable import ScrumTrace

final class CodexHandoffTests: XCTestCase {
    private func withSession(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("scrumtrace-codex-\(UUID().uuidString)", isDirectory: true)
        let session = parent.appendingPathComponent("Session + & = # ' î", isDirectory: true)
        let export = session.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("# Synthetic context\n".utf8).write(to: export.appendingPathComponent("AGENT_CONTEXT.md"))
        try body(session)
    }

    private func writeConsent(_ value: Bool, omitted: Bool = false, session: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "include_full_transcript_in_zip": value,
            "omitted": omitted ? [["path": "full_transcript.json", "reason": "pack_budget"]] : []
        ])
        try data.write(to: session.appendingPathComponent("export/session.manifest.json"))
    }

    func testDesktopLinkUsesANamedExportWorkspaceAndOnlyPrefillsThePrompt() throws {
        try withSession { session in
            let link = try CodexAppHandoff.link(sessionURL: session)
            let parts = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.scheme, "codex")
            XCTAssertEqual(parts.host, "threads")
            XCTAssertEqual(parts.path, "/new")
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(Set(query.keys), ["path", "prompt"])
            let workspace = URL(fileURLWithPath: try XCTUnwrap(query["path"]))
            XCTAssertTrue(workspace.lastPathComponent.hasPrefix("ScrumTrace - Recording - "))
            XCTAssertEqual(workspace.deletingLastPathComponent().standardizedFileURL.path,
                           session.appendingPathComponent(CodexWorkspace.directoryName).standardizedFileURL.path)
            XCTAssertEqual(query["prompt"], CodexWorkspace.prompt(workspace: workspace))
            XCTAssertTrue(query["prompt"]?.contains("Read export/AGENT_CONTEXT.md first") == true)
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("export/AGENT_CONTEXT.md")),
                           try Data(contentsOf: session.appendingPathComponent("export/AGENT_CONTEXT.md")))
            XCTAssertTrue(link.absoluteString.contains("%2B"), "A plus in a path must survive URLSearchParams decoding")
            XCTAssertFalse(link.absoluteString.contains("/archive"))
            XCTAssertFalse(link.absoluteString.contains("submit"))
        }
    }

    @MainActor
    func testDesktopOpenValidatesTheExportBeforeInvokingTheApplication() throws {
        try withSession { session in
            var opened: [URL] = []
            try CodexAppHandoff.open(sessionURL: session, applicationForURL: { _ in
                URL(fileURLWithPath: "/Applications/Codex.app")
            }, openURL: { opened.append($0); return true })
            XCTAssertEqual(opened, [try CodexAppHandoff.link(sessionURL: session)])

            let export = session.appendingPathComponent("export")
            let archive = session.appendingPathComponent("archive")
            try FileManager.default.moveItem(at: export, to: archive)
            try FileManager.default.createSymbolicLink(at: export, withDestinationURL: archive)
            var resolved = false
            XCTAssertThrowsError(try CodexAppHandoff.open(sessionURL: session, applicationForURL: { _ in
                resolved = true
                return URL(fileURLWithPath: "/Applications/Codex.app")
            }, openURL: { opened.append($0); return true })) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .exportMissing)
            }
            XCTAssertFalse(resolved)
            XCTAssertEqual(opened.count, 1)
        }
    }

    @MainActor
    func testDesktopErrorsExplainTheSelectedDestinationWithoutLaunchingATerminalFallback() throws {
        try withSession { session in
            var attemptedOpen = false
            XCTAssertThrowsError(try CodexAppHandoff.open(sessionURL: session, applicationForURL: { _ in nil },
                                                        openURL: { _ in attemptedOpen = true; return true })) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .codexAppMissing)
            }
            XCTAssertFalse(attemptedOpen)
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent(CodexWorkspace.directoryName).path))
            XCTAssertThrowsError(try CodexAppHandoff.open(sessionURL: session, applicationForURL: { _ in
                URL(fileURLWithPath: "/Applications/Codex.app")
            }, openURL: { _ in false })) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .codexAppLaunchFailed)
            }
        }
    }

    @MainActor
    func testSavedPreferenceRoutesAllCodexActionsAndLeavesClaudeInTerminal() throws {
        let suite = "ScrumTrace.CodexDestination.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try withSession { root in
            AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
            defer {
                AgentLog.setFileURLForTesting(nil)
                defaults.removePersistentDomain(forName: suite)
            }
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            XCTAssertEqual(settings.codexHandoffDestination, .app)
            settings.codexHandoffDestination = .terminal
            let restored = AppSettings(defaults: defaults, keyStore: .empty)
            XCTAssertEqual(restored.codexHandoffDestination, .terminal)
            let controller = SessionController(settings: restored, vault: SessionVault(rootURL: root))
            let id = "20260101-codex"
            controller.lastSessionId = id
            var destinations: [String] = []
            controller.openAgentExport = { _, sessionId, cli, destination in
                XCTAssertEqual(sessionId, id)
                destinations.append("\(cli.rawValue)/\(destination.rawValue)")
            }
            controller.openInChatGPT()
            restored.codexHandoffDestination = .app
            let dependencies = RecordingsDependencies.live(controller: controller, startRecording: {})
            XCTAssertNil(dependencies.openInCLI(.chatGPT, id), "Recording actions use the same preference as the menu")
            controller.openInClaude()
            XCTAssertEqual(destinations, ["chatgpt/terminal", "chatgpt/app", "claude/terminal"])

            controller.openAgentExport = { _, _, _, _ in throw ClaudeCLIHandoffError.terminalAutomationDenied }
            XCTAssertEqual(dependencies.openInCLI(.chatGPT, id), ClaudeCLIHandoffError.terminalAutomationDenied.localizedDescription)
            defaults.set("unsupported", forKey: "scrumtrace.codexHandoffDestination")
            XCTAssertEqual(AppSettings(defaults: defaults, keyStore: .empty).codexHandoffDestination, .app)
        }
    }

    func testFullTranscriptRequiresTheExportProjectionOptInForBothDestinations() throws {
        try withSession { session in
            let transcript = session.appendingPathComponent("export/full_transcript.json")
            try Data("{\"text\":\"synthetic private fixture\"}".utf8).write(to: transcript)
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
            try writeConsent(false, session: session)
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
            try writeConsent(true, session: session)
            XCTAssertNotNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
            XCTAssertNoThrow(try CodexAppHandoff.link(sessionURL: session))
            try writeConsent(true, omitted: true, session: session)
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))

            let manifest = session.appendingPathComponent("export/session.manifest.json")
            try Data("{broken".utf8).write(to: manifest)
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
            try writeConsent(true, session: session)
            let source = session.appendingPathComponent("source-consent.json")
            try FileManager.default.moveItem(at: manifest, to: source)
            try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: source)
            XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
        }
    }

    func testTranscriptConsentNeverAllowsRawArchiveMedia() throws {
        try withSession { session in
            try writeConsent(true, session: session)
            for name in ["session.mp4", "audio.wav"] {
                let raw = session.appendingPathComponent("export").appendingPathComponent(name)
                try Data("synthetic private fixture".utf8).write(to: raw)
                XCTAssertNil(ClaudeCLIHandoff.exportDirectory(sessionURL: session))
                XCTAssertThrowsError(try CodexAppHandoff.link(sessionURL: session))
                try FileManager.default.removeItem(at: raw)
            }
        }
    }

    func testTerminalFailuresKeepRawDiagnosticsOutOfTheUserMessageAndLogReason() {
        for code in ["-1743", "-10004"] {
            let error = ClaudeCLIHandoffError.terminalFailure(stderr: "private-path: execution error (\(code))")
            XCTAssertEqual(error, .terminalAutomationDenied)
            XCTAssertFalse(error.localizedDescription.contains("private-path"))
            XCTAssertEqual(error.logReason, "terminal_automation_denied")
        }
        let other = ClaudeCLIHandoffError.terminalFailure(stderr: "private-path: error (-67034)")
        XCTAssertEqual(other, .launchFailed)
        XCTAssertTrue(other.localizedDescription.contains("reopen"))
        XCTAssertFalse(other.localizedDescription.contains("private-path"))
    }

    func testTerminalAppleScriptCompilesWithTheInstalledTerminalDictionary() throws {
        try withSession { session in
            let source = session.appendingPathComponent("handoff.applescript")
            try ClaudeCLIHandoff.appleScriptSource.write(to: source, atomically: true, encoding: .utf8)
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", session.appendingPathComponent("handoff.scpt").path, source.path]
            process.standardError = errors
            try process.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        }
    }
}
