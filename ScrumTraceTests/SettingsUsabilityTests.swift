import XCTest
import WhisperKit
@testable import ScrumTrace

final class SettingsUsabilityTests: XCTestCase {
    private var logFolder: URL!
    override func setUpWithError() throws {
        logFolder = FileManager.default.temporaryDirectory.appendingPathComponent("settings-log-\(UUID().uuidString)")
        AgentLog.setFileURLForTesting(logFolder.appendingPathComponent("agent.jsonl"))
    }
    override func tearDownWithError() throws {
        AgentLog.setFileURLForTesting(nil)
        try? FileManager.default.removeItem(at: logFolder)
    }

    @MainActor
    private func withSettings(_ body: (AppSettings, UserDefaults, MemoryKeys) throws -> Void) throws {
        let suite = "ScrumTrace.SettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys = MemoryKeys()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, keyStore: keys.store)
        try body(settings, defaults, keys)
    }

    @MainActor
    func testProviderProfilesSurviveSwitchAndRelaunch() throws {
        try withSettings { settings, defaults, keys in
            settings.baseURL = "https://example.test/proxy/v1"
            settings.model = "custom-model"
            settings.provider = .anthropic
            XCTAssertEqual(settings.baseURL, AIProviderKind.anthropic.defaultBaseURL)
            settings.model = "custom-anthropic-model"
            settings.provider = .openaiCompatible
            XCTAssertEqual(settings.baseURL, "https://example.test/proxy/v1")
            XCTAssertEqual(settings.model, "custom-model")
            let restored = AppSettings(defaults: defaults, keyStore: keys.store)
            restored.provider = .anthropic
            XCTAssertEqual(restored.model, "custom-anthropic-model")
        }
    }

    @MainActor
    func testLegacyPreferencesAndKeyStayWithOriginalProvider() throws {
        try withSettings { _, defaults, keys in
            defaults.set("anthropic", forKey: "scrumtrace.provider")
            defaults.set("https://legacy.example.test", forKey: "scrumtrace.baseURL")
            defaults.set("existing-model", forKey: "scrumtrace.model")
            defaults.removeObject(forKey: "scrumtrace.legacyCredentialScope")
            keys.values["ai.apiKey"] = "fixture-legacy-key"
            let settings = AppSettings(defaults: defaults, keyStore: keys.store)
            XCTAssertEqual(settings.baseURL, "https://legacy.example.test")
            XCTAssertEqual(settings.model, "existing-model")
            XCTAssertTrue(settings.hasSavedAPIKey)
            XCTAssertTrue(settings.apiKeyDraft.isEmpty)
            XCTAssertEqual(keys.reads, 0, "Opening Settings must not read a saved secret")
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-legacy-key")
            settings.provider = .google
            XCTAssertFalse(settings.hasSavedAPIKey)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "")
            settings.provider = .anthropic
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-legacy-key")
        }
    }

    @MainActor
    func testKeysAreScopedToProviderAndEndpointHost() throws {
        try withSettings { settings, _, _ in
            settings.apiKeyDraft = " fixture-openai-key "
            try settings.saveAPIKey()
            XCTAssertTrue(settings.apiKeyDraft.isEmpty)
            XCTAssertTrue(settings.hasSavedAPIKey)
            settings.baseURL = "https://another.example.test"
            XCTAssertFalse(settings.hasSavedAPIKey)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "")
            settings.apiKeyDraft = "fixture-proxy-key"
            try settings.saveAPIKey()
            settings.baseURL = "https://API.OPENAI.COM:443/v1"
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-openai-key")
            settings.provider = .google
            XCTAssertEqual(settings.providerConfiguration().apiKey, "")
            settings.apiKeyDraft = "fixture-google-key"
            try settings.saveAPIKey()
            settings.provider = .openaiCompatible
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-openai-key")
        }
    }

    @MainActor
    func testBlankSaveCannotDeleteAndRemovalIsExplicit() throws {
        try withSettings { settings, _, keys in
            settings.apiKeyDraft = "fixture-key"
            try settings.saveAPIKey()
            settings.apiKeyDraft = " \n "
            XCTAssertThrowsError(try settings.saveAPIKey())
            XCTAssertEqual(keys.removals, 0)
            XCTAssertTrue(settings.hasSavedAPIKey)
            keys.failRemoval = true
            XCTAssertThrowsError(try settings.removeSavedAPIKey())
            XCTAssertTrue(settings.hasSavedAPIKey)
            keys.failRemoval = false
            try settings.removeSavedAPIKey()
            XCTAssertFalse(settings.hasSavedAPIKey)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "")
        }
    }

    @MainActor
    func testConfigurationValidationDoesNotReadKeyAndExplainsMissingFields() throws {
        try withSettings { settings, _, keys in
            XCTAssertNil(settings.configurationIssue)
            XCTAssertTrue(settings.configurationSummary.contains("No saved key"))
            settings.model = " \n "
            XCTAssertNotNil(settings.configurationIssue)
            settings.baseURL = "http://remote.example.test"
            XCTAssertNotNil(settings.configurationIssue)
            XCTAssertEqual(keys.reads, 0)
        }
    }

    func testEndpointValidationAcceptsRootsAndRejectsMalformedDestinations() throws {
        for endpoint in ["https://api.openai.com", " https://example.test/v1/ ", "http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080"] {
            XCTAssertNoThrow(try ProviderEndpoint.requireHTTPSOrLocal(endpoint), endpoint)
        }
        for endpoint in ["", "https:", "https:///", "ftp://example.test", "http://remote.example.test", "https://user:password@example.test", "https://example.test?key=fixture", "https://example.test#fragment"] {
            XCTAssertThrowsError(try ProviderEndpoint.requireHTTPSOrLocal(endpoint), endpoint)
        }
    }

    @MainActor
    func testSpeechLanguagePersistsAndUsesExplicitDetection() throws {
        try withSettings { settings, defaults, keys in
            XCTAssertEqual(settings.speechLanguage, .automatic)
            settings.speechLanguage = .romanian
            XCTAssertEqual(AppSettings(defaults: defaults, keyStore: keys.store).speechLanguage, .romanian)
        }
        let automatic = WhisperTranscriber.decodingOptions(language: .automatic)
        XCTAssertTrue(automatic.detectLanguage)
        XCTAssertNil(automatic.language)
        XCTAssertFalse(automatic.usePrefillCache)
        XCTAssertTrue(automatic.skipSpecialTokens)
        XCTAssertTrue(automatic.wordTimestamps)
        let romanian = WhisperTranscriber.decodingOptions(language: .romanian)
        XCTAssertFalse(romanian.detectLanguage)
        XCTAssertEqual(romanian.language, "ro")
        XCTAssertEqual(romanian.task, .transcribe)
    }

    func testModelSwitchLoadsRequestedModelAndReusesOnlyMatchingModel() async throws {
        let loader = ModelLoader()
        let transcriber = WhisperTranscriber(loadModel: { try await loader.load($0) })
        try await transcriber.prepare(model: "base")
        try await transcriber.prepare(model: "base")
        XCTAssertTrue(transcriber.isReady(for: "base"))
        XCTAssertFalse(transcriber.isReady(for: "tiny"))
        try await transcriber.prepare(model: "tiny")
        XCTAssertTrue(transcriber.isReady(for: "tiny"))
        XCTAssertFalse(transcriber.isReady(for: "base"))
        let calls = await loader.models
        XCTAssertEqual(calls, [WhisperTranscriber.whisperKitModelName("base"), WhisperTranscriber.whisperKitModelName("tiny")])
    }

    func testFailedModelSwitchCanRetryWithoutClaimingNewModelIsReady() async throws {
        let loader = ModelLoader()
        let transcriber = WhisperTranscriber(loadModel: { try await loader.load($0) })
        try await transcriber.prepare(model: "base")
        await loader.failNextLoad()
        do {
            try await transcriber.prepare(model: "tiny")
            XCTFail("Expected the loader failure")
        } catch {}
        XCTAssertTrue(transcriber.isReady(for: "base"))
        XCTAssertFalse(transcriber.isReady(for: "tiny"))
        XCTAssertFalse(transcriber.isPreparing)
        try await transcriber.prepare(model: "tiny")
        XCTAssertTrue(transcriber.isReady(for: "tiny"))
    }

    func testConcurrentPreparationCoalescesSameModel() async throws {
        let loader = ModelLoader()
        let transcriber = WhisperTranscriber(loadModel: { try await loader.load($0) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { try await transcriber.prepare(model: "base") } }
            try await group.waitForAll()
        }
        let count = await loader.models.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(transcriber.isReady(for: "base"))
    }

    func testVoiceNoteDecodeReceivesSelectedLanguageAndTokenFiltering() async throws {
        let loader = ModelLoader()
        let transcriber = WhisperTranscriber(loadModel: { try await loader.load($0) })
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("settings-speech-\(UUID().uuidString).wav")
        try Data("fixture passed only to a fake decoder".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        transcriber.setLanguage(.romanian)
        try await transcriber.prepare(model: "base")
        _ = try await transcriber.transcribeVoiceNote(at: input)
        let observed = await loader.decodedLanguage
        let filtersTokens = await loader.filtersTokens
        XCTAssertEqual(observed, "ro")
        XCTAssertTrue(filtersTokens)
    }

    func testCurrentRunFilterIsExactAndSearchPrecedesLimit() {
        let input = """
        {"run_id":"old","event":"permission_probe"}
        {"run_id":"current","event":"permission_probe","n":1}
        {"run_id":"current-extra","event":"permission_probe"}
        {"run_id":"current","event":"ready","n":2}
        {"run_id":"current","event":"permission_probe","n":3}
        invalid-json
        """
        let filtered = AgentLog.filteredTail(input, maxLines: 2, runID: "current", query: "PERMISSION", newestFirst: true)
        let lines = filtered.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"n\":3"))
        XCTAssertTrue(lines[1].contains("\"n\":1"))
        XCTAssertFalse(filtered.contains("current-extra"))
        XCTAssertEqual(AgentLog.filteredTail(input, maxLines: 2, runID: "missing", query: "", newestFirst: false), "")
    }
}

private final class MemoryKeys {
    var values: [String: String] = [:]
    var reads = 0
    var removals = 0
    var failRemoval = false
    var store: SettingsKeyStore {
        SettingsKeyStore(
            get: { self.reads += 1; return self.values[$0] },
            contains: { self.values[$0] != nil },
            set: { self.values[$1] = $0 },
            remove: {
                if self.failRemoval { throw SettingsValidationError("Keychain unavailable") }
                self.removals += 1
                self.values.removeValue(forKey: $0)
            }
        )
    }
}

private actor ModelLoader {
    var models: [String] = []
    private var shouldFail = false
    var decodedLanguage: String?
    var filtersTokens = false
    func observe(_ options: DecodingOptions) {
        decodedLanguage = options.language
        filtersTokens = options.skipSpecialTokens
    }
    func failNextLoad() { shouldFail = true }
    func load(_ model: String) async throws -> WhisperTranscriber.LoadedModel {
        models.append(model)
        if shouldFail { shouldFail = false; throw SettingsValidationError("Fixture load failure") }
        return WhisperTranscriber.LoadedModel { _, options in
            self.observe(options)
            return []
        }
    }
}
