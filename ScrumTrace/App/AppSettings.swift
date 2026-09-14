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

    /// Host-scoped accounts remain only as import fallbacks for one migrated service.
    private var applyingConnection = false
    @Published private(set) var connectionLibrary: AIConnectionLibrary
    let connectionLibraryIssue: String?
    @Published private(set) var hasSavedAPIKey = false

    @Published var provider: AIProviderKind {
        didSet {
            guard provider != oldValue else { return }
            defaults.set(provider.rawValue, forKey: Keys.provider)
            if applyingConnection { return }
            applyingConnection = true
            baseURL = provider.defaultBaseURL
            model = provider.defaultModel
            applyingConnection = false
            persistSelectedConnectionFields()
            apiKeyDraft = ""
            refreshKeyStatus()
        }
    }

    @Published var baseURL: String {
        didSet {
            defaults.set(baseURL, forKey: Keys.baseURL)
            defaults.set(baseURL, forKey: Keys.profile(provider, "baseURL"))
            if applyingConnection { return }
            persistSelectedConnectionFields()
            apiKeyDraft = ""
            refreshKeyStatus()
        }
    }

    @Published var model: String {
        didSet {
            defaults.set(model, forKey: Keys.model)
            defaults.set(model, forKey: Keys.profile(provider, "model"))
            if applyingConnection { return }
            persistSelectedConnectionFields()
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

    @Published private(set) var contextLibrary: ProductContextLibrary
    let contextLibraryIssue: String?

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

    /// While the main window is open, ScrumTrace has a Dock tile and a place in Command-Tab. Closing the window
    /// returns it to a menu-bar accessory either way.
    @Published var showInDockWhileWindowOpen: Bool {
        didSet { defaults.set(showInDockWhileWindowOpen, forKey: Keys.showInDock) }
    }

    @Published var apiKeyDraft: String

    var productContext: ProductContext {
        contextLibrary.selected?.snapshot ?? .empty
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
        let contexts = ProductContextLibrary.load(from: defaults)
        self.contextLibrary = contexts.library
        self.contextLibraryIssue = contexts.issue
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
        self.showInDockWhileWindowOpen = defaults.object(forKey: Keys.showInDock) as? Bool ?? true
        self.apiKeyDraft = ""
        let loaded = AIConnectionLibrary.load(from: defaults)
        self.connectionLibraryIssue = loaded.issue
        if loaded.migrated {
            let imported = SavedAIConnection(
                name: AIConnectionNaming.suggestedName(provider: selectedProvider, endpoint: endpoint),
                provider: selectedProvider,
                baseURL: endpoint,
                model: selectedModel,
                fallbackKeyAccount: Self.importedFallbackAccount(
                    provider: selectedProvider,
                    endpoint: endpoint,
                    legacyScope: legacyCredentialScope,
                    keyStore: keyStore
                )
            )
            var library = AIConnectionLibrary()
            library.connections = [imported]
            library.selectedID = imported.id
            if let data = try? JSONEncoder().encode(library) {
                defaults.set(data, forKey: AIConnectionLibrary.defaultsKey)
            }
            self.connectionLibrary = library
        } else {
            self.connectionLibrary = loaded.library
            if let selected = loaded.library.selected {
                self.provider = selected.provider
                self.baseURL = selected.baseURL
                self.model = selected.model
            }
        }
        defaults.set(provider.rawValue, forKey: Keys.provider)
        defaults.set(baseURL, forKey: Keys.baseURL)
        defaults.set(model, forKey: Keys.model)
        defaults.set(baseURL, forKey: Keys.profile(provider, "baseURL"))
        defaults.set(model, forKey: Keys.profile(provider, "model"))
        defaults.set(legacyCredentialScope, forKey: Keys.legacyCredentialScope)
        refreshKeyStatus()
    }

    func saveProductContext(_ profile: SavedProductContext, isNew: Bool) throws {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, profile.name.count <= 80 else {
            throw SettingsValidationError("Enter a context name of up to 80 characters.")
        }
        guard !contextLibrary.profiles.contains(where: {
            $0.id != profile.id && $0.name.compare(profile.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { throw SettingsValidationError("A context with this name already exists. Choose a different name.") }
        profile.product.appName = profile.product.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.product.repoURL = profile.product.repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.product.techStack = profile.product.techStack.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.product.contextID = nil
        profile.product.contextName = nil
        var library = contextLibrary
        if isNew {
            guard !profile.id.isEmpty, !library.profiles.contains(where: { $0.id == profile.id }) else {
                throw SettingsValidationError("This context already exists. Reopen the editor.")
            }
            library.profiles.append(profile)
        } else {
            guard let index = library.profiles.firstIndex(where: { $0.id == profile.id }) else {
                throw SettingsValidationError("This context was deleted. Close the editor and add a new context.")
            }
            library.profiles[index] = profile
        }
        try persistContexts(library)
    }

    func deleteProductContext(id: String) throws {
        var library = contextLibrary
        library.profiles.removeAll { $0.id == id }
        if library.selectedID == id { library.selectedID = nil }
        try persistContexts(library)
    }

    /// Explicit nil means "No context"; never substitute another saved profile.
    @discardableResult
    func selectProductContext(id: String?) throws -> ProductContext {
        if contextLibraryIssue != nil, id == nil { return .empty }
        guard id == nil || contextLibrary.profiles.contains(where: { $0.id == id }) else {
            throw SettingsValidationError("The selected context is no longer available. Choose another context.")
        }
        var library = contextLibrary
        library.selectedID = id
        try persistContexts(library)
        return library.selected?.snapshot ?? .empty
    }

    private func persistContexts(_ library: ProductContextLibrary) throws {
        if let contextLibraryIssue { throw SettingsValidationError(contextLibraryIssue) }
        let data = try JSONEncoder().encode(library)
        defaults.set(data, forKey: ProductContextLibrary.defaultsKey)
        contextLibrary = library
    }

    func saveAIConnection(_ connection: SavedAIConnection, isNew: Bool) throws {
        var connection = connection
        connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !connection.name.isEmpty, connection.name.count <= 80 else {
            throw SettingsValidationError("Enter a service name of up to 80 characters.")
        }
        guard !connectionLibrary.connections.contains(where: {
            $0.id != connection.id
                && $0.name.compare(connection.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            throw SettingsValidationError("A service with this name already exists. Choose a different name.")
        }
        var library = connectionLibrary
        if isNew {
            guard !connection.id.isEmpty, !library.connections.contains(where: { $0.id == connection.id }) else {
                throw SettingsValidationError("This service already exists. Reopen the editor.")
            }
            connection.fallbackKeyAccount = nil
            library.connections.append(connection)
        } else {
            guard let index = library.connections.firstIndex(where: { $0.id == connection.id }) else {
                throw SettingsValidationError("This service was deleted. Close the editor and add a new service.")
            }
            library.connections[index].name = connection.name
        }
        try persistConnections(library)
    }

    @discardableResult
    func addAIConnection(
        name: String,
        provider: AIProviderKind = .openaiCompatible,
        baseURL: String? = nil,
        model: String? = nil
    ) throws -> SavedAIConnection {
        let connection = SavedAIConnection(
            name: name,
            provider: provider,
            baseURL: baseURL ?? provider.defaultBaseURL,
            model: model ?? provider.defaultModel
        )
        try saveAIConnection(connection, isNew: true)
        try selectAIConnection(id: connection.id)
        return connection
    }

    @discardableResult
    func duplicateAIConnection(id: String) throws -> SavedAIConnection {
        guard let source = connectionLibrary.connections.first(where: { $0.id == id }) else {
            throw SettingsValidationError("This service is no longer available. Choose another service.")
        }
        var copy = source
        copy.id = UUID().uuidString
        copy.name = uniqueConnectionName(copying: source.name)
        copy.fallbackKeyAccount = nil
        try saveAIConnection(copy, isNew: true)
        if let secret = storedAPIKey(for: source) {
            try keyStore.set(secret, Self.connectionKeyAccount(id: copy.id))
        }
        try selectAIConnection(id: copy.id)
        return copy
    }

    func deleteAIConnection(id: String) throws {
        guard let connection = connectionLibrary.connections.first(where: { $0.id == id }) else {
            throw SettingsValidationError("This service is no longer available. Choose another service.")
        }
        try keyStore.remove(Self.connectionKeyAccount(id: id))
        if let fallback = connection.fallbackKeyAccount {
            try keyStore.remove(fallback)
        }
        var library = connectionLibrary
        library.connections.removeAll { $0.id == id }
        if library.selectedID == id { library.selectedID = nil }
        try persistConnections(library)
        apiKeyDraft = ""
        refreshKeyStatus()
    }

    /// Explicit nil means "No service"; never substitute another saved service.
    func selectAIConnection(id: String?) throws {
        if let connectionLibraryIssue {
            if id == nil {
                apiKeyDraft = ""
                refreshKeyStatus()
                return
            }
            throw SettingsValidationError(connectionLibraryIssue)
        }
        guard id == nil || connectionLibrary.connections.contains(where: { $0.id == id }) else {
            throw SettingsValidationError("The selected service is no longer available. Choose another service.")
        }
        var library = connectionLibrary
        library.selectedID = id
        try persistConnections(library)
        applyingConnection = true
        if let selected = library.selected {
            provider = selected.provider
            baseURL = selected.baseURL
            model = selected.model
        }
        applyingConnection = false
        apiKeyDraft = ""
        refreshKeyStatus()
    }

    private func persistConnections(_ library: AIConnectionLibrary) throws {
        if let connectionLibraryIssue { throw SettingsValidationError(connectionLibraryIssue) }
        let data = try JSONEncoder().encode(library)
        defaults.set(data, forKey: AIConnectionLibrary.defaultsKey)
        connectionLibrary = library
    }

    private func persistSelectedConnectionFields() {
        guard !applyingConnection,
              connectionLibraryIssue == nil,
              let index = connectionLibrary.connections.firstIndex(where: { $0.id == connectionLibrary.selectedID })
        else { return }
        var library = connectionLibrary
        library.connections[index].provider = provider
        library.connections[index].baseURL = baseURL
        library.connections[index].model = model
        if let data = try? JSONEncoder().encode(library) {
            defaults.set(data, forKey: AIConnectionLibrary.defaultsKey)
            connectionLibrary = library
        }
    }

    private func uniqueConnectionName(copying name: String) -> String {
        let base = String(name.prefix(65))
        var number = 1
        var candidate = "\(base) copy"
        while connectionLibrary.connections.contains(where: {
            $0.name.compare(candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            number += 1
            candidate = "\(base) copy \(number)"
        }
        return candidate
    }

    private func persistCaptureArea() {
        if let data = try? JSONEncoder().encode(captureArea) {
            defaults.set(data, forKey: Keys.captureArea)
        }
    }

    func saveAPIKey() throws {
        guard let selected = connectionLibrary.selected else {
            throw SettingsValidationError("Select or add a service before saving a key.")
        }
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsValidationError("Enter a key to save. Use Remove saved key to delete it.") }
        _ = try ProviderEndpoint.requireHTTPSOrLocal(baseURL)
        try keyStore.set(trimmed, Self.connectionKeyAccount(id: selected.id))
        if selected.fallbackKeyAccount != nil {
            clearFallbackKeyAccount(id: selected.id)
        }
        apiKeyDraft = ""
        refreshKeyStatus()
    }

    func removeSavedAPIKey() throws {
        guard let selected = connectionLibrary.selected else {
            throw SettingsValidationError("Select or add a service before removing a key.")
        }
        try keyStore.remove(Self.connectionKeyAccount(id: selected.id))
        if let fallback = selected.fallbackKeyAccount {
            try keyStore.remove(fallback)
            clearFallbackKeyAccount(id: selected.id)
        }
        apiKeyDraft = ""
        refreshKeyStatus()
    }

    func refreshKeyStatus() {
        guard let selected = connectionLibrary.selected else {
            hasSavedAPIKey = false
            return
        }
        hasSavedAPIKey = keyStore.contains(Self.connectionKeyAccount(id: selected.id))
            || (selected.fallbackKeyAccount.map(keyStore.contains) ?? false)
    }

    func providerConfiguration(includeKey: Bool = true) -> AIProviderConfiguration {
        var key = ""
        if includeKey,
           let selected = connectionLibrary.selected,
           (try? ProviderEndpoint.requireHTTPSOrLocal(baseURL)) != nil {
            key = storedAPIKey(for: selected) ?? ""
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
        if connectionLibrary.selected == nil {
            return "No service selected. Add one to use AI analysis. Recording and local export remain available."
        }
        if let configurationIssue { return configurationIssue }
        return hasSavedAPIKey
            ? "Configured locally. Key validity and model availability have not been checked online."
            : "No saved key for this service. Recording and local export remain available."
    }

    static func connectionKeyAccount(id: String) -> String {
        "ai.apiKey.connection.\(id)"
    }

    private func storedAPIKey(for connection: SavedAIConnection) -> String? {
        keyStore.get(Self.connectionKeyAccount(id: connection.id))
            ?? connection.fallbackKeyAccount.flatMap { keyStore.get($0) }
    }

    private func clearFallbackKeyAccount(id: String) {
        guard let index = connectionLibrary.connections.firstIndex(where: { $0.id == id }) else { return }
        var library = connectionLibrary
        library.connections[index].fallbackKeyAccount = nil
        if let data = try? JSONEncoder().encode(library) {
            defaults.set(data, forKey: AIConnectionLibrary.defaultsKey)
            connectionLibrary = library
        }
    }

    private static func importedFallbackAccount(
        provider: AIProviderKind,
        endpoint: String,
        legacyScope: String,
        keyStore: SettingsKeyStore
    ) -> String? {
        let scope = credentialScope(provider: provider, endpoint: endpoint)
        let hostAccount = "ai.apiKey.\(scope)"
        if keyStore.contains(hostAccount) { return hostAccount }
        if scope == legacyScope && keyStore.contains("ai.apiKey") { return "ai.apiKey" }
        return nil
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
        static let includeTranscript = "scrumtrace.includeFullTranscript"
        static let allowGoogleClip = "scrumtrace.allowGoogleClipUpload"
        static let retentionDays = "scrumtrace.retentionDays"
        static let meetingNotice = "scrumtrace.meetingNoticeAccepted"
        static let captureArea = "scrumtrace.captureArea"
        static let showCursor = "scrumtrace.showCursor"
        static let includeMicrophone = "scrumtrace.includeMicrophone"
        static let showInDock = "scrumtrace.showInDock"
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
