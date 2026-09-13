import Foundation

struct SavedAIConnection: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var provider: AIProviderKind
    var baseURL: String
    var model: String
    /// Host-scoped or legacy Keychain account from import. Never a secret.
    var fallbackKeyAccount: String?
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
            if library.selected == nil { library.selectedID = nil }
            return (library, nil, false)
        }
        return (Self(), nil, true)
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
