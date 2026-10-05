import SwiftUI

struct LocalSubscriptionSettingsView: View {
    let kind: AIProviderKind
    @State private var status = ""
    @State private var checking = false

    var body: some View {
        if let cli = kind.localCLI {
            LabeledContent("Local agent", value: ClaudeCLIHandoff.executable(for: cli) == nil ? "Not installed" : "Installed")
            Text(cli == .claude
                 ? "Sign in once in Terminal: claude auth login"
                 : "Sign in once in Terminal: codex login")
                .font(.caption).textSelection(.enabled)
            HStack {
                Button(checking ? "Checking…" : "Check subscription sign-in") {
                    checking = true
                    status = ""
                    Task {
                        defer { checking = false }
                        do {
                            try await LocalSubscriptionAuth.check(cli: cli)
                            status = "Signed in with your subscription."
                        } catch { status = error.localizedDescription }
                    }
                }
                .disabled(checking)
                Link("Setup instructions", destination: URL(string: cli == .claude
                     ? "https://code.claude.com/docs/en/setup"
                     : "https://developers.openai.com/codex/cli")!)
            }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
        }
    }
}
