import XCTest
@testable import ScrumTrace

/// A quit, crash or reinstall while a recording is being processed must not strand it at "transcribing".
final class InterruptedSessionTests: XCTestCase {
    private struct Bench {
        let vault: SessionVault
        let defaults: UserDefaults
        let log: URL
    }

    @MainActor
    private func withBench(_ body: (Bench) async throws -> Void) async throws {
        let id = "ScrumTrace.InterruptedSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let log = root.appendingPathComponent("agent.jsonl")
        AgentLog.setFileURLForTesting(log)
        defer {
            AgentLog.setFileURLForTesting(nil)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let vault = SessionVault(rootURL: root.appendingPathComponent("sessions"))
        try await body(Bench(vault: vault, defaults: defaults, log: log))
    }

    @MainActor
    private func makeController(_ bench: Bench) -> SessionController {
        SessionController(settings: AppSettings(defaults: bench.defaults, keyStore: .empty), vault: bench.vault)
    }

    private func makeSession(in vault: SessionVault, status: PipelineStatus, age: TimeInterval = 0) throws -> String {
        var manifest = try vault.createSession(product: .empty).manifest
        manifest.pipelineStatus = status
        manifest.createdAt = Date().addingTimeInterval(-age)
        try vault.write(manifest: &manifest)
        // A movie keeps controller start-up from pruning the session as an abandoned start.
        let movie = vault.sessionURL(id: manifest.sessionId).appendingPathComponent(ScrumTracePath.sessionMovie)
        try FileManager.default.createDirectory(at: movie.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 64).write(to: movie)
        return manifest.sessionId
    }

    private func logRows(at url: URL) throws -> [[String: String]] {
        _ = AgentLog.snapshotFieldsForTesting()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
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

    func testOnlyProcessingStatesResumeOnTheirOwn() {
        let resumable = SessionController.autoResumableStatuses
        XCTAssertEqual(resumable, [.transcribing, .slicing, .evaluating, .synthesizing])
        for manual in [PipelineStatus.recording, .paused, .offlineFailed, .idle, .completed] {
            XCTAssertFalse(resumable.contains(manual), "\(manual) stays a manual Retry Analysis")
        }
    }

    @MainActor
    func testAKilledTranscriptionIsPickedUpAtTheNextLaunch() async throws {
        try await withBench { bench in
            let stuck = try makeSession(in: bench.vault, status: .transcribing)
            let controller = makeController(bench)
            XCTAssertEqual(controller.interruptedSessionId, stuck, "Start-up notices the session the last process left mid-pipeline")
            XCTAssertEqual(controller.lastSessionId, stuck)
            XCTAssertTrue(try logRows(at: bench.log).contains { $0["event"] == "interrupted_session" && $0["status"] == "transcribing" })

            // The folder goes away before the resume so the retry ends on the existing "session missing" path instead
            // of running Whisper in a unit test. What matters is that the launch started the retry by itself.
            try FileManager.default.removeItem(at: bench.vault.sessionURL(id: stuck))
            XCTAssertTrue(controller.resumeInterruptedSession(), "The launch resumes the recording without a click")
            XCTAssertNil(controller.interruptedSessionId, "Resumed once")
            let ended = await waitUntil { !controller.isBusy }
            XCTAssertTrue(ended)
            let rows = try logRows(at: bench.log)
            XCTAssertTrue(rows.contains { $0["event"] == "resume_interrupted" && $0["session"] == stuck })
            XCTAssertTrue(rows.contains { $0["event"] == "retry_begin" && $0["session"] == stuck }, "Resume is a Retry Analysis")
            XCTAssertFalse(controller.resumeInterruptedSession(), "A second call at the same launch does nothing")
        }
    }

    @MainActor
    func testEveryProcessingStageResumes() async throws {
        for status in [PipelineStatus.slicing, .evaluating, .synthesizing] {
            try await withBench { bench in
                let stuck = try makeSession(in: bench.vault, status: status)
                let controller = makeController(bench)
                XCTAssertEqual(controller.interruptedSessionId, stuck, "\(status) resumes")
            }
        }
    }

    @MainActor
    func testACrashWhileRecordingOrAFailedRunStaysAManualRetry() async throws {
        for status in [PipelineStatus.recording, .paused, .offlineFailed] {
            try await withBench { bench in
                let unfinished = try makeSession(in: bench.vault, status: status)
                let controller = makeController(bench)
                XCTAssertNil(controller.interruptedSessionId, "\(status) is not resumed on its own")
                XCTAssertFalse(controller.resumeInterruptedSession())
                XCTAssertEqual(controller.lastSessionId, unfinished)
                XCTAssertEqual(controller.statusLine, "Last session is unfinished — Retry Analysis to finish", "The menu still points at Retry Analysis")
                XCTAssertFalse(try logRows(at: bench.log).contains { $0["event"] == "resume_interrupted" })
            }
        }
    }

    @MainActor
    func testACompletedLastSessionNeedsNothing() async throws {
        try await withBench { bench in
            _ = try makeSession(in: bench.vault, status: .transcribing, age: 600)
            let done = try makeSession(in: bench.vault, status: .completed)
            let controller = makeController(bench)
            XCTAssertEqual(controller.lastSessionId, done, "Only the newest recording decides")
            XCTAssertNil(controller.interruptedSessionId)
            XCTAssertFalse(controller.resumeInterruptedSession())
        }
    }

    @MainActor
    func testResumeWaitsWhenAStartIsAlreadyInFlight() async throws {
        try await withBench { bench in
            let stuck = try makeSession(in: bench.vault, status: .transcribing)
            let controller = makeController(bench)
            controller.setStartInFlightForTesting(true)
            XCTAssertFalse(controller.resumeInterruptedSession(), "Never fight a recording that is starting")
            XCTAssertEqual(controller.interruptedSessionId, stuck, "The session is still remembered for Retry Analysis")
            XCTAssertTrue(try logRows(at: bench.log).contains { $0["event"] == "resume_interrupted_skipped" && $0["session"] == stuck })
            controller.setStartInFlightForTesting(false)
        }
    }
}
