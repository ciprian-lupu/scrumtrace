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
}
