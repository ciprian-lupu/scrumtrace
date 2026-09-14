#if os(macOS)
import AppKit
import Combine
import SwiftUI

// MARK: - Usage

/// How often a saved context was recorded with, from session manifest metadata only (C2): the context id
/// each recording copied and the date it was created. Nothing else about a recording is read.
struct ContextUsage: Equatable, Sendable {
    var recordingCount = 0
    var lastUsed: Date?

    /// One value per saved context, zero for a context no recording names. A recording counts for the context
    /// whose id equals its `product_context.context_id`. Recordings without a context id, recordings naming an
    /// id no saved context has (a deleted context), and unreadable manifests count for nobody.
    static func compute(profiles: [SavedProductContext], entries: [SessionEntry]) -> [String: ContextUsage] {
        var usage = profiles.reduce(into: [String: ContextUsage]()) { $0[$1.id] = ContextUsage() }
        for summary in entries.lazy.compactMap(\.summary) {
            guard let id = summary.contextID, var item = usage[id] else { continue }
            item.recordingCount += 1
            if item.lastUsed.map({ summary.createdAt > $0 }) ?? true {
                item.lastUsed = summary.createdAt
            }
            usage[id] = item
        }
        return usage
    }

    /// The readable recordings made with `contextID`, in the order of `entries` (the library lists newest first).
    static func sessions(contextID: String, entries: [SessionEntry]) -> [SessionSummary] {
        entries.compactMap { entry in
            guard let summary = entry.summary, summary.contextID == contextID else { return nil }
            return summary
        }
    }
}

// MARK: - Actions

/// Everything the Contexts section offers. Raw values are technical identifiers, never user text.
enum ContextAction: String, CaseIterable, Identifiable, Sendable {
    case new
    case edit
    case duplicate
    case record
    case setDefault
    case delete

    var id: String { rawValue }

    /// A row's context menu, in order.
    static let rowActions: [ContextAction] = [.record, .setDefault, .edit, .duplicate, .delete]

    var title: String {
        switch self {
        case .new: return "New context…"
        case .edit: return "Edit…"
        case .duplicate: return "Duplicate…"
        case .record: return "Record with this context…"
        case .setDefault: return "Set as default"
        case .delete: return "Delete…"
        }
    }

    var systemImage: String {
        switch self {
        case .new: return "plus"
        case .edit: return "pencil"
        case .duplicate: return "plus.square.on.square"
        case .record: return "record.circle"
        case .setDefault: return "checkmark.circle"
        case .delete: return "trash"
        }
    }

    /// The help tag while the action can run.
    var help: String {
        switch self {
        case .new: return "Add a saved context"
        case .edit: return "Edit the selected context"
        case .duplicate: return "Save a copy of the selected context under a new name"
        case .record: return "Make this the default context and start a recording. You confirm the context and choose the capture area next."
        case .setDefault: return "Preselect this context when you start a recording"
        case .delete: return "Remove the selected context. Existing recordings keep their own copy."
        }
    }

    /// Every action except New acts on one saved context.
    var needsContext: Bool { self != .new }

    /// A separator goes above this action in menus.
    var startsGroup: Bool { self == .edit || self == .delete }

    var accessibilityIdentifier: String { "main.contexts.\(rawValue)" }
}

// MARK: - Model

/// Everything the Contexts section does outside the settings library. Tests inject closures; the app uses `live`.
struct ContextsDependencies {
    /// `controller.canChangeCaptureSettings`, the rule Settings → General follows for saved contexts.
    var canChangeContexts: @MainActor () -> Bool
    /// True while a Start from the menu, Overview, Recordings or here shows the context window or the capture-area overlay.
    var isPreparingRecording: @MainActor () -> Bool
    /// The menu's Start flow: meeting notice, readiness, context confirmation, capture area.
    var startRecording: @MainActor () -> Void

    @MainActor
    static func live(
        controller: SessionController,
        startRecording: @escaping @MainActor () -> Void,
        isPreparingRecording: @escaping @MainActor () -> Bool
    ) -> ContextsDependencies {
        ContextsDependencies(
            canChangeContexts: { controller.canChangeCaptureSettings },
            isPreparingRecording: isPreparingRecording,
            startRecording: startRecording
        )
    }
}

/// State and actions of the Contexts section. The presenter owns one per window. Saved contexts live in
/// `AppSettings`; recording counts come from the shared session index. It never shows or activates the window.
@MainActor
final class ContextsModel: ObservableObject {
    /// While the section is shown in a visible window, the Record button follows a Start's context window at this pace.
    nonisolated static let startStateInterval: Duration = .milliseconds(500)
    nonisolated static let noContextReason = "Select a saved context first."
    nonisolated static let alreadyDefaultReason = "This context is already the default."

    let settings: AppSettings
    let recordings: RecordingsModel
    var navigation: MainNavigation { recordings.navigation }
    var library: SessionLibrary { recordings.library }

    /// The table's selection, a saved context id.
    @Published var selectedContextID: String?
    @Published var editor: ContextEditRequest?
    /// The context Delete… asked about. The confirmation dialog shows while it is set.
    @Published var pendingDelete: SavedProductContext?
    /// A short line after an action that could not run. Never a path or captured text.
    @Published private(set) var message: String?
    @Published private(set) var canChangeContexts: Bool
    @Published private(set) var isPreparingRecording: Bool

    private(set) var startStateLoop: Task<Void, Never>?
    private(set) var isWindowVisible = false
    private(set) var isSectionShown = false

    private let dependencies: ContextsDependencies
    private let startStateInterval: Duration
    private var observations: Set<AnyCancellable> = []
    private var messageObservations: Set<AnyCancellable> = []

    init(
        settings: AppSettings,
        recordings: RecordingsModel,
        dependencies: ContextsDependencies,
        startStateInterval: Duration = ContextsModel.startStateInterval
    ) {
        self.settings = settings
        self.recordings = recordings
        self.dependencies = dependencies
        self.startStateInterval = startStateInterval
        canChangeContexts = dependencies.canChangeContexts()
        isPreparingRecording = dependencies.isPreparingRecording()
        // A line belongs to the row and section it was shown for. Synchronous, like RecordingsModel.
        Publishers.Merge(
            $selectedContextID.removeDuplicates().dropFirst().map { _ in () },
            recordings.navigation.$section.removeDuplicates().dropFirst().map { _ in () }
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissMessage() }
        }
        .store(in: &messageObservations)
    }

    // MARK: Visibility

    /// Follows the controller, so actions wait for recording, analysis and a start in flight.
    func observe(controller: SessionController) {
        observations.removeAll()
        Publishers.Merge3(
            controller.$phase.map { _ in () },
            controller.$isBusy.map { _ in () },
            controller.$startInFlight.map { _ in () }
        )
        // @Published emits before the new value is stored; read the controller after it is.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.syncStartState() }
        }
        .store(in: &observations)
    }

    /// True while the section is shown in a visible window.
    var isActive: Bool { isSectionShown && isWindowVisible }

    var isStartStateLoopActive: Bool { startStateLoop != nil }

    /// ContextsView appeared: select a saved context when none is, and join or start a session index refresh
    /// for the recording counts.
    func sectionDidAppear() {
        isSectionShown = true
        syncStartState()
        validateSelection()
        recordings.sectionDidAppear()
        updateStartStateLoop()
    }

    func sectionDidDisappear() {
        isSectionShown = false
        updateStartStateLoop()
    }

    /// The presenter reports whether the window is on screen. A hidden window does no periodic work.
    func setWindowVisible(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        if isActive { syncStartState() }
        updateStartStateLoop()
    }

    private func updateStartStateLoop() {
        guard isActive != (startStateLoop != nil) else { return }
        startStateLoop?.cancel()
        startStateLoop = nil
        guard isActive else { return }
        let interval = startStateInterval
        startStateLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.syncStartState()
            }
        }
    }

    /// Reads the capture state and whether a Start shows its context window. Publishes only changes.
    func syncStartState() {
        let canChange = dependencies.canChangeContexts()
        if canChange != canChangeContexts { canChangeContexts = canChange }
        let preparing = dependencies.isPreparingRecording()
        if preparing != isPreparingRecording { isPreparingRecording = preparing }
    }

    // MARK: Rows

    var profiles: [SavedProductContext] { settings.contextLibrary.profiles }

    /// The context the recording-context window preselects. Nil means No context.
    var defaultContextID: String? { settings.contextLibrary.selectedID }

    func profile(id: String?) -> SavedProductContext? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    var selectedProfile: SavedProductContext? { profile(id: selectedContextID) }

    /// Recording counts and last-used dates for every saved context, from the session index.
    var usage: [String: ContextUsage] {
        ContextUsage.compute(profiles: profiles, entries: library.entries)
    }

    func sessions(for contextID: String) -> [SessionSummary] {
        ContextUsage.sessions(contextID: contextID, entries: library.entries)
    }

    /// Keeps a saved context selected when the selection is empty or was removed: the default, else the first.
    func validateSelection() {
        guard selectedProfile == nil else { return }
        let next = profile(id: defaultContextID)?.id ?? profiles.first?.id
        if selectedContextID != next { selectedContextID = next }
    }

    func dismissMessage() {
        if message != nil { message = nil }
    }

    // MARK: Actions

    /// Why `action` cannot run for the context `id` now, in plain words for a help tag or the message line.
    /// The rules of Settings → General: an unreadable library and running capture or analysis block every change.
    func unavailableReason(_ action: ContextAction, for id: String?) -> String? {
        if let issue = settings.contextLibraryIssue { return issue }
        if !canChangeContexts { return RecordingsModel.busyReason }
        guard action.needsContext else { return nil }
        guard let id, profile(id: id) != nil else { return Self.noContextReason }
        switch action {
        case .record:
            return isPreparingRecording ? OverviewModel.preparingReason : nil
        case .setDefault:
            return defaultContextID == id ? Self.alreadyDefaultReason : nil
        case .new, .edit, .duplicate, .delete:
            return nil
        }
    }

    func isEnabled(_ action: ContextAction, for id: String?) -> Bool {
        unavailableReason(action, for: id) == nil
    }

    /// Runs `action`. New, Edit and Duplicate open the editor; Delete only asks for confirmation here.
    @discardableResult
    func perform(_ action: ContextAction, on id: String?) -> Bool {
        syncStartState()
        guard isEnabled(action, for: id) else { return false }
        let profile = profile(id: id)
        switch action {
        case .new:
            dismissMessage()
            editor = ContextEditRequest(profile: SavedProductContext(name: ""), isNew: true)
        case .edit:
            guard let profile else { return false }
            dismissMessage()
            editor = ContextEditRequest(profile: profile, isNew: false)
        case .duplicate:
            guard let profile else { return false }
            dismissMessage()
            editor = ContextEditRequest(profile: ProductContextNaming.duplicate(of: profile, existing: profiles), isNew: true)
        case .delete:
            guard let profile else { return false }
            dismissMessage()
            pendingDelete = profile
        case .record, .setDefault:
            guard let id else { return false }
            do {
                if action == .record {
                    try recordWithContext(id: id)
                } else {
                    try setDefault(id: id)
                }
            } catch {
                message = error.localizedDescription
                return false
            }
        }
        return true
    }

    /// The editor's Save. Throws, keeping the sheet open with the message, while capture or analysis runs or
    /// when `AppSettings.saveProductContext` refuses the context.
    func save(_ profile: SavedProductContext, isNew: Bool) throws {
        syncStartState()
        guard canChangeContexts else { throw SettingsValidationError(RecordingsModel.busyReason) }
        try settings.saveProductContext(profile, isNew: isNew)
        AgentLog.event("main_context_save", ["kind": isNew ? "new" : "edit"])
        selectedContextID = profile.id
        dismissMessage()
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    /// Removes a context the user confirmed from the saved library. Recordings are not touched: each keeps the
    /// copy it confirmed. The state is checked again because recording may have started while the dialog was open.
    @discardableResult
    func confirmDelete(_ profile: SavedProductContext) -> Bool {
        if pendingDelete != nil { pendingDelete = nil }
        syncStartState()
        if let reason = unavailableReason(.delete, for: profile.id) {
            message = reason
            return false
        }
        do {
            try settings.deleteProductContext(id: profile.id)
        } catch {
            message = error.localizedDescription
            return false
        }
        AgentLog.event("main_context_delete", [:])
        dismissMessage()
        validateSelection()
        return true
    }

    /// Record with this context…: makes `id` the default, then runs the app's Start flow, whose recording-context
    /// window opens with it preselected. The recording copies the context confirmed there (C2). Throws and starts
    /// nothing while recording, analysis or another Start is running, or when `id` is not a saved context.
    ///
    /// The Start flow returns without opening its context window when it stops early: the meeting notice was
    /// cancelled, recording is not allowed yet (the flow says why), or there is no menu. Nothing is recorded then,
    /// so the previous default comes back instead of changing every later Start.
    func recordWithContext(id: String) throws {
        syncStartState()
        if let issue = settings.contextLibraryIssue { throw SettingsValidationError(issue) }
        guard canChangeContexts else { throw SettingsValidationError(RecordingsModel.busyReason) }
        guard !isPreparingRecording else { throw SettingsValidationError(OverviewModel.preparingReason) }
        let previousDefault = defaultContextID
        try settings.selectProductContext(id: id)
        dismissMessage()
        AgentLog.event("main_start", ["section": MainSection.contexts.rawValue])
        dependencies.startRecording()
        syncStartState()
        if !isPreparingRecording, previousDefault != id {
            // Best effort: if the previous default is gone or the library became unreadable, `id` stays.
            _ = try? settings.selectProductContext(id: previousDefault)
        }
    }

    /// Set as default: the recording-context window preselects `id`. Nothing is recorded.
    func setDefault(id: String) throws {
        syncStartState()
        if let issue = settings.contextLibraryIssue { throw SettingsValidationError(issue) }
        guard canChangeContexts else { throw SettingsValidationError(RecordingsModel.busyReason) }
        try settings.selectProductContext(id: id)
        dismissMessage()
        AgentLog.event("main_context_default", [:])
    }

    /// Selects a recording in the Recordings section, dropping a search or filter that would hide it.
    func showInRecordings(_ sessionId: String) {
        recordings.revealInList(sessionId: sessionId)
        navigation.selectedSessionId = sessionId
        navigation.section = .recordings
    }
}

// MARK: - Row text

enum ContextRowText {
    /// Blank fields show a dash; line breaks in a tech stack become spaces so a cell stays one line.
    static func field(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.trimmingCharacters(in: .whitespaces).isEmpty ? "—" : flat
    }

    static func count(_ usage: ContextUsage?, isCounting: Bool) -> String {
        guard !isCounting, let usage else { return "—" }
        return String(usage.recordingCount)
    }

    /// The date only, so the column stays narrow; its help tag and the detail pane give the time too.
    static func lastUsed(_ usage: ContextUsage?, isCounting: Bool) -> String {
        guard !isCounting, let usage else { return "—" }
        return usage.lastUsed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Never"
    }

    static func usageLine(_ usage: ContextUsage) -> String {
        let count = usage.recordingCount == 1 ? "1 recording" : "\(usage.recordingCount) recordings"
        guard let last = usage.lastUsed else { return count }
        return "\(count) · last used \(SessionSummary.formattedDate(last))"
    }
}

// MARK: - Views

struct ContextsView: View {
    @ObservedObject var model: ContextsModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var recordings: RecordingsModel
    @ObservedObject var library: SessionLibrary

    /// Leaves the table a few rows at the window's minimum size, with the live banner shown.
    private static let detailHeight: CGFloat = 280

    var body: some View {
        content
            .toolbar { toolbar }
            .onAppear { model.sectionDidAppear() }
            .onDisappear { model.sectionDidDisappear() }
            .onChange(of: settings.contextLibrary.profiles.map(\.id)) { _, _ in model.validateSelection() }
            .sheet(item: $model.editor) { request in
                ProductContextEditor(profile: request.profile, isNew: request.isNew) { profile in
                    try model.save(profile, isNew: request.isNew)
                }
            }
            .confirmationDialog(
                "Delete saved context?",
                isPresented: Binding(
                    get: { model.pendingDelete != nil },
                    set: { if !$0 { model.cancelDelete() } }
                ),
                titleVisibility: .visible,
                presenting: model.pendingDelete
            ) { profile in
                Button("Delete context", role: .destructive) { model.confirmDelete(profile) }
                    .accessibilityIdentifier("main.contexts.confirmDelete")
                Button("Cancel", role: .cancel) { model.cancelDelete() }
            } message: { profile in
                Text("Remove “\(profile.name)” from saved contexts? Existing recordings keep their original context.")
            }
    }

    /// The first scan of the session index has not finished, so counts are not known yet.
    private var isCounting: Bool {
        library.isLoading || (!recordings.hasLoaded && library.entries.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if let issue = settings.contextLibraryIssue {
            ContentUnavailableView {
                Label("Contexts unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(issue).foregroundStyle(.red)
            }
        } else if settings.contextLibrary.profiles.isEmpty {
            ContentUnavailableView {
                Label("No saved contexts", systemImage: MainSection.contexts.systemImage)
            } description: {
                Text("Save a context for each product or type of call. You confirm one before every recording, and each recording keeps its own copy.")
            } actions: {
                Button(ContextAction.new.title) { model.perform(.new, on: nil) }
                    .disabled(!model.isEnabled(.new, for: nil))
                    .help(model.unavailableReason(.new, for: nil) ?? ContextAction.new.help)
                    .accessibilityIdentifier("main.contexts.empty.new")
            }
        } else {
            let usage = model.usage
            // A SwiftUI stack rather than VSplitView, for the reason RecordingsView gives.
            VStack(spacing: 0) {
                listPane(usage: usage)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    .layoutPriority(1)
                Divider()
                detailPane(usage: usage)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.detailHeight)
            }
        }
    }

    private func listPane(usage: [String: ContextUsage]) -> some View {
        VStack(spacing: 0) {
            ContextsTable(
                model: model,
                profiles: settings.contextLibrary.profiles,
                defaultContextID: settings.contextLibrary.selectedID,
                usage: usage,
                isCounting: isCounting
            )
            if let message = model.message {
                footer(systemImage: "exclamationmark.circle", text: message) {
                    Button { model.dismissMessage() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss message")
                    .accessibilityIdentifier("main.contexts.dismissMessage")
                }
            } else if !model.canChangeContexts {
                footer(systemImage: "clock", text: RecordingsModel.busyReason) { EmptyView() }
            }
        }
    }

    private func footer<Accessory: View>(
        systemImage: String,
        text: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func detailPane(usage: [String: ContextUsage]) -> some View {
        if let profile = model.selectedProfile {
            ContextDetailView(
                model: model,
                profile: profile,
                isDefault: settings.contextLibrary.selectedID == profile.id,
                usage: usage[profile.id] ?? ContextUsage(),
                sessions: model.sessions(for: profile.id),
                isCounting: isCounting
            )
        } else {
            ContentUnavailableView(
                "No context selected",
                systemImage: MainSection.contexts.systemImage,
                description: Text("Select a context to see its product details and the recordings made with it.")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            toolbarButton(.new)
            toolbarButton(.edit)
            toolbarButton(.duplicate)
            toolbarButton(.record)
            toolbarButton(.setDefault)
            toolbarButton(.delete)
        }
    }

    private func toolbarButton(_ action: ContextAction) -> some View {
        let id = action.needsContext ? model.selectedContextID : nil
        return Button(role: action == .delete ? .destructive : nil) {
            model.perform(action, on: id)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .help(model.unavailableReason(action, for: id) ?? action.help)
        .disabled(!model.isEnabled(action, for: id))
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}

struct ContextsTable: View {
    @ObservedObject var model: ContextsModel
    let profiles: [SavedProductContext]
    let defaultContextID: String?
    let usage: [String: ContextUsage]
    let isCounting: Bool

    var body: some View {
        // Ideal widths fit all six columns beside the sidebar at the default 960-point window.
        Table(profiles, selection: $model.selectedContextID) {
            TableColumn("Name") { profile in
                ContextNameLabel(name: profile.name, isDefault: profile.id == defaultContextID)
            }
            .width(min: 100, ideal: 140)
            TableColumn("Product") { profile in
                ContextFieldCell(text: profile.product.appName)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Repository") { profile in
                ContextFieldCell(text: profile.product.repoURL)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Tech stack") { profile in
                ContextFieldCell(text: profile.product.techStack)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Recordings") { profile in
                Text(ContextRowText.count(usage[profile.id], isCounting: isCounting))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 76)
            TableColumn("Last used") { profile in
                let item = usage[profile.id]
                Text(ContextRowText.lastUsed(item, isCounting: isCounting))
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(isCounting ? "" : item?.lastUsed.map(SessionSummary.formattedDate) ?? "")
            }
            .width(min: 90, ideal: 104)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                ContextActionMenuItems(model: model, id: id)
            }
        } primaryAction: { ids in
            if let id = ids.first { model.perform(.edit, on: id) }
        }
        .onDeleteCommand { model.perform(.delete, on: model.selectedContextID) }
        .accessibilityIdentifier("main.contexts.table")
    }
}

/// A saved context's name, with the Default badge on the context the recording-context window preselects.
/// The table's Name column and the detail header both use it.
struct ContextNameLabel: View {
    let name: String
    let isDefault: Bool
    /// Nil keeps the surrounding font.
    var font: Font?

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(name)
            if isDefault {
                ContextDefaultBadge()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Marks the context the recording-context window preselects. Text, so it never relies on color.
private struct ContextDefaultBadge: View {
    var body: some View {
        Text("Default")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .fixedSize()
            .help("Preselected when you start a recording")
            .accessibilityLabel("Default context")
    }
}

private struct ContextFieldCell: View {
    let text: String

    var body: some View {
        let shown = ContextRowText.field(text)
        Text(shown)
            .foregroundStyle(shown == "—" ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(shown == "—" ? "" : text)
    }
}

/// Menu items for one saved context, grouped with separators.
struct ContextActionMenuItems: View {
    @ObservedObject var model: ContextsModel
    let id: String

    var body: some View {
        ForEach(Array(ContextAction.rowActions.enumerated()), id: \.element) { index, action in
            if index > 0 && action.startsGroup {
                Divider()
            }
            Button(role: action == .delete ? .destructive : nil) {
                model.perform(action, on: id)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(!model.isEnabled(action, for: id))
        }
    }
}

/// The selected context: its product details and the recordings that copied it.
struct ContextDetailView: View {
    @ObservedObject var model: ContextsModel
    let profile: SavedProductContext
    let isDefault: Bool
    let usage: ContextUsage
    let sessions: [SessionSummary]
    let isCounting: Bool

    var body: some View {
        Form {
            Section {
                header
                ProductContextSummary(product: profile.product)
            }
            Section("Recordings with this context") {
                if isCounting {
                    ProgressView("Loading recordings…")
                        .controlSize(.small)
                } else if sessions.isEmpty {
                    Text("No recordings use this context yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { summary in
                        sessionRow(summary)
                    }
                }
                Text("A recording counts here when it was made with this saved context. Recordings made with No context are not counted. Editing or deleting a context never changes existing recordings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                ContextNameLabel(name: profile.name, isDefault: isDefault, font: .headline)
                Text(isCounting ? "Counting recordings…" : ContextRowText.usageLine(usage))
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            detailButton(.setDefault)
            detailButton(.record)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 2)
    }

    private func detailButton(_ action: ContextAction) -> some View {
        Button(action.title) { model.perform(action, on: profile.id) }
            .fixedSize()
            .disabled(!model.isEnabled(action, for: profile.id))
            .help(model.unavailableReason(action, for: profile.id) ?? action.help)
            .accessibilityIdentifier("main.contexts.detail.\(action.rawValue)")
    }

    private func sessionRow(_ summary: SessionSummary) -> some View {
        HStack(spacing: 10) {
            Text(SessionSummary.formattedDate(summary.createdAt))
                .monospacedDigit()
            Text(PipelineStatusOrder.label(summary.pipelineStatus))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(SessionController.clock(summary.mediaSeconds))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Recorded time \(SessionController.clock(summary.mediaSeconds))")
            Button("Show in Recordings") { model.showInRecordings(summary.sessionId) }
                .controlSize(.small)
                .accessibilityIdentifier("main.contexts.session.\(summary.sessionId)")
        }
    }
}
#endif
