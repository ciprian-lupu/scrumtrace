import XCTest
@testable import ScrumTrace

/// Gate 6 / A10: real `SessionPackZipper` on an oversized 8-clip / 20-shot fixture.
final class PackGateTests: XCTestCase {
    func testOversizedEightClipTwentyShotPackStaysUnderBudgetWithNamedOmissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrumtrace-pack-gate-\(UUID().uuidString)")
        let export = root.appendingPathComponent("export")
        let shotsDir = export.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("# context\n".utf8).write(to: export.appendingPathComponent("AGENT_CONTEXT.md"))
        try Data("<html></html>".utf8).write(to: export.appendingPathComponent("SESSION_BRIEF.html"))
        try Data("prompt".utf8).write(to: export.appendingPathComponent("AGENT_PROMPT.txt"))
        try Data("{}".utf8).write(to: export.appendingPathComponent("session.manifest.json"))

        // ~5 MiB payloads → 8 clips + 20 shots ≈ 140 MiB before omission.
        let chunk = Data(repeating: 0x5A, count: 5 * 1024 * 1024)
        var manifest = SessionManifest.makeNew(sessionId: "pack-gate-oversized", product: .empty)
        var slices: [SliceRecord] = []
        var tasks: [TaskRecord] = []
        var shots: [ShotRecord] = []

        for index in 1 ... 8 {
            let folderName = String(format: "task-%02d", index)
            let folder = export.appendingPathComponent("media/\(folderName)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let relative = "media/\(folderName)/clip.mp4"
            try chunk.write(to: export.appendingPathComponent(relative))
            let sliceId = String(format: "slice-%02d", index)
            slices.append(
                SliceRecord(
                    sliceId: sliceId,
                    startMedia: Double(index * 30),
                    endMedia: Double(index * 30 + 20),
                    trigger: .keyword,
                    associatedShotId: nil,
                    clipPath: "export/\(relative)",
                    exportClipPath: "export/\(relative)",
                    stills: [],
                    analysisStatus: .success,
                    score: 40
                )
            )
            tasks.append(
                TaskRecord(
                    taskId: String(format: "TASK-%02d", index),
                    sourceSliceId: sliceId,
                    kind: .bug,
                    status: .confirmed,
                    title: "Task \(index)",
                    observed: "observed \(index)",
                    stated: "stated \(index)",
                    inferred: "inferred \(index)",
                    agentInstructions: "inspect",
                    quotes: [],
                    evidenceMedia: ["export/\(relative)"],
                    confidence: 0.9
                )
            )
        }

        for index in 1 ... 20 {
            let name = String(format: "%03d.jpg", index)
            try chunk.write(to: shotsDir.appendingPathComponent(name))
            shots.append(
                ShotRecord(
                    id: String(format: "shot-%03d", index),
                    tMedia: Double(index),
                    rawPath: "export/shots/\(name)",
                    annotatedPath: nil,
                    exportPath: "export/shots/\(name)",
                    note: "note \(index)",
                    source: .typed
                )
            )
        }

        manifest.slices = slices
        manifest.tasks = tasks
        manifest.shots = shots

        let result = try SessionPackZipper().zip(sessionURL: root, manifest: manifest)
        XCTAssertLessThanOrEqual(result.byteCount, MediaBudget.maxZipBytes)
        XCTAssertFalse(result.omitted.isEmpty, "oversized fixture must name dropped assets")
        for item in result.omitted {
            XCTAssertFalse(item.path.isEmpty)
            XCTAssertFalse(item.reason.isEmpty)
            XCTAssertFalse(item.path.contains(".."))
            XCTAssertFalse(item.path.hasPrefix("/"))
            XCTAssertFalse(item.path.split(separator: "/").contains("archive"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.zipURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: result.zipURL.path)
        let size = attrs[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, result.byteCount)
    }
}
