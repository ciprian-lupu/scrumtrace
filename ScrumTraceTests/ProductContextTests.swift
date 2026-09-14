import AppKit
import SwiftUI
import XCTest
@testable import ScrumTrace

final class ProductContextTests: XCTestCase {
    @MainActor
    private func withPreferences(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "ScrumTrace.ContextTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try body(defaults, root)
    }

    private func profile(_ name: String) -> SavedProductContext {
        SavedProductContext(name: name, product: ProductContext(appName: name, repoURL: "https://example.test/\(name)", techStack: name == "GIB" ? "Shell" : "Swift"))
    }

    @MainActor
    func testFreshInstallHasAnExplicitNoContextChoice() throws {
        try withPreferences { defaults, _ in
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            XCTAssertTrue(settings.contextLibrary.profiles.isEmpty)
            XCTAssertNil(settings.contextLibrary.selectedID)
            XCTAssertEqual(try settings.selectProductContext(id: nil), .empty)
        }
    }

    @MainActor
    func testLegacyContextMigratesOnceAndDoesNotReturnAfterDeletion() throws {
        try withPreferences { defaults, _ in
            defaults.set("ScrumTrace", forKey: "scrumtrace.appName")
            defaults.set("https://example.test/scrumtrace", forKey: "scrumtrace.repoURL")
            defaults.set("Swift, AppKit", forKey: "scrumtrace.techStack")
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            let imported = try XCTUnwrap(settings.contextLibrary.selected)
            XCTAssertEqual(imported.name, "ScrumTrace")
            XCTAssertEqual(imported.product.techStack, "Swift, AppKit")
            XCTAssertEqual(imported.product.repoURL, "https://example.test/scrumtrace")
            let reloaded = AppSettings(defaults: defaults, keyStore: .empty)
            XCTAssertEqual(reloaded.contextLibrary.profiles, [imported])
            try reloaded.deleteProductContext(id: imported.id)
            let afterDeletion = AppSettings(defaults: defaults, keyStore: .empty)
            XCTAssertTrue(afterDeletion.contextLibrary.profiles.isEmpty)
            XCTAssertEqual(afterDeletion.productContext, .empty)
        }
    }

    @MainActor
    func testLegacyContextWithoutAppNamePreservesItsOtherFields() throws {
        try withPreferences { defaults, _ in
            defaults.set("git@example.test:team/product.git", forKey: "scrumtrace.repoURL")
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            XCTAssertEqual(settings.contextLibrary.selected?.name, "Imported context")
            XCTAssertEqual(settings.productContext.repoURL, "git@example.test:team/product.git")
        }
    }

    @MainActor
    func testTwoContextsAndExplicitNoContextSurviveRelaunch() throws {
        try withPreferences { defaults, _ in
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            let scrum = profile("ScrumTrace"), gib = profile("GIB")
            try settings.saveProductContext(scrum, isNew: true)
            try settings.saveProductContext(gib, isNew: true)
            XCTAssertEqual(try settings.selectProductContext(id: scrum.id).appName, "ScrumTrace")
            XCTAssertEqual(try settings.selectProductContext(id: gib.id).appName, "GIB")
            let reloaded = AppSettings(defaults: defaults, keyStore: .empty)
            XCTAssertEqual(reloaded.contextLibrary.profiles, [scrum, gib])
            XCTAssertEqual(reloaded.productContext.contextID, gib.id)
            try reloaded.selectProductContext(id: nil)
            let withoutContext = AppSettings(defaults: defaults, keyStore: .empty)
            XCTAssertEqual(withoutContext.productContext, .empty)
            XCTAssertEqual(withoutContext.contextLibrary.profiles.count, 2)
        }
    }

    @MainActor
    func testNamesAreValidatedAndFailedEditsLeaveStoredContextsIntact() throws {
        try withPreferences { defaults, _ in
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            var scrum = profile(" ScrumTrace ")
            try settings.saveProductContext(scrum, isNew: true)
            XCTAssertEqual(settings.contextLibrary.profiles.first?.name, "ScrumTrace")
            let persisted = defaults.data(forKey: ProductContextLibrary.defaultsKey)
            XCTAssertThrowsError(try settings.saveProductContext(profile("scrumtrace"), isNew: true))
            XCTAssertThrowsError(try settings.saveProductContext(profile("  "), isNew: true))
            XCTAssertThrowsError(try settings.saveProductContext(profile(String(repeating: "x", count: 81)), isNew: true))
            XCTAssertEqual(defaults.data(forKey: ProductContextLibrary.defaultsKey), persisted)
            scrum.name = "ScrumTrace planning"
            try settings.saveProductContext(scrum, isNew: false)
            XCTAssertEqual(settings.contextLibrary.profiles.count, 1)
            XCTAssertEqual(settings.contextLibrary.profiles.first?.name, "ScrumTrace planning")
        }
    }

    @MainActor
    func testDeletedSelectionDoesNotFallBackToAnotherProductOrRecreateFromEditor() throws {
        try withPreferences { defaults, _ in
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            let scrum = profile("ScrumTrace"), gib = profile("GIB")
            try settings.saveProductContext(scrum, isNew: true)
            try settings.saveProductContext(gib, isNew: true)
            try settings.selectProductContext(id: scrum.id)
            try settings.deleteProductContext(id: scrum.id)
            XCTAssertEqual(settings.productContext, .empty)
            XCTAssertThrowsError(try settings.selectProductContext(id: scrum.id))
            XCTAssertThrowsError(try settings.saveProductContext(scrum, isNew: false))
            XCTAssertEqual(settings.contextLibrary.profiles, [gib])
        }
    }

    @MainActor
    func testUnreadableLibraryIsPreservedWhileNoContextRecordingRemainsAvailable() throws {
        try withPreferences { defaults, _ in
            let unreadable = Data("incomplete preferences".utf8)
            defaults.set(unreadable, forKey: ProductContextLibrary.defaultsKey)
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            XCTAssertNotNil(settings.contextLibraryIssue)
            XCTAssertEqual(try settings.selectProductContext(id: nil), .empty)
            XCTAssertThrowsError(try settings.saveProductContext(profile("GIB"), isNew: true))
            XCTAssertEqual(defaults.data(forKey: ProductContextLibrary.defaultsKey), unreadable)
        }
    }

    func testNameOnlyContextSuppliesTheProductForAnalysis() {
        let saved = SavedProductContext(name: "GIB")
        XCTAssertEqual(saved.snapshot.appName, "GIB")
        XCTAssertEqual(saved.snapshot.contextName, "GIB")
        XCTAssertTrue(saved.product.appName.isEmpty)
    }

    func testOldProductContextStillDecodesWithoutLibraryMetadata() throws {
        let data = Data(#"{"app_name":"Old product","repo_url":"","tech_stack":"Swift"}"#.utf8)
        let old = try JSONDecoder().decode(ProductContext.self, from: data)
        XCTAssertEqual(old.appName, "Old product")
        XCTAssertNil(old.contextID)
        XCTAssertNil(old.contextName)
    }

    @MainActor
    func testConfirmedSnapshotRemainsInManifestAndExportAfterSwitchEditAndDelete() throws {
        try withPreferences { defaults, root in
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            var scrum = profile("ScrumTrace")
            let gib = profile("GIB")
            try settings.saveProductContext(scrum, isNew: true)
            try settings.saveProductContext(gib, isNew: true)
            let vault = SessionVault(rootURL: root.appendingPathComponent("sessions"))
            let controller = SessionController(settings: settings, vault: vault)
            let presenter = RecordingContextPresenter()
            defer { presenter.cancel() }
            var confirmed: ProductContext?
            presenter.present(controller: controller) { confirmed = $0 }
            let window = try XCTUnwrap(presenter.window)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.isVisible)
            try presenter.confirmSelection(id: scrum.id)
            XCTAssertNil(presenter.window)
            let snapshot = try XCTUnwrap(confirmed)
            // The user changes Settings while selecting the capture area.
            try settings.selectProductContext(id: gib.id)
            scrum.name = "Changed later"
            scrum.product.techStack = "Changed later"
            try settings.saveProductContext(scrum, isNew: false)
            try settings.deleteProductContext(id: scrum.id)
            let created = try vault.createSession(product: snapshot)
            var manifest = created.manifest
            manifest.pipelineStatus = .completed
            try vault.write(manifest: &manifest)
            let saved = try vault.loadManifest(id: manifest.sessionId)
            XCTAssertEqual(saved.productContext.appName, "ScrumTrace")
            XCTAssertEqual(saved.productContext.techStack, "Swift")
            XCTAssertEqual(saved.productContext.contextName, "ScrumTrace")
            XCTAssertEqual(saved.productContext.contextID, scrum.id)
            XCTAssertEqual(settings.productContext.appName, "GIB")
            let context = AgentContextRenderer().render(manifest: saved, sessionURL: created.url)
            let brief = SessionBriefRenderer().render(manifest: saved, excerpts: [:], sessionURL: created.url)
            XCTAssertTrue(context.contains("ScrumTrace"))
            XCTAssertFalse(context.contains("Changed later"))
            XCTAssertFalse(brief.contains("Changed later"))
            XCTAssertFalse(brief.contains("{{CONTEXT_BADGE}}"))
            XCTAssertTrue(brief.contains("ScrumTrace"))
        }
    }

    @MainActor
    func testCancelAndWindowCloseDoNotSelectAContextOrCreateASession() throws {
        try withPreferences { defaults, root in
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            let scrum = profile("ScrumTrace")
            try settings.saveProductContext(scrum, isNew: true)
            let controller = SessionController(settings: settings, vault: SessionVault(rootURL: root.appendingPathComponent("sessions")))
            let presenter = RecordingContextPresenter()
            var responses: [ProductContext?] = []
            presenter.present(controller: controller) { responses.append($0) }
            let window = try XCTUnwrap(presenter.window)
            presenter.present(controller: controller) { _ in XCTFail("A second request must not replace the active recording setup") }
            XCTAssertTrue(presenter.window === window)
            window.performClose(nil)
            presenter.cancel()
            XCTAssertEqual(responses.count, 1)
            XCTAssertNil(responses[0])
            XCTAssertNil(settings.contextLibrary.selectedID)
            XCTAssertTrue(controller.vault.recentSessions(limit: 10).isEmpty)
            XCTAssertFalse(controller.startInFlight)
        }
    }

    @MainActor
    func testNoContextConfirmationAndBusyGuard() throws {
        try withPreferences { defaults, root in
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            let scrum = profile("ScrumTrace")
            try settings.saveProductContext(scrum, isNew: true)
            try settings.selectProductContext(id: scrum.id)
            let controller = SessionController(settings: settings, vault: SessionVault(rootURL: root.appendingPathComponent("sessions")))
            let presenter = RecordingContextPresenter()
            defer { presenter.cancel() }
            var confirmed: ProductContext?
            presenter.present(controller: controller) { confirmed = $0 }
            controller.isBusy = true
            XCTAssertThrowsError(try presenter.confirmSelection(id: nil))
            XCTAssertNotNil(presenter.window)
            XCTAssertNil(confirmed)
            XCTAssertEqual(settings.productContext.contextID, scrum.id)
            controller.isBusy = false
            try presenter.confirmSelection(id: nil)
            XCTAssertEqual(confirmed, .empty)
            XCTAssertNil(settings.contextLibrary.selectedID)
        }
    }

    @MainActor
    func testRecordingWindowRemainsStableAcrossDisplayCycles() async throws {
        let suite = "ScrumTrace.ContextWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        AgentLog.setFileURLForTesting(root.appendingPathComponent("agent.jsonl"))
        let settings = AppSettings(defaults: defaults, keyStore: .empty)
        let controller = SessionController(settings: settings, vault: SessionVault(rootURL: root.appendingPathComponent("sessions")))
        let presenter = RecordingContextPresenter()
        defer {
            presenter.cancel()
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        presenter.present(controller: controller) { _ in }
        let window = try XCTUnwrap(presenter.window)
        let size = window.frame.size
        // A single synchronous layout missed the AppKit/SwiftUI crash: allow
        // real display cycles to run while the live library changes.
        for index in 0..<4 {
            try settings.saveProductContext(profile("Context \(index)"), isNew: true)
            try await Task.sleep(nanoseconds: 75_000_000)
            window.layoutIfNeeded()
            XCTAssertEqual(window.frame.size, size)
            XCTAssertTrue(window.isVisible)
        }
    }

    func testContextNameIsEscapedInBrief() {
        var manifest = SessionManifest.makeNew(sessionId: "context-escaping", product: .empty)
        manifest.productContext.contextName = #"<script>alert("context")</script>"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("context-escaping-\(UUID().uuidString)")
        let brief = SessionBriefRenderer().render(manifest: manifest, excerpts: [:], sessionURL: url)
        XCTAssertTrue(brief.contains("&lt;script&gt;"))
        XCTAssertFalse(brief.contains(#"<script>alert("context")</script>"#))
    }

    // MARK: - Contexts section of the main window

    /// A controller over an empty temporary vault, with its own preferences and agent log.
    @MainActor
    private func withContextsController(
        preferences: (UserDefaults) -> Void = { _ in },
        _ body: (SessionController, URL) async throws -> Void
    ) async throws {
        let suite = "ScrumTrace.ContextsSectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let log = root.appendingPathComponent("agent.jsonl")
        AgentLog.setFileURLForTesting(log)
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        preferences(defaults)
        let controller = SessionController(
            settings: AppSettings(defaults: defaults, keyStore: .empty),
            vault: SessionVault(rootURL: root.appendingPathComponent("sessions", isDirectory: true))
        )
        try await body(controller, log)
    }

    /// A recording made with `product`. Dates are whole seconds, as manifests store them.
    @discardableResult
    private func makeSession(
        in vault: SessionVault,
        product: ProductContext,
        createdAt: Date,
        status: PipelineStatus = .completed
    ) throws -> String {
        var manifest = try vault.createSession(product: product).manifest
        manifest.createdAt = createdAt
        manifest.pipelineStatus = status
        try vault.write(manifest: &manifest)
        // A movie keeps controller start-up from pruning the folder as an abandoned start.
        let movie = vault.sessionURL(id: manifest.sessionId).appendingPathComponent(ScrumTracePath.sessionMovie)
        try FileManager.default.createDirectory(at: movie.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 64).write(to: movie)
        return manifest.sessionId
    }

    /// A Contexts model whose capture state, Start-flow state and Start flow come from `state`. The Start flow
    /// records the context the recording-context window would preselect, then opens that window unless
    /// `state.opensContextWindow` is false.
    @MainActor
    private func makeContextsModel(controller: SessionController, state: ContextsTestState) -> ContextsModel {
        let settings = controller.settings
        let recordings = RecordingsModel(
            library: SessionLibrary(vault: controller.vault),
            navigation: MainNavigation(),
            dependencies: .live(controller: controller, startRecording: {})
        )
        return ContextsModel(
            settings: settings,
            recordings: recordings,
            dependencies: ContextsDependencies(
                canChangeContexts: { state.canChange },
                isPreparingRecording: { state.preparing },
                startRecording: {
                    state.starts.append(settings.contextLibrary.selectedID)
                    if state.opensContextWindow { state.preparing = true }
                }
            )
        )
    }

    /// Log rows so far. The synchronous snapshot waits for queued async events.
    private func logRows(at url: URL) throws -> [[String: String]] {
        _ = AgentLog.snapshotFieldsForTesting()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }
    }

    /// `main_*` rows so far. Beyond the fields every row carries, `main_context_save` may hold its kind and
    /// `main_start` its section; every other row nothing. No row holds a context id, name or product field.
    private func contextEventRows(
        at log: URL,
        profiles: [SavedProductContext],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [[String: String]] {
        AgentLog.event("contexts_test_baseline", [:])
        let rows = try logRows(at: log)
        let baseline = try XCTUnwrap(rows.last { $0["event"] == "contexts_test_baseline" }, file: file, line: line)
        let common = Set(baseline.keys)
        let allowed: [String: Set<String>] = ["main_context_save": ["kind"], "main_start": ["section"]]
        let main = rows.filter { ($0["event"] ?? "").hasPrefix("main_") }
        for row in main {
            let event = row["event"] ?? ""
            let extra = Set(row.keys).subtracting(common)
            XCTAssertTrue(extra.isSubset(of: allowed[event] ?? []), "\(event) carries \(extra)", file: file, line: line)
            for value in row.values {
                for profile in profiles {
                    XCTAssertFalse(value.contains(profile.id), "\(event) names a context id", file: file, line: line)
                    XCTAssertFalse(value.contains(profile.product.repoURL), "\(event) names a repository", file: file, line: line)
                }
            }
        }
        return main
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// The Contexts table: the only table in the window with six columns.
    @MainActor
    private func contextsTable(in window: NSWindow) -> NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.tableColumns.count == 6 { return table }
            for subview in view.subviews {
                if let table = find(subview) { return table }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// The name label the Name cell of `row` shows. SwiftUI builds no accessibility tree in-process and a table
    /// cell's hosting view reports no fitting width, so the test reads the view value the table hosts for the row.
    @MainActor
    private func nameLabel(in table: NSTableView, row: Int) -> ContextNameLabel? {
        guard row < table.numberOfRows, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
        var stack: [NSView] = [cell]
        while let view = stack.popLast() {
            if let host = view as? HostedRootView {
                var value: Any = host.hostedRootView
                while true {
                    if let label = value as? ContextNameLabel { return label }
                    guard let modified = value as? ModifiedViewContent else { break }
                    value = modified.modifiedContent
                }
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The view classes of a Name cell, for a failure message.
    @MainActor
    private func nameCellDescription(in table: NSTableView, row: Int) -> String {
        guard row < table.numberOfRows, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return "no cell" }
        return "\(type(of: cell)) subviews \(cell.subviews.map { String(describing: type(of: $0)) })"
    }

    /// Writes a PNG only when SCRUMTRACE_SNAPSHOT_DIR is set, for manual layout review.
    @MainActor
    private func writeSnapshot(of window: NSWindow, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SCRUMTRACE_SNAPSHOT_DIR"],
              let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("main-\(name).png"))
    }

    @MainActor
    func testContextUsageCountsAndLastUsedDatesComeFromRecordingManifests() throws {
        try withPreferences { defaults, root in
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            let scrum = profile("ScrumTrace"), gib = profile("GIB"), unused = profile("Unused")
            for saved in [scrum, gib, unused] {
                try settings.saveProductContext(saved, isNew: true)
            }
            let vault = SessionVault(rootURL: root.appendingPathComponent("sessions", isDirectory: true))
            let base = Date(timeIntervalSince1970: 1_780_000_000)
            let olderScrum = try makeSession(in: vault, product: scrum.snapshot, createdAt: base)
            let newerScrum = try makeSession(
                in: vault, product: scrum.snapshot, createdAt: base.addingTimeInterval(86_400), status: .transcribing
            )
            let gibSession = try makeSession(
                in: vault, product: gib.snapshot, createdAt: base.addingTimeInterval(3_600), status: .offlineFailed
            )
            // Newer than every counted recording, yet none counts for anybody: No context, a product that carries
            // ScrumTrace's name but no context id, a blank context id, and a context that is not saved (deleted).
            try makeSession(in: vault, product: .empty, createdAt: base.addingTimeInterval(90_000))
            try makeSession(
                in: vault,
                product: ProductContext(appName: "ScrumTrace", repoURL: "", techStack: "Swift", contextID: nil, contextName: "ScrumTrace"),
                createdAt: base.addingTimeInterval(90_060)
            )
            try makeSession(
                in: vault,
                product: ProductContext(appName: "Blank", repoURL: "", techStack: "", contextID: "  ", contextName: "Blank"),
                createdAt: base.addingTimeInterval(90_120)
            )
            try makeSession(in: vault, product: SavedProductContext(name: "Deleted").snapshot, createdAt: base.addingTimeInterval(90_180))
            // An unreadable manifest that mentions ScrumTrace's id is ignored, never guessed at.
            let corrupt = vault.sessionURL(id: "2020-01-01-0000-bad001")
            try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
            try Data(#"{"product_context":{"context_id":"\#(scrum.id)""#.utf8)
                .write(to: corrupt.appendingPathComponent(ScrumTracePath.manifest))

            let entries = vault.sessionEntries()
            XCTAssertEqual(entries.count, 8)
            XCTAssertEqual(entries.filter { $0.summary == nil }.map(\.id), ["2020-01-01-0000-bad001"])
            let profiles = settings.contextLibrary.profiles
            let usage = ContextUsage.compute(profiles: profiles, entries: entries)
            XCTAssertEqual(Set(usage.keys), [scrum.id, gib.id, unused.id], "One value per saved context and no other")
            XCTAssertEqual(usage[scrum.id], ContextUsage(recordingCount: 2, lastUsed: base.addingTimeInterval(86_400)))
            XCTAssertEqual(usage[gib.id], ContextUsage(recordingCount: 1, lastUsed: base.addingTimeInterval(3_600)))
            XCTAssertEqual(usage[unused.id], ContextUsage(recordingCount: 0, lastUsed: nil))
            XCTAssertEqual(
                ContextUsage.compute(profiles: profiles, entries: entries.reversed()),
                usage,
                "Last used is the newest date in any order"
            )
            XCTAssertEqual(ContextUsage.sessions(contextID: scrum.id, entries: entries).map(\.sessionId), [newerScrum, olderScrum])
            XCTAssertEqual(ContextUsage.sessions(contextID: gib.id, entries: entries).map(\.sessionId), [gibSession])
            XCTAssertEqual(ContextUsage.sessions(contextID: unused.id, entries: entries), [])

            XCTAssertEqual(ContextRowText.count(usage[scrum.id], isCounting: false), "2")
            XCTAssertEqual(
                ContextRowText.lastUsed(usage[scrum.id], isCounting: false),
                base.addingTimeInterval(86_400).formatted(date: .abbreviated, time: .omitted)
            )
            XCTAssertEqual(ContextRowText.usageLine(usage[gib.id] ?? ContextUsage()), "1 recording · last used \(SessionSummary.formattedDate(base.addingTimeInterval(3_600)))")
            XCTAssertEqual(ContextRowText.usageLine(ContextUsage()), "0 recordings")
            XCTAssertEqual(ContextRowText.lastUsed(usage[unused.id], isCounting: false), "Never")
            XCTAssertEqual(ContextRowText.count(usage[scrum.id], isCounting: true), "—", "No count before the first scan")
            XCTAssertEqual(ContextRowText.lastUsed(usage[scrum.id], isCounting: true), "—")
            XCTAssertEqual(ContextRowText.field("  "), "—")
            XCTAssertEqual(ContextRowText.field("Swift\nAppKit"), "Swift AppKit")
        }
    }

    @MainActor
    func testTheDefaultBadgeWidensTheContextName() {
        func width(isDefault: Bool, font: Font? = nil) -> CGFloat {
            NSHostingView(rootView: ContextNameLabel(name: "GIB", isDefault: isDefault, font: font)).fittingSize.width
        }
        XCTAssertGreaterThan(width(isDefault: true) - width(isDefault: false), 20, "The Name column draws the badge")
        XCTAssertGreaterThan(
            width(isDefault: true, font: .headline) - width(isDefault: false, font: .headline),
            20,
            "The detail header draws the badge"
        )
    }

    @MainActor
    func testDeletingAContextLeavesItsRecordingsByteForByteUntouched() async throws {
        try await withContextsController { controller, log in
            let settings = controller.settings
            let scrum = profile("ScrumTrace"), gib = profile("GIB")
            try settings.saveProductContext(scrum, isNew: true)
            try settings.saveProductContext(gib, isNew: true)
            try settings.selectProductContext(id: scrum.id)
            let vault = controller.vault
            let recorded = try makeSession(in: vault, product: scrum.snapshot, createdAt: Date(timeIntervalSince1970: 1_780_000_000))
            let session = vault.sessionURL(id: recorded)
            let agentContext = session.appendingPathComponent(ScrumTracePath.agentContext)
            try FileManager.default.createDirectory(at: agentContext.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# Agent context for ScrumTrace".utf8).write(to: agentContext)
            let manifestURL = session.appendingPathComponent(ScrumTracePath.manifest)
            let manifestBytes = try Data(contentsOf: manifestURL)
            let exportBytes = try Data(contentsOf: agentContext)
            let manifestModified = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date

            let state = ContextsTestState()
            let model = makeContextsModel(controller: controller, state: state)
            await model.recordings.refresh().value
            model.validateSelection()
            XCTAssertEqual(model.selectedContextID, scrum.id, "The default context is selected first")
            XCTAssertEqual(model.usage[scrum.id]?.recordingCount, 1)

            // Delete… asks first; Cancel changes nothing.
            XCTAssertTrue(model.perform(.delete, on: scrum.id))
            XCTAssertEqual(model.pendingDelete, scrum)
            model.cancelDelete()
            XCTAssertNil(model.pendingDelete)
            XCTAssertEqual(settings.contextLibrary.profiles, [scrum, gib])

            // Recording started while the dialog was open: the confirmation is refused with a line.
            XCTAssertTrue(model.perform(.delete, on: scrum.id))
            state.canChange = false
            XCTAssertFalse(model.confirmDelete(scrum))
            XCTAssertNil(model.pendingDelete)
            XCTAssertEqual(model.message, RecordingsModel.busyReason)
            XCTAssertEqual(settings.contextLibrary.profiles, [scrum, gib])
            XCTAssertFalse(model.perform(.delete, on: scrum.id), "Delete… waits for recording and analysis")
            XCTAssertNil(model.pendingDelete)
            state.canChange = true

            XCTAssertTrue(model.perform(.delete, on: scrum.id))
            XCTAssertNil(model.message, "A new action replaces the line")
            XCTAssertTrue(model.confirmDelete(scrum))
            XCTAssertEqual(settings.contextLibrary.profiles, [gib])
            XCTAssertNil(settings.contextLibrary.selectedID, "Deleting the default leaves No context, never another product")
            XCTAssertEqual(model.selectedContextID, gib.id, "The table moves to a saved context")

            // The recording keeps its own copy of the context, byte for byte, and was not rewritten.
            XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
            XCTAssertEqual(try Data(contentsOf: agentContext), exportBytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date, manifestModified)
            let reloaded = try vault.loadManifest(id: recorded)
            XCTAssertEqual(reloaded.productContext.contextID, scrum.id)
            XCTAssertEqual(reloaded.productContext.contextName, "ScrumTrace")
            XCTAssertEqual(reloaded.productContext.repoURL, scrum.product.repoURL)
            await model.recordings.refresh().value
            XCTAssertEqual(model.library.entries.map(\.id), [recorded], "The recording is still listed")
            XCTAssertEqual(model.library.entries.first?.summary?.contextID, scrum.id)
            XCTAssertEqual(Set(model.usage.keys), [gib.id], "A deleted context is no longer counted")
            XCTAssertEqual(model.sessions(for: gib.id), [])

            let rows = try contextEventRows(at: log, profiles: [scrum, gib])
            XCTAssertEqual(rows.map { $0["event"] }, ["main_context_delete"])
        }
    }

    @MainActor
    func testRecordWithContextSelectsItBeforeTheStartFlowRunsAndAMissingContextStartsNothing() async throws {
        try await withContextsController { controller, log in
            let settings = controller.settings
            let scrum = profile("ScrumTrace"), gib = profile("GIB")
            try settings.saveProductContext(scrum, isNew: true)
            try settings.saveProductContext(gib, isNew: true)
            try settings.selectProductContext(id: gib.id)
            let state = ContextsTestState()
            let model = makeContextsModel(controller: controller, state: state)

            try model.recordWithContext(id: scrum.id)
            XCTAssertEqual(state.starts, [scrum.id], "The Start flow runs once, after the context was selected")
            XCTAssertEqual(settings.contextLibrary.selectedID, scrum.id, "The context window opened with it preselected, so it stays the default")
            XCTAssertEqual(settings.productContext, scrum.snapshot)
            XCTAssertEqual(model.unavailableReason(.record, for: gib.id), OverviewModel.preparingReason)
            // The user confirms or cancels the context window.
            state.preparing = false

            // A missing id throws and starts nothing; the default stays.
            XCTAssertThrowsError(try model.recordWithContext(id: "missing-context"))
            XCTAssertEqual(model.unavailableReason(.record, for: "missing-context"), ContextsModel.noContextReason)
            XCTAssertFalse(model.perform(.record, on: "missing-context"))
            XCTAssertFalse(model.perform(.record, on: nil))
            // A context deleted after the table listed it.
            try settings.deleteProductContext(id: gib.id)
            XCTAssertThrowsError(try model.recordWithContext(id: gib.id))
            XCTAssertEqual(state.starts, [scrum.id])
            XCTAssertEqual(settings.contextLibrary.selectedID, scrum.id)

            // While recording or analysis runs, nothing is selected or started.
            try settings.saveProductContext(gib, isNew: true)
            state.canChange = false
            XCTAssertThrowsError(try model.recordWithContext(id: gib.id)) { error in
                XCTAssertEqual(error.localizedDescription, RecordingsModel.busyReason)
            }
            XCTAssertThrowsError(try model.setDefault(id: gib.id))
            XCTAssertFalse(model.perform(.record, on: gib.id))
            XCTAssertFalse(model.perform(.setDefault, on: gib.id))
            state.canChange = true
            // While a Start already shows its context window, Record waits for it.
            state.preparing = true
            XCTAssertThrowsError(try model.recordWithContext(id: gib.id)) { error in
                XCTAssertEqual(error.localizedDescription, OverviewModel.preparingReason)
            }
            XCTAssertEqual(model.unavailableReason(.record, for: gib.id), OverviewModel.preparingReason)
            XCTAssertFalse(model.perform(.record, on: gib.id))
            XCTAssertEqual(state.starts, [scrum.id])
            XCTAssertEqual(settings.contextLibrary.selectedID, scrum.id)

            // Set as default selects without recording.
            XCTAssertTrue(model.perform(.setDefault, on: gib.id))
            XCTAssertEqual(settings.contextLibrary.selectedID, gib.id)
            XCTAssertEqual(state.starts, [scrum.id])
            XCTAssertEqual(model.unavailableReason(.setDefault, for: gib.id), ContextsModel.alreadyDefaultReason)
            state.preparing = false
            XCTAssertTrue(model.perform(.record, on: gib.id))
            XCTAssertEqual(state.starts, [scrum.id, gib.id])
            state.preparing = false

            // A Start that stops before its context window (a cancelled meeting notice, recording not allowed yet,
            // no menu) records nothing, so the previous default comes back.
            state.opensContextWindow = false
            XCTAssertTrue(model.perform(.record, on: scrum.id))
            XCTAssertEqual(state.starts, [scrum.id, gib.id, scrum.id], "The flow still ran with the context selected")
            XCTAssertEqual(settings.contextLibrary.selectedID, gib.id)
            XCTAssertEqual(settings.productContext, gib.snapshot)
            try settings.selectProductContext(id: nil)
            try model.recordWithContext(id: gib.id)
            XCTAssertEqual(state.starts, [scrum.id, gib.id, scrum.id, gib.id])
            XCTAssertNil(settings.contextLibrary.selectedID, "No context stays No context")
            state.opensContextWindow = true

            // A line left by an action that could not run goes away once Set as default or Record succeeds.
            XCTAssertTrue(model.perform(.delete, on: scrum.id))
            state.canChange = false
            XCTAssertFalse(model.confirmDelete(scrum))
            XCTAssertEqual(model.message, RecordingsModel.busyReason)
            state.canChange = true
            XCTAssertTrue(model.perform(.setDefault, on: scrum.id))
            XCTAssertNil(model.message, "Set as default replaces the line")
            XCTAssertTrue(model.perform(.delete, on: gib.id))
            state.canChange = false
            XCTAssertFalse(model.confirmDelete(gib))
            XCTAssertEqual(model.message, RecordingsModel.busyReason)
            state.canChange = true
            XCTAssertTrue(model.perform(.record, on: gib.id))
            XCTAssertNil(model.message, "Record with this context… replaces the line")
            XCTAssertEqual(settings.contextLibrary.selectedID, gib.id)
            XCTAssertEqual(settings.contextLibrary.profiles, [scrum, gib], "Nothing was deleted")

            let rows = try contextEventRows(at: log, profiles: [scrum, gib])
            XCTAssertEqual(
                rows.map { $0["event"] },
                ["main_start", "main_context_default", "main_start", "main_start", "main_start", "main_context_default", "main_start"]
            )
            XCTAssertEqual(rows.filter { $0["event"] == "main_start" }.map { $0["section"] }, Array(repeating: "contexts", count: 5))
        }
    }

    @MainActor
    func testNewEditAndDuplicateSaveThroughTheSettingsRules() async throws {
        try await withContextsController { controller, log in
            let settings = controller.settings
            let state = ContextsTestState()
            let model = makeContextsModel(controller: controller, state: state)
            XCTAssertTrue(model.isEnabled(.new, for: nil))
            XCTAssertEqual(model.unavailableReason(.edit, for: nil), ContextsModel.noContextReason)

            XCTAssertTrue(model.perform(.new, on: nil))
            let newRequest = try XCTUnwrap(model.editor)
            XCTAssertTrue(newRequest.isNew)
            var orbit = newRequest.profile
            orbit.name = " Orbit "
            orbit.product.repoURL = "https://example.test/orbit"
            try model.save(orbit, isNew: true)
            XCTAssertEqual(settings.contextLibrary.profiles.map(\.name), ["Orbit"])
            XCTAssertEqual(model.selectedContextID, orbit.id)
            XCTAssertNil(settings.contextLibrary.selectedID, "Saving never makes a context the default")

            XCTAssertTrue(model.perform(.edit, on: orbit.id))
            let editRequest = try XCTUnwrap(model.editor)
            XCTAssertFalse(editRequest.isNew)
            var edited = editRequest.profile
            XCTAssertEqual(edited, settings.contextLibrary.profiles.first)
            edited.name = "Orbit web"
            try model.save(edited, isNew: false)
            XCTAssertEqual(settings.contextLibrary.profiles.map(\.name), ["Orbit web"])

            XCTAssertTrue(model.perform(.duplicate, on: orbit.id))
            let copyRequest = try XCTUnwrap(model.editor)
            XCTAssertTrue(copyRequest.isNew)
            XCTAssertNotEqual(copyRequest.profile.id, orbit.id)
            XCTAssertEqual(copyRequest.profile.name, "Orbit web copy")
            XCTAssertEqual(copyRequest.profile.product, edited.product)
            try model.save(copyRequest.profile, isNew: true)
            XCTAssertEqual(model.selectedContextID, copyRequest.profile.id)

            // Save keeps the settings rules, so the editor stays open with the message.
            XCTAssertThrowsError(try model.save(SavedProductContext(name: "orbit WEB"), isNew: true))
            state.canChange = false
            XCTAssertFalse(model.perform(.new, on: nil))
            XCTAssertThrowsError(try model.save(SavedProductContext(name: "Later"), isNew: true)) { error in
                XCTAssertEqual(error.localizedDescription, RecordingsModel.busyReason)
            }
            XCTAssertEqual(settings.contextLibrary.profiles.map(\.name), ["Orbit web", "Orbit web copy"])

            let rows = try contextEventRows(at: log, profiles: settings.contextLibrary.profiles)
            XCTAssertEqual(rows.map { $0["event"] }, ["main_context_save", "main_context_save", "main_context_save"])
            XCTAssertEqual(rows.map { $0["kind"] }, ["new", "edit", "new"])
        }
    }

    @MainActor
    func testDuplicateNamesTheCopyTheWaySaveComparesNames() throws {
        try withPreferences { defaults, _ in
            let settings = AppSettings(defaults: defaults, keyStore: .empty)
            let cafe = profile("Café")
            try settings.saveProductContext(cafe, isNew: true)
            let first = ProductContextNaming.duplicate(of: cafe, existing: settings.contextLibrary.profiles)
            XCTAssertNotEqual(first.id, cafe.id)
            XCTAssertEqual(first.name, "Café copy")
            XCTAssertEqual(first.product, cafe.product)
            // A name that differs only by case and accents is taken, as Save sees it.
            try settings.saveProductContext(SavedProductContext(name: "CAFE COPY"), isNew: true)
            let second = ProductContextNaming.duplicate(of: cafe, existing: settings.contextLibrary.profiles)
            XCTAssertEqual(second.name, "Café copy 2")
            try settings.saveProductContext(second, isNew: true)
            XCTAssertEqual(ProductContextNaming.duplicate(of: cafe, existing: settings.contextLibrary.profiles).name, "Café copy 3")
            // A long name keeps room for the suffix within the 80-character limit.
            let long = SavedProductContext(name: String(repeating: "x", count: 80))
            try settings.saveProductContext(long, isNew: true)
            let longCopy = ProductContextNaming.duplicate(of: long, existing: settings.contextLibrary.profiles)
            XCTAssertEqual(longCopy.name, String(repeating: "x", count: 65) + " copy")
            try settings.saveProductContext(longCopy, isNew: true)
        }
    }

    @MainActor
    func testAnUnreadableContextLibraryBlocksEveryContextAction() async throws {
        let unreadable = Data("incomplete preferences".utf8)
        try await withContextsController(preferences: { $0.set(unreadable, forKey: ProductContextLibrary.defaultsKey) }) { controller, _ in
            let issue = try XCTUnwrap(controller.settings.contextLibraryIssue)
            let state = ContextsTestState()
            let model = makeContextsModel(controller: controller, state: state)
            for action in ContextAction.allCases {
                XCTAssertEqual(model.unavailableReason(action, for: "any"), issue, action.rawValue)
                XCTAssertFalse(model.perform(action, on: "any"), action.rawValue)
            }
            XCTAssertThrowsError(try model.recordWithContext(id: "any")) { error in
                XCTAssertEqual(error.localizedDescription, issue)
            }
            XCTAssertThrowsError(try model.save(SavedProductContext(name: "GIB"), isNew: true))
            XCTAssertEqual(state.starts, [])
            XCTAssertNil(model.editor)
        }
    }

    @MainActor
    func testTheContextsSectionListsCountsAndStartsTheAppFlowFromTheWindow() async throws {
        try await withContextsController { controller, _ in
            let settings = controller.settings
            let scrum = profile("ScrumTrace"), gib = profile("GIB")
            try settings.saveProductContext(scrum, isNew: true)
            try settings.saveProductContext(gib, isNew: true)
            try settings.selectProductContext(id: gib.id)
            let base = Date(timeIntervalSince1970: 1_780_000_000)
            let first = try makeSession(in: controller.vault, product: scrum.snapshot, createdAt: base)
            let second = try makeSession(
                in: controller.vault, product: scrum.snapshot, createdAt: base.addingTimeInterval(3_600), status: .transcribing
            )
            let state = ContextsTestState()
            let presenter = MainWindowPresenter(
                controller: controller,
                frameAutosaveName: nil,
                // Other apps covering the test window must not stop the loops this test waits for.
                isWindowOnScreen: { $0.isVisible && !$0.isMiniaturized },
                onStartRecording: {
                    state.starts.append(settings.contextLibrary.selectedID)
                    // The app's flow opens the recording-context window.
                    state.preparing = true
                },
                isPreparingRecording: { state.preparing }
            )
            defer { presenter.window?.close() }
            let contexts = presenter.contexts

            presenter.show(section: .contexts)
            let window = try XCTUnwrap(presenter.window)
            let listed = await waitUntil {
                self.contextsTable(in: window)?.numberOfRows == 2
                    && presenter.recordings.library.entries.count == 2
                    && contexts.isStartStateLoopActive
            }
            XCTAssertTrue(listed, "Opening on Contexts lists the saved contexts and reads the recordings")
            XCTAssertEqual(contexts.selectedContextID, gib.id, "The default context is selected first")
            XCTAssertTrue(presenter.recordings.isPeriodicRefreshActive)
            XCTAssertEqual(contexts.usage[scrum.id], ContextUsage(recordingCount: 2, lastUsed: base.addingTimeInterval(3_600)))
            XCTAssertEqual(contexts.usage[gib.id], ContextUsage())
            XCTAssertEqual(contexts.sessions(for: scrum.id).map(\.sessionId), [second, first])
            writeSnapshot(of: window, named: "contexts-default")

            // The Default badge sits on GIB's row and moves with Set as default. Rows follow the saved order.
            let table = try XCTUnwrap(contextsTable(in: window))
            let marked = await waitUntil {
                self.nameLabel(in: table, row: 0).map { $0.name == scrum.name && !$0.isDefault } == true
                    && self.nameLabel(in: table, row: 1).map { $0.name == gib.name && $0.isDefault } == true
            }
            XCTAssertTrue(marked, "Only the default context's row shows the badge; \(nameCellDescription(in: table, row: 1))")
            XCTAssertTrue(contexts.perform(.setDefault, on: scrum.id))
            let moved = await waitUntil {
                self.nameLabel(in: table, row: 0)?.isDefault == true && self.nameLabel(in: table, row: 1)?.isDefault == false
            }
            XCTAssertTrue(moved, "The badge moves to the new default")
            XCTAssertEqual(contexts.selectedContextID, gib.id, "Set as default keeps the selection")

            // Two clicks from the window: select the row, then Record with this context….
            contexts.selectedContextID = scrum.id
            _ = await waitUntil(timeout: 0.3) { false }
            writeSnapshot(of: window, named: "contexts-selected")
            window.setContentSize(MainWindowPresenter.minimumContentSize)
            _ = await waitUntil(timeout: 0.3) { false }
            writeSnapshot(of: window, named: "contexts-minimum")
            XCTAssertEqual(contextsTable(in: window)?.numberOfRows, 2, "The table keeps its rows at the minimum size")
            XCTAssertTrue(contexts.perform(.record, on: contexts.selectedContextID))
            XCTAssertEqual(state.starts, [scrum.id])
            XCTAssertEqual(contexts.unavailableReason(.record, for: scrum.id), OverviewModel.preparingReason)
            state.preparing = false
            let followed = await waitUntil(timeout: 2) { contexts.isEnabled(.record, for: scrum.id) }
            XCTAssertTrue(followed, "Record follows the context window while the section is shown")

            // While the section is shown, capture state disables its actions and the footer says why.
            controller.isBusy = true
            let waited = await waitUntil { !contexts.canChangeContexts }
            XCTAssertTrue(waited)
            XCTAssertEqual(contexts.unavailableReason(.new, for: nil), RecordingsModel.busyReason)
            writeSnapshot(of: window, named: "contexts-busy")
            controller.isBusy = false
            let idle = await waitUntil { contexts.canChangeContexts }
            XCTAssertTrue(idle)

            // A recording in the detail opens in Recordings.
            contexts.showInRecordings(first)
            XCTAssertEqual(presenter.navigation.section, .recordings)
            XCTAssertEqual(presenter.navigation.selectedSessionId, first)
            let left = await waitUntil { !contexts.isStartStateLoopActive }
            XCTAssertTrue(left, "Another section does no Contexts work")

            // With the section hidden no loop re-reads capture state, so only the presenter's controller observer
            // carries it: analysis and a start in flight each reach the model.
            defer { controller.setStartInFlightForTesting(false) }
            controller.isBusy = true
            let busyObserved = await waitUntil { !contexts.canChangeContexts }
            XCTAssertTrue(busyObserved, "isBusy reaches the Contexts model through its controller observer")
            XCTAssertFalse(contexts.isStartStateLoopActive)
            controller.isBusy = false
            let idleObserved = await waitUntil { contexts.canChangeContexts }
            XCTAssertTrue(idleObserved)
            controller.setStartInFlightForTesting(true)
            let inFlightObserved = await waitUntil { !contexts.canChangeContexts }
            XCTAssertTrue(inFlightObserved, "startInFlight reaches the Contexts model through its controller observer")
            XCTAssertEqual(contexts.unavailableReason(.record, for: scrum.id), RecordingsModel.busyReason)
            XCTAssertFalse(contexts.isStartStateLoopActive)
            controller.setStartInFlightForTesting(false)
            let clearedObserved = await waitUntil { contexts.canChangeContexts }
            XCTAssertTrue(clearedObserved)

            presenter.show(section: .contexts)
            let back = await waitUntil { contexts.isStartStateLoopActive }
            XCTAssertTrue(back)
            window.close()
            XCTAssertFalse(contexts.isStartStateLoopActive, "A closed window does no Contexts work")
        }
    }
}

/// What the injected Contexts closures read while a test changes it, and the context each Start saw selected.
@MainActor
private final class ContextsTestState {
    var canChange = true
    var preparing = false
    /// Whether the fake Start flow opens the recording-context window. The app's flow does unless it stops early:
    /// a cancelled meeting notice, recording not allowed yet, or no menu.
    var opensContextWindow = true
    var starts: [String?] = []
}

/// Reads the root view of an AppKit hosting view, so a window test can see what a SwiftUI Table cell shows.
@MainActor
private protocol HostedRootView {
    var hostedRootView: Any { get }
}

extension NSHostingView: HostedRootView {
    var hostedRootView: Any { rootView }
}

/// Unwraps one modifier from a SwiftUI view value.
private protocol ModifiedViewContent {
    var modifiedContent: Any { get }
}

extension ModifiedContent: ModifiedViewContent {
    var modifiedContent: Any { content }
}
