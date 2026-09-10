import Darwin
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
        guard ExportRel.isUsableSessionRoot(sessionURL) else {
            throw SessionRecorderError.writerFailed("session folder")
        }
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        PackBudget.removeEscapingExportLinks(exportDir: exportDir)
        try ExportRel.ensureContainedDirectories(relative: ScrumTracePath.export, sessionURL: sessionURL)
        if (try? exportDir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try? ExportRel.removeItemIfRegularFile(exportDir, sessionRoot: sessionURL)
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        if ExportRel.containsSymlinkComponent(ScrumTracePath.export, sessionURL: sessionURL) {
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        if PackBudget.exportStillContainsSymlink(exportDir: exportDir) {
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        let zipURL = sessionURL.appendingPathComponent(ScrumTracePath.packZip)
        var omitted = uniquedOmitted(manifest.omitted)
        var includeTranscript = manifest.includeFullTranscriptInZip

        do {
            try runZip(
                exportDir: exportDir,
                includeFullTranscript: includeTranscript,
                sessionURL: sessionURL
            )
        } catch {
            if PackBudget.exportStillContainsSymlink(exportDir: exportDir) {
                throw error
            }
            omitted.append(OmittedAsset(path: "session-pack.zip", reason: error.localizedDescription))
            let listed = uniquedOmitted(omitted)
            try writeOmittedMarkdown(sessionURL: sessionURL, omitted: listed)
            return Result(
                zipURL: zipURL,
                byteCount: discardPackIfOverBudget(sessionURL: sessionURL),
                omitted: listed
            )
        }
        var size = try measuredPackBytes(sessionURL: sessionURL)

        let dropList = PackBudget.omissionOrder(manifest: manifest, sessionURL: sessionURL)
        for path in dropList where size > MediaBudget.maxZipBytes {
            guard ExportRel.isUnderExport(path) else { continue }
            if PackBudget.isProtected(path) { continue }
            let url = sessionURL.appendingPathComponent(path)
            let plantedLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            if plantedLink {
                do {
                    try ExportRel.removeItemIfRegularFile(url, sessionRoot: sessionURL)
                } catch {
                    continue
                }
            } else {
                guard ExportRel.isContainedRegularFile(url, sessionRoot: sessionURL) else { continue }
                do {
                    try ExportRel.removeItemIfRegularFile(url, sessionRoot: sessionURL)
                } catch {
                    continue
                }
            }
            omitted.append(OmittedAsset(path: ExportRel.toExportRoot(path), reason: "Pack over 35 MB; dropped by priority"))
            do {
                try runZip(
                    exportDir: exportDir,
                    includeFullTranscript: includeTranscript,
                    sessionURL: sessionURL
                )
                size = try measuredPackBytes(sessionURL: sessionURL)
            } catch {
                omitted.append(OmittedAsset(path: "session-pack.zip", reason: error.localizedDescription))
                break
            }
        }

        if size > MediaBudget.maxZipBytes {
            // C3: opted-in transcript is allow-listed, not immortal. Archive keeps
            // archive/full_transcript.json. The export copy loses to the 35 MB cap.
            let transcriptRel = "export/full_transcript.json"
            let transcriptURL = sessionURL.appendingPathComponent(transcriptRel)
            if ExportRel.isContainedRegularFile(transcriptURL, sessionRoot: sessionURL) {
                do {
                    try ExportRel.removeItemIfRegularFile(transcriptURL, sessionRoot: sessionURL)
                    omitted.append(
                        OmittedAsset(
                            path: "full_transcript.json",
                            reason: "Pack over 35 MB; opted-in full transcript dropped. Archive copy kept."
                        )
                    )
                    includeTranscript = false
                    try runZip(
                        exportDir: exportDir,
                        includeFullTranscript: false,
                        sessionURL: sessionURL
                    )
                    size = try measuredPackBytes(sessionURL: sessionURL)
                } catch {
                    omitted.append(OmittedAsset(path: "session-pack.zip", reason: error.localizedDescription))
                }
            }
            let stillOver = size > MediaBudget.maxZipBytes
            if stillOver {
                omitted.append(
                    OmittedAsset(
                        path: "session-pack.zip",
                        reason: "Pack still \(size) bytes after dropping all droppable export media; protected docs remain."
                    )
                )
            }
        }
        omitted = uniquedOmitted(omitted)
        do {
            try writeOmittedMarkdown(sessionURL: sessionURL, omitted: omitted)
        } catch {
            return Result(
                zipURL: zipURL,
                byteCount: discardPackIfOverBudget(sessionURL: sessionURL),
                omitted: omitted
            )
        }
        if omitted.contains(where: { !$0.path.isEmpty }) {
            do {
                try runZip(
                    exportDir: exportDir,
                    includeFullTranscript: includeTranscript,
                    sessionURL: sessionURL
                )
                size = try measuredPackBytes(sessionURL: sessionURL)
            } catch {
                omitted.append(OmittedAsset(path: "session-pack.zip", reason: error.localizedDescription))
                omitted = uniquedOmitted(omitted)
                do {
                    try writeOmittedMarkdown(sessionURL: sessionURL, omitted: omitted)
                } catch {
                    return Result(
                        zipURL: zipURL,
                        byteCount: discardPackIfOverBudget(sessionURL: sessionURL),
                        omitted: omitted
                    )
                }
                return Result(
                    zipURL: zipURL,
                    byteCount: discardPackIfOverBudget(sessionURL: sessionURL),
                    omitted: omitted
                )
            }
        }
        return Result(
            zipURL: zipURL,
            byteCount: discardPackIfOverBudget(sessionURL: sessionURL),
            omitted: omitted
        )
    }

    func writeZip(sessionURL: URL, includeFullTranscript: Bool = false) throws -> Int {
        guard ExportRel.isUsableSessionRoot(sessionURL) else {
            throw SessionRecorderError.writerFailed("session folder")
        }
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        PackBudget.removeEscapingExportLinks(exportDir: exportDir)
        try ExportRel.ensureContainedDirectories(relative: ScrumTracePath.export, sessionURL: sessionURL)
        if (try? exportDir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try? ExportRel.removeItemIfRegularFile(exportDir, sessionRoot: sessionURL)
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        if ExportRel.containsSymlinkComponent(ScrumTracePath.export, sessionURL: sessionURL) {
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        if PackBudget.exportStillContainsSymlink(exportDir: exportDir) {
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        try runZip(
            exportDir: exportDir,
            includeFullTranscript: includeFullTranscript,
            sessionURL: sessionURL
        )
        return try measuredPackBytes(sessionURL: sessionURL)
    }

    func writeOmittedMarkdown(sessionURL: URL, omitted: [OmittedAsset]) throws {
        PackBudget.removeEscapingExportLinks(
            exportDir: sessionURL.appendingPathComponent(ScrumTracePath.export)
        )
        let dest = sessionURL.appendingPathComponent(ScrumTracePath.omitted)
        if omitted.isEmpty {
            try ExportRel.removeItemIfRegularFile(dest, sessionRoot: sessionURL)
            return
        }
        let lines = ["# Omitted from export", ""] + omitted.map {
            "- `\(PromptTemplates.wrapUntrustedInline(ExportRel.omittedHandoffPath($0.path)))` — \(PromptTemplates.wrapUntrustedInline($0.reason))"
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

    /// C3: `export/session-pack.zip` may not stay on disk over 35 MB.
    /// OMITTED.md already records that protected docs could not fit.
    func discardPackIfOverBudget(sessionURL: URL) -> Int {
        guard ExportRel.isUsableSessionRoot(sessionURL) else { return 0 }
        let zipURL = sessionURL.appendingPathComponent(ScrumTracePath.packZip)
        let bytes = ExportRel.regularFileByteCount(relative: ScrumTracePath.packZip, sessionURL: sessionURL) ?? 0
        guard bytes > MediaBudget.maxZipBytes else { return bytes }
        do {
            try ExportRel.removeItemIfRegularFile(zipURL, sessionRoot: sessionURL)
        } catch {
            ExportRel.unlinkLastComponentUnfollowed(zipURL)
        }
        let leftover = ExportRel.regularFileByteCount(relative: ScrumTracePath.packZip, sessionURL: sessionURL) ?? 0
        if leftover > MediaBudget.maxZipBytes {
            ExportRel.unlinkLastComponentUnfollowed(zipURL)
        }
        return ExportRel.regularFileByteCount(relative: ScrumTracePath.packZip, sessionURL: sessionURL) ?? 0
    }

    /// Weigh the zip with `openat`/`fstat`. Following a dest symlink would
    /// count a planted pack file as the private master movie (C3).
    private func measuredPackBytes(sessionURL: URL) throws -> Int {
        guard let size = ExportRel.regularFileByteCount(relative: ScrumTracePath.packZip, sessionURL: sessionURL),
              size > 0 else {
            throw SessionRecorderError.writerFailed("session-pack.zip is missing or not a regular file.")
        }
        return size
    }

    private func runZip(exportDir: URL, includeFullTranscript: Bool, sessionURL: URL) throws {
        let destRel = try ExportRel.prepareContainedWrite(
            relative: ScrumTracePath.packZip,
            sessionURL: sessionURL
        )
        let scanned = PackBudget.allowList(
            exportDir: exportDir,
            includeFullTranscript: includeFullTranscript
        )
        // Re-check after allowList: a planted symlink must not enter `-@`
        // and must not become zip's cwd (`export/` → `archive/`).
        PackBudget.removeEscapingExportLinks(exportDir: exportDir)
        if (try? exportDir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || ExportRel.containsSymlinkComponent(ScrumTracePath.export, sessionURL: sessionURL)
            || PackBudget.exportStillContainsSymlink(exportDir: exportDir) {
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        let members = scanned.compactMap { member in
            ExportRel.containedExportMember(
                file: exportDir.appendingPathComponent(member),
                exportDir: exportDir
            )
        }
        guard !members.isEmpty else {
            throw SessionRecorderError.writerFailed("export/ allow-list is empty; nothing to zip.")
        }
        // Do not set Process.currentDirectoryURL to exportDir. Process
        // resolves cwd at launch; a planted export/ → archive/ link would pack
        // archive/ members (C2). Copy members via openat into a private
        // staging directory, then posix_spawn_file_actions_addfchdir_np.
        // mkdtemp is exclusive; createDirectory + UUID is a TOCTOU window.
        let template = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrumtrace-zip-stage-XXXXXX")
            .path
        var stageBytes = Array(template.utf8CString)
        let made = stageBytes.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return Darwin.mkdtemp(base) != nil
        }
        guard made else {
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        let stage = URL(fileURLWithPath: String(cString: stageBytes))
        defer { ExportRel.removePrivateTemporaryDirectory(stage) }
        if (try? stage.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            ExportRel.removePrivateTemporaryDirectory(stage)
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        guard let stageFd = ExportRel.openUnfollowedDirectory(stage) else {
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        defer { ExportRel.closeDescriptor(stageFd) }
        var staged: [String] = []
        for member in members {
            guard !member.contains(where: { $0.isNewline || $0 == "\0" }) else { continue }
            let copy: URL
            do {
                copy = try ExportRel.copyContainedToTemporaryFile(
                    relative: ExportRel.sessionPath(member),
                    sessionURL: sessionURL,
                    prefix: "scrumtrace-zip-member"
                )
            } catch {
                if PackBudget.protectedNames.contains(URL(fileURLWithPath: member).lastPathComponent) {
                    throw SessionRecorderError.writerFailed("export/ allow-list is empty; nothing to zip.")
                }
                continue
            }
            do {
                try ExportRel.placeIntoOpenedDirectory(from: copy, relative: member, directoryFd: stageFd)
                ExportRel.removePrivateTemporaryURL(copy)
            } catch {
                ExportRel.removePrivateTemporaryURL(copy)
                throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
            }
            staged.append(member)
        }
        guard !staged.isEmpty else {
            throw SessionRecorderError.writerFailed("export/ allow-list is empty; nothing to zip.")
        }
        let temp: URL
        do {
            temp = try ExportRel.makePrivateTemporaryURL(prefix: "scrumtrace-zip", ext: "zip")
        } catch {
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        // Exclusive dest fd: zip writes the archive to stdout, never to a
        // dest path that could be replaced with a symlink after create (C2).
        let destFd = temp.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard destFd >= 0 else {
            ExportRel.removePrivateTemporaryURL(temp)
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        if (try? exportDir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || ExportRel.containsSymlinkComponent(ScrumTracePath.export, sessionURL: sessionURL) {
            Darwin.close(destFd)
            ExportRel.removePrivateTemporaryURL(temp)
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        if (try? stage.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            Darwin.close(destFd)
            ExportRel.removePrivateTemporaryURL(temp)
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        do {
            try ExportRel.spawnWithDirectoryFd(
                executable: "/usr/bin/zip",
                arguments: ["-q", "-y", "-", "-@"],
                directoryFd: stageFd,
                stdin: Data((staged.joined(separator: "\n") + "\n").utf8),
                stdoutFd: destFd
            )
        } catch {
            Darwin.close(destFd)
            ExportRel.removePrivateTemporaryURL(temp)
            throw SessionRecorderError.writerFailed("zip failed with status -1.")
        }
        let synced = Darwin.fsync(destFd) == 0
        Darwin.close(destFd)
        guard synced else {
            ExportRel.removePrivateTemporaryURL(temp)
            throw SessionRecorderError.writerFailed("zip failed with status -1.")
        }
        do {
            try ExportRel.fsyncRegularFile(temp, relative: destRel)
            try ExportRel.moveIntoSession(from: temp, relative: destRel, sessionURL: sessionURL)
            ExportRel.removePrivateTemporaryURL(temp)
        } catch {
            ExportRel.removePrivateTemporaryURL(temp)
            throw error
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
        "OMITTED.md",
        "full_transcript.json"
    ]

    static func isProtected(_ sessionPath: String) -> Bool {
        protectedNames.contains(URL(fileURLWithPath: sessionPath).lastPathComponent)
    }

    /// Folder-handoff must match zip. A leftover `export/shots` → `archive/`
    /// link is a C2 leak even if the zip allow-list skipped it.
    static func exportStillContainsSymlink(exportDir: URL) -> Bool {
        let linkKey = URLResourceKey.isSymbolicLinkKey
        if (try? exportDir.resourceValues(forKeys: [linkKey]).isSymbolicLink) == true {
            return true
        }
        guard let enumerator = FileManager.default.enumerator(
            at: exportDir,
            includingPropertiesForKeys: [linkKey],
            options: []
        ) else {
            return true
        }
        for case let file as URL in enumerator {
            if (try? file.resourceValues(forKeys: [linkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                return true
            }
        }
        return false
    }

    /// Deletes every symbolic link under `export/` so a Finder/Cursor folder drop
    /// cannot follow a planted `shots/` or `media/` link into `archive/` (C2).
    /// The zip allow-list already skips links; this matches folder-handoff to zip.
    static func removeEscapingExportLinks(exportDir: URL) {
        let sessionRoot = exportDir.deletingLastPathComponent()
        let linkKey = URLResourceKey.isSymbolicLinkKey
        if (try? exportDir.resourceValues(forKeys: [linkKey]).isSymbolicLink) == true {
            try? ExportRel.removeItemIfRegularFile(exportDir, sessionRoot: sessionRoot)
            ExportRel.unlinkLastComponentUnfollowed(exportDir)
            if (try? exportDir.resourceValues(forKeys: [linkKey]).isSymbolicLink) == true {
                return
            }
            try? ExportRel.ensureContainedDirectories(
                relative: ScrumTracePath.export,
                sessionURL: sessionRoot
            )
            if (try? exportDir.resourceValues(forKeys: [linkKey]).isSymbolicLink) == true {
                try? ExportRel.removeItemIfRegularFile(exportDir, sessionRoot: sessionRoot)
                ExportRel.unlinkLastComponentUnfollowed(exportDir)
            }
            return
        }
        guard let enumerator = FileManager.default.enumerator(
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
            try? ExportRel.removeItemIfRegularFile(link, sessionRoot: sessionRoot)
            ExportRel.unlinkLastComponentUnfollowed(link)
            if (try? link.resourceValues(forKeys: [linkKey]).isSymbolicLink) == true {
                ExportRel.unlinkLastComponentUnfollowed(link)
            }
        }
    }

    /// Explicit members under `export/` — never the session root, never `archive/`.
    /// `full_transcript.json` is only listed when the user opted it into the pack.
    /// Membership is resolved-path containment, not a string prefix strip.
    static func allowList(exportDir: URL, includeFullTranscript: Bool = false) -> [String] {
        removeEscapingExportLinks(exportDir: exportDir)
        let sessionRoot = exportDir.deletingLastPathComponent()
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
            // Enumerator follows a directory symlink. Delete it instead of
            // walking `export/media` → `archive/` (C2).
            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try? ExportRel.removeItemIfRegularFile(root, sessionRoot: sessionRoot)
                ExportRel.unlinkLastComponentUnfollowed(root)
                continue
            }
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
                if let rel = ExportRel.unfollowedRelative(url, sessionRoot: sessionRoot),
                   ExportRel.containsSymlinkComponent(rel, sessionURL: sessionRoot) {
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
            (ExportRel.regularFileByteCount(relative: $0, sessionURL: sessionURL) ?? 0)
                > (ExportRel.regularFileByteCount(relative: $1, sessionURL: sessionURL) ?? 0)
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
        if dropped.contains("full_transcript.json") {
            copy.includeFullTranscriptInZip = false
        }
        return copy
    }

    static func exportMediaSessionPaths(sessionURL: URL) -> [String] {
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        removeEscapingExportLinks(exportDir: exportDir)
        if (try? exportDir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return []
        }
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
            if let rel = ExportRel.unfollowedRelative(url, sessionRoot: sessionURL),
               ExportRel.containsSymlinkComponent(rel, sessionURL: sessionURL) {
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

}
