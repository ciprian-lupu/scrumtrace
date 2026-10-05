import AppKit
import XCTest
@testable import ScrumTrace

final class LocalSubscriptionTests: XCTestCase {
    func configuration(_ kind: AIProviderKind) -> AIProviderConfiguration {
        AIProviderConfiguration(kind: kind, baseURL: kind.defaultBaseURL, model: "", apiKey: "",
                                acceptsText: true, acceptsImages: true, acceptsVideo: false)
    }

    func testSubscriptionsNeedNoKeyAndNeverUploadVideo() throws {
        for kind in [AIProviderKind.claudeSubscription, .codexSubscription] {
            XCTAssertNoThrow(try configuration(kind).validate())
            XCTAssertFalse(kind.requiresAPIKey)
            XCTAssertFalse(ProviderWireMedia.adapterCanUploadVideo(kind))
            XCTAssertTrue(AIEngine.make(configuration: configuration(kind)) is LocalSubscriptionClient)
        }
    }

    func testAuthRejectsAPIKeysAndSignedOutStates() {
        func result(_ text: String, status: Int32 = 0) -> LocalAgentResult {
            LocalAgentResult(status: status, output: Data(text.utf8), errors: Data())
        }
        XCTAssertTrue(LocalSubscriptionAuth.isSubscription(result(#"{"loggedIn":true,"authMethod":"claude.ai"}"#), cli: .claude))
        XCTAssertFalse(LocalSubscriptionAuth.isSubscription(result(#"{"loggedIn":true,"authMethod":"api_key"}"#), cli: .claude))
        XCTAssertFalse(LocalSubscriptionAuth.isSubscription(result(#"{"loggedIn":false,"authMethod":"claude.ai"}"#), cli: .claude))
        XCTAssertTrue(LocalSubscriptionAuth.isSubscription(result("Logged in using ChatGPT"), cli: .chatGPT))
        XCTAssertFalse(LocalSubscriptionAuth.isSubscription(result("Logged in using an API key"), cli: .chatGPT))
        XCTAssertFalse(LocalSubscriptionAuth.isSubscription(result("Logged in using ChatGPT", status: 1), cli: .chatGPT))
        XCTAssertTrue(AIProviderError.isAuthFailure(LocalAgentError.signInRequired))
    }

    func testEnvironmentDoesNotOverrideSubscriptionWithAPIAuth() {
        let environment = LocalAgentProcess.environment([
            "ANTHROPIC_API_KEY": "secret", "ANTHROPIC_AUTH_TOKEN": "secret",
            "OPENAI_API_KEY": "secret", "CODEX_API_KEY": "secret", "CODEX_ACCESS_TOKEN": "secret",
            "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDECODE": "1", "PATH": "/usr/bin", "HOME": "/fixture/home"
        ])
        XCTAssertFalse(environment.values.contains("secret"))
        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertNil(environment["CLAUDE_CODE_USE_BEDROCK"])
        XCTAssertEqual(environment["HOME"], "/fixture/home")
    }

    func testPreparedEvidenceIsPassedWithoutReadingArchive() throws {
        let directory = try LocalAgentProcess.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        let images = [ComparisonInput.Image(mime: "image/jpeg", base64: bytes.base64EncodedString())]
        let claude = try LocalSubscriptionClient.invocation(cli: .claude, model: "sonnet", system: "system",
                                                            prompt: "evidence $(do not execute)", images: images, directory: directory)
        let message = try XCTUnwrap(try JSONSerialization.jsonObject(with: claude.input) as? [String: Any])
        let contents = try XCTUnwrap((message["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(contents[0]["text"] as? String, "evidence $(do not execute)")
        XCTAssertEqual((contents[1]["source"] as? [String: String])?["data"], images[0].base64)
        XCTAssertFalse(claude.arguments.contains("--bare"))
        XCTAssertTrue(claude.arguments.contains("--safe-mode"))
        XCTAssertFalse(claude.arguments.contains("evidence $(do not execute)"))
        let codex = try LocalSubscriptionClient.invocation(cli: .chatGPT, model: "", system: "system",
                                                           prompt: "evidence", images: images, directory: directory)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("evidence-0.jpg")), bytes)
        XCTAssertEqual(String(decoding: codex.input, as: UTF8.self), "system\n\nevidence")
        XCTAssertTrue(codex.arguments.contains("--ignore-user-config"))
        XCTAssertFalse(codex.arguments.contains("--model"))
        XCTAssertEqual(codex.arguments.last, "-")
    }

    func testResponsesRequireSuccessfulCompletion() throws {
        func result(_ text: String, status: Int32 = 0) -> LocalAgentResult {
            LocalAgentResult(status: status, output: Data(text.utf8), errors: Data())
        }
        let claude = #"{"type":"result","is_error":false,"result":"pong"}"#
        XCTAssertEqual(try LocalSubscriptionClient.response(result(claude), cli: .claude), "pong")
        XCTAssertThrowsError(try LocalSubscriptionClient.response(result(#"{"type":"result","is_error":true,"result":"quota exhausted"}"#), cli: .claude))
        let codex = #"{"type":"item.completed","item":{"type":"agent_message","text":"pong"}}"#
        XCTAssertThrowsError(try LocalSubscriptionClient.response(result(codex), cli: .chatGPT))
        XCTAssertEqual(try LocalSubscriptionClient.response(result(codex + "\n" + #"{"type":"turn.completed"}"#), cli: .chatGPT), "pong")
        XCTAssertThrowsError(try LocalSubscriptionClient.response(result(codex + "\n" + #"{"type":"turn.failed"}"#), cli: .chatGPT))
        XCTAssertThrowsError(try LocalSubscriptionClient.response(result(claude, status: 1), cli: .claude))
    }

    func testRunnerHandlesLargeInputAndOutputWithoutPipeDeadlock() async throws {
        let directory = try LocalAgentProcess.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = Data(repeating: 65, count: 200_000)
        let result = try await LocalAgentProcess.run(executable: URL(fileURLWithPath: "/bin/cat"),
                                                     arguments: [], input: input, directory: directory, timeout: 5)
        XCTAssertEqual(result.output, input)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testTimeoutAndCancellationReapProcessAndCleanFiles() async throws {
        let directory = try LocalAgentProcess.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await LocalAgentProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                arguments: ["20"], directory: directory, timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? LocalAgentError, .timedOut) }
        let task = Task { try await LocalAgentProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                          arguments: ["20"], directory: directory) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testRunnerRejectsOversizedOutput() async throws {
        let directory = try LocalAgentProcess.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await LocalAgentProcess.run(executable: URL(fileURLWithPath: "/bin/dd"),
                arguments: ["if=/dev/zero", "bs=1048576", "count=9"], directory: directory)
            XCTFail("Expected output limit")
        } catch { XCTAssertEqual(error as? LocalAgentError, .outputTooLarge) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testLiveImageAndStructuredResponseWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["SCRUMTRACE_TEST_SUBSCRIPTIONS"] == "1" else {
            throw XCTSkip("Opt-in only: synthetic image, no meeting data.")
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(rep.bitmapData)
        for y in 0..<256 { for x in 0..<256 {
            let offset = y * rep.bytesPerRow + x * 3
            pixels[offset] = 255; pixels[offset + 1] = 0; pixels[offset + 2] = 0
        } }
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        for kind in [AIProviderKind.claudeSubscription, .codexSubscription] {
            let text = try await LocalSubscriptionClient(configuration: configuration(kind)).complete(
                system: "Inspect the attached image. Return only a JSON object with a color field.",
                prompt: "What is the dominant color of this image? Use one basic English color name.",
                images: [.init(mime: "image/jpeg", base64: jpeg.base64EncodedString())])
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(JSONExtractor.stripFences(text).utf8)) as? [String: String])
            XCTAssertEqual(object["color"]?.lowercased(), "red", kind.rawValue)
        }
    }

    func testLiveSubscriptionConnectionsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["SCRUMTRACE_TEST_SUBSCRIPTIONS"] == "1" else {
            throw XCTSkip("Opt-in only: consumes a small amount of subscription usage, no meeting data.")
        }
        for kind in [AIProviderKind.claudeSubscription, .codexSubscription] {
            let response = try await AIConnectionTest.run(configuration: configuration(kind))
            XCTAssertTrue(response.replyPreview.lowercased().contains("pong"), kind.rawValue)
        }
    }
}
