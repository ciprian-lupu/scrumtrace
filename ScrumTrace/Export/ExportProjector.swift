#if os(macOS)
import AppKit
#endif
import Foundation

struct ExportProjection: Sendable {
    var manifest: SessionManifest
    var omitted: [OmittedAsset]
}

/// Copies allow-listed evidence into `export/` and writes a path-rewritten projection.
/// Projection paths are relative to `export/` (`shots/…`, `media/…`) so agents
/// can drop that folder into a workspace.
struct ExportProjector {
    func project(
        sessionURL: URL,
        manifest: SessionManifest,
        includeFullTranscript: Bool = false
    ) throws -> ExportProjection {
        let fileManager = FileManager.default
        try resetExportTree(sessionURL: sessionURL)

        var omitted: [OmittedAsset] = []
        var projected = manifest
        var projectedShots: [ShotRecord] = []
        var projectedSlices: [SliceRecord] = []
        var projectedTasks: [TaskRecord] = []
        var placed: [String: String] = [:]

        for shot in manifest.shots {
            var copy = shot
            let stem = URL(fileURLWithPath: shot.rawPath).deletingPathExtension().lastPathComponent
            if let raw = try copyStill(
                from: sessionURL.appendingPathComponent(shot.rawPath),
                destRelative: "export/shots/\(stem).jpg",
                sessionURL: sessionURL,
                omitted: &omitted
            ) {
                copy.rawPath = ExportRel.toExportRoot(raw)
                placed[shot.rawPath] = copy.rawPath
            } else {
                copy.rawPath = ""
            }
            if let annotated = shot.annotatedPath {
                let dest = "export/shots/\(stem).annotated.jpg"
                if let placedAnnotated = try copyStill(
                    from: sessionURL.appendingPathComponent(annotated),
                    destRelative: dest,
                    sessionURL: sessionURL,
                    omitted: &omitted
                ) {
                    copy.annotatedPath = ExportRel.toExportRoot(placedAnnotated)
                    copy.exportPath = copy.annotatedPath
                    placed[annotated] = copy.annotatedPath ?? ExportRel.toExportRoot(placedAnnotated)
                } else {
                    copy.annotatedPath = nil
                }
            } else {
                copy.exportPath = copy.rawPath.isEmpty ? nil : copy.rawPath
            }
            if copy.exportPath == nil {
                copy.exportPath = copy.annotatedPath ?? (copy.rawPath.isEmpty ? nil : copy.rawPath)
            }
            projectedShots.append(copy)
        }

        var extraStillsCopied = 0
        for (index, slice) in manifest.slices.enumerated() {
            var copy = slice
            let ordinal = String(format: "%02d", index + 1)
            if let clip = slice.clipPath {
                let dest = "\(ScrumTracePath.media)/task-\(ordinal)/clip.mp4"
                if let placedClip = try copyIfPresent(
                    from: sessionURL.appendingPathComponent(clip),
                    to: sessionURL.appendingPathComponent(dest),
                    sessionURL: sessionURL,
                    omitted: &omitted
                ) {
                    let rel = ExportRel.toExportRoot(placedClip)
                    copy.exportClipPath = rel
                    copy.clipPath = rel
                    placed[clip] = rel
                } else {
                    copy.exportClipPath = nil
                    copy.clipPath = nil
                }
            }
            var exportStills: [String] = []
            for still in slice.stills {
                let name = URL(fileURLWithPath: still).lastPathComponent
                let destName: String
                if name.lowercased().hasSuffix(".png") {
                    destName = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + ".jpg"
                } else {
                    destName = name
                }
                let dest = "\(ScrumTracePath.media)/task-\(ordinal)/\(destName)"
                if let mapped = placed[still] {
                    exportStills.append(mapped)
                    continue
                }
                // Human shots are already in `placed`. Remaining stills are extras
                // (clip grabs). Cap those at MediaBudget.maxStills; 35 MB omit is later.
                if extraStillsCopied >= MediaBudget.maxStills {
                    omitted.append(OmittedAsset(
                        path: still,
                        reason: "Over extra-still budget (\(MediaBudget.maxStills))"
                    ))
                    continue
                }
                if let placedStill = try copyStill(
                    from: sessionURL.appendingPathComponent(still),
                    destRelative: dest,
                    sessionURL: sessionURL,
                    omitted: &omitted
                ) {
                    let rel = ExportRel.toExportRoot(placedStill)
                    exportStills.append(rel)
                    placed[still] = rel
                    extraStillsCopied += 1
                }
            }
            copy.stills = exportStills
            projectedSlices.append(copy)
        }

        for task in manifest.tasks {
            var copy = task
            copy.evidenceMedia = task.evidenceMedia.compactMap { path in
                if let mapped = placed[path] {
                    return mapped
                }
                if let mapped = placed[ExportRel.sessionPath(path)] {
                    return mapped
                }
                guard let exportCandidate = rewriteEvidence(path) else {
                    omitted.append(OmittedAsset(path: path, reason: "Not present under export/ after projection"))
                    return nil
                }
                let session = ExportRel.sessionPath(exportCandidate)
                if ExportRel.isUnderExport(session),
                   fileManager.fileExists(atPath: sessionURL.appendingPathComponent(session).path) {
                    return ExportRel.toExportRoot(session)
                }
                omitted.append(OmittedAsset(path: path, reason: "Not present under export/ after projection"))
                return nil
            }
            if copy.status == .confirmed && copy.evidenceMedia.isEmpty {
                copy.status = .needsReview
            }
            projectedTasks.append(copy)
        }

        projected.shots = projectedShots
        projected.slices = projectedSlices
        projected.tasks = projectedTasks
        projected.includeFullTranscriptInZip = includeFullTranscript

        if includeFullTranscript {
            let source = sessionURL.appendingPathComponent(ScrumTracePath.fullTranscript)
            _ = try copyIfPresent(
                from: source,
                to: sessionURL.appendingPathComponent("export/full_transcript.json"),
                sessionURL: sessionURL,
                omitted: &omitted
            )
        }

        projected.omitted = omitted.map {
            OmittedAsset(path: ExportRel.omittedHandoffPath($0.path), reason: $0.reason)
        }
        try writeProjectionManifest(projected, sessionURL: sessionURL)
        return ExportProjection(manifest: projected, omitted: projected.omitted)
    }

    /// C2/D5: rebuild `export/` from this projection. Stale `full_transcript.json`
    /// and orphan `media/` from a prior run must not survive into the zip.
    /// Never touches `archive/` or the canonical session-root manifest.
    private func resetExportTree(sessionURL: URL) throws {
        let fileManager = FileManager.default
        let export = sessionURL.appendingPathComponent(ScrumTracePath.export)
        if fileManager.fileExists(atPath: export.path) {
            try fileManager.removeItem(at: export)
        }
        try fileManager.createDirectory(at: export, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: sessionURL.appendingPathComponent(ScrumTracePath.exportShots),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: sessionURL.appendingPathComponent(ScrumTracePath.media),
            withIntermediateDirectories: true
        )
    }

    func writeProjectionManifest(_ manifest: SessionManifest, sessionURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: sessionURL.appendingPathComponent(ScrumTracePath.exportManifest))
    }

    private func rewriteEvidence(_ path: String) -> String? {
        if let handoff = ExportRel.handoffPath(path) {
            return handoff
        }
        guard let parts = ExportRel.normalizedComponents(path) else { return nil }
        if parts.first == "archive", parts.count >= 3, parts[1] == "shots" {
            let stem = URL(fileURLWithPath: parts.last ?? "").deletingPathExtension().lastPathComponent
            return "shots/\(stem).jpg"
        }
        if let idx = parts.firstIndex(of: "media-work"), idx + 1 < parts.count {
            return (["media"] + Array(parts[(idx + 1)...])).joined(separator: "/")
        }
        if parts.count == 1 {
            return "shots/\(parts[0])"
        }
        return nil
    }

    private func copyStill(
        from: URL,
        destRelative: String,
        sessionURL: URL,
        omitted: inout [OmittedAsset]
    ) throws -> String? {
        #if os(macOS)
        if FileManager.default.fileExists(atPath: from.path),
           let jpegRelative = try transcodeJPEG(from: from, destRelative: destRelative, sessionURL: sessionURL) {
            return jpegRelative
        }
        #endif
        let destIsJPEG = destRelative.lowercased().hasSuffix(".jpg") || destRelative.lowercased().hasSuffix(".jpeg")
        let sourceExt = from.pathExtension.lowercased()
        if destIsJPEG && sourceExt != "jpg" && sourceExt != "jpeg" {
            omitted.append(
                OmittedAsset(
                    path: destRelative,
                    reason: "JPEG transcode failed; refusing to copy \(sourceExt) bytes as JPEG"
                )
            )
            return nil
        }
        return try copyIfPresent(
            from: from,
            to: sessionURL.appendingPathComponent(destRelative),
            sessionURL: sessionURL,
            omitted: &omitted
        )
    }

    #if os(macOS)
    private func transcodeJPEG(from: URL, destRelative: String, sessionURL: URL) throws -> String? {
        let prefix = sessionURL.path.hasSuffix("/") ? sessionURL.path : sessionURL.path + "/"
        guard from.path.hasPrefix(prefix) else { return nil }
        let fromRel = String(from.path.dropFirst(prefix.count))
        guard ExportRel.containedRelative(fromRel, sessionURL: sessionURL) != nil,
              let destRel = ExportRel.containedRelative(destRelative, sessionURL: sessionURL) else {
            return nil
        }
        guard let image = NSImage(contentsOf: from) else { return nil }
        guard let jpeg = ImageBase64.jpegData(
            from: image,
            maxEdge: CGFloat(MediaBudget.stillMaxWidth),
            quality: MediaBudget.stillJPEGQuality
        ) else { return nil }
        let dest = sessionURL.appendingPathComponent(destRel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try jpeg.write(to: dest)
        return destRel
    }
    #endif

    private func copyIfPresent(
        from: URL,
        to: URL,
        sessionURL: URL,
        omitted: inout [OmittedAsset]
    ) throws -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: from.path) else {
            omitted.append(OmittedAsset(path: from.lastPathComponent, reason: "Source missing in archive"))
            return nil
        }
        let prefix = sessionURL.path.hasSuffix("/") ? sessionURL.path : sessionURL.path + "/"
        guard from.path.hasPrefix(prefix), to.path.hasPrefix(prefix) else {
            omitted.append(OmittedAsset(path: to.lastPathComponent, reason: "Copy path is outside the session folder"))
            return nil
        }
        let fromRel = String(from.path.dropFirst(prefix.count))
        let toRel = String(to.path.dropFirst(prefix.count))
        guard ExportRel.containedRelative(fromRel, sessionURL: sessionURL) != nil,
              ExportRel.containedRelative(toRel, sessionURL: sessionURL) != nil else {
            omitted.append(OmittedAsset(path: to.lastPathComponent, reason: "Copy path escaped the session folder"))
            return nil
        }
        try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: to.path) {
            try fileManager.removeItem(at: to)
        }
        try fileManager.copyItem(at: from, to: to)
        return toRel
    }
}
