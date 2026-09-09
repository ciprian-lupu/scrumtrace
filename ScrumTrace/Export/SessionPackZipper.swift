import Foundation

struct SessionPackZipper {
    struct Result: Sendable {
        var zipURL: URL
        var byteCount: Int
        var omitted: [OmittedAsset]
    }

    /// Zip is built from `export/` only — never the session root or `archive/`.
    func zip(sessionURL: URL, manifest: SessionManifest) throws -> Result {
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let zipURL = sessionURL.appendingPathComponent(ScrumTracePath.packZip)
        try? FileManager.default.removeItem(at: zipURL)

        var omitted = manifest.omitted
        try runZip(exportDir: exportDir, zipURL: zipURL)
        var size = (try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.intValue ?? 0

        let keywordClips = manifest.slices
            .filter { $0.trigger == .keyword }
            .sorted { $0.score < $1.score }
            .compactMap(\.clipPath)

        for clip in keywordClips where size > MediaBudget.maxZipBytes {
            let exportName = URL(fileURLWithPath: clip).lastPathComponent
            omitted.append(OmittedAsset(path: clip, reason: "Pack over 35 MB; dropped keyword clip"))
            try? FileManager.default.removeItem(at: zipURL)
            try runZip(exportDir: exportDir, zipURL: zipURL)
            size = (try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.intValue ?? 0
            _ = exportName
        }

        if size > MediaBudget.maxZipBytes {
            throw SessionRecorderError.writerFailed(
                "session-pack.zip is \(size) bytes after omissions; still over 35 MB."
            )
        }
        return Result(zipURL: zipURL, byteCount: size, omitted: omitted)
    }

    private func runZip(exportDir: URL, zipURL: URL) throws {
        let process = Process()
        process.currentDirectoryURL = exportDir
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", zipURL.lastPathComponent, ".", "-x", "session-pack.zip"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SessionRecorderError.writerFailed("zip failed with status \(process.terminationStatus).")
        }
    }
}
