import Combine
import Foundation

enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openaiCompatible = "openai_compatible"
    case anthropic
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openaiCompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        }
    }

    var defaultModel: String {
        switch self {
        case .openaiCompatible: return "gpt-4o"
        case .anthropic: return "claude-sonnet-5"
        case .google: return "gemini-2.5-flash"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openaiCompatible: return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .google: return "https://generativelanguage.googleapis.com"
        }
    }
}

struct AIProviderConfiguration: Sendable {
    var kind: AIProviderKind
    var baseURL: String
    var model: String
    var apiKey: String
    var acceptsText: Bool
    var acceptsImages: Bool
    var acceptsVideo: Bool

    static func isRetiredAnthropic(_ model: String) -> Bool {
        let lowered = model.lowercased()
        return lowered.contains("claude-3-5") || lowered.contains("claude-3.5")
            || lowered.contains("claude-3-7") || lowered.contains("claude-3.7")
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults: UserDefaults
    private let keyStore: SettingsKeyStore
    private let legacyCredentialScope: String

    /// The legacy key belongs only to the provider/endpoint selected on upgrade.
    /// New saves are scoped so switching a backend cannot reuse another service's key.
    private var credentialScope: String { Self.credentialScope(provider: provider, endpoint: baseURL) }
    private var keyAccount: String { "ai.apiKey.\(credentialScope)" }
    @Published private(set) var hasSavedAPIKey = false

    @Published var provider: AIProviderKind {
        didSet {
            guard provider != oldValue else { return }
            defaults.set(provider.rawValue, forKey: Keys.provider)
            let endpoint = defaults.string(forKey: Keys.profile(provider, "baseURL")) ?? provider.defaultBaseURL
            let selectedModel = defaults.string(forKey: Keys.profile(provider, "model")) ?? provider.defaultModel
            baseURL = endpoint
            model = selectedModel
            apiKeyDraft = ""
            refreshKeyStatus()
        }
    }

    @Published var baseURL: String {
        didSet {
            defaults.set(baseURL, forKey: Keys.baseURL)
            defaults.set(baseURL, forKey: Keys.profile(provider, "baseURL"))
            if Self.credentialScope(provider: provider, endpoint: oldValue) != credentialScope {
                apiKeyDraft = ""
                refreshKeyStatus()
            }
        }
    }

    @Published var model: String {
        didSet {
            defaults.set(model, forKey: Keys.model)
            defaults.set(model, forKey: Keys.profile(provider, "model"))
        }
    }

    @Published var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: Keys.whisperModel) }
    }

    @Published var identifySpeakers: Bool {
        didSet { defaults.set(identifySpeakers, forKey: Keys.identifySpeakers) }
    }

    @Published var speechLanguage: SpeechLanguage {
        didSet { defaults.set(speechLanguage.rawValue, forKey: Keys.speechLanguage) }
    }

    @Published var appName: String {
        didSet { defaults.set(appName, forKey: Keys.appName) }
    }

    @Published var repoURL: String {
        didSet { defaults.set(repoURL, forKey: Keys.repoURL) }
    }

    @Published var techStack: String {
        didSet { defaults.set(techStack, forKey: Keys.techStack) }
    }

    @Published var includeFullTranscriptInZip: Bool {
        didSet { defaults.set(includeFullTranscriptInZip, forKey: Keys.includeTranscript) }
    }

    @Published var allowGoogleClipUpload: Bool {
        didSet { defaults.set(allowGoogleClipUpload, forKey: Keys.allowGoogleClip) }
    }

    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Keys.retentionDays) }
    }

    @Published var meetingNoticeAccepted: Bool {
        didSet { defaults.set(meetingNoticeAccepted, forKey: Keys.meetingNotice) }
    }

    @Published var captureArea: CaptureArea {
        didSet { persistCaptureArea() }
    }

    @Published var showCursor: Bool {
        didSet { defaults.set(showCursor, forKey: Keys.showCursor) }
    }

    @Published var includeMicrophone: Bool {
        didSet { defaults.set(includeMicrophone, forKey: Keys.includeMicrophone) }
    }

    @Published var apiKeyDraft: String

    var productContext: ProductContext {
        ProductContext(appName: appName, repoURL: repoURL, techStack: techStack)
    }

    init(defaults: UserDefaults = .standard, keyStore: SettingsKeyStore = .live) {
        self.defaults = defaults
        self.keyStore = keyStore
        let storedProvider = defaults.string(forKey: Keys.provider).flatMap(AIProviderKind.init(rawValue:))
        let selectedProvider = storedProvider ?? .openaiCompatible
        let endpoint = defaults.string(forKey: Keys.profile(selectedProvider, "baseURL"))
            ?? defaults.string(forKey: Keys.baseURL) ?? selectedProvider.defaultBaseURL
        let selectedModel = defaults.string(forKey: Keys.profile(selectedProvider, "model"))
            ?? defaults.string(forKey: Keys.model) ?? selectedProvider.defaultModel
        self.provider = selectedProvider
        self.baseURL = endpoint
        self.model = selectedModel
        self.legacyCredentialScope = defaults.string(forKey: Keys.legacyCredentialScope)
            ?? Self.credentialScope(provider: selectedProvider, endpoint: endpoint)
        let storedWhisper = defaults.string(forKey: Keys.whisperModel) ?? WhisperTranscriber.defaultStoredModel
        self.whisperModel = Self.migratedWhisperModel(storedWhisper)
        self.identifySpeakers = defaults.object(forKey: Keys.identifySpeakers) as? Bool ?? true
        self.speechLanguage = defaults.string(forKey: Keys.speechLanguage).flatMap(SpeechLanguage.init(rawValue:)) ?? .automatic
        self.appName = defaults.string(forKey: Keys.appName) ?? ""
        self.repoURL = defaults.string(forKey: Keys.repoURL) ?? ""
        self.techStack = defaults.string(forKey: Keys.techStack) ?? ""
        self.includeFullTranscriptInZip = defaults.bool(forKey: Keys.includeTranscript)
        self.allowGoogleClipUpload = defaults.object(forKey: Keys.allowGoogleClip) as? Bool ?? false
        self.retentionDays = defaults.object(forKey: Keys.retentionDays) as? Int ?? 0
        self.meetingNoticeAccepted = defaults.bool(forKey: Keys.meetingNotice)
        if let data = defaults.data(forKey: Keys.captureArea),
           let stored = try? JSONDecoder().decode(CaptureArea.self, from: data) {
            self.captureArea = stored
        } else {
            self.captureArea = .entireDisplay
        }
        self.showCursor = defaults.object(forKey: Keys.showCursor) as? Bool ?? true
        self.includeMicrophone = defaults.object(forKey: Keys.includeMicrophone) as? Bool ?? true
        self.apiKeyDraft = ""
        defaults.set(endpoint, forKey: Keys.profile(selectedProvider, "baseURL"))
        defaults.set(selectedModel, forKey: Keys.profile(selectedProvider, "model"))
        defaults.set(legacyCredentialScope, forKey: Keys.legacyCredentialScope)
        refreshKeyStatus()
    }

    private func persistCaptureArea() {
        if let data = try? JSONEncoder().encode(captureArea) {
            defaults.set(data, forKey: Keys.captureArea)
        }
    }

    func saveAPIKey() throws {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsValidationError("Enter a key to save. Use Remove saved key to delete it.") }
        _ = try ProviderEndpoint.requireHTTPSOrLocal(baseURL)
        try keyStore.set(trimmed, keyAccount)
        apiKeyDraft = ""
        refreshKeyStatus()
    }

    func removeSavedAPIKey() throws {
        try keyStore.remove(keyAccount)
        if credentialScope == legacyCredentialScope { try keyStore.remove("ai.apiKey") }
        apiKeyDraft = ""
        refreshKeyStatus()
    }

    func refreshKeyStatus() {
        hasSavedAPIKey = keyStore.contains(keyAccount)
            || (credentialScope == legacyCredentialScope && keyStore.contains("ai.apiKey"))
    }

    func providerConfiguration(includeKey: Bool = true) -> AIProviderConfiguration {
        var key = ""
        if includeKey, (try? ProviderEndpoint.requireHTTPSOrLocal(baseURL)) != nil {
            key = keyStore.get(keyAccount)
                ?? (credentialScope == legacyCredentialScope ? keyStore.get("ai.apiKey") : nil) ?? ""
        }
        return AIProviderConfiguration(
            kind: provider,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: key,
            acceptsText: true,
            acceptsImages: provider != .anthropic || !model.isEmpty,
            acceptsVideo: ProviderWireMedia.adapterCanUploadVideo(provider) && allowGoogleClipUpload
        )
    }

    var configurationIssue: String? {
        do {
            try providerConfiguration(includeKey: false).validate()
            return nil
        } catch { return error.localizedDescription }
    }

    var configurationSummary: String {
        if let configurationIssue { return configurationIssue }
        return hasSavedAPIKey
            ? "Configured locally. Key validity and model availability have not been checked online."
            : "No saved key for this endpoint. Recording and local export remain available."
    }

    func applyProviderDefaults() {
        baseURL = provider.defaultBaseURL
        model = provider.defaultModel
    }

    static func credentialScope(provider: AIProviderKind, endpoint: String) -> String {
        guard let url = try? ProviderEndpoint.requireHTTPSOrLocal(endpoint),
              let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else {
            return "\(provider.rawValue).invalid"
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(provider.rawValue).\(scheme)://\(host):\(port)"
    }

    static func migratedWhisperModel(_ stored: String) -> String {
        let kit = WhisperTranscriber.whisperKitModelName(stored)
        if kit == WhisperTranscriber.defaultKitModel {
            return WhisperTranscriber.defaultStoredModel
        }
        if kit == WhisperTranscriber.uncompressedKitModel {
            return "large-v3_turbo_uncompressed"
        }
        return stored
    }

    private enum Keys {
        static let provider = "scrumtrace.provider"
        static let baseURL = "scrumtrace.baseURL"
        static let model = "scrumtrace.model"
        static let whisperModel = "scrumtrace.whisperModel"
        static let identifySpeakers = "scrumtrace.identifySpeakers"
        static let speechLanguage = "scrumtrace.speechLanguage"
        static let legacyCredentialScope = "scrumtrace.legacyCredentialScope"
        static func profile(_ provider: AIProviderKind, _ field: String) -> String {
            "scrumtrace.ai.\(provider.rawValue).\(field)"
        }
        static let appName = "scrumtrace.appName"
        static let repoURL = "scrumtrace.repoURL"
        static let techStack = "scrumtrace.techStack"
        static let includeTranscript = "scrumtrace.includeFullTranscript"
        static let allowGoogleClip = "scrumtrace.allowGoogleClipUpload"
        static let retentionDays = "scrumtrace.retentionDays"
        static let meetingNotice = "scrumtrace.meetingNoticeAccepted"
        static let captureArea = "scrumtrace.captureArea"
        static let showCursor = "scrumtrace.showCursor"
        static let includeMicrophone = "scrumtrace.includeMicrophone"
    }
}

/// Injectable storage keeps preference tests away from the user's Keychain.
struct SettingsKeyStore {
    var get: (String) -> String?
    var contains: (String) -> Bool
    var set: (String, String) throws -> Void
    var remove: (String) throws -> Void

    static let live = SettingsKeyStore(
        get: { KeychainStore.get(account: $0) },
        contains: { KeychainStore.contains(account: $0) },
        set: { try KeychainStore.set($0, account: $1) },
        remove: { try KeychainStore.remove(account: $0) }
    )
    static let empty = SettingsKeyStore(get: { _ in nil }, contains: { _ in false }, set: { _, _ in }, remove: { _ in })
}

struct SettingsValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension AIProviderConfiguration {
    func validate() throws {
        _ = try ProviderEndpoint.requireHTTPSOrLocal(baseURL)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsValidationError("Enter the model ID supplied by your provider.")
        }
        if kind == .anthropic && Self.isRetiredAnthropic(model) {
            throw SettingsValidationError("This Anthropic model is retired. Choose a supported model ID.")
        }
        let path = URL(string: baseURL)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        if path.hasSuffix("chat/completions") || path.hasSuffix("messages") {
            throw SettingsValidationError("Enter the API root, without /chat/completions or /messages.")
        }
    }
}
