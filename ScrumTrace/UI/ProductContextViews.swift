import AppKit
import SwiftUI

private struct ContextEditRequest: Identifiable {
    var profile: SavedProductContext
    var isNew: Bool
    var id: String { profile.id }
}

struct ProductContextsSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: SessionController
    @State private var selectedID = ""
    @State private var editor: ContextEditRequest?
    @State private var deleting: SavedProductContext?
    @State private var message = ""

    private var selected: SavedProductContext? {
        settings.contextLibrary.profiles.first { $0.id == selectedID }
    }

    var body: some View {
        Section("Product contexts") {
            Text("Save a context for each product or type of call. You will confirm one before every recording; changes here apply to future sessions.")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = settings.contextLibraryIssue {
                Text(issue).foregroundStyle(.red)
            } else if settings.contextLibrary.profiles.isEmpty {
                Text("No saved contexts yet. Add one, or record without a context.").foregroundStyle(.secondary)
            } else {
                Picker("Saved context", selection: $selectedID) {
                    Text("Choose a context").tag("")
                    ForEach(settings.contextLibrary.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                if let selected { ProductContextSummary(product: selected.product) }
            }
            HStack {
                Button("New context…") { editor = ContextEditRequest(profile: SavedProductContext(name: ""), isNew: true) }
                Button("Edit…") {
                    if let selected { editor = ContextEditRequest(profile: selected, isNew: false) }
                }.disabled(selected == nil)
                Button("Duplicate…") { duplicate() }.disabled(selected == nil)
                Spacer()
                Button("Delete…", role: .destructive) { deleting = selected }.disabled(selected == nil)
            }.disabled(settings.contextLibraryIssue != nil)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .disabled(!controller.canChangeCaptureSettings)
        .onAppear { restoreSelection() }
        .onChange(of: settings.contextLibrary.profiles.map(\.id)) { _, _ in
            if selected == nil { restoreSelection() }
        }
        .sheet(item: $editor) { request in
            ProductContextEditor(profile: request.profile, isNew: request.isNew) { profile in
                guard controller.canChangeCaptureSettings else { throw SettingsValidationError("Wait for recording or analysis to finish.") }
                try settings.saveProductContext(profile, isNew: request.isNew)
                selectedID = profile.id
                message = ""
            }
        }
        .alert("Delete saved context?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete context", role: .destructive) {
                guard controller.canChangeCaptureSettings, let deleting else { return }
                do { try settings.deleteProductContext(id: deleting.id); message = "" }
                catch { message = error.localizedDescription }
                self.deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Remove “\(deleting?.name ?? "")” from saved contexts? Existing recordings keep their original context.")
        }
    }

    private func restoreSelection() {
        selectedID = settings.contextLibrary.selectedID ?? settings.contextLibrary.profiles.first?.id ?? ""
    }

    private func duplicate() {
        guard var copy = selected else { return }
        copy.id = UUID().uuidString
        let base = String(copy.name.prefix(65))
        var number = 1
        var name = "\(base) copy"
        while settings.contextLibrary.profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            number += 1
            name = "\(base) copy \(number)"
        }
        copy.name = name
        editor = ContextEditRequest(profile: copy, isNew: true)
    }
}

struct ProductContextSummary: View {
    var product: ProductContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Product", value: product.appName.isEmpty ? "—" : product.appName)
            LabeledContent("Repository", value: product.repoURL.isEmpty ? "—" : product.repoURL)
            LabeledContent("Tech stack", value: product.techStack.isEmpty ? "—" : product.techStack)
        }
        .font(.callout).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProductContextEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: SavedProductContext
    let isNew: Bool
    let onSave: (SavedProductContext) throws -> Void
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New product context" : "Edit product context").font(.title2)
            Form {
                TextField("Context name", text: $profile.name)
                    .accessibilityIdentifier("context.name")
                TextField("Product / app name (optional)", text: $profile.product.appName)
                    .accessibilityIdentifier("context.product")
                TextField("Repository URL (optional)", text: $profile.product.repoURL)
                    .accessibilityIdentifier("context.repository")
                TextField("Tech stack (optional)", text: $profile.product.techStack, axis: .vertical)
                    .lineLimit(2...4).accessibilityIdentifier("context.stack")
            }.textFieldStyle(.roundedBorder)
            Text("Use a name you will recognize before a call. If the product name is blank, the context name is used in the brief and tasks.")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save context") {
                    do { try onSave(profile); dismiss() }
                    catch { message = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled()
    }
}

struct RecordingContextView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: SessionController
    var onContinue: (String?) throws -> Void
    var onCancel: () -> Void
    @State private var selectedID = ""
    @State private var editor: ContextEditRequest?
    @State private var message = ""

    private var selected: SavedProductContext? {
        settings.contextLibrary.profiles.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose context for this recording").font(.title2)
            Text("Check the product before each call. This session will keep its own copy of the selected context.")
                .foregroundStyle(.secondary)
            Picker("Context", selection: $selectedID) {
                Text("No context").tag("")
                ForEach(settings.contextLibrary.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }.accessibilityIdentifier("recording.context")
            ScrollView {
                Group {
                    if let selected { ProductContextSummary(product: selected.snapshot) }
                    else { Text("No product details will be attached to this recording.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 80, maxHeight: 150).padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("New context…") { editor = ContextEditRequest(profile: SavedProductContext(name: ""), isNew: true) }
                Button("Edit context…") {
                    if let selected { editor = ContextEditRequest(profile: selected, isNew: false) }
                }.disabled(selected == nil)
            }.disabled(settings.contextLibraryIssue != nil)
            if let issue = settings.contextLibraryIssue { Text(issue).font(.caption).foregroundStyle(.red) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            Text("Next, choose the capture area. Recording has not started.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue to capture area") {
                    do { try onContinue(selectedID.isEmpty ? nil : selectedID) }
                    catch { message = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(minWidth: 580, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity, alignment: .topLeading)
        .disabled(!controller.canChangeCaptureSettings)
        .onAppear { selectedID = settings.contextLibrary.selectedID ?? "" }
        .onChange(of: settings.contextLibrary.profiles.map(\.id)) { _, _ in
            if !selectedID.isEmpty, selected == nil {
                selectedID = ""
                message = "The selected context was removed. Choose another context or continue without one."
            }
        }
        .sheet(item: $editor) { request in
            ProductContextEditor(profile: request.profile, isNew: request.isNew) { profile in
                guard controller.canChangeCaptureSettings else { throw SettingsValidationError("Wait for recording or analysis to finish.") }
                try settings.saveProductContext(profile, isNew: request.isNew)
                selectedID = profile.id
                message = ""
            }
        }
    }
}

/// A retained, cancellable window. Closing it must never start capture.
@MainActor
final class RecordingContextPresenter: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var controller: SessionController?
    private var completion: ((ProductContext?) -> Void)?

    func present(controller: SessionController, completion: @escaping (ProductContext?) -> Void) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        self.controller = controller
        self.completion = completion
        let root = RecordingContextView(
            settings: controller.settings, controller: controller,
            onContinue: { [weak self] id in try self?.confirmSelection(id: id) },
            onCancel: { [weak self] in self?.cancel() }
        )
        let hosting = NSHostingController(rootView: root)
        // Explicit window sizing prevents a macOS 26 hosting/safe-area feedback
        // loop when the selected context changes the view's ideal height.
        hosting.sizingOptions = []
        let created = NSWindow(contentViewController: hosting)
        created.title = "ScrumTrace — Recording context"
        created.styleMask = [.titled, .closable, .resizable]
        created.setContentSize(NSSize(width: 620, height: 520))
        created.contentMinSize = NSSize(width: 580, height: 460)
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.center()
        window = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }

    func confirmSelection(id: String?) throws {
        guard let controller, controller.canChangeCaptureSettings else {
            throw SettingsValidationError("Wait for recording or analysis to finish.")
        }
        let snapshot = try controller.settings.selectProductContext(id: id)
        finish(snapshot)
    }

    func cancel() { finish(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { cancel() }

    private func finish(_ product: ProductContext?) {
        let callback = completion
        completion = nil
        let closing = window
        window = nil
        closing?.delegate = nil
        closing?.close()
        controller = nil
        callback?(product)
    }
}
