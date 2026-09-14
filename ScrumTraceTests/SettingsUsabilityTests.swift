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
    func testDeselectedServicesStayDeselectedAfterRelaunch() throws {
        try withSettings { settings, defaults, keys in
            let id = try XCTUnwrap(settings.connectionLibrary.selectedID)
            try settings.setComparisonIncluded(false, id: id)
            let reloaded = AppSettings(defaults: defaults, keyStore: keys.store)
            XCTAssertTrue(reloaded.comparisonServiceConfigurations.isEmpty)
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

    @MainActor
    func testSpeechProfilesPersistSharedCredentialAndMultilingualStrategy() throws {
        try withSettings { settings, defaults, keys in
            let credential = "shared-fixture-credential"
            let first = SavedTranscriptionService(name: "OpenAI Romanian", backend: .openAITranscription, model: "gpt-transcribe", credentialID: credential, language: .one(.romanian), isIncludedInComparison: true)
            let second = SavedTranscriptionService(name: "OpenAI mixed", backend: .openAITranscription, model: "gpt-transcribe", credentialID: credential, language: .init(mode: .expected, languages: [.romanian, .english, .hungarian]), isIncludedInComparison: true)
            try settings.saveTranscriptionService(first, isNew: true)
            try settings.saveTranscriptionService(second, isNew: true)
            try settings.saveTranscriptionAPIKey("fixture-speech-key", credentialID: credential)

            let configured = settings.transcriptionServiceConfigurations(includedOnly: true)
            XCTAssertEqual(configured.count, 2)
            XCTAssertTrue(configured.allSatisfy { $0.apiKey == "fixture-speech-key" })
            XCTAssertNil(configured[1].service.language.singleEngineHint, "Expected-language mode must not serialize ro,en,hu as a false engine code")
            XCTAssertTrue(configured[1].service.language.explanation.contains("context/validation"))
            XCTAssertEqual(keys.values[AppSettings.transcriptionKeyAccount(id: credential)], "fixture-speech-key")

            let restored = AppSettings(defaults: defaults, keyStore: keys.store)
            XCTAssertEqual(restored.transcriptionServiceConfigurations(includedOnly: true).count, 2)
            XCTAssertEqual(restored.transcriptionLibrary.services.first { $0.id == second.id }?.language.languages, [.romanian, .english, .hungarian])
        }
    }

    func testTranscriptionRunsRemainSeparateAndPrimaryPromotionCopiesOnlyChosenText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SessionVault(rootURL: root)
        let created = try vault.createSession(product: .empty)
        let session = vault.sessionURL(id: created.manifest.sessionId)
        let config = TranscriptionServiceConfiguration.Snapshot(serviceID: "one", name: "One", backend: .whisperKit, endpoint: "", requestedModel: "base", language: .automatic, credentialRequired: false)
        let first = TranscriptionRun(id: "run-one", createdAt: Date(), status: .succeeded, configuration: config, inputs: [], resolvedModel: "openai_whisper-base", processingSeconds: 1, transcriptPath: TranscriptionRunStore.transcriptPath("run-one"), diagnostic: nil)
        let failed = TranscriptionRun(id: "run-two", createdAt: Date(), status: .failed, configuration: config, inputs: [], resolvedModel: nil, processingSeconds: 2, transcriptPath: nil, diagnostic: "fixture failure")
        try TranscriptionRunStore.save([first, failed], sessionURL: session)
        try TranscriptionRunStore.saveTranscript(FullTranscript(sessionId: "", language: "ro", segments: [.init(start: 0, end: 1, text: "Ales", speaker: nil, words: [])]), id: first.id, sessionURL: session)
        let promoted = try TranscriptionRunStore.selectPrimary(id: first.id, sessionURL: session)
        XCTAssertEqual(promoted.segments.first?.text, "Ales")
        XCTAssertEqual(try TranscriptionRunStore.load(sessionURL: session).map(\.id), ["run-one", "run-two"])
        XCTAssertEqual(TranscriptionRunStore.loadTranscript(id: first.id, sessionURL: session)?.segments.first?.text, "Ales")
    }

    func testCloudTranscriptionDecodesDocumentedDetectedLanguagesAndTimedSegments() async throws {
        let audio = try ExportRel.makePrivateTemporaryURL(prefix: "speech-http-fixture", ext: "m4a")
        defer { ExportRel.removePrivateTemporaryURL(audio) }
        try Data("AUDIO_ONLY_FIXTURE".utf8).write(to: audio)
        let service = SavedTranscriptionService(
            name: "fixture", backend: .openAITranscription, endpoint: "http://127.0.0.1:9999",
            model: "gpt-transcribe", credentialID: "fixture",
            language: .init(mode: .expected, languages: [.romanian, .english])
        )
        let engine = OpenAITranscriptionEngine { request in
            let body = try XCTUnwrap(request.httpBody)
            let text = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(text.contains("filename=\"audio.m4a\""))
            XCTAssertTrue(text.contains("AUDIO_ONLY_FIXTURE"))
            XCTAssertTrue(text.contains("name=\"languages[]\""))
            XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\nverbose_json"))
            XCTAssertTrue(text.contains("name=\"timestamp_granularities[]\""))
            XCTAssertFalse(text.contains("session.mp4"))
            XCTAssertFalse(text.contains("name=\"prompt\""))
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"text\":\"Salut. Hello.\",\"languages\":[{\"code\":\"ro\"},{\"code\":\"en\"}],\"segments\":[{\"start\":0,\"end\":1.5,\"text\":\"Salut. Hello.\"}]}".utf8), response)
        }
        let transcript = try await engine.transcribe(audioURL: audio, configuration: .init(service: service, apiKey: "fixture-key"))
        XCTAssertEqual(transcript.detectedLanguages, ["ro", "en"])
        XCTAssertEqual(transcript.language, "ro")
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertTrue(transcript.hasTimedSegments)
    }

    func testCloudTranscriptionKeepsUntimedTextWhenOptionalLanguagesAreAbsent() async throws {
        let audio = try ExportRel.makePrivateTemporaryURL(prefix: "speech-http-untimed", ext: "m4a")
        defer { ExportRel.removePrivateTemporaryURL(audio) }
        try Data("AUDIO_ONLY_FIXTURE".utf8).write(to: audio)
        let service = SavedTranscriptionService(name: "fixture", backend: .openAITranscription, endpoint: "http://127.0.0.1:9999", model: "gpt-4o-transcribe", credentialID: "fixture")
        let engine = OpenAITranscriptionEngine { request in
            let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)!
            XCTAssertFalse(body.contains("response_format"))
            XCTAssertFalse(body.contains("timestamp_granularities"))
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"text\":\"fără timestamps\"}".utf8), response)
        }
        let transcript = try await engine.transcribe(audioURL: audio, configuration: .init(service: service, apiKey: "fixture-key"))
        XCTAssertNil(transcript.detectedLanguages)
        XCTAssertEqual(transcript.untimedText, "fără timestamps")
        XCTAssertFalse(transcript.hasTimedSegments)
    }

    func testCloudTranscriptionReportsMalformedResponseRatherThanSavingEmptySuccess() async throws {
        let audio = try ExportRel.makePrivateTemporaryURL(prefix: "speech-http-malformed", ext: "m4a")
        defer { ExportRel.removePrivateTemporaryURL(audio) }
        try Data("AUDIO_ONLY_FIXTURE".utf8).write(to: audio)
        let service = SavedTranscriptionService(name: "fixture", backend: .openAITranscription, endpoint: "http://127.0.0.1:9999", model: "gpt-transcribe", credentialID: "fixture")
        let engine = OpenAITranscriptionEngine { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"text\":\"x\",\"languages\":[{\"wrong\":\"ro\"}]}".utf8), response)
        }
        do {
            _ = try await engine.transcribe(audioURL: audio, configuration: .init(service: service, apiKey: "fixture-key"))
            XCTFail("Malformed response must not become an empty success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be decoded"))
        }
    }

    func testCloudModelCapabilityMapDoesNotSendUndocumentedLanguageLists() async throws {
        let audio = try ExportRel.makePrivateTemporaryURL(prefix: "speech-http-capabilities", ext: "wav")
        defer { ExportRel.removePrivateTemporaryURL(audio) }
        try Data("WAV_FIXTURE".utf8).write(to: audio)
        let language = SpeechLanguageSelection(mode: .expected, languages: [.romanian, .english])
        for model in ["whisper-1", "gpt-4o-transcribe", "gpt-4o-transcribe-diarize"] {
            let service = SavedTranscriptionService(name: model, backend: .openAITranscription, endpoint: "http://127.0.0.1:9999", model: model, credentialID: "fixture", language: language)
            let engine = OpenAITranscriptionEngine { request in
                let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)!
                XCTAssertFalse(body.contains("name=\"languages[]\""), "\(model) does not document language lists")
                if model == "whisper-1" {
                    XCTAssertTrue(body.contains("verbose_json"))
                    XCTAssertTrue(body.contains("timestamp_granularities"))
                } else {
                    XCTAssertFalse(body.contains("verbose_json"))
                    XCTAssertFalse(body.contains("timestamp_granularities"))
                }
                let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("{\"text\":\"ok\"}".utf8), response)
            }
            _ = try await engine.transcribe(audioURL: audio, configuration: .init(service: service, apiKey: "fixture-key"))
        }
    }

    func testUntimedComparisonCannotReplacePrimaryTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("untimed-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SessionVault(rootURL: root)
        let created = try vault.createSession(product: .empty)
        let session = vault.sessionURL(id: created.manifest.sessionId)
        let config = TranscriptionServiceConfiguration.Snapshot(serviceID: "one", name: "One", backend: .openAITranscription, endpoint: "", requestedModel: "gpt-transcribe", whisperSource: nil, language: .automatic, credentialRequired: true)
        try TranscriptionRunStore.saveTranscript(FullTranscript(sessionId: "", language: "ro", segments: [], untimedText: "doar text"), id: "untimed", sessionURL: session)
        XCTAssertThrowsError(try TranscriptionRunStore.selectPrimary(id: "untimed", sessionURL: session))
        _ = config
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

    func testLegacyComparisonIndexLoadsWithHonestTransformAndKeepsHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SessionVault(rootURL: root)
        let created = try vault.createSession(product: .empty)
        let session = vault.sessionURL(id: created.manifest.sessionId)
        let config = TranscriptionServiceConfiguration.Snapshot(serviceID: "legacy", name: "Legacy", backend: .whisperKit, endpoint: "", requestedModel: "base", language: .automatic, credentialRequired: false)
        let old = TranscriptionRun(id: "old", createdAt: Date(), status: .succeeded, configuration: config,
            inputs: [.init(source: "archive/audio.wav", transform: "direct_audio", sha256: "abc", bytes: 42, startMediaSeconds: nil)],
            resolvedModel: "base", processingSeconds: 1, transcriptPath: TranscriptionRunStore.transcriptPath("old"), diagnostic: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([old])) as? [[String: Any]])
        var inputs = try XCTUnwrap(json[0]["inputs"] as? [[String: Any]])
        inputs[0].removeValue(forKey: "transform")
        json[0]["inputs"] = inputs
        try ExportRel.writeContainedData(try JSONSerialization.data(withJSONObject: json), relative: TranscriptionRunStore.indexPath, sessionURL: session)
        try TranscriptionRunStore.saveTranscript(FullTranscript(sessionId: created.manifest.sessionId, language: "ro", segments: [.init(start: 0, end: 1, text: "istoric", speaker: nil, words: [])]), id: "old", sessionURL: session)

        var loaded = try TranscriptionRunStore.load(sessionURL: session)
        XCTAssertEqual(loaded.map(\.id), ["old"])
        XCTAssertEqual(loaded[0].inputs[0].transform, "legacy_unknown")
        let new = TranscriptionRun(id: "new", createdAt: Date(), status: .failed, configuration: config, inputs: [], resolvedModel: nil, processingSeconds: nil, transcriptPath: nil, diagnostic: "fixture")
        loaded.append(new)
        try TranscriptionRunStore.save(loaded, sessionURL: session)
        XCTAssertEqual(try TranscriptionRunStore.load(sessionURL: session).map(\.id), ["old", "new"])
        XCTAssertEqual(TranscriptionRunStore.loadTranscript(id: "old", sessionURL: session)?.segments.first?.text, "istoric")
    }

    func testUnreadableComparisonIndexFailsWithoutOverwritingArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SessionVault(rootURL: root)
        let created = try vault.createSession(product: .empty)
        let session = vault.sessionURL(id: created.manifest.sessionId)
        let bytes = Data("{ corrupt history".utf8)
        try ExportRel.writeContainedData(bytes, relative: TranscriptionRunStore.indexPath, sessionURL: session)
        XCTAssertThrowsError(try TranscriptionRunStore.load(sessionURL: session)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unreadable"))
        }
        XCTAssertEqual(ExportRel.readContainedData(relative: TranscriptionRunStore.indexPath, sessionURL: session), bytes)
    }

    func testAbsentComparisonIndexStartsHistoryNormally() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("absent-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SessionVault(rootURL: root)
        let created = try vault.createSession(product: .empty)
        let session = vault.sessionURL(id: created.manifest.sessionId)
        XCTAssertTrue(try TranscriptionRunStore.load(sessionURL: session).isEmpty)
        try TranscriptionRunStore.save([], sessionURL: session)
        XCTAssertTrue(try TranscriptionRunStore.load(sessionURL: session).isEmpty)
    }

    func testReviewTextIncludesUntimedAndTimedPassages() {
        let transcript = FullTranscript(sessionId: "review", language: "ro", segments: [.init(start: 0, end: 1, text: "segment", speaker: nil, words: [])], untimedText: "untimed")
        XCTAssertEqual(TranscriptionReviewText.fullText(transcript), "segment\n\nuntimed")
        XCTAssertEqual(TranscriptionReviewText.fullText(FullTranscript(sessionId: "review", language: "ro", segments: [], untimedText: "only untimed")), "only untimed")
    }

    func testLaterPromotionInvalidatesDependentStagesWithoutRerunningComparison() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("promotion-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SessionVault(rootURL: root)
        let created = try vault.createSession(product: .empty)
        let session = vault.sessionURL(id: created.manifest.sessionId)
        let config = TranscriptionServiceConfiguration.Snapshot(serviceID: "one", name: "One", backend: .whisperKit, endpoint: "", requestedModel: "base", language: .automatic, credentialRequired: false)
        let run = TranscriptionRun(id: "later", createdAt: Date(), status: .succeeded, configuration: config, inputs: [], resolvedModel: "base", processingSeconds: 1, transcriptPath: TranscriptionRunStore.transcriptPath("later"), diagnostic: nil)
        try TranscriptionRunStore.save([run], sessionURL: session)
        try TranscriptionRunStore.saveTranscript(FullTranscript(sessionId: created.manifest.sessionId, language: "ro", segments: [.init(start: 0, end: 1, text: "chosen later", speaker: nil, words: [])]), id: run.id, sessionURL: session)
        var manifest = try vault.loadManifest(id: created.manifest.sessionId)
        manifest.completedStages = [.transcribing, .slicing, .evaluating, .synthesizing, .completed]
        manifest.slices = [.init(sliceId: "old", startMedia: 0, endMedia: 1, trigger: .pin, associatedShotId: nil, clipPath: "media/old.mp4", stills: [], analysisStatus: .success, score: 1)]
        try vault.write(manifest: &manifest)

        _ = try SessionProcessor(vault: vault, transcriber: WhisperTranscriber()).selectPrimaryTranscription(sessionId: created.manifest.sessionId, runID: run.id)
        let reloaded = try vault.loadManifest(id: created.manifest.sessionId)
        XCTAssertTrue(reloaded.slices.isEmpty)
        XCTAssertTrue(reloaded.hasCompleted(.transcribing))
        XCTAssertFalse(reloaded.hasCompleted(.slicing))
        XCTAssertEqual(try TranscriptionRunStore.load(sessionURL: session).map(\.id), ["later"])
    }

    func testProcessorReusesSavedPrimaryWithoutTouchingLocalLoader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-primary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SessionVault(rootURL: root)
        let created = try vault.createSession(product: .empty)
        let session = vault.sessionURL(id: created.manifest.sessionId)
        let primary = FullTranscript(sessionId: created.manifest.sessionId, language: "ro", segments: [.init(start: 0, end: 1, text: "keep exactly this", speaker: nil, words: [])])
        try SpeakerTimeline.save(primary, sessionURL: session)
        let original = try XCTUnwrap(ExportRel.readContainedData(relative: ScrumTracePath.fullTranscript, sessionURL: session))
        let loader = ModelLoader()
        await loader.failNextLoad()
        let processor = SessionProcessor(vault: vault, transcriber: WhisperTranscriber(loadModel: { try await loader.load($0) }))
        let localOnly = AIProviderConfiguration(kind: .openaiCompatible, baseURL: "https://example.invalid", model: "unused", apiKey: "", acceptsText: true, acceptsImages: false, acceptsVideo: false)

        _ = try await processor.process(sessionId: created.manifest.sessionId, pinTimes: [], configuration: localOnly, whisperModel: "missing", identifySpeakers: false) { _, _ in }
        let loaderCalls = await loader.models
        XCTAssertTrue(loaderCalls.isEmpty)
        XCTAssertEqual(ExportRel.readContainedData(relative: ScrumTracePath.fullTranscript, sessionURL: session), original)
    }

    @MainActor
    func testRetryAnalysisDoesNotLoadUnavailableLocalModelWhenPrimaryIsValid() async throws {
        let loader = ModelLoader()
        await loader.failNextLoad()
        let transcriber = WhisperTranscriber(loadModel: { try await loader.load($0) })
        let service = SavedTranscriptionService(name: "unavailable folder", backend: .whisperKit, model: "missing", whisperSource: .folder("/definitely/unavailable"))
        let reused = try await prepareLocalTranscriptionIfNeeded(transcriber: transcriber, service: service, reusingPrimaryTranscript: true)
        let callsWhileReusing = await loader.models
        XCTAssertEqual(reused, "missing")
        XCTAssertTrue(callsWhileReusing.isEmpty)

        let recoveryService = SavedTranscriptionService(name: "loader failure", backend: .whisperKit, model: "missing")
        do {
            _ = try await prepareLocalTranscriptionIfNeeded(transcriber: transcriber, service: recoveryService, reusingPrimaryTranscript: false)
            XCTFail("An invalid primary must not skip recovery preparation")
        } catch { }
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
