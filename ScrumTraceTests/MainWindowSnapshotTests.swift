import AppKit
import SwiftUI
import XCTest
@testable import ScrumTrace

/// Layout snapshots of the real main window, for a human visual review. Runs only when SCRUMTRACE_SNAPSHOT_DIR is
/// set, and skips otherwise. Each view is drawn at 960×640 points of content in the light and dark appearance and
/// written as `<section>-<variant>-<light|dark>.png`. Nothing is asserted about pixels.
final class MainWindowSnapshotTests: XCTestCase {
    private static let contentSize = NSSize(width: 960, height: 640)
    private static let appearances: [(name: NSAppearance.Name, suffix: String)] = [(.aqua, "light"), (.darkAqua, "dark")]

    private struct Fixture {
        /// Completed, with export files, two `export/shots` stills, tasks and approved upload consent.
        let completed: String
        /// Transcribing, no export files.
        let unfinished: String
        /// Analysis ended offline.
        let offlineFailed: String
        /// A folder whose manifest is not JSON.
        let corrupt: String
        /// Saved context the completed recording used.
        let usedContext: SavedProductContext
        /// Saved context no recording used. It is the default, so the badge sits on another row than the selection.
        let unusedContext: SavedProductContext
    }

    private func snapshotDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SCRUMTRACE_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set SCRUMTRACE_SNAPSHOT_DIR to render main window snapshots for layout review")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Tests

    @MainActor
    func testRenderSectionsOverAFixtureVault() async throws {
        let directory = try snapshotDirectory()
        try await withController(populated: true) { controller, fixture in
            let f = try XCTUnwrap(fixture)
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
            defer { presenter.window?.close() }
            let recordings = presenter.recordings
            let library = recordings.library

            presenter.show(section: .overview)
            let window = try XCTUnwrap(presenter.window)
            try await render(window, as: "overview-idle", into: directory) {
                presenter.overview.readiness != nil && library.entries.count == 4 && library.totalArchiveBytes != nil
            }

            // The live banner sits above the section while a recording runs.
            controller.phase = .recording
            controller.statusLine = "Recording"
            controller.mediaElapsed = 754
            try await render(window, as: "overview-recording", into: directory) {
                !presenter.overview.canStartRecording && !recordings.canChangeSessions
            }
            controller.phase = .idle
            controller.mediaElapsed = 0
            controller.statusLine = "Ready"
            let idle = await waitUntil { presenter.overview.canStartRecording && recordings.canChangeSessions }
            XCTAssertTrue(idle, "The window follows the recording ending")

            // Needs attention, Last recording and Storage sit below the readiness card.
            try await render(window, as: "overview-scrolled", into: directory, beforeCapture: scrollToBottom) {
                presenter.overview.attention.unfinished.count == 2 && presenter.overview.attention.unreadableIds == [f.corrupt]
            }

            presenter.show(sessionId: f.completed)
            let detailLoaded: @MainActor () -> Bool = {
                guard let summary = recordings.selectedEntry?.summary, summary.sessionId == f.completed else { return false }
                return recordings.isDetailCurrent(for: summary) && recordings.detail(for: summary)?.thumbnails.count == 2
            }
            try await render(window, as: "recordings-selected", into: directory, ready: detailLoaded)
            // The Recording facts and the Shots thumbnails sit below the fold of the detail pane.
            try await render(window, as: "recordings-scrolled", into: directory, beforeCapture: scrollToBottom, ready: detailLoaded)

            presenter.show(section: .contexts)
            presenter.contexts.selectedContextID = f.usedContext.id
            try await render(window, as: "contexts-selected", into: directory) {
                presenter.contexts.selectedContextID == f.usedContext.id
                    && presenter.contexts.usage[f.usedContext.id]?.recordingCount == 1
            }

            presenter.show(tab: .speech)
            try await render(window, as: "settings-speech", into: directory) {
                presenter.navigation.section == .settings
            }
            XCTAssertEqual(Set(library.entries.map(\.id)), [f.completed, f.unfinished, f.offlineFailed, f.corrupt])
        }
    }

    @MainActor
    func testRenderTheRecordingsEmptyState() async throws {
        let directory = try snapshotDirectory()
        try await withController(populated: false) { controller, _ in
            let presenter = MainWindowPresenter(controller: controller, frameAutosaveName: nil)
            defer { presenter.window?.close() }
            presenter.show(section: .recordings)
            let window = try XCTUnwrap(presenter.window)
            try await render(window, as: "recordings-empty", into: directory) {
                presenter.recordings.hasLoaded && presenter.recordings.library.entries.isEmpty
            }
        }
    }

    // MARK: - Rendering

    /// Draws the window, title bar and toolbar included, once per appearance. `beforeCapture` runs after the
    /// content settled, for example to scroll.
    ///
    /// `cacheDisplay` cannot draw Liquid Glass on macOS 26: the sidebar, and in the dark appearance the toolbar
    /// items and the Settings tab strip, come out as blank white shapes. Check those on a Mac.
    @MainActor
    private func render(
        _ window: NSWindow,
        as name: String,
        into directory: URL,
        beforeCapture: (@MainActor (NSWindow) -> Void)? = nil,
        ready: @MainActor () -> Bool
    ) async throws {
        for appearance in Self.appearances {
            window.appearance = NSAppearance(named: appearance.name)
            window.setContentSize(Self.contentSize)
            let loaded = await waitUntil(timeout: 10, ready)
            XCTAssertTrue(loaded, "\(name) finished loading")
            // Real display cycles, so SwiftUI redraws in the new appearance and settles its layout.
            spinRunLoop(for: 0.5)
            if let beforeCapture {
                beforeCapture(window)
                spinRunLoop(for: 0.2)
            }
            XCTAssertEqual(window.contentView?.bounds.size, Self.contentSize, name)
            let file = directory.appendingPathComponent("\(name)-\(appearance.suffix).png")
            try pngData(of: window).write(to: file)
        }
        window.appearance = nil
    }

    @MainActor
    private func pngData(of window: NSWindow) throws -> Data {
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// Scrolls every vertical scroll view except tables and the sidebar list to its end.
    @MainActor
    private func scrollToBottom(in window: NSWindow) {
        guard let content = window.contentView else { return }
        var stack: [NSView] = [content]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard let scroll = view as? NSScrollView, let document = scroll.documentView,
                  !(document is NSTableView) else { continue }
            let overflow = document.frame.height - scroll.contentView.bounds.height
            guard overflow > 0 else { continue }
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: document.isFlipped ? overflow : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @MainActor
    private func spinRunLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: - Fixture

    /// An isolated defaults suite, agent log and session vault. `populated` fills the vault and the saved contexts
    /// before the controller starts, so start-up keeps every fixture folder.
    @MainActor
    private func withController(
        populated: Bool,
        _ body: (SessionController, Fixture?) async throws -> Void
    ) async throws {
        let suite = "ScrumTrace.MainWindowSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: defaults, keyStore: .empty)
        let vault = SessionVault(rootURL: root.appendingPathComponent("sessions", isDirectory: true))
        let fixture = populated ? try populate(vault: vault, settings: settings) : nil
        try await body(SessionController(settings: settings, vault: vault), fixture)
    }

    @MainActor
    private func populate(vault: SessionVault, settings: AppSettings) throws -> Fixture {
        let orbit = SavedProductContext(
            name: "Orbit web",
            product: ProductContext(appName: "Orbit Checkout", repoURL: "https://example.test/orbit-checkout", techStack: "Swift, SwiftUI")
        )
        let ledger = SavedProductContext(
            name: "Ledger API",
            product: ProductContext(appName: "Ledger", repoURL: "https://example.test/ledger", techStack: "Go, PostgreSQL")
        )
        try settings.saveProductContext(orbit, isNew: true)
        try settings.saveProductContext(ledger, isNew: true)
        try settings.selectProductContext(id: ledger.id)

        let now = Date()
        var completed = try vault.createSession(product: orbit.snapshot).manifest
        completed.createdAt = now.addingTimeInterval(-26 * 3_600)
        completed.pipelineStatus = .completed
        completed.completedStages = PipelineStatusOrder.processingFlow
        completed.duration = DurationPair(wallSeconds: 1_520, mediaSeconds: 1_384)
        completed.pauses = [
            PauseInterval(pauseWall: 300, resumeWall: 380),
            PauseInterval(pauseWall: 900, resumeWall: 956)
        ]
        completed.shots = (1...2).map { (index: Int) -> ShotRecord in
            let name = "shot-00\(index)"
            return ShotRecord(
                id: name,
                tMedia: TimeInterval(index * 240),
                rawPath: "\(ScrumTracePath.shots)/\(name).png",
                annotatedPath: nil,
                exportPath: "\(ScrumTracePath.exportShots)/\(name).png",
                note: "",
                source: .typed
            )
        }
        completed.slices = (1...3).map { (index: Int) -> SliceRecord in
            let fromShot = index < 3
            let trigger: SliceTrigger = fromShot ? .shot : .keyword
            let shotId: String? = fromShot ? "shot-00\(index)" : nil
            let start = TimeInterval(index * 220)
            return SliceRecord(
                sliceId: "slice-00\(index)",
                startMedia: start,
                endMedia: start + 60,
                trigger: trigger,
                associatedShotId: shotId,
                clipPath: nil,
                stills: [],
                analysisStatus: .success,
                score: 0.8
            )
        }
        let taskStatuses: [TaskStatus] = [.confirmed, .confirmed, .needsReview]
        completed.tasks = taskStatuses.enumerated().map { (index: Int, status: TaskStatus) -> TaskRecord in
            TaskRecord(
                taskId: "task-00\(index + 1)",
                sourceSliceId: "slice-00\(index + 1)",
                kind: .bug,
                status: status,
                title: "Fixture task \(index + 1)",
                observed: "",
                stated: "",
                inferred: "",
                agentInstructions: "",
                quotes: [],
                evidenceMedia: [],
                confidence: 0.7
            )
        }
        completed.uploadConsent = UploadConsent(
            approved: true,
            approvedAt: now,
            provider: "anthropic",
            endpoint: "https://api.example.test",
            model: "model-x",
            includesClipAudio: true,
            includesClipVideo: false,
            includesStills: true
        )
        try vault.write(manifest: &completed)
        let completedURL = vault.sessionURL(id: completed.sessionId)
        try writeFile(Data(repeating: 0x61, count: 4_200), to: ScrumTracePath.agentContext, in: completedURL)
        try writeFile(Data(repeating: 0x61, count: 1_100), to: ScrumTracePath.agentPrompt, in: completedURL)
        try writeFile(Data(repeating: 0x61, count: 18_500), to: ScrumTracePath.sessionBrief, in: completedURL)
        try writeFile(Data(count: 1_350_000), to: ScrumTracePath.packZip, in: completedURL)
        try writeFile(try shotPNG(hue: 0.58), to: "\(ScrumTracePath.exportShots)/shot-001.png", in: completedURL)
        try writeFile(try shotPNG(hue: 0.08), to: "\(ScrumTracePath.exportShots)/shot-002.png", in: completedURL)
        try writeFile(Data(#"{"segments":[]}"#.utf8), to: ScrumTracePath.fullTranscript, in: completedURL)
        // A movie keeps controller start-up from pruning each fixture folder as an abandoned start.
        try writeFile(Data(count: 64), to: ScrumTracePath.sessionMovie, in: completedURL)

        var failed = try vault.createSession(product: .empty).manifest
        failed.createdAt = now.addingTimeInterval(-3 * 3_600)
        failed.pipelineStatus = .offlineFailed
        failed.completedStages = [.transcribing, .slicing]
        failed.duration = DurationPair(wallSeconds: 640, mediaSeconds: 602)
        failed.slices = [
            SliceRecord(
                sliceId: "slice-001",
                startMedia: 120,
                endMedia: 180,
                trigger: .pin,
                associatedShotId: nil,
                clipPath: nil,
                stills: [],
                analysisStatus: .offlineFailed,
                score: 0.5
            )
        ]
        try vault.write(manifest: &failed)
        try writeFile(Data(count: 64), to: ScrumTracePath.sessionMovie, in: vault.sessionURL(id: failed.sessionId))

        var unfinished = try vault.createSession(product: .empty).manifest
        unfinished.createdAt = now.addingTimeInterval(-20 * 60)
        unfinished.pipelineStatus = .transcribing
        unfinished.duration = DurationPair(wallSeconds: 310, mediaSeconds: 296)
        try vault.write(manifest: &unfinished)
        try writeFile(Data(count: 64), to: ScrumTracePath.sessionMovie, in: vault.sessionURL(id: unfinished.sessionId))

        let corrupt = "2026-09-10-0930-bad001"
        let corruptURL = vault.sessionURL(id: corrupt)
        try writeFile(Data("{ not json".utf8), to: ScrumTracePath.manifest, in: corruptURL)
        try writeFile(Data(count: 64), to: ScrumTracePath.sessionMovie, in: corruptURL)

        return Fixture(
            completed: completed.sessionId,
            unfinished: unfinished.sessionId,
            offlineFailed: failed.sessionId,
            corrupt: corrupt,
            usedContext: orbit,
            unusedContext: ledger
        )
    }

    private func writeFile(_ data: Data, to relative: String, in session: URL) throws {
        let url = session.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// A 640×400 still with a coloured backdrop and a light panel, so thumbnails are visible in both appearances.
    private func shotPNG(hue: CGFloat) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 640,
            pixelsHigh: 400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedHue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        NSColor(calibratedHue: hue, saturation: 0.7, brightness: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 352, width: 640, height: 48).fill()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSRect(x: 40, y: 40, width: 380, height: 280).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
