import Foundation

struct SessionPackZipper {
    struct Result: Sendable {
        var zipURL: URL
        var byteCount: Int
        var omitted: [OmittedAsset]
    }

    /// Zip is built from `export/` only. Files are deleted from export (not archive)
    /// in spec priority until the measured zip is ≤ 35 MB.
    func zip(sessionURL: URL, manifest: SessionManifest) throws -> Result {
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let zipURL = sessionURL.appendingPathComponent(ScrumTracePath.packZip)
        var omitted = uniquedOmitted(manifest.omitted)

        try runZip(exportDir: exportDir, zipURL: zipURL)
        var size = fileSize(zipURL)

        let dropList = PackBudget.omissionOrder(manifest: manifest, sessionURL: sessionURL)
        for path in dropList where size > MediaBudget.maxZipBytes {
            guard ExportRel.isUnderExport(path) else { continue }
            if PackBudget.isProtected(path) { continue }
            let url = sessionURL.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
            omitted.append(OmittedAsset(path: ExportRel.toExportRoot(path), reason: "Pack over 35 MB; dropped by priority"))
            try runZip(exportDir: exportDir, zipURL: zipURL)
            size = fileSize(zipURL)
        }

        if size > MediaBudget.maxZipBytes {
            throw SessionRecorderError.writerFailed(
                "session-pack.zip is \(size) bytes after omissions; still over 35 MB."
            )
        }
        try writeOmittedMarkdown(sessionURL: sessionURL, omitted: omitted)
        // Include OMITTED.md in the zip when present.
        if omitted.contains(where: { !$0.path.isEmpty }) {
            try runZip(exportDir: exportDir, zipURL: zipURL)
            size = fileSize(zipURL)
        }
        return Result(zipURL: zipURL, byteCount: size, omitted: omitted)
    }

    func writeZip(sessionURL: URL) throws -> Int {
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        let zipURL = sessionURL.appendingPathComponent(ScrumTracePath.packZip)
        try runZip(exportDir: exportDir, zipURL: zipURL)
        return fileSize(zipURL)
    }

    func writeOmittedMarkdown(sessionURL: URL, omitted: [OmittedAsset]) throws {
        let url = sessionURL.appendingPathComponent(ScrumTracePath.omitted)
        if omitted.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let lines = ["# Omitted from export", ""] + omitted.map { "- `\($0.path)` — \($0.reason)" }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func uniquedOmitted(_ items: [OmittedAsset]) -> [OmittedAsset] {
        var seen = Set<String>()
        var out: [OmittedAsset] = []
        for item in items where seen.insert(item.path).inserted {
            out.append(item)
        }
        return out
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func runZip(exportDir: URL, zipURL: URL) throws {
        try? FileManager.default.removeItem(at: zipURL)
        let members = PackBudget.allowList(exportDir: exportDir)
        guard !members.isEmpty else {
            throw SessionRecorderError.writerFailed("export/ allow-list is empty; nothing to zip.")
        }
        let process = Process()
        process.currentDirectoryURL = exportDir
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", zipURL.path, "-@"]
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        if let data = (members.joined(separator: "\n") + "\n").data(using: .utf8) {
            try pipe.fileHandleForWriting.write(contentsOf: data)
        }
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SessionRecorderError.writerFailed("zip failed with status \(process.terminationStatus).")
        }
    }
}

enum PackBudget {
    static let protectedNames: Set<String> = [
        "AGENT_CONTEXT.md",
        "SESSION_BRIEF.html",
        "AGENT_PROMPT.txt",
        "session.manifest.json",
        "session-pack.zip",
        "OMITTED.md"
    ]

    static func isProtected(_ sessionPath: String) -> Bool {
        protectedNames.contains(URL(fileURLWithPath: sessionPath).lastPathComponent)
    }

    /// Explicit members under `export/` — never the session root, never `archive/`.
    static func allowList(exportDir: URL) -> [String] {
        let named = [
            "AGENT_CONTEXT.md",
            "SESSION_BRIEF.html",
            "AGENT_PROMPT.txt",
            "session.manifest.json",
            "OMITTED.md",
            "full_transcript.json"
        ]
        var out: [String] = []
        for name in named {
            if FileManager.default.fileExists(atPath: exportDir.appendingPathComponent(name).path) {
                out.append(name)
            }
        }
        let prefix = exportDir.path.hasSuffix("/") ? exportDir.path : exportDir.path + "/"
        for folder in ["shots", "media"] {
            let root = exportDir.appendingPathComponent(folder)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if url.lastPathComponent == "session-pack.zip" { continue }
                out.append(url.path.replacingOccurrences(of: prefix, with: ""))
            }
        }
        return out.sorted()
    }

    /// Lowest priority first. 35 MB wins: evidence media is last, never archive/.
    static func omissionOrder(manifest: SessionManifest, sessionURL: URL) -> [String] {
        let keyword = manifest.slices
            .filter { $0.trigger == .keyword }
            .sorted { $0.score < $1.score }
            .compactMap { $0.exportClipPath ?? $0.clipPath }
            .map(ExportRel.sessionPath)
            .filter(ExportRel.isUnderExport)

        let kept: Set<TaskStatus> = [.confirmed, .needsReview]
        let evidence = Set(
            manifest.tasks
                .filter { kept.contains($0.status) }
                .flatMap(\.evidenceMedia)
                .map(ExportRel.sessionPath)
        )

        var reservedClips: [String] = []
        for task in manifest.tasks where kept.contains(task.status) {
            guard let slice = manifest.slices.first(where: { $0.sliceId == task.sourceSliceId }) else { continue }
            if let clip = slice.exportClipPath ?? slice.clipPath {
                let path = ExportRel.sessionPath(clip)
                if ExportRel.isUnderExport(path) { reservedClips.append(path) }
            }
        }

        let evidenceShotsNewestFirst = manifest.shots
            .sorted { $0.tMedia > $1.tMedia }
            .compactMap { $0.exportPath ?? $0.annotatedPath ?? ($0.rawPath.isEmpty ? nil : $0.rawPath) }
            .map(ExportRel.sessionPath)
            .filter { evidence.contains($0) && ExportRel.isUnderExport($0) }

        let extraStills = manifest.slices
            .flatMap(\.stills)
            .map(ExportRel.sessionPath)
            .filter { ExportRel.isUnderExport($0) && !evidence.contains($0) && !$0.lowercased().hasSuffix(".mp4") }

        let extraShots = manifest.shots
            .compactMap { $0.exportPath ?? $0.annotatedPath }
            .map(ExportRel.sessionPath)
            .filter { ExportRel.isUnderExport($0) && !evidence.contains($0) }

        let reservedClipSet = Set(reservedClips)
        let extraClips = manifest.slices
            .filter { $0.trigger != .keyword }
            .compactMap { $0.exportClipPath ?? $0.clipPath }
            .map(ExportRel.sessionPath)
            .filter { ExportRel.isUnderExport($0) && !evidence.contains($0) && !reservedClipSet.contains($0) }

        let listed = Set(keyword + extraStills + extraClips + extraShots + reservedClips + evidenceShotsNewestFirst)
        let leftover = exportMediaSessionPaths(sessionURL: sessionURL)
            .filter { !listed.contains($0) && !isProtected($0) }

        let evidenceClipsDrop = reservedClips.sorted {
            fileSize(sessionURL.appendingPathComponent($0)) > fileSize(sessionURL.appendingPathComponent($1))
        }
        let evidenceStillsDrop = Array(evidenceShotsNewestFirst.reversed())

        return uniqued(
            keyword + extraStills + extraClips + extraShots + leftover + evidenceClipsDrop + evidenceStillsDrop
        )
        .filter { FileManager.default.fileExists(atPath: sessionURL.appendingPathComponent($0).path) }
        .filter { ExportRel.isUnderExport($0) && !isProtected($0) }
    }

    static func stripOmitted(_ omitted: [OmittedAsset], from manifest: SessionManifest) -> SessionManifest {
        let dropped = Set(omitted.map { ExportRel.toExportRoot($0.path) })
        var copy = manifest
        copy.slices = copy.slices.map { slice in
            var next = slice
            if let clip = next.exportClipPath ?? next.clipPath,
               dropped.contains(ExportRel.toExportRoot(clip)) {
                next.exportClipPath = nil
                if let clipPath = next.clipPath, dropped.contains(ExportRel.toExportRoot(clipPath)) {
                    next.clipPath = nil
                }
            }
            next.stills = next.stills.filter { !dropped.contains(ExportRel.toExportRoot($0)) }
            return next
        }
        copy.shots = copy.shots.map { shot in
            var next = shot
            if let path = next.exportPath, dropped.contains(ExportRel.toExportRoot(path)) {
                next.exportPath = nil
            }
            if let annotated = next.annotatedPath, dropped.contains(ExportRel.toExportRoot(annotated)) {
                next.annotatedPath = nil
            }
            if dropped.contains(ExportRel.toExportRoot(next.rawPath)) {
                next.rawPath = ""
            }
            return next
        }
        copy.tasks = copy.tasks.map { task in
            var next = task
            next.evidenceMedia = task.evidenceMedia.filter { !dropped.contains(ExportRel.toExportRoot($0)) }
            if next.status == .confirmed && next.evidenceMedia.isEmpty {
                next.status = .needsReview
            }
            return next
        }
        copy.omitted = omitted
        return copy
    }

    static func exportMediaSessionPaths(sessionURL: URL) -> [String] {
        let root = sessionURL.appendingPathComponent(ScrumTracePath.export)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefix = sessionURL.path.hasSuffix("/") ? sessionURL.path : sessionURL.path + "/"
        var out: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if isProtected(url.lastPathComponent) { continue }
            let rel = url.path.replacingOccurrences(of: prefix, with: "")
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "mp4", "wav", "webp", "json"].contains(ext) {
                out.append(rel)
            }
        }
        return out.sorted()
    }

    private static func uniqued(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths where seen.insert(path).inserted {
            out.append(path)
        }
        return out
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }
}
