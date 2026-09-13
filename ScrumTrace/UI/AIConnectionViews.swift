import SwiftUI

private struct AIConnectionNameRequest: Identifiable {
    var connection: SavedAIConnection
    var isNew: Bool
    var id: String { connection.id }
}

struct AIConnectionsSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: SessionController
    @State private var editor: AIConnectionNameRequest?
    @State private var deleting: SavedAIConnection?
    @State private var message = ""

    private var selected: SavedAIConnection? {
        settings.connectionLibrary.selected
    }

    var body: some View {
        Section("Saved services") {
            Text("Choose one active service to edit or test. Select every service that may receive the same evidence for a serial, side-by-side comparison. Unselected services receive nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let issue = settings.connectionLibraryIssue {
                Text(issue).foregroundStyle(.red)
            } else if settings.connectionLibrary.connections.isEmpty {
                Text("No saved services yet. Add one to store a key, or record without AI.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Active service", selection: activeServiceBinding) {
                    Text("No service").tag("")
                    ForEach(settings.connectionLibrary.connections) { connection in
                        Text(connection.name).tag(connection.id)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Include in multi-model comparison")
                        .font(.subheadline.weight(.medium))
                    ForEach(settings.connectionLibrary.connections) { connection in
                        Toggle(isOn: Binding(
                            get: { connection.isIncludedInComparison },
                            set: { included in
                                do { try settings.setComparisonIncluded(included, id: connection.id); message = "" }
                                catch { message = error.localizedDescription }
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(connection.name)
                                Text("\(connection.provider.title) · \(connection.model)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("ai.comparison.\(connection.id)")
                        .accessibilityLabel("Include \(connection.name) in multi-model comparison")
                    }
                    Text("Each selected destination is shown again for approval at Stop. Keys remain separate in Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("New service…") {
                    editor = AIConnectionNameRequest(
                        connection: SavedAIConnection(
                            name: "",
                            provider: .openaiCompatible,
                            baseURL: AIProviderKind.openaiCompatible.defaultBaseURL,
                            model: AIProviderKind.openaiCompatible.defaultModel
                        ),
                        isNew: true
                    )
                }
                Button("Rename…") {
                    if let selected { editor = AIConnectionNameRequest(connection: selected, isNew: false) }
                }
                .disabled(selected == nil)
                Button("Duplicate") { duplicate() }
                    .disabled(selected == nil)
                Spacer()
                Button("Delete…", role: .destructive) { deleting = selected }
                    .disabled(selected == nil)
            }
            .disabled(settings.connectionLibraryIssue != nil)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .disabled(!controller.canChangeCaptureSettings)
        .sheet(item: $editor) { request in
            AIConnectionNameEditor(connection: request.connection, isNew: request.isNew) { connection in
                guard controller.canChangeCaptureSettings else {
                    throw SettingsValidationError("Wait for recording or analysis to finish.")
                }
                try settings.saveAIConnection(connection, isNew: request.isNew)
                if request.isNew {
                    try settings.selectAIConnection(id: connection.id)
                }
                message = ""
            }
        }
        .alert(
            "Delete saved service?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete service", role: .destructive) {
                guard controller.canChangeCaptureSettings, let deleting else { return }
                do {
                    try settings.deleteAIConnection(id: deleting.id)
                    message = ""
                } catch {
                    message = error.localizedDescription
                }
                self.deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Remove “\(deleting?.name ?? "")” and its saved key from this Mac? Other services are unchanged.")
        }
    }

    private var activeServiceBinding: Binding<String> {
        Binding(
            get: { settings.connectionLibrary.selectedID ?? "" },
            set: { newValue in
                do {
                    try settings.selectAIConnection(id: newValue.isEmpty ? nil : newValue)
                    message = ""
                } catch {
                    message = error.localizedDescription
                }
            }
        )
    }

    private func duplicate() {
        guard let selected else { return }
        do {
            _ = try settings.duplicateAIConnection(id: selected.id)
            message = ""
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct AIConnectionNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var connection: SavedAIConnection
    let isNew: Bool
    let onSave: (SavedAIConnection) throws -> Void
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New service" : "Rename service").font(.title2)
            Form {
                TextField("Service name", text: $connection.name)
                    .accessibilityIdentifier("ai.connection.name")
            }
            .textFieldStyle(.roundedBorder)
            Text(isNew
                 ? "Use a name you will recognize, such as Hive or DeepSeek. You can set the endpoint, model, and key after saving."
                 : "This only changes the name. The endpoint, model, and key stay with this service.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Add service" : "Save name") {
                    do {
                        try onSave(connection)
                        dismiss()
                    } catch {
                        message = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}
