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
    private func withDefaults(_ body: (UserDefaults, MemoryKeys) throws -> Void) throws {
        let suite = "ScrumTrace.SettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys = MemoryKeys()
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, keys)
    }

    @MainActor
    private func withSettings(_ body: (AppSettings, UserDefaults, MemoryKeys) throws -> Void) throws {
        try withDefaults { defaults, keys in
            let settings = AppSettings(defaults: defaults, keyStore: keys.store)
            try body(settings, defaults, keys)
        }
    }

    @MainActor
    func testFreshInstallHasDefaultServiceAndNoKey() throws {
        try withSettings { settings, _, keys in
            XCTAssertEqual(settings.connectionLibrary.connections.count, 1)
            XCTAssertEqual(settings.connectionLibrary.selected?.name, "OpenAI")
            XCTAssertEqual(settings.provider, .openaiCompatible)
            XCTAssertFalse(settings.hasSavedAPIKey)
            XCTAssertEqual(keys.reads, 0)
            XCTAssertTrue(settings.configurationSummary.contains("No saved key"))
        }
    }

    @MainActor
    func testSavedServicesSurviveSwitchAndRelaunch() throws {
        try withSettings { settings, defaults, keys in
            let firstID = try XCTUnwrap(settings.connectionLibrary.selectedID)
            settings.baseURL = "https://example.test/proxy/v1"
            settings.model = "custom-model"
            settings.apiKeyDraft = "fixture-openai-key"
            try settings.saveAPIKey()
            try settings.addAIConnection(name: "Anthropic work", provider: .anthropic)
            XCTAssertEqual(settings.provider, .anthropic)
            settings.model = "custom-anthropic-model"
            settings.apiKeyDraft = "fixture-anthropic-key"
            try settings.saveAPIKey()
            let secondID = try XCTUnwrap(settings.connectionLibrary.selectedID)
            XCTAssertNotEqual(firstID, secondID)

            try settings.selectAIConnection(id: firstID)
            XCTAssertEqual(settings.baseURL, "https://example.test/proxy/v1")
            XCTAssertEqual(settings.model, "custom-model")
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-openai-key")

            try settings.selectAIConnection(id: secondID)
            XCTAssertEqual(settings.provider, .anthropic)
            XCTAssertEqual(settings.model, "custom-anthropic-model")
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-anthropic-key")

            let restored = AppSettings(defaults: defaults, keyStore: keys.store)
            XCTAssertEqual(restored.connectionLibrary.selectedID, secondID)
            XCTAssertEqual(restored.model, "custom-anthropic-model")
            try restored.selectAIConnection(id: firstID)
            XCTAssertEqual(restored.baseURL, "https://example.test/proxy/v1")
            XCTAssertEqual(restored.providerConfiguration().apiKey, "fixture-openai-key")
        }
    }

    @MainActor
    func testLegacyPreferencesAndKeyStayWithImportedService() throws {
        try withDefaults { defaults, keys in
            defaults.set("anthropic", forKey: "scrumtrace.provider")
            defaults.set("https://legacy.example.test", forKey: "scrumtrace.baseURL")
            defaults.set("existing-model", forKey: "scrumtrace.model")
            defaults.removeObject(forKey: "scrumtrace.legacyCredentialScope")
            keys.values["ai.apiKey"] = "fixture-legacy-key"
            let settings = AppSettings(defaults: defaults, keyStore: keys.store)
            XCTAssertEqual(settings.connectionLibrary.connections.count, 1)
            XCTAssertEqual(settings.connectionLibrary.selected?.name, "Imported service")
            XCTAssertEqual(settings.baseURL, "https://legacy.example.test")
            XCTAssertEqual(settings.model, "existing-model")
            XCTAssertTrue(settings.hasSavedAPIKey)
            XCTAssertTrue(settings.apiKeyDraft.isEmpty)
            XCTAssertEqual(keys.reads, 0, "Opening Settings must not read a saved secret")
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-legacy-key")
            try settings.addAIConnection(name: "Hive")
            XCTAssertFalse(settings.hasSavedAPIKey)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "")
            let importedID = try XCTUnwrap(
                settings.connectionLibrary.connections.first { $0.name == "Imported service" }?.id
            )
            try settings.selectAIConnection(id: importedID)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-legacy-key")
            try settings.selectAIConnection(id: nil)
            XCTAssertFalse(settings.hasSavedAPIKey)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "")
        }
    }

    @MainActor
    func testHostScopedKeyMigratesAsFallbackForImportedService() throws {
        try withDefaults { defaults, keys in
            let scope = AppSettings.credentialScope(
                provider: .openaiCompatible,
                endpoint: "https://api.openai.com"
            )
            keys.values["ai.apiKey.\(scope)"] = "fixture-host-key"
            let settings = AppSettings(defaults: defaults, keyStore: keys.store)
            XCTAssertEqual(settings.connectionLibrary.selected?.name, "OpenAI")
            XCTAssertEqual(settings.connectionLibrary.selected?.fallbackKeyAccount, "ai.apiKey.\(scope)")
            XCTAssertTrue(settings.hasSavedAPIKey)
            XCTAssertEqual(keys.reads, 0)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-host-key")
        }
    }

    @MainActor
    func testKeysStayWithSelectedServiceWhenEndpointChanges() throws {
        try withSettings { settings, _, keys in
            let firstID = try XCTUnwrap(settings.connectionLibrary.selectedID)
            settings.apiKeyDraft = " fixture-openai-key "
            try settings.saveAPIKey()
            XCTAssertTrue(settings.apiKeyDraft.isEmpty)
            XCTAssertTrue(settings.hasSavedAPIKey)
            settings.baseURL = "https://another.example.test"
            XCTAssertTrue(settings.hasSavedAPIKey)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-openai-key")
            settings.provider = .google
            XCTAssertEqual(settings.provider, .google)
            XCTAssertEqual(settings.baseURL, AIProviderKind.google.defaultBaseURL)
            XCTAssertTrue(settings.hasSavedAPIKey)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-openai-key")
            XCTAssertEqual(keys.values[AppSettings.connectionKeyAccount(id: firstID)], "fixture-openai-key")

            try settings.addAIConnection(name: "Google", provider: .google)
            settings.apiKeyDraft = "fixture-google-key"
            try settings.saveAPIKey()
            let secondID = try XCTUnwrap(settings.connectionLibrary.selectedID)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-google-key")
            try settings.selectAIConnection(id: firstID)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-openai-key")
            XCTAssertEqual(keys.values[AppSettings.connectionKeyAccount(id: secondID)], "fixture-google-key")
        }
    }

    @MainActor
    func testDeletingServiceRemovesItsKeyAndDoesNotSelectAnother() throws {
        try withSettings { settings, defaults, keys in
            let first = try XCTUnwrap(settings.connectionLibrary.selected)
            settings.apiKeyDraft = "fixture-first-key"
            try settings.saveAPIKey()
            try settings.addAIConnection(name: "Hive")
            settings.apiKeyDraft = "fixture-hive-key"
            try settings.saveAPIKey()
            let hiveID = try XCTUnwrap(settings.connectionLibrary.selectedID)
            try settings.deleteAIConnection(id: hiveID)
            XCTAssertNil(settings.connectionLibrary.selectedID)
            XCTAssertEqual(settings.connectionLibrary.connections.map(\.id), [first.id])
            XCTAssertNil(keys.values[AppSettings.connectionKeyAccount(id: hiveID)])
            XCTAssertEqual(settings.providerConfiguration().apiKey, "")
            let restored = AppSettings(defaults: defaults, keyStore: keys.store)
            XCTAssertNil(restored.connectionLibrary.selectedID)
            XCTAssertEqual(restored.connectionLibrary.connections.map(\.id), [first.id])
            XCTAssertTrue(restored.configurationSummary.contains("No service selected"))
        }
    }

    @MainActor
    func testDeletingLastServiceDoesNotRemigrate() throws {
        try withSettings { settings, defaults, keys in
            let id = try XCTUnwrap(settings.connectionLibrary.selectedID)
            try settings.deleteAIConnection(id: id)
            XCTAssertTrue(settings.connectionLibrary.connections.isEmpty)
            let restored = AppSettings(defaults: defaults, keyStore: keys.store)
            XCTAssertTrue(restored.connectionLibrary.connections.isEmpty)
            XCTAssertNil(restored.connectionLibrary.selectedID)
        }
    }

    @MainActor
    func testDuplicateServiceCopiesKeyOntoANewAccount() throws {
        try withSettings { settings, _, keys in
            settings.apiKeyDraft = "fixture-shared-shape"
            try settings.saveAPIKey()
            let source = try XCTUnwrap(settings.connectionLibrary.selected)
            let copy = try settings.duplicateAIConnection(id: source.id)
            XCTAssertEqual(copy.name, "\(source.name) copy")
            XCTAssertNotEqual(copy.id, source.id)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-shared-shape")
            XCTAssertEqual(keys.values[AppSettings.connectionKeyAccount(id: copy.id)], "fixture-shared-shape")
            settings.apiKeyDraft = "fixture-copy-only"
            try settings.saveAPIKey()
            try settings.selectAIConnection(id: source.id)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "fixture-shared-shape")
        }
    }

    @MainActor
    func testComparisonSelectionKeepsActiveEditorAndSeparateKeychainServices() throws {
        try withSettings { settings, _, keys in
            let openAI = try XCTUnwrap(settings.connectionLibrary.selected)
            settings.apiKeyDraft = "fixture-openai-key"
            try settings.saveAPIKey()
            let google = try settings.addAIConnection(name: "Google", provider: .google)
            settings.apiKeyDraft = "fixture-google-key"
            try settings.saveAPIKey()
            try settings.setComparisonIncluded(true, id: openAI.id)
            try settings.setComparisonIncluded(true, id: google.id)
            try settings.selectAIConnection(id: openAI.id)

            XCTAssertEqual(settings.connectionLibrary.selectedID, openAI.id, "Editing remains single-service")
            XCTAssertEqual(Set(settings.comparisonServiceConfigurations.map { $0.service.id }), Set([openAI.id, google.id]))
            XCTAssertEqual(keys.values[AppSettings.connectionKeyAccount(id: openAI.id)], "fixture-openai-key")
            XCTAssertEqual(keys.values[AppSettings.connectionKeyAccount(id: google.id)], "fixture-google-key")
        }
    }

    @MainActor
    func testServiceNamesAreValidatedAndUnreadableLibraryIsPreserved() throws {
        try withSettings { settings, _, _ in
            XCTAssertThrowsError(try settings.addAIConnection(name: "openai"))
            XCTAssertThrowsError(try settings.addAIConnection(name: "  "))
            XCTAssertThrowsError(try settings.addAIConnection(name: String(repeating: "x", count: 81)))
            try settings.addAIConnection(name: "Hive")
            XCTAssertEqual(settings.connectionLibrary.connections.count, 2)
        }
        try withDefaults { defaults, keys in
            let unreadable = Data("incomplete preferences".utf8)
            defaults.set(unreadable, forKey: AIConnectionLibrary.defaultsKey)
            let settings = AppSettings(defaults: defaults, keyStore: keys.store)
            XCTAssertEqual(settings.connectionLibraryIssue, AIConnectionLibrary.unreadableMessage)
            XCTAssertTrue(settings.connectionLibrary.connections.isEmpty)
            XCTAssertThrowsError(try settings.addAIConnection(name: "Hive"))
            XCTAssertEqual(defaults.data(forKey: AIConnectionLibrary.defaultsKey), unreadable)
            XCTAssertEqual(settings.providerConfiguration().apiKey, "")
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

    func testConnectionPingCopyDoesNotEchoProviderBodies() {
        XCTAssertEqual(AIConnectionTest.prompt, "Reply with the single word pong.")
        XCTAssertEqual(
            AIConnectionTest.sanitizePreview("  pong \n"),
            "pong"
        )
        XCTAssertTrue(AIConnectionTest.sanitizePreview(String(repeating: "x", count: 80)).hasSuffix("…"))
        XCTAssertEqual(
            AIConnectionTest.userMessage(for: AIProviderError.missingAPIKey),
            "Save an API key first, or paste one above and test before saving."
        )
        XCTAssertEqual(
            AIConnectionTest.userMessage(for: AIProviderError.httpStatus(401, "secret-token-should-not-appear")),
            "The key was rejected (HTTP 401). Check that it belongs to this endpoint."
        )
        XCTAssertFalse(
            AIConnectionTest.userMessage(for: AIProviderError.httpStatus(500, "captured-key")).contains("captured-key")
        )
        XCTAssertEqual(
            AIConnectionTest.successLine(
                result: ProviderPingResult(replyPreview: "pong", elapsedMs: 400),
                model: "deepseek-flash"
            ),
            "Key accepted. deepseek-flash replied “pong” in 0.4s."
        )
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
