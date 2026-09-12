import Foundation
import XCTest
@testable import ScrumTrace

final class AgentLogTests: XCTestCase {
    private func rows(at url: URL) throws -> [[String: String]] {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        return try text.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return object as? [String: String] ?? [:]
        }
    }

    func testRunIdentityAndSessionContextAreAutomatic() {
        let sessionID = "agent-log-\(UUID().uuidString.lowercased())"
        let before = AgentLog.snapshotFieldsForTesting()
        XCTAssertNotNil(before?["run_id"])
        XCTAssertNil(before?["session"])

        XCTAssertTrue(AgentLog.setSessionContext(sessionID))
        defer {
            XCTAssertTrue(AgentLog.clearSessionContext(matching: sessionID))
        }

        let scoped = AgentLog.snapshotFieldsForTesting()
        XCTAssertEqual(scoped?["run_id"], before?["run_id"])
        XCTAssertEqual(scoped?["session"], sessionID)

        let explicit = AgentLog.snapshotFieldsForTesting(["session": sessionID])
        XCTAssertEqual(explicit?["session"], sessionID)
    }

    func testExplicitMismatchCannotOverwriteContext() {
        let sessionID = "agent-log-\(UUID().uuidString.lowercased())"
        XCTAssertTrue(AgentLog.setSessionContext(sessionID))
        defer {
            XCTAssertTrue(AgentLog.clearSessionContext(matching: sessionID))
        }

        XCTAssertNil(
            AgentLog.snapshotFieldsForTesting(["session": "different-session"])
        )
        XCTAssertEqual(
            AgentLog.snapshotFieldsForTesting()?["session"],
            sessionID
        )
    }

    func testContextSnapshotsAreSerialized() {
        let sessionID = "agent-log-\(UUID().uuidString.lowercased())"
        XCTAssertTrue(AgentLog.setSessionContext(sessionID))
        defer {
            XCTAssertTrue(AgentLog.clearSessionContext(matching: sessionID))
        }

        let lock = NSLock()
        var observed: [String?] = []
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            let value = AgentLog.snapshotFieldsForTesting()?["session"]
            lock.lock()
            observed.append(value)
            lock.unlock()
        }
        XCTAssertEqual(observed.count, 100)
        XCTAssertTrue(observed.allSatisfy { $0 == sessionID })
    }

    func testForbiddenContentKeysAreDroppedButTechnicalBooleanRemains() {
        let fields = AgentLog.snapshotFieldsForTesting([
            "title": "private window",
            "windowTitle": "private window",
            "url": "https://example.test/private",
            "note": "private note",
            "transcript": "private transcript",
            "transcript_excerpt": "private transcript",
            "api_key": "private key",
            "apiKey": "private key",
            "access_token": "private token",
            "token": "private token",
            "passphrase": "private phrase",
            "secret": "private secret",
            "has_url": "1"
        ])

        XCTAssertEqual(fields?["has_url"], "1")
        for key in [
            "title", "windowTitle", "url", "note", "transcript", "transcript_excerpt",
            "api_key", "apiKey", "access_token", "token",
            "passphrase", "secret"
        ] {
            XCTAssertNil(fields?[key])
        }
    }

    func testQueuedEventsKeepContextThroughTerminationAndClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-log-\(UUID().uuidString)",
            isDirectory: true
        )
        let log = root.appendingPathComponent("agent.jsonl")
        defer {
            AgentLog.setFileURLForTesting(nil)
            try? FileManager.default.removeItem(at: root)
        }
        AgentLog.setFileURLForTesting(log)

        let sessionID = "session-\(UUID().uuidString.lowercased())"
        XCTAssertTrue(AgentLog.setSessionContext(sessionID))
        AgentLog.event("queued_before_clear")
        AgentLog.eventSync("terminate")
        XCTAssertTrue(AgentLog.clearSessionContext(matching: sessionID))
        AgentLog.eventSync("after_clear")

        let written = try rows(at: log)
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(written[0]["session"], sessionID)
        XCTAssertEqual(written[1]["event"], "terminate")
        XCTAssertEqual(written[1]["session"], sessionID)
        XCTAssertNil(written[2]["session"])
        XCTAssertEqual(Set(written.compactMap { $0["run_id"] }).count, 1)
    }

    func testClearRemovesSessionButPreservesRunIdentity() {
        let sessionID = "agent-log-\(UUID().uuidString.lowercased())"
        let runID = AgentLog.snapshotFieldsForTesting()?["run_id"]
        XCTAssertTrue(AgentLog.setSessionContext(sessionID))
        XCTAssertTrue(AgentLog.clearSessionContext(matching: sessionID))

        let fields = AgentLog.snapshotFieldsForTesting()
        XCTAssertNil(fields?["session"])
        XCTAssertEqual(fields?["run_id"], runID)
    }
}
