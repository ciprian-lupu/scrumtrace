import Foundation

struct SavedProductContext: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var product: ProductContext = .empty

    /// A recording owns this value, not a live reference to the settings library.
    var snapshot: ProductContext {
        var copy = product
        if copy.appName.isEmpty { copy.appName = name }
        copy.contextID = id
        copy.contextName = name
        return copy
    }
}

struct ProductContextLibrary: Codable, Equatable, Sendable {
    static let defaultsKey = "scrumtrace.productContexts.v1"
    var profiles: [SavedProductContext] = []
    var selectedID: String?

    var selected: SavedProductContext? { profiles.first { $0.id == selectedID } }

    static func load(from defaults: UserDefaults) -> (library: Self, issue: String?) {
        if defaults.object(forKey: defaultsKey) != nil {
            guard let data = defaults.data(forKey: defaultsKey),
                  var library = try? JSONDecoder().decode(Self.self, from: data),
                  Set(library.profiles.map(\.id)).count == library.profiles.count,
                  library.profiles.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                // Preserve unreadable data instead of overwriting the user's library.
                return (Self(), "Saved contexts could not be loaded. Their stored data has been kept. You can still record without a context.")
            }
            if library.selected == nil { library.selectedID = nil }
            return (library, nil)
        }
        let product = ProductContext(
            appName: defaults.string(forKey: "scrumtrace.appName") ?? "",
            repoURL: defaults.string(forKey: "scrumtrace.repoURL") ?? "",
            techStack: defaults.string(forKey: "scrumtrace.techStack") ?? ""
        )
        var library = Self()
        if [product.appName, product.repoURL, product.techStack].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let name = product.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let imported = SavedProductContext(name: name.isEmpty ? "Imported context" : name, product: product)
            library.profiles = [imported]
            library.selectedID = imported.id
        }
        // Persist an empty library too: deleting the last profile must not repeat migration.
        if let data = try? JSONEncoder().encode(library) { defaults.set(data, forKey: defaultsKey) }
        return (library, nil)
    }
}
