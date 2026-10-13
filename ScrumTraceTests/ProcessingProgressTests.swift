import AppKit
import SwiftUI
import XCTest
@testable import ScrumTrace

final class ProcessingProgressTests: XCTestCase {
    func testUnknownProgressStaysIndeterminateAndElapsedTimeKeepsAdvancing() {
        let start = Date(timeIntervalSince1970: 100)
        let progress = ProcessingProgress(message: "Preparing speech model…", startedAt: start)
        let later = progress.refreshed(at: start.addingTimeInterval(125))
        XCTAssertNil(later.percent)
        XCTAssertEqual(later.statusLine, "Preparing speech model… · 2m 5s")
        XCTAssertEqual(later.id, progress.id)
        XCTAssertNil(ProcessingProgress(message: "Loading", fraction: .nan).percent)
        XCTAssertNil(ProcessingProgress(message: "Loading", fraction: .infinity).percent)
        XCTAssertEqual(ProcessingProgress(message: "Downloading", fraction: 0.429).percent, 42)
    }

    func testDelayedCallbacksCannotChangeTheNextOperationOrRegressProgress() throws {
        let reporter = ProcessingProgressReporter()
        let download = reporter.begin("Downloading model")
        reporter.update(download, fraction: 0.7)
        reporter.update(download, fraction: 0.2)
        XCTAssertEqual(reporter.snapshot?.percent, 70)
        let loading = reporter.begin("Preparing model")
        reporter.update(download, fraction: 1)
        reporter.end(download)
        XCTAssertEqual(reporter.snapshot?.id, loading)
        XCTAssertNil(reporter.snapshot?.fraction)
        reporter.end(loading)
        XCTAssertNil(reporter.snapshot)
    }

    @MainActor
    func testWorkerProgressAppearsInControllerAndMinifiedHUDWithoutRecordingClock() throws {
        let name = "progress-ui-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: SessionVault(rootURL: root))
        controller.isBusy = true
        controller.phase = .transcribing
        controller.reportProcessingProgress("Transcribing")
        let download = controller.transcriber.progressReporter.begin("Downloading speech model")
        controller.transcriber.progressReporter.update(download, fraction: 0.42)
        controller.sampleProcessingProgress()
        XCTAssertTrue(controller.displayStatusLine.contains("42% · Downloading speech model"))
        let hud = RecordingHUDWindow(controller: controller, defaults: defaults)
        hud.isReleasedWhenClosed = false
        defer { hud.orderOut(nil) }
        hud.setMinified(true)
        hud.refresh()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let labels = views(try XCTUnwrap(hud.contentView)).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { !$0.isHidden && $0.stringValue == "42%" })
        controller.transcriber.progressReporter.end(download)
        controller.statusLine = "Identifying speakers…"
        controller.sampleProcessingProgress()
        XCTAssertNil(controller.processingProgress?.percent, "The next operation must not inherit 42%")
        controller.sampleProcessingProgress(at: Date().addingTimeInterval(10))
        XCTAssertTrue(controller.displayStatusLine.contains("10s"))
        controller.isBusy = false
        controller.statusLine = "Transcription incomplete"
        XCTAssertEqual(controller.displayStatusLine, "Transcription incomplete")

        if let directory = ProcessInfo.processInfo.environment["SCRUMTRACE_PROGRESS_SNAPSHOT_DIR"] {
            controller.isBusy = true
            controller.reportProcessingProgress("Generating clip 3 of 8", fraction: 0.25)
            hud.setMinified(false)
            hud.refresh()
            let host = NSHostingView(rootView: MainProcessingBanner(controller: controller))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 90)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, view) in [("processing-banner", host as NSView), ("processing-hud", try XCTUnwrap(hud.contentView))] {
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
    }

    @MainActor
    func testSpeechPreparationIsVisibleBeforeThePipelineStartsAndClearsOnFailure() async throws {
        let transcriber = WhisperTranscriber(loadModel: { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            throw SettingsValidationError("Fixture load failure")
        })
        let loading = Task { try await transcriber.prepare(model: "tiny") }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(transcriber.isPreparing)
        XCTAssertEqual(transcriber.progressReporter.snapshot?.message, "Preparing speech model…")
        XCTAssertNil(transcriber.progressReporter.snapshot?.fraction)
        do { try await loading.value; XCTFail("The fixture must fail") } catch {}
        XCTAssertNil(transcriber.progressReporter.snapshot)
    }
}
