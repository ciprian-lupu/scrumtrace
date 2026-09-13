#if os(macOS)
import AppKit
import Combine
import ImageIO
import SwiftUI

// MARK: - Actions

/// Everything a recording offers. Raw values are technical identifiers, never user text.
enum RecordingAction: String, CaseIterable, Identifiable, Sendable {
    case revealExport
    case openInClaude
    case openInChatGPT
    case openBrief
    case copyExportPath
    case retryAnalysis
    case reviewSpeakers
    case revealArchive
    case revealFolder
    case delete

    var id: String { rawValue }

    /// A session whose manifest was read, in menu order.
    static let readableActions: [RecordingAction] = [
        .revealExport, .openInClaude, .openInChatGPT, .openBrief, .copyExportPath,
        .retryAnalysis, .reviewSpeakers, .revealArchive, .delete
    ]

    /// A session whose manifest could not be read: nothing that trusts its contents.
    static let unreadableActions: [RecordingAction] = [.revealFolder, .delete]

    var title: String {
        switch self {
        case .revealExport: return "Reveal export/"
        case .openInClaude: return "Open in Claude"
        case .openInChatGPT: return "Open in ChatGPT"
        case .openBrief: return "Open brief"
        case .copyExportPath: return "Copy export path"
        case .retryAnalysis: return "Retry analysis"
        case .reviewSpeakers: return "Review speakers…"
        case .revealArchive: return "Reveal archive…"
        case .revealFolder: return "Reveal folder…"
        case .delete: return "Delete…"
        }
    }

    var systemImage: String {
        switch self {
        case .revealExport: return "folder"
        case .openInClaude, .openInChatGPT: return "terminal"
        case .openBrief: return "doc.richtext"
        case .copyExportPath: return "doc.on.clipboard"
        case .retryAnalysis: return "arrow.clockwise"
        case .reviewSpeakers: return "person.2"
        case .revealArchive: return "archivebox"
        case .revealFolder: return "folder.badge.questionmark"
        case .delete: return "trash"
        }
    }

    /// Actions that change a session or show its private files wait for recording and analysis to finish.
    var needsIdleCapture: Bool {
        switch self {
        case .retryAnalysis, .reviewSpeakers, .revealArchive, .revealFolder, .delete:
            return true
        case .revealExport, .openInClaude, .openInChatGPT, .openBrief, .copyExportPath:
            return false
        }
    }

    /// A separator goes above this action in menus.
    var startsGroup: Bool {
        switch self {
        case .retryAnalysis, .revealArchive, .delete: return true
        default: return false
        }
    }

    /// AgentLog event name. Logged with the session id only.
    var logEvent: String {
        switch self {
        case .revealExport: return "main_reveal_export"
        case .openInClaude: return "main_claude"
        case .openInChatGPT: return "main_chatgpt"
        case .openBrief: return "main_open_brief"
        case .copyExportPath: return "main_copy_export_path"
        case .retryAnalysis: return "main_retry"
        case .reviewSpeakers: return "main_review_speakers"
        case .revealArchive: return "main_reveal_archive"
        case .revealFolder: return "main_reveal_folder"
        case .delete: return "main_delete"
        }
    }

    var accessibilityIdentifier: String { "main.recordings.\(rawValue)" }
}

extension SessionStatusFilter {
    var title: String {
        switch self {
        case .completed: return "Completed"
        case .needsReview: return "Needs review"
        case .unfinished: return "Unfinished"
        case .offlineFailed: return "Offline failed"
        }
    }
}

// MARK: - File access

/// Locations the Recordings actions may hand to Finder, a browser, the pasteboard or a drag. Each is
/// opened without following links and must be a direct child of its own session folder (C2).
enum SessionFileAccess {
    /// The session folder as an `O_NOFOLLOW` open resolved it. Nil for an invalid id, a missing or
    /// symlinked folder, or a sessions folder that is a link.
    static func sessionDirectory(vault: SessionVault, id: String) -> URL? {
        guard let session = checkedSessionURL(vault: vault, id: id) else { return nil }
        return ExportRel.unfollowedDirectoryURL(session)
    }

    /// `export/`, with the checks `SessionVault.revealInFinder` makes. A folder that holds any link is
    /// refused, so a drop or a pasted path cannot lead an agent into `archive/`.
    static func exportDirectory(vault: SessionVault, id: String) -> URL? {
        guard let session = checkedSessionURL(vault: vault, id: id),
              let folder = containedDirectory(ScrumTracePath.export, in: session),
              !PackBudget.exportStillContainsSymlink(exportDir: folder) else { return nil }
        return folder
    }

    /// `archive/`, only when it is a real folder directly inside the session folder.
    static func archiveDirectory(vault: SessionVault, id: String) -> URL? {
        guard let session = checkedSessionURL(vault: vault, id: id) else { return nil }
        return containedDirectory(ScrumTracePath.archive, in: session)
    }

    /// `export/SESSION_BRIEF.html`, only when `ExportRel.existingSessionFile` accepts it.
    static func briefURL(vault: SessionVault, id: String) -> URL? {
        guard let session = checkedSessionURL(vault: vault, id: id),
              ExportRel.existingSessionFile(ScrumTracePath.sessionBrief, sessionURL: session) == ScrumTracePath.sessionBrief else {
            return nil
        }
        return session.appendingPathComponent(ScrumTracePath.sessionBrief)
    }

    /// The guards `SessionVault.revealInFinder` starts with: a valid id, a usable sessions folder and a
    /// session folder that is not a link. The folder may be missing.
    static func checkedSessionURL(vault: SessionVault, id: String) -> URL? {
        guard SessionVault.isValidSessionId(id), ExportRel.isUsableSessionRoot(vault.rootURL) else { return nil }
        let session = vault.sessionURL(id: id)
        guard ExportRel.isUsableSessionRoot(session), !isSymbolicLink(session) else { return nil }
        return session
    }

    private static func containedDirectory(_ name: String, in session: URL) -> URL? {
        guard !ExportRel.containsSymlinkComponent(name, sessionURL: session),
              let sessionFolder = ExportRel.unfollowedDirectoryURL(session),
              let folder = ExportRel.unfollowedDirectoryURL(session.appendingPathComponent(name, isDirectory: true)),
              folder.lastPathComponent == name,
              folder.deletingLastPathComponent().standardizedFileURL.path == sessionFolder.standardizedFileURL.path,
              !isSymbolicLink(folder),
              !ExportRel.containsSymlinkComponent(name, sessionURL: session) else { return nil }
        return folder
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

// MARK: - Thumbnails

/// A downscaled still from `export/shots`. CGImage is immutable, so it may cross actors.
struct SessionThumbnail: Identifiable, Equatable, @unchecked Sendable {
    /// Session-relative path, `export/shots/<name>`.
    let id: String
    let image: CGImage

    var name: String { (id as NSString).lastPathComponent }

    static func == (lhs: SessionThumbnail, rhs: SessionThumbnail) -> Bool {
        lhs.id == rhs.id && lhs.image === rhs.image
    }
}

/// Loads Shot stills for the detail pane from `export/shots` only, never from `archive/` (C2).
enum SessionThumbnailLoader {
    static let limit = 8
    static let maxPixelSize = 320
    /// Larger files are skipped rather than read.
    static let maxFileBytes = 32 * 1024 * 1024
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    /// Reads one session-relative file. Tests inject a recorder.
    typealias Reader = @Sendable (_ relative: String, _ sessionURL: URL) -> Data?

    static let containedRead: Reader = { relative, sessionURL in
        ExportRel.readContainedData(relative: relative, sessionURL: sessionURL)
    }

    /// True only for `export/shots/<image>` spelled exactly that way: no `.`, `..`, extra slashes,
    /// hidden names or deeper folders.
    static func isShotPath(_ relative: String) -> Bool {
        guard let parts = ExportRel.normalizedComponents(relative),
              parts.joined(separator: "/") == relative,
              parts.count == 3,
              "\(parts[0])/\(parts[1])" == ScrumTracePath.exportShots,
              !parts[2].hasPrefix(".") else { return false }
        return imageExtensions.contains((parts[2] as NSString).pathExtension.lowercased())
    }

    /// Stills tried before giving up, so a folder of broken files cannot make a selection read many.
    static var maxAttempts: Int { limit * 4 }
    private static let extensionRank: [String: Int] = ["png": 0, "jpg": 1, "jpeg": 2]

    /// Every still per Shot, Shots in name order. Within a Shot the annotated copies come first, then
    /// the plain ones, each ranked png, jpg, jpeg, so the choice never depends on directory order.
    /// Empty when `export/shots` is missing, a link, or reached through a link.
    static func shotCandidates(sessionURL: URL) -> [[String]] {
        guard !ExportRel.containsSymlinkComponent(ScrumTracePath.exportShots, sessionURL: sessionURL),
              let folder = ExportRel.unfollowedDirectoryURL(
                sessionURL.appendingPathComponent(ScrumTracePath.exportShots, isDirectory: true)
              ),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var byStem: [String: [String]] = [:]
        for name in names where isShotPath("\(ScrumTracePath.exportShots)/\(name)") {
            byStem[shotStem(name), default: []].append(name)
        }
        return byStem.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { stem in
                (byStem[stem] ?? []).sorted(by: isPreferred).map { "\(ScrumTracePath.exportShots)/\($0)" }
            }
    }

    /// Nil unless `relative` is a shot path naming a non-empty regular file reached without links.
    /// Nothing is read before those checks pass.
    static func loadThumbnail(relative: String, sessionURL: URL, read: Reader = containedRead) -> SessionThumbnail? {
        guard isShotPath(relative),
              ExportRel.existingSessionFile(relative, sessionURL: sessionURL) == relative,
              let bytes = ExportRel.regularFileByteCount(relative: relative, sessionURL: sessionURL),
              bytes <= maxFileBytes,
              let data = read(relative, sessionURL),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return SessionThumbnail(id: relative, image: image)
    }

    /// Up to `limit` thumbnails, one per Shot. A still that is empty, too large or not an image falls
    /// back to the Shot's next candidate, and a Shot with none usable leaves room for a later Shot.
    static func thumbnails(
        sessionURL: URL,
        limit: Int = SessionThumbnailLoader.limit,
        read: Reader = containedRead
    ) -> [SessionThumbnail] {
        var loaded: [SessionThumbnail] = []
        var attempts = 0
        for candidates in shotCandidates(sessionURL: sessionURL) where loaded.count < limit {
            for relative in candidates {
                guard attempts < maxAttempts else { return loaded }
                attempts += 1
                if let thumbnail = loadThumbnail(relative: relative, sessionURL: sessionURL, read: read) {
                    loaded.append(thumbnail)
                    break
                }
            }
        }
        return loaded
    }

    private static func isAnnotated(_ name: String) -> Bool {
        (name as NSString).deletingPathExtension.hasSuffix(".annotated")
    }

    private static func isPreferred(_ lhs: String, _ rhs: String) -> Bool {
        if isAnnotated(lhs) != isAnnotated(rhs) { return isAnnotated(lhs) }
        let left = extensionRank[(lhs as NSString).pathExtension.lowercased()] ?? .max
        let right = extensionRank[(rhs as NSString).pathExtension.lowercased()] ?? .max
        return left == right ? lhs < rhs : left < right
    }

    private static func shotStem(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.hasSuffix(".annotated") ? String(base.dropLast(".annotated".count)) : base
    }
}

// MARK: - Detail

/// What the detail pane shows beyond the index row. Loaded off the main actor when a row is selected.
/// Of the manifest only upload consent is kept; export files are sized, never read.
struct SessionDetailFacts: Sendable, Equatable {
    struct ExportFile: Sendable, Equatable, Identifiable {
        /// Session-relative path under `export/`.
        let path: String
        let bytes: Int

        var id: String { path }
        var name: String { ExportRel.toExportRoot(path) }
    }

    struct Consent: Sendable, Equatable {
        let approved: Bool
        /// Only when approved.
        let provider: String?
        /// Only when approved.
        let model: String?
        let includesClipAudio: Bool
        let includesClipVideo: Bool
    }

    let exportFiles: [ExportFile]
    /// Nil when the manifest could not be read again.
    let consent: Consent?
    let thumbnails: [SessionThumbnail]

    static func load(vault: SessionVault, id: String) -> SessionDetailFacts {
        let sizes = vault.exportSizes(id: id)
        let files = SessionVault.indexedExportFiles.compactMap { path in
            sizes[path].map { ExportFile(path: path, bytes: $0) }
        }
        let consent = (try? vault.loadManifest(id: id)).map { Consent($0.uploadConsent) }
        let thumbnails = SessionFileAccess.checkedSessionURL(vault: vault, id: id).map {
            SessionThumbnailLoader.thumbnails(sessionURL: $0)
        } ?? []
        return SessionDetailFacts(exportFiles: files, consent: consent, thumbnails: thumbnails)
    }
}

extension SessionDetailFacts.Consent {
    init(_ consent: UploadConsent) {
        func nonBlank(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.init(
            approved: consent.approved,
            provider: consent.approved ? nonBlank(consent.provider) : nil,
            model: consent.approved ? nonBlank(consent.model) : nil,
            includesClipAudio: consent.includesClipAudio,
            includesClipVideo: consent.includesClipVideo
        )
    }
}

/// One stage of `PipelineStatusOrder.processingFlow` for a session.
struct SessionStageStep: Identifiable, Equatable {
    enum State: Equatable {
        case done
        case current
        case pending
        /// The analysis ended offline before this stage.
        case failed
    }

    let stage: PipelineStatus
    let state: State

    var id: String { stage.rawValue }

    /// Completed stages come from `completedStages`. An offline failure marks the first stage that did not
    /// complete as failed, so it never reads as still in progress.
    static func steps(for summary: SessionSummary) -> [SessionStageStep] {
        let completed = Set(summary.completedStages)
        var failureShown = false
        return PipelineStatusOrder.processingFlow.map { stage in
            if summary.pipelineStatus == .completed || completed.contains(stage) {
                return SessionStageStep(stage: stage, state: .done)
            }
            if summary.pipelineStatus == .offlineFailed {
                defer { failureShown = true }
                return SessionStageStep(stage: stage, state: failureShown ? .pending : .failed)
            }
            return SessionStageStep(stage: stage, state: summary.pipelineStatus == stage ? .current : .pending)
        }
    }
}

// MARK: - Model

/// Everything the Recordings section does outside its own state. Tests inject closures; the app uses `live`.
struct RecordingsDependencies {
    var canChangeSessions: @MainActor () -> Bool
    var activeSessionId: @MainActor () -> String?
    /// The validated `export/` folder, or nil. It walks `export/` for links, so actions call it off the
    /// main actor; only a row drag, which must answer at once, calls it on the main actor.
    var exportDirectory: @Sendable (String) -> URL?
    /// Shows the folder `exportDirectory` accepted off the main actor. It is not walked again here, so the
    /// main actor never walks `export/`; `SessionFileAccess.exportDirectory` makes the checks
    /// `SessionVault.revealInFinder` makes.
    var revealExport: @MainActor (URL) -> Void
    /// Nil when the handoff started, otherwise a fixed line saying why not (never a path).
    var openInCLI: @MainActor (LocalCodingCLI, String) -> String?
    /// False when the brief is not a usable export file.
    var openBrief: @MainActor (String) -> Bool
    var retryAnalysis: @MainActor (String) -> Void
    /// Puts the validated folder's path on the pasteboard. The path is never logged.
    var copyExportPath: @MainActor (URL) -> Bool
    var revealArchive: @MainActor (String) -> Bool
    var revealFolder: @MainActor (String) -> Bool
    /// Runs off the main actor.
    var deleteSession: @Sendable (String) throws -> Void
    /// Runs off the main actor.
    var loadDetail: @Sendable (String) -> SessionDetailFacts
    var startRecording: @MainActor () -> Void

    @MainActor
    static func live(
        controller: SessionController,
        startRecording: @escaping @MainActor () -> Void
    ) -> RecordingsDependencies {
        let vault = controller.vault
        return RecordingsDependencies(
            canChangeSessions: { controller.canChangeCaptureSettings },
            activeSessionId: { controller.activeSessionId },
            exportDirectory: { SessionFileAccess.exportDirectory(vault: vault, id: $0) },
            revealExport: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            openInCLI: { cli, id in
                controller.openInLocalCLI(cli, sessionId: id)
                // The controller reports only through its status line: the success text, or the fixed
                // description of a ClaudeCLIHandoffError.
                return controller.statusLine == cli.successStatus ? nil : controller.statusLine
            },
            openBrief: { id in
                guard let url = SessionFileAccess.briefURL(vault: vault, id: id) else { return false }
                return NSWorkspace.shared.open(url)
            },
            retryAnalysis: { controller.retryAnalysis(sessionId: $0) },
            copyExportPath: { folder in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return pasteboard.setString(folder.path, forType: .string)
            },
            revealArchive: { id in
                guard let folder = SessionFileAccess.archiveDirectory(vault: vault, id: id) else { return false }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
                return true
            },
            revealFolder: { id in
                guard let folder = SessionFileAccess.sessionDirectory(vault: vault, id: id) else { return false }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
                return true
            },
            deleteSession: { try vault.deleteSession(id: $0) },
            loadDetail: { SessionDetailFacts.load(vault: vault, id: $0) },
            startRecording: startRecording
        )
    }
}

/// Asks before showing a folder that holds the full recording and transcript.
struct PrivateRevealRequest: Identifiable, Equatable {
    let sessionId: String
    /// `.revealArchive` or `.revealFolder`.
    let action: RecordingAction

    var id: String { "\(action.rawValue)-\(sessionId)" }
}

struct SpeakerReviewRequest: Identifiable, Equatable {
    let sessionId: String
    var id: String { sessionId }
}

struct SessionContextFilterOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// State and actions of the Recordings section. The presenter owns one per window, so the session index
/// and its caches outlive section changes. It never shows or activates the window.
@MainActor
final class RecordingsModel: ObservableObject {
    nonisolated static let refreshInterval: Duration = .seconds(5)
    nonisolated static let detailCacheLimit = 8

    /// Shown while recording or analysis runs, for every action that waits for them.
    nonisolated static let busyReason = "Wait until recording and analysis finish."
    /// Shown for Delete on the session the controller still holds.
    /// Starting a recording moves the hold to the new session, but Delete waits for that recording and its
    /// analysis. A retry of another recording moves the hold too; relaunching clears it.
    nonisolated static let heldSessionReason = "ScrumTrace still holds this recording from its last recording or analysis. You can delete it after another recording, or a retry of another recording, has finished, or after you quit and reopen ScrumTrace."
    nonisolated static let unlistedReason = "This recording is no longer listed."

    /// One load of a session's detail facts: the index row it was loaded for, and how many times an action
    /// asked for the facts to be read again without that row changing.
    struct DetailKey: Hashable {
        let summary: SessionSummary
        let generation: Int
    }

    struct CachedDetail: Equatable {
        let key: DetailKey
        let facts: SessionDetailFacts
    }

    private struct DetailRequest {
        let key: DetailKey
        let task: Task<Void, Never>
    }

    let library: SessionLibrary
    let navigation: MainNavigation

    @Published var searchText = ""
    @Published var statusFilter: SessionStatusFilter?
    @Published var contextFilter: String?
    /// The session id Delete… asked about. The confirmation dialog shows while it is set.
    @Published var pendingDelete: String?
    @Published var pendingPrivateReveal: PrivateRevealRequest?
    @Published var speakerReview: SpeakerReviewRequest?
    /// A short line after an action that could not run. Never a path or captured text.
    @Published private(set) var message: String?
    /// `controller.canChangeCaptureSettings`, followed while the model observes a controller.
    @Published private(set) var canChangeSessions: Bool
    @Published private(set) var activeSessionId: String?
    /// True once the first refresh this model asked for has finished.
    @Published private(set) var hasLoaded = false
    @Published private(set) var details: [String: CachedDetail] = [:]
    /// Raised when an action may have rewritten a session's export without changing its index row.
    @Published private var detailGenerations: [String: Int] = [:]

    /// The latest action that finishes later, because its `export/` check runs off the main actor.
    private(set) var actionTask: Task<Void, Never>?
    /// The refresh loop that runs while the window is visible.
    private(set) var periodicRefresh: Task<Void, Never>?
    private(set) var isWindowVisible = false

    private let dependencies: RecordingsDependencies
    private let refreshInterval: Duration
    private var observations: Set<AnyCancellable> = []
    private var navigationObservations: Set<AnyCancellable> = []
    private var detailOrder: [String] = []
    private var detailRequests: [String: DetailRequest] = [:]
    private var reviewedSessionId: String?
    /// The refresh this model started last, until it finishes. The section appearing joins it.
    private var runningRefresh: Task<Void, Never>?
    private var refreshCount = 0
    /// Raised by every action that starts. A Reveal export/ or Copy export path whose `export/` check
    /// finishes after a newer action started does nothing, so an older path never lands on the pasteboard.
    private var actionGeneration = 0
    /// Raised with `actionGeneration`, and when the selection or the section changes. A line from a check
    /// that finishes later is shown only while this is unchanged, so it never appears under another row.
    private var messageContext = 0

    init(
        library: SessionLibrary,
        navigation: MainNavigation,
        dependencies: RecordingsDependencies,
        refreshInterval: Duration = RecordingsModel.refreshInterval
    ) {
        self.library = library
        self.navigation = navigation
        self.dependencies = dependencies
        self.refreshInterval = refreshInterval
        canChangeSessions = dependencies.canChangeSessions()
        activeSessionId = dependencies.activeSessionId()
        // Synchronous: @Published emits on the main actor, in the change itself, so a line set right after a
        // selection change is never cleared by a queued block.
        Publishers.Merge(
            navigation.$selectedSessionId.removeDuplicates().dropFirst().map { _ in () },
            navigation.$section.removeDuplicates().dropFirst().map { _ in () }
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.messageContextDidChange() }
        }
        .store(in: &navigationObservations)
    }

    /// A line under the table belongs to the row and section it was shown for.
    private func messageContextDidChange() {
        messageContext += 1
        if message != nil { message = nil }
    }

    // MARK: Refresh

    /// Follows the controller: capture state for enabled actions, and a refresh when processing ends.
    func observe(controller: SessionController) {
        observations.removeAll()
        controller.$phase
            .removeDuplicates()
            .dropFirst()
            .filter(Self.endsProcessing)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.refresh() }
            }
            .store(in: &observations)
        Publishers.Merge3(
            controller.$phase.map { _ in () },
            controller.$isBusy.map { _ in () },
            controller.$startInFlight.map { _ in () }
        )
        // @Published emits before the new value is stored; read the controller after it is.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCaptureState() }
        }
        .store(in: &observations)
    }

    /// Phases that end processing: back to idle, completed, or analysis that ended offline.
    nonisolated static func endsProcessing(_ phase: PipelineStatus) -> Bool {
        phase == .idle || phase == .completed || phase == .offlineFailed
    }

    func syncCaptureState() {
        let canChange = dependencies.canChangeSessions()
        if canChange != canChangeSessions { canChangeSessions = canChange }
        let active = dependencies.activeSessionId()
        if active != activeSessionId { activeSessionId = active }
    }

    /// Scans the vault again. Mutating actions and processing that ends always start a new scan.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        let scan = library.refresh()
        refreshCount += 1
        let number = refreshCount
        let task = Task { @MainActor [weak self] in
            await scan.value
            guard let self else { return }
            if !self.hasLoaded { self.hasLoaded = true }
            if self.refreshCount == number { self.runningRefresh = nil }
        }
        runningRefresh = task
        return task
    }

    /// RecordingsView appeared. A refresh already running, such as the one the window started when it
    /// opened on Recordings, is joined instead of decoding every manifest a second time.
    @discardableResult
    func sectionDidAppear() -> Task<Void, Never> {
        syncCaptureState()
        return runningRefresh ?? refresh()
    }

    /// Sections that show rows from the session index: Recordings, and the Overview's unfinished recordings,
    /// last recording and storage line.
    nonisolated static func listsSessions(_ section: MainSection) -> Bool {
        section == .recordings || section == .overview
    }

    /// The presenter reports whether the window is on screen. Becoming visible on a section that lists
    /// sessions refreshes at once; another section refreshes nothing, and a listing section refreshes when it
    /// appears. While the window stays visible, those sections refresh every `refreshInterval`. A hidden
    /// window does no periodic work.
    func setWindowVisible(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        periodicRefresh?.cancel()
        periodicRefresh = nil
        guard visible else { return }
        if Self.listsSessions(navigation.section) {
            refresh()
        }
        let interval = refreshInterval
        periodicRefresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                if Self.listsSessions(self.navigation.section) {
                    await self.refresh().value
                }
            }
        }
    }

    var isPeriodicRefreshActive: Bool { periodicRefresh != nil }

    // MARK: Rows

    var visibleEntries: [SessionEntry] {
        library.filtered(search: searchText, status: statusFilter, contextID: contextFilter)
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || statusFilter != nil || contextFilter != nil
    }

    /// True when the search and filters keep `entry` in the table.
    func isListed(_ entry: SessionEntry) -> Bool {
        ![entry].filtered(search: searchText, status: statusFilter, contextID: contextFilter).isEmpty
    }

    func clearFilters() {
        if !searchText.isEmpty { searchText = "" }
        if statusFilter != nil { statusFilter = nil }
        if contextFilter != nil { contextFilter = nil }
    }

    /// Before `show(sessionId:)` selects a row, drop a search or filter that would hide it.
    func revealInList(sessionId: String) {
        guard hasActiveFilters, !visibleEntries.contains(where: { $0.id == sessionId }) else { return }
        clearFilters()
    }

    func entry(id: String?) -> SessionEntry? {
        guard let id else { return nil }
        return library.entries.first { $0.id == id }
    }

    /// The selected row while the table lists it. A search or filter that hides the row leaves the id in
    /// `navigation`, so clearing them brings the selection back, but the detail pane and toolbar go idle.
    var selectedEntry: SessionEntry? {
        guard let entry = entry(id: navigation.selectedSessionId), isListed(entry) else { return nil }
        return entry
    }

    /// Contexts recorded in listed sessions, named as their newest session saved them.
    var contextOptions: [SessionContextFilterOption] {
        var names: [String: String] = [:]
        for summary in library.entries.compactMap(\.summary) {
            guard let id = summary.contextID, names[id] == nil else { continue }
            let name = summary.contextName ?? summary.productName
            names[id] = name.isEmpty ? "Unnamed context" : name
        }
        return names
            .map { SessionContextFilterOption(id: $0.key, name: $0.value) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    func dismissMessage() {
        message = nil
    }

    // MARK: Actions

    func actions(for entry: SessionEntry) -> [RecordingAction] {
        entry.summary == nil ? RecordingAction.unreadableActions : RecordingAction.readableActions
    }

    func isEnabled(_ action: RecordingAction, for entry: SessionEntry) -> Bool {
        actions(for: entry).contains(action) && unavailableReason(action, for: entry) == nil
    }

    /// Why `action` cannot run for `entry` now, in plain words for a help tag or the message line. Nil when
    /// it can run, and for actions the entry does not offer at all.
    func unavailableReason(_ action: RecordingAction, for entry: SessionEntry) -> String? {
        guard actions(for: entry).contains(action) else { return nil }
        if action.needsIdleCapture && !canChangeSessions { return Self.busyReason }
        switch action {
        case .delete:
            return isActiveSession(entry.id) ? Self.heldSessionReason : nil
        case .openBrief:
            return entry.summary?.hasBrief == true ? nil : "This recording has no brief yet."
        case .openInClaude, .openInChatGPT:
            // The handoff needs export/AGENT_CONTEXT.md, the file `hasExportContext` probes.
            return entry.summary?.hasExportContext == true ? nil : "This recording has no export to hand to an agent yet."
        case .reviewSpeakers:
            return entry.summary?.hasFullTranscriptArchive == true ? nil : "This recording has no transcript to review yet."
        case .revealExport, .copyExportPath, .retryAnalysis, .revealArchive, .revealFolder:
            return nil
        }
    }

    /// For the toolbar: the action on the selected row.
    func isEnabled(_ action: RecordingAction) -> Bool {
        selectedEntry.map { isEnabled(action, for: $0) } ?? false
    }

    func unavailableReason(_ action: RecordingAction) -> String? {
        selectedEntry.flatMap { unavailableReason(action, for: $0) }
    }

    /// Runs `action` for a listed session. Delete and the private reveals only ask for confirmation here.
    @discardableResult
    func perform(_ action: RecordingAction, on id: String) -> Bool {
        syncCaptureState()
        guard let entry = entry(id: id), isEnabled(action, for: entry) else { return false }
        beginAction()
        switch action {
        case .revealExport:
            log(action, id)
            withExportDirectory(id, missing: "The export folder is missing or contains a link, so it was not revealed.") { [dependencies] folder in
                dependencies.revealExport(folder)
                return nil
            }
        case .openInClaude, .openInChatGPT:
            log(action, id)
            if let failure = dependencies.openInCLI(action == .openInClaude ? .claude : .chatGPT, id) {
                message = failure
            }
        case .openBrief:
            log(action, id)
            if !dependencies.openBrief(id) {
                message = "The brief for this recording is not available."
            }
        case .copyExportPath:
            log(action, id)
            withExportDirectory(id, missing: "The export folder is missing or contains a link, so its path was not copied.") { [dependencies] folder in
                dependencies.copyExportPath(folder) ? nil : "The export path could not be put on the clipboard."
            }
        case .retryAnalysis:
            log(action, id)
            dependencies.retryAnalysis(id)
            reloadDetail(id)
            refresh()
        case .reviewSpeakers:
            log(action, id)
            reviewedSessionId = id
            speakerReview = SpeakerReviewRequest(sessionId: id)
        case .revealArchive, .revealFolder:
            pendingPrivateReveal = PrivateRevealRequest(sessionId: id, action: action)
        case .delete:
            pendingDelete = id
        }
        return true
    }

    @discardableResult
    func performOnSelection(_ action: RecordingAction) -> Bool {
        guard let entry = selectedEntry else { return false }
        return perform(action, on: entry.id)
    }

    /// A new action replaces the line and supersedes any `export/` check still running.
    private func beginAction() {
        actionGeneration += 1
        messageContext += 1
        if message != nil { message = nil }
        actionTask = nil
    }

    /// Checks `export/` off the main actor, then runs `body` with the folder here, or shows `missing`.
    /// `body` returns a failure line, or nil. Nothing runs when a newer action started meanwhile, and no
    /// line is shown when the selection or section changed.
    private func withExportDirectory(_ id: String, missing: String, _ body: @escaping @MainActor (URL) -> String?) {
        let lookup = dependencies.exportDirectory
        let generation = actionGeneration
        let context = messageContext
        actionTask = Task { @MainActor [weak self] in
            let folder = await Task.detached(priority: .userInitiated) { lookup(id) }.value
            guard let self, self.actionGeneration == generation else { return }
            let failure: String?
            if let folder {
                failure = body(folder)
            } else {
                failure = missing
            }
            if let failure, self.messageContext == context { self.message = failure }
        }
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    /// Deletes a session the user confirmed, off the main actor. The state is checked again because
    /// recording may have started while the dialog was open. On success the selection is cleared when it
    /// pointed there; the list refreshes either way. A failure line names the recording, because deleting
    /// a large archive can outlast a selection change; it is dropped only when a newer action started.
    @discardableResult
    func confirmDelete(_ id: String) -> Task<Void, Never>? {
        if pendingDelete != nil { pendingDelete = nil }
        syncCaptureState()
        beginAction()
        guard let entry = entry(id: id) else {
            message = Self.unlistedReason
            return nil
        }
        if let reason = unavailableReason(.delete, for: entry) {
            message = reason
            return nil
        }
        log(.delete, id)
        let generation = actionGeneration
        let delete = dependencies.deleteSession
        return Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> DeleteOutcome in
                do {
                    try delete(id)
                    return .deleted
                } catch let error as SessionVaultError {
                    switch error {
                    case .sessionMissing: return .deleted
                    case .writeFailed(let what): return what == "session is live" ? .live : .failed
                    }
                } catch {
                    return .failed
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .deleted:
                if self.navigation.selectedSessionId == id { self.navigation.selectedSessionId = nil }
                self.forgetDetail(id)
            case .live:
                AgentLog.event("main_delete_refused", ["session": id])
                if self.actionGeneration == generation { self.message = Self.liveDeleteLine(id) }
            case .failed:
                AgentLog.event("main_delete_failed", ["session": id])
                if self.actionGeneration == generation { self.message = Self.failedDeleteLine(id) }
            }
            await self.refresh().value
        }
    }

    nonisolated static func liveDeleteLine(_ id: String) -> String {
        "Recording \(id) is still live. Stop it before deleting."
    }

    nonisolated static func failedDeleteLine(_ id: String) -> String {
        "Could not delete all of recording \(id). What remains is still listed."
    }

    private enum DeleteOutcome: Sendable {
        case deleted
        case live
        case failed
    }

    func cancelPrivateReveal() {
        pendingPrivateReveal = nil
    }

    /// Reveals `archive/` or the session folder after the warning was confirmed. The state is checked again
    /// because recording may have started while the warning was open.
    func confirmPrivateReveal(_ request: PrivateRevealRequest) {
        if pendingPrivateReveal != nil { pendingPrivateReveal = nil }
        syncCaptureState()
        guard request.action == .revealArchive || request.action == .revealFolder else { return }
        beginAction()
        guard let entry = entry(id: request.sessionId) else {
            message = Self.unlistedReason
            return
        }
        guard actions(for: entry).contains(request.action) else { return }
        if let reason = unavailableReason(request.action, for: entry) {
            message = reason
            return
        }
        log(request.action, request.sessionId)
        if request.action == .revealArchive {
            if !dependencies.revealArchive(request.sessionId) {
                message = "archive/ is not a real folder inside this recording, so it was not revealed."
            }
        } else if !dependencies.revealFolder(request.sessionId) {
            message = "The recording folder is missing or is a link, so it was not revealed."
        }
    }

    /// A speaker review can rebuild the export without changing the index row, so its facts are read again.
    func speakerReviewDidClose() {
        if let id = reviewedSessionId { reloadDetail(id) }
        reviewedSessionId = nil
        refresh()
    }

    /// The only item a row drag offers: the validated `export/` folder of a readable session. A drag needs
    /// its answer at once, so this check runs on the main actor, the same walk Reveal export/ makes.
    func exportDragURL(for id: String) -> URL? {
        guard entry(id: id)?.summary != nil else { return nil }
        return dependencies.exportDirectory(id)
    }

    func dragItemProvider(for id: String) -> NSItemProvider? {
        guard let folder = exportDragURL(for: id) else { return nil }
        AgentLog.event("main_drag_export", ["session": id])
        return NSItemProvider(object: folder as NSURL)
    }

    func startRecording() {
        syncCaptureState()
        guard canChangeSessions else { return }
        AgentLog.event("main_start", [:])
        dependencies.startRecording()
    }

    /// True for the session the controller holds, in any spelling of its id.
    func isActiveSession(_ id: String) -> Bool {
        guard let activeSessionId else { return false }
        return activeSessionId.caseInsensitiveCompare(id) == .orderedSame
    }

    // MARK: Detail

    func detailKey(for summary: SessionSummary) -> DetailKey {
        DetailKey(summary: summary, generation: detailGenerations[summary.sessionId] ?? 0)
    }

    /// The newest facts loaded for this session. After its row changed or an action asked for a reload,
    /// they stay on screen until the new facts arrive, so the pane does not fall back to a spinner.
    func detail(for summary: SessionSummary) -> SessionDetailFacts? {
        details[summary.sessionId]?.facts
    }

    func isDetailCurrent(for summary: SessionSummary) -> Bool {
        details[summary.sessionId]?.key == detailKey(for: summary)
    }

    /// Loads the facts for this row off the main actor unless they are current. A load already running
    /// for the same row and generation is returned instead of starting another.
    @discardableResult
    func loadDetail(for summary: SessionSummary) -> Task<Void, Never>? {
        let key = detailKey(for: summary)
        let id = summary.sessionId
        if details[id]?.key == key { return nil }
        if let running = detailRequests[id], running.key == key { return running.task }
        let load = dependencies.loadDetail
        let task = Task { @MainActor [weak self] in
            let facts = await Task.detached(priority: .utility) { load(id) }.value
            guard let self, self.detailRequests[id]?.key == key else { return }
            self.detailRequests[id] = nil
            self.storeDetail(CachedDetail(key: key, facts: facts))
        }
        detailRequests[id] = DetailRequest(key: key, task: task)
        return task
    }

    private func storeDetail(_ detail: CachedDetail) {
        let id = detail.key.summary.sessionId
        detailOrder.removeAll { $0 == id }
        detailOrder.append(id)
        var updated = details
        updated[id] = detail
        while detailOrder.count > Self.detailCacheLimit {
            updated[detailOrder.removeFirst()] = nil
        }
        details = updated
    }

    /// After an action that may rewrite `export/` without changing the index row. The facts shown stay; the
    /// selected session reads them again now, any other session when it is next shown.
    private func reloadDetail(_ id: String) {
        detailGenerations[id, default: 0] += 1
        if let summary = selectedEntry?.summary, summary.sessionId == id {
            loadDetail(for: summary)
        }
    }

    /// After a delete: nothing about the session is kept.
    private func forgetDetail(_ id: String) {
        detailOrder.removeAll { $0 == id }
        detailRequests[id] = nil
        if detailGenerations[id] != nil { detailGenerations[id] = nil }
        if details[id] != nil { details[id] = nil }
    }

    private func log(_ action: RecordingAction, _ id: String) {
        AgentLog.event(action.logEvent, ["session": id])
    }
}

// MARK: - Row text

@MainActor
enum RecordingRowText {
    static func date(_ entry: SessionEntry) -> String {
        entry.sortDate.map(SessionSummary.formattedDate) ?? "—"
    }

    static func contextAndProduct(_ summary: SessionSummary) -> String {
        let product = summary.productName
        guard let context = summary.contextName else {
            return product.isEmpty ? "No context" : product
        }
        return product.isEmpty || product == context ? context : "\(context) / \(product)"
    }

    static func duration(_ entry: SessionEntry) -> String {
        entry.summary.map { SessionController.clock($0.mediaSeconds) } ?? "—"
    }

    /// A completed session can still hold tasks or slices that need review.
    static func needsReviewMarker(_ summary: SessionSummary) -> Bool {
        summary.pipelineStatus != .offlineFailed && SessionStatusFilter.needsReview.matches(summary)
    }

    static func shots(_ entry: SessionEntry) -> String {
        entry.summary.map { String($0.shotCount) } ?? "—"
    }

    static func tasks(_ entry: SessionEntry) -> String {
        entry.summary.map { "\($0.taskCounts.confirmed) / \($0.taskCounts.needsReview)" } ?? "—"
    }

    static func export(_ entry: SessionEntry) -> String {
        entry.summary?.packBytes.map(bytes) ?? "—"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Views

struct RecordingsView: View {
    @ObservedObject var model: RecordingsModel
    @ObservedObject var library: SessionLibrary
    @ObservedObject var navigation: MainNavigation
    /// Only handed to the speaker review sheet, which observes it itself.
    let controller: SessionController

    var body: some View {
        content
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search recordings")
            .toolbar { toolbar }
            .onAppear { model.sectionDidAppear() }
            .confirmationDialog(
                "Delete this recording?",
                isPresented: Binding(
                    get: { model.pendingDelete != nil },
                    set: { if !$0 { model.cancelDelete() } }
                ),
                titleVisibility: .visible,
                presenting: model.pendingDelete
            ) { id in
                Button("Delete recording", role: .destructive) { model.confirmDelete(id) }
                    .accessibilityIdentifier("main.recordings.confirmDelete")
                Button("Cancel", role: .cancel) { model.cancelDelete() }
            } message: { id in
                Text("\(id) will be removed, including archive/ with the full recording and transcript, and export/ with the brief and session pack. This cannot be undone.")
            }
            .background {
                // A second dialog on its own view, so the two presentations never compete.
                Color.clear
                    .confirmationDialog(
                        "Reveal private files?",
                        isPresented: Binding(
                            get: { model.pendingPrivateReveal != nil },
                            set: { if !$0 { model.cancelPrivateReveal() } }
                        ),
                        titleVisibility: .visible,
                        presenting: model.pendingPrivateReveal
                    ) { request in
                        Button(request.action == .revealFolder ? "Reveal folder" : "Reveal archive") {
                            model.confirmPrivateReveal(request)
                        }
                        .accessibilityIdentifier("main.recordings.confirmPrivateReveal")
                        Button("Cancel", role: .cancel) { model.cancelPrivateReveal() }
                    } message: { _ in
                        Text("This folder holds the full recording and transcript. Never hand it to an agent.")
                    }
            }
            .sheet(item: $model.speakerReview, onDismiss: { model.speakerReviewDidClose() }) { request in
                SpeakerReviewView(controller: controller, initialSessionId: request.sessionId)
            }
    }

    @ViewBuilder
    private var content: some View {
        if library.entries.isEmpty {
            if library.isLoading || !model.hasLoaded {
                ProgressView("Loading recordings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        } else {
            // A SwiftUI stack rather than VSplitView: the AppKit split view ignored the sidebar's safe
            // area and its offered width, so columns slid under the sidebar or shrank to a narrow strip.
            VStack(spacing: 0) {
                listPane
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    .layoutPriority(1)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.detailHeight)
            }
        }
    }

    /// Leaves the table at least a few rows at the window's minimum size, with the live banner shown.
    private static let detailHeight: CGFloat = 290

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No recordings yet", systemImage: MainSection.recordings.systemImage)
        } description: {
            Text("Recordings appear here after you stop a session. Each one keeps a private archive and an export you can hand to an agent.")
        } actions: {
            Button("Start recording") { model.startRecording() }
                .disabled(!model.canChangeSessions)
                .accessibilityIdentifier("main.recordings.start")
        }
    }

    private var listPane: some View {
        let entries = model.visibleEntries
        return VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No matching recordings", systemImage: "magnifyingglass")
                } description: {
                    Text("No recording matches the search and filters.")
                } actions: {
                    Button("Clear search and filters") { model.clearFilters() }
                        .accessibilityIdentifier("main.recordings.clearFilters")
                }
            } else {
                RecordingsTable(model: model, navigation: navigation, entries: entries)
            }
            if let message = model.message {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button { model.dismissMessage() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss message")
                    .accessibilityIdentifier("main.recordings.dismissMessage")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch model.selectedEntry {
        case .loaded(let summary):
            SessionDetailView(model: model, summary: summary)
        case .unreadable(let id, let reason):
            UnreadableSessionDetailView(model: model, id: id, reason: reason)
        case nil:
            ContentUnavailableView(
                "No recording selected",
                systemImage: "film",
                description: Text("Select a recording to see its processing stages, upload consent and export files.")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Status", selection: $model.statusFilter) {
                    Text("All statuses").tag(SessionStatusFilter?.none)
                    ForEach(SessionStatusFilter.allCases) { filter in
                        Text(filter.title).tag(SessionStatusFilter?.some(filter))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(
                    "Status filter",
                    systemImage: model.statusFilter == nil
                        ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .help("Filter by status")
            .accessibilityIdentifier("main.recordings.filter.status")

            Menu {
                Picker("Context", selection: $model.contextFilter) {
                    Text("All contexts").tag(String?.none)
                    ForEach(model.contextOptions) { option in
                        Text(option.name).tag(String?.some(option.id))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Context filter", systemImage: model.contextFilter == nil ? "shippingbox" : "shippingbox.fill")
            }
            .help("Filter by product context")
            .disabled(model.contextOptions.isEmpty && model.contextFilter == nil)
            .accessibilityIdentifier("main.recordings.filter.context")

            toolbarButton(.revealExport)
                .keyboardShortcut("r", modifiers: .command)

            Menu {
                selectionMenuItems([.openInClaude, .openInChatGPT, .openBrief, .copyExportPath])
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            .help("Open or copy the export")
            .disabled(model.selectedEntry?.summary == nil)
            .accessibilityIdentifier("main.recordings.open")

            toolbarButton(.retryAnalysis)

            Menu {
                selectionMenuItems([.reviewSpeakers, .revealArchive, .revealFolder])
            } label: {
                Label("More actions", systemImage: "ellipsis.circle")
            }
            .help("More actions")
            .disabled(model.selectedEntry == nil)
            .accessibilityIdentifier("main.recordings.more")

            toolbarButton(.delete)
        }
    }

    private func toolbarButton(_ action: RecordingAction) -> some View {
        Button(role: action == .delete ? .destructive : nil) {
            model.performOnSelection(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .help(model.unavailableReason(action) ?? action.title)
        .disabled(!model.isEnabled(action))
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }

    @ViewBuilder
    private func selectionMenuItems(_ actions: [RecordingAction]) -> some View {
        if let entry = model.selectedEntry {
            RecordingActionMenuItems(
                model: model,
                entry: entry,
                actions: actions.filter { model.actions(for: entry).contains($0) }
            )
        }
    }
}

struct RecordingsTable: View {
    @ObservedObject var model: RecordingsModel
    @ObservedObject var navigation: MainNavigation
    let entries: [SessionEntry]

    var body: some View {
        Table(of: SessionEntry.self, selection: $navigation.selectedSessionId) {
            TableColumn("Date") { entry in
                Text(RecordingRowText.date(entry)).monospacedDigit()
            }
            .width(min: 120, ideal: 172)
            TableColumn("Context / product") { entry in
                RecordingContextCell(entry: entry)
            }
            .width(min: 140, ideal: 190)
            TableColumn("Duration") { entry in
                Text(RecordingRowText.duration(entry)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 68)
            TableColumn("Status") { entry in
                RecordingStatusCell(entry: entry)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Shots") { entry in
                Text(RecordingRowText.shots(entry)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 46)
            TableColumn("Tasks") { entry in
                RecordingTasksCell(entry: entry)
            }
            .width(min: 48, ideal: 60)
            TableColumn("Export") { entry in
                Text(RecordingRowText.export(entry)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 72)
        } rows: {
            ForEach(entries) { entry in
                TableRow(entry)
                    .itemProvider { model.dragItemProvider(for: entry.id) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let entry = model.entry(id: id) {
                RecordingActionMenuItems(model: model, entry: entry, actions: model.actions(for: entry))
            }
        }
        .onDeleteCommand { model.performOnSelection(.delete) }
        .accessibilityIdentifier("main.recordings.table")
    }
}

private struct RecordingContextCell: View {
    let entry: SessionEntry

    var body: some View {
        switch entry {
        case .loaded(let summary):
            let text = RecordingRowText.contextAndProduct(summary)
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
        case .unreadable:
            Label {
                Text("Unreadable manifest")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct RecordingStatusCell: View {
    let entry: SessionEntry

    var body: some View {
        switch entry {
        case .loaded(let summary):
            HStack(spacing: 4) {
                Text(PipelineStatusOrder.label(summary.pipelineStatus))
                    .lineLimit(1)
                if RecordingRowText.needsReviewMarker(summary) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .help("Needs review")
                        .accessibilityLabel("Needs review")
                }
            }
        case .unreadable(_, let reason):
            Text(reason)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct RecordingTasksCell: View {
    let entry: SessionEntry

    var body: some View {
        let text = RecordingRowText.tasks(entry)
        if let counts = entry.summary?.taskCounts {
            Text(text).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("\(counts.confirmed) confirmed, \(counts.needsReview) need review")
                .accessibilityLabel("\(counts.confirmed) confirmed, \(counts.needsReview) need review")
        } else {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Menu items for one session, grouped with separators.
struct RecordingActionMenuItems: View {
    @ObservedObject var model: RecordingsModel
    let entry: SessionEntry
    let actions: [RecordingAction]

    var body: some View {
        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
            if index > 0 && action.startsGroup {
                Divider()
            }
            Button(role: action == .delete ? .destructive : nil) {
                model.perform(action, on: entry.id)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(!model.isEnabled(action, for: entry))
            .help(model.unavailableReason(action, for: entry) ?? action.title)
        }
    }
}

/// The selected recording, laid out so the header, stages, upload consent and export files fit the pane's
/// height at the default window size. Wider windows add columns; the rest scrolls.
struct SessionDetailView: View {
    @ObservedObject var model: RecordingsModel
    let summary: SessionSummary

    private static let primaryActions: [RecordingAction] = [.revealExport, .openInClaude, .openInChatGPT, .openBrief]
    private static let columns = [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)]

    private struct Fact: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var body: some View {
        let facts = model.detail(for: summary)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                header
                VStack(alignment: .leading, spacing: 4) {
                    SessionStageProgress(steps: SessionStageStep.steps(for: summary))
                    if summary.pipelineStatus == .offlineFailed {
                        Text("Analysis could not finish online. The local export is kept; Retry analysis tries again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.canChangeSessions, model.isActiveSession(summary.sessionId) {
                        Text(RecordingsModel.heldSessionReason)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                    GroupBox("Export") { exportFiles(facts) }
                    GroupBox("Upload") { factGrid(uploadFacts(facts)) }
                    GroupBox("Recording") { factGrid(recordingFacts) }
                    if let thumbnails = facts?.thumbnails, !thumbnails.isEmpty {
                        GroupBox("Shots") { shots(thumbnails) }
                    }
                }
                Text("Only export/ is handed to agents. Dragging a row offers this folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keyed on the generation too, so an action that asked for fresh facts reloads them on screen.
        .task(id: model.detailKey(for: summary)) {
            await model.loadDetail(for: summary)?.value
        }
        .accessibilityIdentifier("main.recordings.detail")
    }

    private var header: some View {
        let entry = SessionEntry.loaded(summary)
        let others = model.actions(for: entry).filter { !Self.primaryActions.contains($0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(summary.sessionId)
                .font(.headline)
                .textSelection(.enabled)
            Text(headerLine)
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: 8) {
                ForEach(Self.primaryActions) { action in
                    Button(action.title) { model.perform(action, on: summary.sessionId) }
                        .disabled(!model.isEnabled(action, for: entry))
                        .help(model.unavailableReason(action, for: entry) ?? action.title)
                        .accessibilityIdentifier("main.recordings.detail.\(action.rawValue)")
                }
                Menu("More") {
                    RecordingActionMenuItems(model: model, entry: entry, actions: others)
                }
                .fixedSize()
                .accessibilityIdentifier("main.recordings.detail.more")
            }
        }
    }

    /// Created, media against wall-clock duration, and pauses.
    private var headerLine: String {
        let pauses = summary.pauseCount == 1 ? "1 pause" : "\(summary.pauseCount) pauses"
        return [
            "Created \(SessionSummary.formattedDate(summary.createdAt))",
            "\(SessionController.clock(summary.mediaSeconds)) recorded",
            "\(SessionController.clock(summary.wallSeconds)) wall clock",
            pauses
        ].joined(separator: " · ")
    }

    private func uploadFacts(_ facts: SessionDetailFacts?) -> [Fact] {
        var rows = [Fact(label: "Consent", value: summary.consentApproved ? "Approved" : "Not approved")]
        if let consent = facts?.consent {
            let service = [consent.provider, consent.model].compactMap { $0 }.joined(separator: " · ")
            if consent.approved, !service.isEmpty {
                rows.append(Fact(label: "AI service", value: service))
            }
            rows.append(Fact(label: "Clip audio", value: consent.includesClipAudio ? "Included" : "Not included"))
            rows.append(Fact(label: "Clip video", value: consent.includesClipVideo ? "Included" : "Not included"))
        }
        let omitted = summary.omittedCount == 1 ? "1 file left out of the pack" : "\(summary.omittedCount) files left out of the pack"
        rows.append(Fact(label: "Omitted", value: omitted))
        return rows
    }

    private var recordingFacts: [Fact] {
        let tasks = summary.taskCounts
        return [
            Fact(label: "Context", value: RecordingRowText.contextAndProduct(summary)),
            Fact(label: "Shots", value: "\(summary.shotCount) Shots · \(summary.sliceCount) slices"),
            Fact(label: "Tasks", value: "\(tasks.confirmed) confirmed · \(tasks.needsReview) need review · \(tasks.dropped) dropped")
        ]
    }

    private func factGrid(_ rows: [Fact]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func exportFiles(_ facts: SessionDetailFacts?) -> some View {
        if let facts {
            if facts.exportFiles.isEmpty {
                Text("No export files yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                    ForEach(facts.exportFiles) { file in
                        GridRow {
                            Text(file.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(RecordingRowText.bytes(file.bytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shots(_ thumbnails: [SessionThumbnail]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(thumbnails) { thumbnail in
                    Image(thumbnail.image, scale: 1, label: Text("Shot \(thumbnail.name)"))
                        .resizable()
                        .scaledToFit()
                        .frame(height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                        .help(thumbnail.name)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct SessionStageProgress: View {
    let steps: [SessionStageStep]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 3) {
                    icon(for: step.state)
                    Text(PipelineStatusOrder.label(step.stage))
                        .font(.caption)
                        .foregroundStyle(step.state == .pending ? .secondary : .primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(PipelineStatusOrder.label(step.stage)), \(stateLabel(step.state))")
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func icon(for state: SessionStageStep.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .current:
            Image(systemName: "circle.dotted").foregroundStyle(Color.accentColor)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func stateLabel(_ state: SessionStageStep.State) -> String {
        switch state {
        case .done: return "done"
        case .current: return "not finished"
        case .pending: return "not started"
        case .failed: return "ended offline"
        }
    }
}

private struct UnreadableSessionDetailView: View {
    @ObservedObject var model: RecordingsModel
    let id: String
    let reason: String

    var body: some View {
        let entry = SessionEntry.unreadable(id: id, reason: reason)
        ContentUnavailableView {
            Label("Unreadable manifest", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The manifest of \(id) could not be used (\(reason)). Reveal the folder to inspect it, or delete the recording.")
        } actions: {
            HStack {
                ForEach(model.actions(for: entry)) { action in
                    Button(action.title, role: action == .delete ? .destructive : nil) {
                        model.perform(action, on: id)
                    }
                    .fixedSize()
                    .disabled(!model.isEnabled(action, for: entry))
                    .help(model.unavailableReason(action, for: entry) ?? action.title)
                    .accessibilityIdentifier("main.recordings.detail.\(action.rawValue)")
                }
            }
        }
    }
}
#endif
