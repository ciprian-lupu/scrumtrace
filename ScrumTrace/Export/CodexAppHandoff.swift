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
    struct ProjectRequest: Equatable {
        let suggestedName: String
        let existing: Bool
        let includeArchive: Bool
    }

    static func link(sessionURL: URL, projectName: String? = nil) throws -> URL {
        let workspace = try CodexWorkspace.prepare(sessionURL: sessionURL, projectName: projectName)
        return try link(workspace: workspace, prompt: CodexWorkspace.prompt(workspace: workspace))
    }

    private static func link(workspace: URL, prompt: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "path", value: workspace.path),
            URLQueryItem(name: "prompt", value: prompt)
        ]
        // URLSearchParams treats an unescaped plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ClaudeCLIHandoffError.codexAppLaunchFailed }
        return url
    }

    /// Same path/project, different source snapshot and task prompt. The caller obtains archive consent.
    static func privateArchiveLink(sessionURL: URL, projectName: String? = nil) throws -> URL {
        let workspace = try CodexWorkspace.preparePrivateArchive(sessionURL: sessionURL, projectName: projectName)
        return try link(workspace: workspace, prompt: CodexWorkspace.privateArchivePrompt(workspace: workspace))
    }

    #if os(macOS)
    @MainActor
    static func open(
        sessionURL: URL,
        configureProject: @MainActor (ProjectRequest) -> String? = { requestProject($0) },
        applicationForURL: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) throws {
        guard ClaudeCLIHandoff.exportDirectory(sessionURL: sessionURL) != nil else {
            throw ClaudeCLIHandoffError.exportMissing
        }
        // Check installation before writing the workspace.
        guard let scheme = URL(string: "codex://threads/new"), applicationForURL(scheme) != nil else {
            throw ClaudeCLIHandoffError.codexAppMissing
        }
        let name = try projectName(sessionURL: sessionURL, includeArchive: false, configure: configureProject)
        let url = try link(sessionURL: sessionURL, projectName: name)
        guard openURL(url) else { throw ClaudeCLIHandoffError.codexAppLaunchFailed }
    }

    @MainActor
    static func openPrivateArchive(
        sessionURL: URL,
        configureProject: @MainActor (ProjectRequest) -> String? = { requestProject($0) },
        applicationForURL: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) async throws {
        // Check installation before copying any private source material.
        guard let scheme = URL(string: "codex://threads/new"), applicationForURL(scheme) != nil else {
            throw ClaudeCLIHandoffError.codexAppMissing
        }
        guard ExportRel.existingSessionFile(ScrumTracePath.sessionMovie, sessionURL: sessionURL) != nil else {
            throw ClaudeCLIHandoffError.privateArchiveMissing
        }
        // One dialog combines the initial project name and the explicit archive handoff.
        let name = try projectName(sessionURL: sessionURL, includeArchive: true, configure: configureProject)
        // A full recording can be many GB. The descriptor-safe copy runs away from the UI actor;
        // only the actual app launch returns to it.
        let url = try await Task.detached(priority: .userInitiated) {
            try privateArchiveLink(sessionURL: sessionURL, projectName: name)
        }.value
        guard openURL(url) else { throw ClaudeCLIHandoffError.codexAppLaunchFailed }
    }

    @MainActor
    private static func projectName(
        sessionURL: URL, includeArchive: Bool, configure: @MainActor (ProjectRequest) -> String?
    ) throws -> String? {
        let existing = try CodexWorkspace.existingWorkspace(sessionURL: sessionURL)
        if existing != nil && !includeArchive { return nil }
        let request = ProjectRequest(
            suggestedName: try existing?.lastPathComponent ?? CodexWorkspace.suggestedProjectName(sessionURL: sessionURL),
            existing: existing != nil, includeArchive: includeArchive
        )
        guard let name = configure(request), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeCLIHandoffError.handoffCancelled
        }
        return existing == nil ? name : nil
    }

    @MainActor
    static func requestProject(_ request: ProjectRequest) -> String? {
        let (alert, field) = projectAlert(request)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return request.existing ? request.suggestedName : field.stringValue
    }

    /// Kept separate from presentation so native layout tests never open a modal or another app.
    @MainActor
    static func projectAlert(_ request: ProjectRequest) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = request.includeArchive ? "Open archive in Codex" : "Open export in Codex"
        let projectText = request.existing
            ? "Uses the existing project: \(request.suggestedName)."
            : "Choose a descriptive project name, such as Import Flow Review. Export and archive analyses will use this same project."
        alert.informativeText = projectText + (request.includeArchive
            ? "\n\nAdds the original recording, audio, transcript and events. These remain accessible in the project, including to later tasks. Codex may send analyzed content to its model service when you submit the prompt."
            : "\n\nThe prompt requests the task title Analyze export. You submit it in Codex.")
        let field = NSTextField(string: request.suggestedName)
        if !request.existing {
            field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
            field.placeholderString = "Project name"
            field.setAccessibilityLabel("Codex project name")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
        }
        alert.addButton(withTitle: request.includeArchive ? "Open archive" : "Open export")
        alert.addButton(withTitle: "Cancel")
        return (alert, field)
    }
    #endif
}
