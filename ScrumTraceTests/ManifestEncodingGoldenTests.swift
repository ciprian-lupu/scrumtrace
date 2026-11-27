import XCTest
@testable import ScrumTrace

/// The saved manifest bytes must not change when the lifecycle moves into its own type: old sessions on disk and
/// Mac-to-Mac transfers between app versions read and write the same JSON.
/// To re-record after a deliberate format change: TEST_RUNNER_SCRUMTRACE_RECORD_MANIFEST_GOLDEN=1.
final class ManifestEncodingGoldenTests: XCTestCase {
    private var goldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/manifest-encoding-golden.json")
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func manifest(_ id: String, status: PipelineStatus, done: [PipelineStatus]) -> SessionManifest {
        var manifest = SessionManifest.makeNew(
            sessionId: id,
            product: ProductContext(appName: "Golden", repoURL: "", techStack: "Swift")
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        manifest.fixtureStatus = status
        manifest.fixtureStages = done
        return manifest
    }

    private func cases() -> [SessionManifest] {
        let statuses: [PipelineStatus] = [
            .idle, .recording, .paused, .transcribing, .slicing, .evaluating, .synthesizing, .completed, .offlineFailed
        ]
        var all = statuses.map { manifest("2026-11-27-1000-\($0.rawValue)", status: $0, done: []) }
        all.append(manifest("2026-11-27-1000-all-done", status: .completed,
                            done: [.transcribing, .slicing, .evaluating, .synthesizing, .completed]))
        all.append(manifest("2026-11-27-1000-legacy-order", status: .paused,
                            done: [.slicing, .recording, .transcribing]))
        var rich = manifest("2026-11-27-1000-rich", status: .offlineFailed, done: [.transcribing, .slicing])
        let sender = SessionEnvironment(computer: "Golden Mac", macOS: "27.2", appVersion: "1.0", appBuild: "1",
                                        architecture: "arm64")
        rich.captureEnvironment = sender
        rich.importOrigin = .init(kind: .imported, originalSessionID: "2026-11-26-0900-source",
                                  importedAt: Date(timeIntervalSince1970: 1_800_000_600), exportedFrom: sender,
                                  transferID: "00000000-0000-0000-0000-000000000001", scope: .complete,
                                  integrityVerified: true, parentSessionID: nil)
        rich.includeFullTranscriptInZip = true
        rich.duration = DurationPair(wallSeconds: 61.5, mediaSeconds: 60.25)
        all.append(rich)
        return all
    }

    private func encodedCases() throws -> Data {
        let encoder = encoder()
        var output = Data()
        for value in cases() {
            output.append(try encoder.encode(value))
            output.append(Data("\n---\n".utf8))
        }
        return output
    }

    func testManifestBytesMatchTheRecordedFormat() throws {
        let encoded = try encodedCases()
        if ProcessInfo.processInfo.environment["SCRUMTRACE_RECORD_MANIFEST_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: goldenURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoded.write(to: goldenURL)
            return
        }
        let golden = try Data(contentsOf: goldenURL)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), String(decoding: golden, as: UTF8.self))
    }

    func testDecodingAndEncodingAgainKeepsEveryByte() throws {
        let encoder = encoder()
        let decoder = decoder()
        for value in cases() {
            let first = try encoder.encode(value)
            let again = try encoder.encode(try decoder.decode(SessionManifest.self, from: first))
            XCTAssertEqual(String(decoding: again, as: UTF8.self), String(decoding: first, as: UTF8.self),
                           value.sessionId)
        }
    }
}
