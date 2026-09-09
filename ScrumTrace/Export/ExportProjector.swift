import Foundation

struct ExportProjection: Sendable {
    var manifest: SessionManifest
    var omitted: [OmittedAsset]
}

/// Copies allow-listed evidence into `export/` and writes a path-rewritten projection.
struct ExportProjector {
    func project(sessionURL: URL, manifest: SessionManifest) throws -> ExportProjection {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: sessionURL.appendingPathComponent(ScrumTracePath.export),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: sessionURL.appendingPathComponent(ScrumTracePath.exportShots),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: sessionURL.appendingPathComponent(ScrumTracePath.media),
            withIntermediateDirectories: true
        )

        var omitted: [OmittedAsset] = []
        var projected = manifest
        var projectedShots: [ShotRecord] = []
        var projectedSlices: [SliceRecord] = []
        var projectedTasks: [TaskRecord] = []

        for shot in manifest.shots {
            var copy = shot
            let sourcePath = shot.annotatedPath ?? shot.rawPath
            let destName = URL(fileURLWithPath: sourcePath).lastPathComponent
            copy.exportPath = try copyIfPresent(
                from: sessionURL.appendingPathComponent(sourcePath),
                to: sessionURL.appendingPathComponent("\(ScrumTracePath.exportShots)/\(destName)"),
                sessionURL: sessionURL,
                omitted: &omitted
            )
            projectedShots.append(copy)
        }

        for (index, slice) in manifest.slices.enumerated() {
            var copy = slice
            let ordinal = String(format: "%02d", index + 1)
            if let clip = slice.clipPath {
                let dest = "\(ScrumTracePath.media)/task-\(ordinal)/clip.mp4"
                copy.exportClipPath = try copyIfPresent(
                    from: sessionURL.appendingPathComponent(clip),
                    to: sessionURL.appendingPathComponent(dest),
                    sessionURL: sessionURL,
                    omitted: &omitted
                )
            }
            var exportStills: [String] = []
            for still in slice.stills {
                let dest = "\(ScrumTracePath.media)/task-\(ordinal)/\(URL(fileURLWithPath: still).lastPathComponent)"
                if let placed = try copyIfPresent(
                    from: sessionURL.appendingPathComponent(still),
                    to: sessionURL.appendingPathComponent(dest),
                    sessionURL: sessionURL,
                    omitted: &omitted
                ) {
                    exportStills.append(placed)
                }
            }
            copy.stills = exportStills
            projectedSlices.append(copy)
        }

        for task in manifest.tasks {
            var copy = task
            copy.evidenceMedia = task.evidenceMedia.compactMap { path in
                let exportCandidate: String
                if path.hasPrefix("export/") {
                    exportCandidate = path
                } else if path.hasPrefix("archive/shots/") {
                    exportCandidate = path.replacingOccurrences(of: "archive/shots/", with: "export/shots/")
                } else if path.contains("media-work") {
                    exportCandidate = path.replacingOccurrences(of: "archive/media-work/", with: "export/media/")
                } else {
                    exportCandidate = "\(ScrumTracePath.exportShots)/\(URL(fileURLWithPath: path).lastPathComponent)"
                }
                if fileManager.fileExists(atPath: sessionURL.appendingPathComponent(exportCandidate).path) {
                    return exportCandidate
                }
                omitted.append(OmittedAsset(path: path, reason: "Not present under export/ after projection"))
                return nil
            }
            projectedTasks.append(copy)
        }

        projected.shots = projectedShots
        projected.slices = projectedSlices
        projected.tasks = projectedTasks
        projected.omitted = omitted

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(projected).write(to: sessionURL.appendingPathComponent(ScrumTracePath.exportManifest))

        if !omitted.isEmpty {
            let lines = ["# Omitted from export", ""] + omitted.map { "- `\($0.path)` — \($0.reason)" }
            try lines.joined(separator: "\n").write(
                to: sessionURL.appendingPathComponent(ScrumTracePath.omitted),
                atomically: true,
                encoding: .utf8
            )
        }
        return ExportProjection(manifest: projected, omitted: omitted)
    }

    private func copyIfPresent(
        from: URL,
        to: URL,
        sessionURL: URL,
        omitted: inout [OmittedAsset]
    ) throws -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: from.path) else {
            omitted.append(OmittedAsset(path: from.path, reason: "Source missing in archive"))
            return nil
        }
        try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: to.path) {
            try fileManager.removeItem(at: to)
        }
        try fileManager.copyItem(at: from, to: to)
        let prefix = sessionURL.path.hasSuffix("/") ? sessionURL.path : sessionURL.path + "/"
        return to.path.replacingOccurrences(of: prefix, with: "")
    }
}
