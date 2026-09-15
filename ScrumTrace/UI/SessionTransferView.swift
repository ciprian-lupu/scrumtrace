#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let scrumTraceTransfer = UTType(exportedAs: "com.str8minds.ScrumTrace.transfer", conformingTo: .package)
}

private enum SessionTransferOutcome: Sendable {
    case batch(SessionTransferBatchResult), analysis(String)
}

@MainActor
final class SessionTransferModel: ObservableObject {
    @Published var exportSessionIDs: [String] = []
    @Published var batchResult: SessionTransferBatchResult?
    @Published var scope: SessionTransferScope = .evidence
    @Published var includePrivate = false
    @Published var isWorking = false
    @Published var progress = ""
    @Published var notice: String?
    private let controller: SessionController
    private let imported: @MainActor ([String]) -> Void
    private var work: Task<SessionTransferOutcome, Error>?
    private var workID: UUID?

    init(controller: SessionController, imported: @escaping @MainActor ([String]) -> Void) {
        self.controller = controller
        self.imported = imported
    }

    func presentExport(id: String) {
        presentExport(ids: [id])
    }

    func presentExport(ids: [String]) {
        scope = .evidence
        includePrivate = false
        var seen = Set<String>()
        exportSessionIDs = ids.filter { seen.insert($0).inserted }
    }

    static func importPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Import recordings"
        panel.message = "Choose one or more .scrumtrace packages, session folders, or export folders. Use Command or Shift to select several. Unzip older session packs first."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        return panel
    }

    func chooseImport() {
        guard controller.canChangeCaptureSettings, !isWorking else { return }
        let panel = Self.importPanel()
        guard panel.runModal() == .OK else { return }
        importSources(panel.urls)
    }

    func importSources(_ sources: [URL]) {
        guard !sources.isEmpty else { return }
        run("Importing recordings") { transfer, progress in
            .batch(transfer.importRecordings(from: sources) { progress($0.description) })
        }
    }

    func saveExport() {
        let ids = exportSessionIDs
        guard !ids.isEmpty, scope != .complete || includePrivate else { return }
        let chosenScope = scope
        let consent = includePrivate
        let environment = SessionEnvironment.current()
        let requests: [SessionTransferExportRequest]
        if ids.count == 1, let id = ids.first {
            let panel = NSSavePanel()
            panel.title = "Export recording for another Mac"
            panel.allowedContentTypes = [.scrumTraceTransfer]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(id).scrumtrace"
            panel.message = chosenScope == .complete
                ? "Includes private original media, transcripts and existing results."
                : "Includes only the evidence already included in export/."
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            requests = [.init(sessionID: id, destination: destination)]
        } else {
            let panel = NSOpenPanel()
            panel.title = "Export \(ids.count) recordings"
            panel.prompt = "Export here"
            panel.message = "Choose one destination folder. Each selected recording gets its own .scrumtrace package. Existing packages are skipped."
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            requests = ids.map { .init(sessionID: $0, destination: folder.appendingPathComponent("\($0).scrumtrace")) }
        }
        exportSessionIDs = []
        run("Exporting recordings") { transfer, progress in
            .batch(try transfer.exportRecordings(requests, scope: chosenScope, includePrivate: consent,
                                                  environment: environment) { progress($0.description) })
        }
    }

    func analyzeCopy(id: String, retranscribe: Bool) {
        run("Preparing analysis copy") { transfer, progress in
            .analysis(try transfer.analysisCopy(id: id, retranscribe: retranscribe) { done, total in
                progress("\(done) of \(total) files")
            })
        }
    }

    func cancel() { work?.cancel() }

    func review(id: String) async -> SessionTransferAssessment {
        let vault = controller.vault
        return await Task.detached(priority: .utility) {
            SessionTransferAssessment.load(vault: vault, id: id)
        }.value
    }

    func environment(id: String) async -> SessionEnvironment? {
        let vault = controller.vault
        return await Task.detached(priority: .utility) {
            try? vault.loadManifest(id: id).captureEnvironment
        }.value
    }

    private func run(
        _ title: String,
        operation: @escaping @Sendable (SessionTransfer, @escaping @Sendable (String) -> Void) throws -> SessionTransferOutcome
    ) {
        guard !isWorking, controller.beginSessionTransfer() else {
            notice = SessionTransferError.busy.localizedDescription
            return
        }
        isWorking = true
        progress = title
        let token = UUID()
        workID = token
        let transfer = SessionTransfer(vault: controller.vault)
        let update: @Sendable (String) -> Void = { [weak self] detail in
            Task { @MainActor [weak self] in
                guard self?.workID == token else { return }
                self?.progress = "\(title) · \(detail)"
            }
        }
        let task = Task.detached(priority: .utility) { try operation(transfer, update) }
        work = task
        Task { [self] in
            let result = await task.result
            work = nil
            workID = nil
            isWorking = false
            controller.endSessionTransfer()
            switch result {
            case .success(.batch(let result)):
                let ids = result.importedIDs.isEmpty ? result.existingImportIDs : result.importedIDs
                if !ids.isEmpty { imported(ids) }
                AgentLog.event("transfer_batch", ["completed": String(result.successCount),
                                                 "skipped": String(result.skippedCount),
                                                 "failed": String(result.failureCount)])
                batchResult = result
            case .success(.analysis(let id)):
                AgentLog.event("transfer_analysis_copy", ["session": id])
                imported([id])
                controller.retryAnalysis(sessionId: id)
            case .failure(is CancellationError):
                notice = "Transfer cancelled."
            case .failure(let error):
                notice = (error as? SessionTransferError)?.localizedDescription
                    ?? "The transfer could not be read or written. Check its format, destination and available space."
                AgentLog.event("transfer_failed", ["reason": "validation_or_io"])
            }
        }
    }
}

struct SessionTransferExportView: View {
    @ObservedObject var model: SessionTransferModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transfer to another Mac").font(.title2.weight(.semibold))
            Text(model.exportSessionIDs.count == 1
                 ? "1 recording selected"
                 : "\(model.exportSessionIDs.count) recordings selected · one package per recording")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Contents", selection: $model.scope) {
                ForEach(SessionTransferScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.radioGroup)
            Text(model.scope == .complete
                 ? "Includes original video and audio, complete transcripts, raw events, existing results and available technical diagnostics. The private package can be much larger than the 35 MB agent export."
                 : "Includes the existing brief, selected clips, stills and any transcript explicitly included in export/. Missing original media cannot be recovered from this package.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.scope == .complete {
                Toggle("Include the private recording and complete transcript", isOn: $model.includePrivate)
                Text("Share this package only with a trusted Mac. Use the ordinary export/ folder for coding agents. Saved API keys and app settings are not included.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.exportSessionIDs = [] }.keyboardShortcut(.cancelAction)
                Button("Choose destination…") { model.saveExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.scope == .complete && !model.includePrivate)
            }
        }
        .padding(24)
        .frame(width: 500)
        .accessibilityIdentifier("main.recordings.transfer.export")
    }
}

struct SessionTransferResultsView: View {
    @ObservedObject var model: SessionTransferModel
    let result: SessionTransferBatchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(result.title).font(.title2.weight(.semibold))
            Text(result.summary).font(.callout)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(result.items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: symbol(item.outcome))
                                .foregroundStyle(item.outcome.succeeded ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.callout.weight(.medium)).lineLimit(1).help(item.name)
                                Text(item.outcome.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(height: min(300, CGFloat(max(1, result.items.count)) * 64))
            Text(nextStep)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !result.exportedURLs.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(result.exportedURLs) }
                }
                Spacer()
                Button("Done") { model.batchResult = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onExitCommand { model.batchResult = nil }
        .accessibilityIdentifier("main.recordings.transfer.results")
    }

    private var nextStep: String {
        if result.wasCancelled {
            return "Completed transfers are kept. You can select the remaining recordings and try again."
        }
        if result.operation == .importing {
            if result.successCount > 0 {
                return "Imported recordings are selected in the library. No online analysis has started."
            }
            return "No new recordings were imported. Review the skipped or failed items before trying again."
        }
        if result.successCount == 0 {
            return "No new packages were created. Review the skipped or failed items before trying again."
        }
        return "Copy the complete .scrumtrace packages to the other Mac, then choose Import recordings."
    }

    private func symbol(_ outcome: SessionTransferBatchResult.Outcome) -> String {
        switch outcome {
        case .imported, .exported: return "checkmark.circle.fill"
        case .alreadyImported, .existingDestination: return "arrow.uturn.forward.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled, .notStarted: return "minus.circle"
        }
    }
}

struct SessionTransferReviewView: View {
    @ObservedObject var transfer: SessionTransferModel
    let summary: SessionSummary
    let canAnalyze: Bool
    @State private var assessment: SessionTransferAssessment?
    @State private var captureEnvironment: SessionEnvironment?

    var body: some View {
        if let origin = summary.importOrigin {
            GroupBox("Origin & analysis") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(origin.kind == .imported ? "Imported recording" : "Analysis copy",
                          systemImage: origin.kind == .imported ? "square.and.arrow.down" : "doc.on.doc")
                        .font(.headline)
                    Text("Original session: \(origin.originalSessionID)")
                        .font(.caption).textSelection(.enabled)
                    Text("Imported \(SessionSummary.formattedDate(origin.importedAt)) · \(origin.scope.title)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let source = origin.exportedFrom {
                        Text("Exported from \(source.computer) · \(source.macOS) · ScrumTrace \(source.appVersion) (\(source.appBuild))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(captureEnvironment.map {
                        "Captured on \($0.computer) · \($0.macOS) · ScrumTrace \($0.appVersion) (\($0.appBuild))"
                    } ?? "Capture environment was not recorded by the original app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(origin.integrityVerified
                         ? "All files matched the package checksums at import."
                         : "Legacy folder: no source checksums were available.")
                        .font(.caption)
                    if let assessment {
                        assessmentView(assessment)
                    } else {
                        ProgressView("Checking available materials…").controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .task(id: summary) {
                assessment = await transfer.review(id: summary.sessionId)
                captureEnvironment = await transfer.environment(id: summary.sessionId)
            }
            .accessibilityIdentifier("main.recordings.transfer.review")
        }
    }

    private func assessmentView(_ value: SessionTransferAssessment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Original media: \(value.hasRecording ? "available" : "missing") · Timed passages: \(value.timedSegments) · Missing referenced evidence: \(value.missingEvidence)")
                .font(.caption)
            if summary.importOrigin?.scope == .evidence {
                Text("This evidence-only import supports reviewing the brief and evidence. Import a complete recording to reprocess it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Analyze a copy") { transfer.analyzeCopy(id: summary.sessionId, retranscribe: false) }
                        .disabled(!canAnalyze || transfer.isWorking || !(value.hasRecording || value.hasTimedTranscript))
                    Button("Transcribe a new copy") { transfer.analyzeCopy(id: summary.sessionId, retranscribe: true) }
                        .disabled(!canAnalyze || transfer.isWorking || !value.hasRecording)
                }
                Text("Creates a separate recording and uses this Mac's selected services. The original results stay available for comparison. Online services ask for consent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if summary.importOrigin?.kind == .analysisCopy {
                Text("Processing: \(value.sourceStatus ?? "unknown") → \(value.currentStatus ?? "unknown") · Tasks: \(value.sourceTaskCount.map(String.init) ?? "unknown") → \(value.currentTaskCount)")
                    .font(.caption)
                if let before = value.sourceWhisperSeconds, let after = value.currentWhisperSeconds,
                   before.isFinite, after.isFinite {
                    Text("Recorded transcription time: \(before.formatted(.number.precision(.fractionLength(1)))) s → \(after.formatted(.number.precision(.fractionLength(1)))) s")
                        .font(.caption)
                }
            }
            Text("File integrity and task counts do not prove accuracy. Compare the same inputs and review their evidence before claiming a speed or quality improvement.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
