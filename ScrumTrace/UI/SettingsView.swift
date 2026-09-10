import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var keyStatus = ""

    var body: some View {
        Form {
            Section("AI provider") {
                Picker("Backend", selection: $settings.provider) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .onChange(of: settings.provider) { _, _ in
                    settings.applyProviderDefaults()
                }
                TextField("Endpoint", text: $settings.baseURL)
                TextField("Model", text: $settings.model)
                if settings.provider == .anthropic {
                    Text("Documented Messages models: claude-sonnet-5, claude-opus-5, claude-haiku-4-5. Retired claude-3-5 and claude-3-7 ids are refused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.model.isEmpty {
                        Text("Anthropic stays off until you set a currently documented Messages model.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if AIProviderConfiguration.isRetiredAnthropic(settings.model) {
                        Text("This model id is retired (2025–2026). Anthropic calls are refused.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                SecureField("API key (Keychain)", text: $settings.apiKeyDraft)
                Text("Keys stay on this Mac. ScrumTrace never proxies them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save key") {
                    do {
                        try settings.saveAPIKey()
                        let empty = settings.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        keyStatus = empty ? "Key removed from Keychain." : "Key saved on this Mac."
                    } catch {
                        keyStatus = error.localizedDescription
                    }
                }
                if !keyStatus.isEmpty {
                    Text(keyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Provider capabilities") {
                Text("MVP backend: OpenAI-compatible. Adapters send only what these flags allow. Shipped adapters do not upload MP4 even if capabilities.acceptsVideo is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Text", value: capabilities.acceptsText ? "yes" : "no")
                LabeledContent("Images", value: capabilities.acceptsImages ? "yes" : "no")
                LabeledContent("Video", value: ProviderWireMedia.willUploadClip(configuration: capabilities) ? "yes" : "no")
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
                Text("Off by default. The local archive always keeps full_transcript.json. Agents receive export/ only. The first provider call still asks for upload consent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Capture") {
                Text("Shot  ⌥⌘S    Pin  ⌥⌘Space    Pause  ⌥⌘P")
                    .font(.system(.body, design: .monospaced))
                Text("HUD shows t_media. Pause discards screen frames, system audio, microphone PCM, metadata, Shot, and Hold-to-Talk. After Stop, WhisperKit transcribes the room mic and the movie’s system-audio track, then merges on t_media.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Enable browser URL metadata (Accessibility)") {
                    MetadataSampler.requestTrust(prompt: true)
                }
                Text("Optional. Record needs Screen Recording and Microphone only. Accessibility adds window titles and browser URLs. A new Debug build can look like a different app to macOS — toggle this for the binary you just opened, then quit and reopen once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 780)
        .padding()
    }

    private var capabilities: AIProviderConfiguration {
        settings.providerConfiguration()
    }
}
