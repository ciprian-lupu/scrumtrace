import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("AI provider") {
                Picker("Backend", selection: $settings.provider) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .onChange(of: settings.provider) { _ in
                    settings.applyProviderDefaults()
                }
                TextField("Endpoint", text: $settings.baseURL)
                TextField("Model", text: $settings.model)
                SecureField("API key (Keychain)", text: $settings.apiKeyDraft)
                Text("Keys stay on this Mac. ScrumTrace never proxies them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save key") {
                    try? settings.saveAPIKey()
                }
            }
            Section("Speech") {
                TextField("WhisperKit model", text: $settings.whisperModel)
                Text("Pinned default is large-v3-turbo (openai_whisper-large-v3-turbo). First run downloads the CoreML model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Product context") {
                TextField("App name", text: $settings.appName)
                TextField("Repo URL", text: $settings.repoURL)
                TextField("Tech stack", text: $settings.techStack)
            }
            Section("Export") {
                Toggle("Include full transcript in session-pack.zip", isOn: $settings.includeFullTranscriptInZip)
                Text("Off by default. The local archive always keeps full_transcript.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Capture") {
                Text("Shot  ⌥⌘S    Pin  ⌥⌘Space    Pause  ⌥⌘P")
                    .font(.system(.body, design: .monospaced))
                Text("HUD shows t_media. Pause discards frames, microphone PCM, and metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .padding()
    }
}
