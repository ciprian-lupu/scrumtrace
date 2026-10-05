import Foundation
import Darwin

/// The installed CLI owns authentication. ScrumTrace never reads or copies its tokens.
enum LocalAgentError: Error, LocalizedError, Equatable {
    case notInstalled, signInRequired, failed, timedOut, outputTooLarge, unsupported

    var diagnosticCode: String {
        switch self {
        case .notInstalled: return "local_agent_missing"
        case .signInRequired: return "local_agent_sign_in_required"
        case .failed: return "local_agent_failed"
        case .timedOut: return "local_agent_timeout"
        case .outputTooLarge: return "local_agent_output_limit"
        case .unsupported: return "local_agent_unsupported"
        }
    }
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Install the Claude Code or Codex command on this Mac, then check again."
        case .signInRequired: return "Sign in to the selected local agent with your Claude or ChatGPT subscription. An API-key login cannot be used for this service."
        case .failed: return "The local agent could not finish. Check its sign-in, subscription allowance, and model in Terminal, then retry."
        case .timedOut: return "The local agent took too long. Retry when it is available."
        case .outputTooLarge: return "The local agent returned too much output. Try again."
        case .unsupported: return "Update the local Claude Code or Codex command to a version supporting subscription analysis."
        }
    }
}

struct LocalAgentResult: Sendable {
    var status: Int32
    var output: Data
    var errors: Data
}

/// Files rather than pipes avoid deadlocks with large image inputs and simultaneous stdout/stderr.
/// Work never runs in a recording, repository, or the user's home directory.
enum LocalAgentProcess {
    static let outputLimit = 8 * 1024 * 1024

    static func environment(_ source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = source
        for key in source.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("OPENAI_")
            || key.hasPrefix("CLAUDE_CODE_") || key == "CODEX_API_KEY" || key == "CODEX_ACCESS_TOKEN"
            || key == "CLAUDECODE" || key == "CLAUDE_CONFIG_DIR" {
            result.removeValue(forKey: key)
        }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (source["PATH"] ?? "/usr/bin:/bin")
        return result
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scrumtrace-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }

    static func run(executable: URL, arguments: [String], input: Data = Data(), directory: URL,
                    timeout: TimeInterval = 180) async throws -> LocalAgentResult {
        try Task.checkCancellation()
        let fm = FileManager.default
        let prefix = UUID().uuidString
        let urls = ["in", "out", "err"].map { directory.appendingPathComponent("\(prefix).\($0)") }
        for url in urls { fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
        defer { for url in urls { try? fm.removeItem(at: url) } }
        try input.write(to: urls[0])
        let stdin = try FileHandle(forReadingFrom: urls[0])
        let stdout = try FileHandle(forWritingTo: urls[1])
        let stderr = try FileHandle(forWritingTo: urls[2])
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw LocalAgentError.notInstalled }
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date() >= deadline { throw LocalAgentError.timedOut }
                if urls.dropFirst().contains(where: { fileSize($0) > outputLimit }) {
                    throw LocalAgentError.outputTooLarge
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch {
            // Reap before deleting evidence inputs. No abandoned CLI can keep consuming a subscription.
            if process.isRunning { process.terminate() }
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace {
                // Detached sleep remains usable when the calling task was cancelled.
                await Task.detached { try? await Task.sleep(nanoseconds: 50_000_000) }.value
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            while process.isRunning {
                await Task.detached { try? await Task.sleep(nanoseconds: 50_000_000) }.value
            }
            throw error
        }
        guard urls.dropFirst().allSatisfy({ fileSize($0) <= outputLimit }) else { throw LocalAgentError.outputTooLarge }
        return LocalAgentResult(status: process.terminationStatus,
                                output: try Data(contentsOf: urls[1]), errors: try Data(contentsOf: urls[2]))
    }

    private static func fileSize(_ url: URL) -> Int {
        // URL resource values can cache a size read while the child is still writing.
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }
}

enum LocalSubscriptionAuth {
    static func isSubscription(_ result: LocalAgentResult, cli: LocalCodingCLI) -> Bool {
        guard result.status == 0 else { return false }
        switch cli {
        case .claude:
            guard let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] else { return false }
            return object["loggedIn"] as? Bool == true && object["authMethod"] as? String == "claude.ai"
        case .chatGPT:
            // Codex writes login status to stderr in some versions. This command contains no tokens.
            let text = String(decoding: result.output + result.errors, as: UTF8.self).lowercased()
            return text.contains("logged in using chatgpt") && !text.contains("api key")
        }
    }

    static func check(cli: LocalCodingCLI) async throws {
        guard let executable = ClaudeCLIHandoff.executable(for: cli) else { throw LocalAgentError.notInstalled }
        let directory = try LocalAgentProcess.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await LocalAgentProcess.run(executable: executable,
            arguments: cli == .claude ? ["auth", "status", "--json"] : ["login", "status"],
            directory: directory, timeout: 15)
        guard isSubscription(result, cli: cli) else { throw LocalAgentError.signInRequired }
    }
}

struct LocalSubscriptionClient: AIProvider {
    var configuration: AIProviderConfiguration
    var kind: AIProviderKind { configuration.kind }

    func evaluate(request: SliceEvaluationRequest) async throws -> CandidateEvaluationResponse {
        let text = try await complete(system: request.systemPrompt, prompt: request.userPrompt,
                                      images: request.imagePayloads)
        return try JSONExtractor.decodeCandidates(from: text)
    }

    func complete(system: String, prompt: String, images: [ComparisonInput.Image] = []) async throws -> String {
        try configuration.validate()
        guard let cli = kind.localCLI else { throw LocalAgentError.unsupported }
        try await LocalSubscriptionAuth.check(cli: cli)
        guard let executable = ClaudeCLIHandoff.executable(for: cli) else { throw LocalAgentError.notInstalled }
        let directory = try LocalAgentProcess.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try Self.invocation(cli: cli, model: configuration.model, system: system,
                                              prompt: prompt, images: images, directory: directory)
        let result = try await LocalAgentProcess.run(executable: executable, arguments: invocation.arguments,
                                                     input: invocation.input, directory: directory)
        return try Self.response(result, cli: cli)
    }

    struct Invocation {
        var arguments: [String]
        var input: Data
    }

    static func invocation(cli: LocalCodingCLI, model: String, system: String, prompt: String,
                           images: [ComparisonInput.Image], directory: URL) throws -> Invocation {
        var args: [String]
        let input: Data
        switch cli {
        case .claude:
            // Safe mode preserves subscription auth while skipping hooks/plugins/custom instructions.
            // Do not use --bare: it excludes subscription authentication.
            args = ["--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--tools", "", "--no-session-persistence", "--print", "--input-format", "stream-json",
                    "--output-format", "stream-json", "--verbose", "--system-prompt", system]
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            for image in images {
                content.append(["type": "image", "source": ["type": "base64", "media_type": image.mime, "data": image.base64]])
            }
            var data = try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": content]])
            data.append(0x0a)
            input = data
        case .chatGPT:
            args = ["exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
                    "--color", "never", "--json", "-c", "approval_policy=\"never\"",
                    "-c", "web_search=\"disabled\"", "-c", "features.shell_tool=false",
                    "-c", "features.apps=false", "-c", "features.multi_agent=false", "-c", "features.hooks=false"]
            for (index, image) in images.enumerated() {
                guard image.mime == "image/jpeg", let data = Data(base64Encoded: image.base64) else {
                    throw AIProviderError.decoding("Invalid JPEG evidence.")
                }
                let url = directory.appendingPathComponent("evidence-\(index).jpg")
                try data.write(to: url)
                args += ["--image", url.path]
            }
            input = Data((system + "\n\n" + prompt).utf8)
        }
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--model", model] }
        if cli == .chatGPT { args += ["-"] }
        return Invocation(arguments: args, input: input)
    }

    static func response(_ result: LocalAgentResult, cli: LocalCodingCLI) throws -> String {
        guard result.status == 0 else { throw LocalAgentError.failed }
        switch cli {
        case .claude:
            let objects = String(decoding: result.output, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            guard let object = objects.last(where: { $0["type"] as? String == "result" }) else {
                throw AIProviderError.emptyResponse
            }
            guard object["is_error"] as? Bool != true else { throw LocalAgentError.failed }
            guard let text = object["result"] as? String, !text.isEmpty else { throw AIProviderError.emptyResponse }
            return text
        case .chatGPT:
            var message: String?
            var completed = false
            for line in String(decoding: result.output, as: UTF8.self).split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let type = object["type"] as? String
                if type == "turn.failed" || type == "error" { throw LocalAgentError.failed }
                if type == "turn.completed" { completed = true }
                if type == "item.completed", let item = object["item"] as? [String: Any],
                   item["type"] as? String == "agent_message" { message = item["text"] as? String }
            }
            guard completed, let message, !message.isEmpty else { throw AIProviderError.emptyResponse }
            return message
        }
    }
}
