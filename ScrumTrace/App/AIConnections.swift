import Foundation

struct SavedAIConnection: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var provider: AIProviderKind
    var baseURL: String
    var model: String
    /// Host-scoped or legacy Keychain account from import. Never a secret.
    var fallbackKeyAccount: String?
    /// Explicit opt-in for comparison uploads. The active service is still
    /// independent: it only controls which service is being edited/tested.
    var isIncludedInComparison: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, provider, baseURL, model, fallbackKeyAccount
        case isIncludedInComparison = "is_included_in_comparison"
    }

    init(id: String = UUID().uuidString, name: String, provider: AIProviderKind, baseURL: String, model: String, fallbackKeyAccount: String? = nil, isIncludedInComparison: Bool = false) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.fallbackKeyAccount = fallbackKeyAccount
        self.isIncludedInComparison = isIncludedInComparison
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        provider = try container.decode(AIProviderKind.self, forKey: .provider)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        fallbackKeyAccount = try container.decodeIfPresent(String.self, forKey: .fallbackKeyAccount)
        isIncludedInComparison = try container.decodeIfPresent(Bool.self, forKey: .isIncludedInComparison) ?? false
    }
}

struct AIConnectionLibrary: Codable, Equatable, Sendable {
    static let defaultsKey = "scrumtrace.aiConnections.v1"
    static let unreadableMessage =
        "Saved services could not be loaded. Their stored data has been kept. You can still record without a service."

    var connections: [SavedAIConnection] = []
    var selectedID: String?

    var selected: SavedAIConnection? { connections.first { $0.id == selectedID } }

    static func load(from defaults: UserDefaults) -> (library: Self, issue: String?, migrated: Bool) {
        if defaults.object(forKey: defaultsKey) != nil {
            guard let data = defaults.data(forKey: defaultsKey),
                  var library = try? JSONDecoder().decode(Self.self, from: data),
                  Set(library.connections.map(\.id)).count == library.connections.count,
                  library.connections.allSatisfy({
                      !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                return (Self(), unreadableMessage, false)
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = object["connections"] as? [[String: Any]],
               rows.allSatisfy({ $0["is_included_in_comparison"] == nil }),
               let index = library.connections.firstIndex(where: { $0.id == library.selectedID }) {
                library.connections[index].isIncludedInComparison = true
                if let migrated = try? JSONEncoder().encode(library) { defaults.set(migrated, forKey: defaultsKey) }
            }
            if library.selected == nil { library.selectedID = nil }
            return (library, nil, false)
        }
        return (Self(), nil, true)
    }
}

/// Runtime-only service configuration. `configuration.apiKey` is fetched from
/// Keychain immediately before processing and is never encoded into a manifest.
struct AIServiceConfiguration: Sendable {
    var service: SavedAIConnection
    var configuration: AIProviderConfiguration

    var destination: UploadDestination {
        UploadDestination(
            serviceId: service.id,
            serviceName: service.name,
            provider: configuration.kind.rawValue,
            endpoint: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            includesClipVideo: false
        )
    }
}

enum AIConnectionNaming {
    static func suggestedName(provider: AIProviderKind, endpoint: String) -> String {
        guard let url = try? ProviderEndpoint.requireHTTPSOrLocal(endpoint),
              let host = url.host?.lowercased() else {
            return provider.title
        }
        if host == "api.thehive.ai" || host.hasSuffix(".thehive.ai") { return "Hive" }
        if host == "api.openai.com" { return "OpenAI" }
        if host == "api.anthropic.com" { return "Anthropic" }
        if host == "generativelanguage.googleapis.com" { return "Google" }
        if host == "api.deepseek.com" { return "DeepSeek" }
        return "Imported service"
    }
}
