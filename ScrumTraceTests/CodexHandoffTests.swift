import XCTest
@testable import ScrumTrace

final class CodexHandoffTests: XCTestCase {
    private func withSession(_ body: (URL) throws -> Void) throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }
        try body(session)
    }

    private func makeSession() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("scrumtrace-codex-\(UUID().uuidString)", isDirectory: true)
        let session = parent.appendingPathComponent("Session + & = # ' î", isDirectory: true)
        let export = session.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Data("# Synthetic context\n".utf8).write(to: export.appendingPathComponent("AGENT_CONTEXT.md"))
        return session
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
            XCTAssertTrue(workspace.lastPathComponent.hasPrefix("Recording - "))
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

    func testArchiveAndExportLinksUseTheSameProjectWithDifferentSimpleTaskTitles() throws {
        try withSession { session in
            let archive = session.appendingPathComponent("archive")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try Data("private movie".utf8).write(to: archive.appendingPathComponent("session.mp4"))
            try Data("private transcript".utf8).write(to: archive.appendingPathComponent("full_transcript.json"))
            try Data("{}".utf8).write(to: session.appendingPathComponent("session.manifest.json"))

            let link = try CodexAppHandoff.privateArchiveLink(sessionURL: session)
            let parts = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let workspace = URL(fileURLWithPath: try XCTUnwrap(query["path"]))
            XCTAssertEqual(workspace.deletingLastPathComponent().lastPathComponent, CodexWorkspace.directoryName)
            XCTAssertTrue(query["prompt"]?.contains("Analyze archive") == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("source/archive/session.mp4").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("archive").path))
            let exportLink = try CodexAppHandoff.link(sessionURL: session)
            let exportQuery = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: exportLink, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(exportQuery["path"], query["path"])
            XCTAssertTrue(exportQuery["prompt"]?.contains("Analyze export") == true)
            XCTAssertNotEqual(exportQuery["prompt"], query["prompt"])
        }
    }

    @MainActor
    func testDesktopOpenValidatesTheExportBeforeInvokingTheApplication() throws {
        try withSession { session in
            var opened: [URL] = []
            try CodexAppHandoff.open(sessionURL: session, configureProject: { $0.suggestedName }, applicationForURL: { _ in
                URL(fileURLWithPath: "/Applications/Codex.app")
            }, openURL: { opened.append($0); return true })
            XCTAssertEqual(opened, [try CodexAppHandoff.link(sessionURL: session)])

            let export = session.appendingPathComponent("export")
            let archive = session.appendingPathComponent("archive")
            try FileManager.default.moveItem(at: export, to: archive)
            try FileManager.default.createSymbolicLink(at: export, withDestinationURL: archive)
            var resolved = false
            XCTAssertThrowsError(try CodexAppHandoff.open(sessionURL: session, configureProject: { $0.suggestedName }, applicationForURL: { _ in
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
            XCTAssertThrowsError(try CodexAppHandoff.open(sessionURL: session, configureProject: { $0.suggestedName }, applicationForURL: { _ in nil },
                                                        openURL: { _ in attemptedOpen = true; return true })) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .codexAppMissing)
            }
            XCTAssertFalse(attemptedOpen)
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent(CodexWorkspace.directoryName).path))
            XCTAssertThrowsError(try CodexAppHandoff.open(sessionURL: session, configureProject: { $0.suggestedName }, applicationForURL: { _ in
                URL(fileURLWithPath: "/Applications/Codex.app")
            }, openURL: { _ in false })) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .codexAppLaunchFailed)
            }
        }
    }

    @MainActor
    func testFirstOpenAsksForTheProjectNameAndReopeningDoesNotAskOrCreateAnotherProject() throws {
        try withSession { session in
            var requests: [CodexAppHandoff.ProjectRequest] = []
            var opened: [URL] = []
            for _ in 0..<2 {
                try CodexAppHandoff.open(sessionURL: session, configureProject: {
                    requests.append($0)
                    return "Guildford Import Flow Review"
                }, applicationForURL: { _ in URL(fileURLWithPath: "/Applications/Codex.app") },
                   openURL: { opened.append($0); return true })
            }
            XCTAssertEqual(requests.count, 1)
            XCTAssertFalse(try XCTUnwrap(requests.first).existing)
            XCTAssertFalse(try XCTUnwrap(requests.first).includeArchive)
            XCTAssertEqual(opened.count, 2)
            XCTAssertEqual(opened.first, opened.last)
            XCTAssertEqual(try CodexWorkspace.existingWorkspace(sessionURL: session)?.lastPathComponent, "Guildford Import Flow Review")
        }
    }

    @MainActor
    func testCancelFirstOpenCreatesNoWorkspaceAndDoesNotLaunchCodex() throws {
        try withSession { session in
            XCTAssertThrowsError(try CodexAppHandoff.open(sessionURL: session, configureProject: { _ in nil },
                applicationForURL: { _ in URL(fileURLWithPath: "/Applications/Codex.app") },
                openURL: { _ in XCTFail("Cancelled handoff must not launch"); return true })) {
                XCTAssertEqual($0 as? ClaudeCLIHandoffError, .handoffCancelled)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent(CodexWorkspace.directoryName).path))
        }
    }

    @MainActor
    func testArchiveConfirmationUsesExistingProjectAndCancellationCopiesNothing() async throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }
        let archive = session.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("original media".utf8).write(to: archive.appendingPathComponent("session.mp4"))
        try Data("{}".utf8).write(to: session.appendingPathComponent("session.manifest.json"))
        let workspace = try CodexWorkspace.prepare(sessionURL: session, projectName: "Guildford Import Flow Review")
        var opened = false
        var requests: [CodexAppHandoff.ProjectRequest] = []
        do {
            try await CodexAppHandoff.openPrivateArchive(sessionURL: session, configureProject: {
                requests.append($0)
                return nil
            }, applicationForURL: { _ in URL(fileURLWithPath: "/Applications/Codex.app") },
               openURL: { _ in opened = true; return true })
            XCTFail("Cancellation must not succeed")
        } catch {
            XCTAssertEqual(error as? ClaudeCLIHandoffError, .handoffCancelled)
        }
        XCTAssertEqual(requests, [.init(suggestedName: "Guildford Import Flow Review", existing: true, includeArchive: true)])
        XCTAssertFalse(opened)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("source").path))
        try await CodexAppHandoff.openPrivateArchive(sessionURL: session, configureProject: { $0.suggestedName },
            applicationForURL: { _ in URL(fileURLWithPath: "/Applications/Codex.app") }, openURL: { url in
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value, workspace.path)
                opened = true
                return true
            })
        XCTAssertTrue(opened)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("source/archive/session.mp4"), encoding: .utf8), "original media")
    }

    @MainActor
    func testArchiveHandoffSerializesCopiesAndReleasesBusyStateOnSuccessFailureAndCancel() async throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }
        let suite = "ScrumTrace.CodexArchiveBusy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        AgentLog.setFileURLForTesting(session.appendingPathComponent("test-agent.jsonl"))
        defer { defaults.removePersistentDomain(forName: suite); AgentLog.setFileURLForTesting(nil) }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty),
                                           vault: SessionVault(rootURL: session))
        var copies = 0
        controller.openAgentArchive = { _, _ in
            copies += 1
            XCTAssertTrue(controller.isBusy)
            XCTAssertFalse(controller.canChangeCaptureSettings)
            XCTAssertFalse(controller.beginSessionTransfer())
            XCTAssertNil(controller.openPrivateArchiveInCodex(sessionId: "duplicate"))
            controller.openInChatGPT(sessionId: "export")
            XCTAssertEqual(controller.statusLine, "Wait for the Codex archive copy to finish.")
        }
        controller.openAgentExport = { _, _, _, _ in XCTFail("Export must wait until archive copy completes") }
        let task = try XCTUnwrap(controller.openPrivateArchiveInCodex(sessionId: "recording"))
        XCTAssertTrue(controller.isBusy, "Busy must be set before the async task starts")
        await task.value
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(controller.statusLine, "Opened archive in Codex")
        XCTAssertTrue(controller.canChangeCaptureSettings)
        XCTAssertNil(controller.codexArchiveTask)
        for error in [ClaudeCLIHandoffError.codexWorkspaceFailed, .handoffCancelled] {
            controller.openAgentArchive = { _, _ in throw error }
            let failed = try XCTUnwrap(controller.openPrivateArchiveInCodex(sessionId: "recording"))
            await failed.value
            XCTAssertFalse(controller.isBusy)
            XCTAssertNil(controller.codexArchiveTask)
            XCTAssertEqual(controller.statusLine, error.localizedDescription)
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
