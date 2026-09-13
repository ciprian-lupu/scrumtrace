import SwiftUI

/// Saved speech profiles are intentionally shown apart from AI analysis
/// services: selecting the default does not select comparison destinations.
struct TranscriptionConnectionViews: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: SessionController
    @State private var editor: SpeechServiceDraft?
    @State private var message = ""

    var body: some View {
        Section("Transcription services") {
            Text("The default service is used for a normal recording. Check services only when you explicitly compare an existing session; comparison runs serially and keeps separate results.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Default service", selection: Binding(get: { settings.transcriptionLibrary.selectedID ?? "" }, set: { value in
                do { try settings.selectTranscriptionService(id: value.isEmpty ? nil : value); message = "" } catch { message = error.localizedDescription }
            })) {
                Text("No default").tag("")
                ForEach(settings.transcriptionLibrary.services) { Text($0.name).tag($0.id) }
            }
            ForEach(settings.transcriptionLibrary.services) { service in
                Toggle(isOn: Binding(get: { service.isIncludedInComparison }, set: { value in
                    do { try settings.setTranscriptionComparisonIncluded(value, id: service.id); message = "" } catch { message = error.localizedDescription }
                })) {
                    VStack(alignment: .leading) {
                        Text("Compare: \(service.name)")
                        Text("\(service.backend.title) · \(service.model)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("speech.comparison.\(service.id)")
            }
            HStack {
                Button("New transcription service…") { editor = SpeechServiceDraft(service: SavedTranscriptionService(name: "", backend: .whisperKit), isNew: true) }
                Button("Edit…") { if let service = settings.transcriptionLibrary.selected { editor = SpeechServiceDraft(service: service, isNew: false) } }
                    .disabled(settings.transcriptionLibrary.selected == nil)
                Button("Delete", role: .destructive) {
                    guard let id = settings.transcriptionLibrary.selectedID else { return }
                    do { try settings.deleteTranscriptionService(id: id); message = "Service deleted; any shared credential was kept." } catch { message = error.localizedDescription }
                }.disabled(settings.transcriptionLibrary.selected == nil)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .disabled(!controller.canChangeCaptureSettings)
        .sheet(item: $editor) { draft in
            SpeechServiceEditor(draft: draft) { service, key in
                try settings.saveTranscriptionService(service, isNew: draft.isNew)
                if let credential = service.credentialID, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try settings.saveTranscriptionAPIKey(key, credentialID: credential)
                }
                try settings.selectTranscriptionService(id: service.id)
            }
        }
    }
}

private struct SpeechServiceDraft: Identifiable {
    var service: SavedTranscriptionService
    var isNew: Bool
    var id: String { service.id }
}

private struct SpeechServiceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: SpeechServiceDraft
    @State private var key = ""
    @State private var error = ""
    @State private var whisperSourceKind = "standard"
    @State private var whisperSourceValue = ""
    let save: (SavedTranscriptionService, String) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isNew ? "New transcription service" : "Edit transcription service").font(.title2)
            Form {
                TextField("Name", text: $draft.service.name)
                Picker("Backend", selection: $draft.service.backend) {
                    ForEach(SpeechBackendKind.allCases) { Text($0.title).tag($0) }
                }
                TextField("Model", text: $draft.service.model)
                if draft.service.backend == .whisperKit {
                    Picker("Model source", selection: $whisperSourceKind) {
                        Text("Standard catalog").tag("standard")
                        Text("Custom repository").tag("repository")
                        Text("Local folder").tag("folder")
                    }
                    if whisperSourceKind != "standard" {
                        TextField(whisperSourceKind == "repository" ? "Repository name or URL" : "Absolute model folder", text: $whisperSourceValue)
                    }
                    Text("Custom sources are loaded only on this Mac. Repository access tokens are not stored in this profile.").font(.caption).foregroundStyle(.secondary)
                }
                if draft.service.backend.requiresCredential {
                    TextField("Endpoint", text: $draft.service.endpoint)
                    TextField("Credential ID (reuse to share a saved key)", text: Binding(get: { draft.service.credentialID ?? "" }, set: { draft.service.credentialID = $0 }))
                    SecureField("New API key (optional when already saved)", text: $key)
                    Text("The key stays in Keychain. A shared credential ID lets two model profiles use the same key.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Local WhisperKit never uploads meeting audio and does not use an API key.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Language behavior", selection: $draft.service.language.mode) {
                    ForEach(SpeechLanguageSelection.Mode.allCases) { Text($0.title).tag($0) }
                }
                if draft.service.language.mode != .automatic {
                    ForEach(SpeechLanguage.allCases.filter { $0 != .automatic }) { language in
                        Toggle(language.title, isOn: Binding(get: { draft.service.language.languages.contains(language) }, set: { selected in
                            if selected { if !draft.service.language.languages.contains(language) { draft.service.language.languages.append(language) } }
                            else { draft.service.language.languages.removeAll { $0 == language } }
                        }))
                    }
                }
                Text(languageExplanation).font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Button("Cancel", role: .cancel) { dismiss() }; Spacer(); Button("Save") {
                do {
                    switch whisperSourceKind {
                    case "repository": draft.service.whisperSource = .repository(whisperSourceValue)
                    case "folder": draft.service.whisperSource = .folder(whisperSourceValue)
                    default: draft.service.whisperSource = nil
                    }
                    try draft.service.whisperSource?.validated()
                    try save(draft.service, key); dismiss()
                } catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 560).interactiveDismissDisabled()
        .onChange(of: draft.service.backend) { _, backend in
            draft.service.endpoint = backend.defaultEndpoint; draft.service.model = backend.defaultModel
            if backend.requiresCredential && draft.service.credentialID == nil { draft.service.credentialID = UUID().uuidString }
            if !backend.requiresCredential { draft.service.credentialID = nil }
        }
        .onChange(of: draft.service.language.mode) { _, mode in
            if mode == .automatic { draft.service.language.languages = [] }
            if mode == .single && draft.service.language.languages.count != 1 { draft.service.language.languages = [.romanian] }
            if mode == .expected && draft.service.language.languages.count < 2 { draft.service.language.languages = [.romanian, .english, .hungarian] }
        }
        .onAppear {
            switch draft.service.whisperSource ?? .standard {
            case .standard: whisperSourceKind = "standard"
            case .repository(let value): whisperSourceKind = "repository"; whisperSourceValue = value
            case .folder(let value): whisperSourceKind = "folder"; whisperSourceValue = value
            }
        }
    }

    private var languageExplanation: String {
        guard draft.service.backend == .openAITranscription,
              draft.service.language.mode == .expected,
              draft.service.model != "gpt-transcribe" else {
            return draft.service.language.explanation
        }
        return "This model does not document support for several expected-language hints. ScrumTrace will not send a hidden first-language substitute; it will use normal language detection without translation."
    }
}
