import Foundation

struct SessionTransferBatchResult: Identifiable, Sendable {
    enum Operation: Sendable { case importing, exporting }
    enum Outcome: Sendable, Equatable {
        case imported(String), exported(URL), alreadyImported(String)
        case existingDestination, failed(String), cancelled, notStarted

        var succeeded: Bool {
            switch self {
            case .imported, .exported: return true
            default: return false
            }
        }

        var detail: String {
            switch self {
            case .imported: return "Imported"
            case .exported: return "Exported"
            case .alreadyImported(let id): return "Already imported as \(id)"
            case .existingDestination: return "A package with this name already exists. Choose another destination to export it again."
            case .failed(let reason): return reason
            case .cancelled: return "Cancelled; the unfinished copy was removed."
            case .notStarted: return "Not started"
            }
        }
    }

    struct Item: Identifiable, Sendable {
        let id: Int
        let name: String
        let outcome: Outcome
    }

    let id = UUID()
    let operation: Operation
    var items: [Item] = []
    var wasCancelled = false
    var successCount: Int { items.filter { $0.outcome.succeeded }.count }
    var skippedCount: Int {
        items.filter {
            switch $0.outcome {
            case .alreadyImported, .existingDestination: return true
            default: return false
            }
        }.count
    }
    var failureCount: Int {
        items.filter { if case .failed = $0.outcome { return true }; return false }.count
    }
    var importedIDs: [String] {
        items.compactMap { if case .imported(let id) = $0.outcome { return id }; return nil }
    }
    var existingImportIDs: [String] {
        items.compactMap { if case .alreadyImported(let id) = $0.outcome { return id }; return nil }
    }
    var exportedURLs: [URL] {
        items.compactMap { if case .exported(let url) = $0.outcome { return url }; return nil }
    }
    var title: String {
        if wasCancelled { return "Transfer cancelled" }
        return operation == .importing ? "Import results" : "Export results"
    }
    var summary: String {
        let action = operation == .importing ? "imported" : "exported"
        return "\(successCount) of \(items.count) \(action) · \(skippedCount) skipped · \(failureCount) failed"
    }
}

struct SessionTransferBatchProgress: Sendable {
    let recording: Int
    let totalRecordings: Int
    let files: Int
    let totalFiles: Int

    var description: String {
        let recording = "Recording \(recording) of \(totalRecordings)"
        return totalFiles > 0 ? "\(recording) · \(files) of \(totalFiles) files" : recording
    }
}

struct SessionTransferExportRequest: Sendable {
    let sessionID: String
    let destination: URL
}

extension SessionTransfer {
    typealias BatchProgress = @Sendable (SessionTransferBatchProgress) -> Void

    /// Each package commits independently. A rejected package does not hide later usable recordings.
    func importRecordings(from sources: [URL], progress: @escaping BatchProgress = { _ in }) -> SessionTransferBatchResult {
        runBatch(names: sources.map(\.lastPathComponent), operation: .importing, progress: progress) { index, files in
            .imported(try importRecording(from: sources[index], progress: files))
        }
    }

    func exportRecordings(
        _ requests: [SessionTransferExportRequest], scope: SessionTransferScope,
        includePrivate: Bool, environment: SessionEnvironment, progress: @escaping BatchProgress = { _ in }
    ) throws -> SessionTransferBatchResult {
        // One explicit choice covers this frozen selection, before any private file is copied.
        guard scope != .complete || includePrivate else { throw SessionTransferError.privateConsentRequired }
        return runBatch(names: requests.map(\.sessionID), operation: .exporting, progress: progress) { index, files in
            let request = requests[index]
            _ = try export(id: request.sessionID, to: request.destination, scope: scope,
                           includePrivate: includePrivate, environment: environment, progress: files)
            return .exported(request.destination)
        }
    }

    private func runBatch(
        names: [String], operation: SessionTransferBatchResult.Operation, progress: @escaping BatchProgress,
        perform: (Int, Progress) throws -> SessionTransferBatchResult.Outcome
    ) -> SessionTransferBatchResult {
        var result = SessionTransferBatchResult(operation: operation)
        for (index, name) in names.enumerated() {
            if result.wasCancelled || Task.isCancelled {
                result.wasCancelled = true
                result.items.append(.init(id: index, name: name, outcome: .notStarted))
                continue
            }
            let outcome: SessionTransferBatchResult.Outcome
            do {
                progress(.init(recording: index + 1, totalRecordings: names.count, files: 0, totalFiles: 0))
                try Task.checkCancellation()
                outcome = try perform(index) { done, total in
                    progress(.init(recording: index + 1, totalRecordings: names.count, files: done, totalFiles: total))
                }
            } catch is CancellationError {
                result.wasCancelled = true
                outcome = .cancelled
            } catch SessionTransferError.duplicate(let id) {
                outcome = .alreadyImported(id)
            } catch SessionTransferError.destinationExists {
                outcome = .existingDestination
            } catch {
                outcome = .failed((error as? SessionTransferError)?.localizedDescription
                    ?? "The recording could not be read or written. Check its format and available space.")
            }
            result.items.append(.init(id: index, name: name, outcome: outcome))
        }
        return result
    }
}
