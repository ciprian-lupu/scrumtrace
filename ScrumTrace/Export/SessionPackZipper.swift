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
        PackBudget.removeEscapingExportLinks(exportDir: exportDir)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let zipURL = sessionURL.appendingPathComponent(ScrumTracePath.packZip)
        var omitted = uniquedOmitted(manifest.omitted)

        do {
            try runZip(
                exportDir: exportDir,
                includeFullTranscript: manifest.includeFullTranscriptInZip,
                sessionURL: sessionURL
            )
        } catch {
            omitted.append(OmittedAsset(path: "session-pack.zip", reason: error.localizedDescription))
            return Result(zipURL: zipURL, byteCount: fileSize(zipURL), omitted: uniquedOmitted(omitted))
        }
        var size = fileSize(zipURL)

        let dropList = PackBudget.omissionOrder(manifest: manifest, sessionURL: sessionURL)
        for path in dropList where size > MediaBudget.maxZipBytes {
            guard ExportRel.isUnderExport(path) else { continue }
            if PackBudget.isProtected(path) { continue }
            let url = sessionURL.appendingPathComponent(path)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard ExportRel.isContainedRegularFile(url, sessionRoot: sessionURL) else { continue }
            try? FileManager.default.removeItem(at: url)
            omitted.append(OmittedAsset(path: ExportRel.toExportRoot(path), reason: "Pack over 35 MB; dropped by priority"))
            do {
                try runZip(
                    exportDir: exportDir,
                    includeFullTranscript: manifest.includeFullTranscriptInZip,
                    sessionURL: sessionURL
                )
                size = fileSize(zipURL)
            } catch {
                omitted.append(OmittedAsset(path: "session-pack.zip", reason: error.localizedDescription))
                break
            }
        }

        if size > MediaBudget.maxZipBytes {
            omitted.append(
                OmittedAsset(
                    path: "session-pack.zip",
                    reason: "Pack still \(size) bytes after dropping all droppable export media; protected docs remain."
                )
            )
        }
        omitted = uniquedOmitted(omitted)
        try writeOmittedMarkdown(sessionURL: sessionURL, omitted: omitted)
        if omitted.contains(where: { !$0.path.isEmpty }) {
            try runZip(
                exportDir: exportDir,
                includeFullTranscript: manifest.includeFullTranscriptInZip,
                sessionURL: sessionURL
            )
            size = fileSize(zipURL)
        }
        return Result(zipURL: zipURL, byteCount: size, omitted: omitted)
    }

    func writeZip(sessionURL: URL, includeFullTranscript: Bool = false) throws -> Int {
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        let zipURL = sessionURL.appendingPathComponent(ScrumTracePath.packZip)
        try runZip(
            exportDir: exportDir,
            includeFullTranscript: includeFullTranscript,
            sessionURL: sessionURL
        )
        return fileSize(zipURL)
    }

    func writeOmittedMarkdown(sessionURL: URL, omitted: [OmittedAsset]) throws {
        PackBudget.removeEscapingExportLinks(
            exportDir: sessionURL.appendingPathComponent(ScrumTracePath.export)
        )
        let dest = sessionURL.appendingPathComponent(ScrumTracePath.omitted)
        if omitted.isEmpty {
            if (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try? FileManager.default.removeItem(at: dest)
            } else if ExportRel.isContainedRegularFile(dest, sessionRoot: sessionURL) {
                try? FileManager.default.removeItem(at: dest)
            }
            return
        }
        let lines = ["# Omitted from export", ""] + omitted.map {
            "- `\(ExportRel.omittedHandoffPath($0.path))` — \($0.reason)"
        }
        try ExportRel.writeExportText(lines.joined(separator: "\n"), relative: ScrumTracePath.omitted, sessionURL: sessionURL)
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

    private func runZip(exportDir: URL, includeFullTranscript: Bool, sessionURL: URL) throws {
        let destRel = try ExportRel.prepareContainedWrite(
            relative: ScrumTracePath.packZip,
            sessionURL: sessionURL
        )
        let dest = sessionURL.appendingPathComponent(destRel)
        if ExportRel.isContainedRegularFile(dest, sessionRoot: sessionURL) {
            try FileManager.default.removeItem(at: dest)
        }
        let members = PackBudget.allowList(
            exportDir: exportDir,
            includeFullTranscript: includeFullTranscript
        )
        guard !members.isEmpty else {
            throw SessionRecorderError.writerFailed("export/ allow-list is empty; nothing to zip.")
        }
        let process = Process()
        process.currentDirectoryURL = exportDir
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // `-y` stores a symlink as a link if one is ever listed; allowList still
        // omits links so zip cannot follow them into archive/ or another tree.
        process.arguments = ["-q", "-y", dest.path, "-@"]
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

    /// Deletes every symbolic link under `export/` so a Finder/Cursor folder drop
    /// cannot follow a planted `shots/` or `media/` link into `archive/` (C2).
    /// The zip allow-list already skips links; this matches folder-handoff to zip.
    static func removeEscapingExportLinks(exportDir: URL) {
        let fm = FileManager.default
        let linkKey = URLResourceKey.isSymbolicLinkKey
        if (try? exportDir.resourceValues(forKeys: [linkKey]).isSymbolicLink) == true {
            try? fm.removeItem(at: exportDir)
            try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
            return
        }
        guard let enumerator = fm.enumerator(
            at: exportDir,
            includingPropertiesForKeys: [linkKey],
            options: []
        ) else { return }
        var links: [URL] = []
        for case let file as URL in enumerator {
            if (try? file.resourceValues(forKeys: [linkKey]).isSymbolicLink) == true {
                links.append(file)
                enumerator.skipDescendants()
            }
        }
        for link in links.reversed() {
            try? fm.removeItem(at: link)
        }
    }

    /// Explicit members under `export/` — never the session root, never `archive/`.
    /// `full_transcript.json` is only listed when the user opted it into the pack.
    /// Membership is resolved-path containment, not a string prefix strip.
    static func allowList(exportDir: URL, includeFullTranscript: Bool = false) -> [String] {
        removeEscapingExportLinks(exportDir: exportDir)
        let named = [
            "AGENT_CONTEXT.md",
            "SESSION_BRIEF.html",
            "AGENT_PROMPT.txt",
            "session.manifest.json",
            "OMITTED.md"
        ]
        var out: [String] = []
        for name in named {
            if let member = ExportRel.containedExportMember(
                file: exportDir.appendingPathComponent(name),
                exportDir: exportDir
            ) {
                out.append(member)
            }
        }
        if includeFullTranscript {
            if let member = ExportRel.containedExportMember(
                file: exportDir.appendingPathComponent("full_transcript.json"),
                exportDir: exportDir
            ) {
                out.append(member)
            }
        }
        for folder in ["shots", "media"] {
            let root = exportDir.appendingPathComponent(folder)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    enumerator.skipDescendants()
                    continue
                }
                if url.lastPathComponent == "session-pack.zip" { continue }
                if let member = ExportRel.containedExportMember(file: url, exportDir: exportDir) {
                    out.append(member)
                }
            }
        }
        return out.sorted()
    }

    /// Lowest priority first. 35 MB wins: evidence media is last, never archive/.
    static func omissionOrder(manifest: SessionManifest, sessionURL: URL) -> [String] {
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
        let reservedClipSet = Set(reservedClips)

        // Keyword-only clips — not the one clip reserved per kept task.
        let keyword = manifest.slices
            .filter { $0.trigger == .keyword }
            .sorted { $0.score < $1.score }
            .compactMap { $0.exportClipPath ?? $0.clipPath }
            .map(ExportRel.sessionPath)
            .filter { ExportRel.isUnderExport($0) && !reservedClipSet.contains($0) }

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

        // Spec drop order: keyword-only clips, extra stills, remaining clips,
        // then evidence clips, then evidence Shot stills (newest kept longest).
        return uniqued(
            keyword + extraStills + extraShots + leftover + extraClips + evidenceClipsDrop + evidenceStillsDrop
        )
        .filter { ExportRel.isContainedRegularFile(sessionURL.appendingPathComponent($0), sessionRoot: sessionURL) }
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
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        guard let enumerator = FileManager.default.enumerator(
            at: exportDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            if isProtected(url.lastPathComponent) { continue }
            guard let exportRel = ExportRel.containedExportMember(file: url, exportDir: exportDir) else {
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "mp4", "wav", "webp", "json"].contains(ext) {
                out.append(ExportRel.sessionPath(exportRel))
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
