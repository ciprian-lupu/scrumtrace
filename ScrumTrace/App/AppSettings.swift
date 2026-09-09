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
        case .anthropic: return "" // Set a currently documented Messages API model in Settings. Do not use retired 3.5 / 3.7 IDs.
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
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults: UserDefaults
    private let keyAccount = "ai.apiKey"

    @Published var provider: AIProviderKind {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }

    @Published var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Keys.baseURL) }
    }

    @Published var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }

    @Published var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: Keys.whisperModel) }
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

    @Published var apiKeyDraft: String

    var productContext: ProductContext {
        ProductContext(appName: appName, repoURL: repoURL, techStack: techStack)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedProvider = defaults.string(forKey: Keys.provider).flatMap(AIProviderKind.init(rawValue:))
        self.provider = storedProvider ?? .openaiCompatible
        self.baseURL = defaults.string(forKey: Keys.baseURL) ?? AIProviderKind.openaiCompatible.defaultBaseURL
        self.model = defaults.string(forKey: Keys.model) ?? AIProviderKind.openaiCompatible.defaultModel
        self.whisperModel = defaults.string(forKey: Keys.whisperModel) ?? "large-v3-turbo"
        self.appName = defaults.string(forKey: Keys.appName) ?? ""
        self.repoURL = defaults.string(forKey: Keys.repoURL) ?? ""
        self.techStack = defaults.string(forKey: Keys.techStack) ?? ""
        self.includeFullTranscriptInZip = defaults.bool(forKey: Keys.includeTranscript)
        self.apiKeyDraft = KeychainStore.get(account: keyAccount) ?? ""
    }

    func saveAPIKey() throws {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: keyAccount)
        } else {
            try KeychainStore.set(trimmed, account: keyAccount)
        }
    }

    func providerConfiguration() -> AIProviderConfiguration {
        AIProviderConfiguration(
            kind: provider,
            baseURL: baseURL,
            model: model,
            apiKey: KeychainStore.get(account: keyAccount) ?? apiKeyDraft
        )
    }

    func applyProviderDefaults() {
        baseURL = provider.defaultBaseURL
        model = provider.defaultModel
    }

    private enum Keys {
        static let provider = "scrumtrace.provider"
        static let baseURL = "scrumtrace.baseURL"
        static let model = "scrumtrace.model"
        static let whisperModel = "scrumtrace.whisperModel"
        static let appName = "scrumtrace.appName"
        static let repoURL = "scrumtrace.repoURL"
        static let techStack = "scrumtrace.techStack"
        static let includeTranscript = "scrumtrace.includeFullTranscript"
    }
}
