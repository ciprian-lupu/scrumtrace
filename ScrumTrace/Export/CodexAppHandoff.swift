import Foundation
#if os(macOS)
import AppKit
#endif

enum CodexHandoffDestination: String, CaseIterable, Identifiable, Sendable {
    case app
    case terminal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .app: return "Codex app"
        case .terminal: return "Codex CLI in Terminal"
        }
    }
}

/// Uses the documented local-workspace link. The prompt stays in the composer until the user sends it.
/// https://learn.chatgpt.com/docs/reference/commands#deep-links
enum CodexAppHandoff {
    static func link(sessionURL: URL) throws -> URL {
        guard let export = ClaudeCLIHandoff.exportDirectory(sessionURL: sessionURL) else {
            throw ClaudeCLIHandoffError.exportMissing
        }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "path", value: export.path),
            URLQueryItem(name: "prompt", value: ClaudeCLIHandoff.startupPrompt)
        ]
        // URLSearchParams treats an unescaped plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ClaudeCLIHandoffError.codexAppLaunchFailed }
        return url
    }

    #if os(macOS)
    @MainActor
    static func open(
        sessionURL: URL,
        applicationForURL: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) throws {
        let url = try link(sessionURL: sessionURL)
        guard applicationForURL(url) != nil else { throw ClaudeCLIHandoffError.codexAppMissing }
        guard openURL(url) else { throw ClaudeCLIHandoffError.codexAppLaunchFailed }
    }
    #endif
}
