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
                if let placedStill = try copyStill(
                    from: sessionURL.appendingPathComponent(still),
                    destRelative: dest,
                    sessionURL: sessionURL,
                    omitted: &omitted
                ) {
                    let rel = ExportRel.toExportRoot(placedStill)
                    exportStills.append(rel)
                    placed[still] = rel
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
                let exportCandidate = rewriteEvidence(path)
                if fileManager.fileExists(atPath: sessionURL.appendingPathComponent(ExportRel.sessionPath(exportCandidate)).path) {
                    return ExportRel.toExportRoot(exportCandidate)
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

        projected.omitted = omitted
        try writeProjectionManifest(projected, sessionURL: sessionURL)
        return ExportProjection(manifest: projected, omitted: omitted)
    }

    func writeProjectionManifest(_ manifest: SessionManifest, sessionURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: sessionURL.appendingPathComponent(ScrumTracePath.exportManifest))
    }

    private func rewriteEvidence(_ path: String) -> String {
        if path.hasPrefix("export/") || !path.contains("/") {
            return ExportRel.toExportRoot(path)
        }
        if path.hasPrefix("archive/shots/") {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return "shots/\(name).jpg"
        }
        if path.contains("media-work") {
            return path.replacingOccurrences(of: "archive/media-work/", with: "media/")
        }
        return "shots/\(URL(fileURLWithPath: path).lastPathComponent)"
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
        return try copyIfPresent(
            from: from,
            to: sessionURL.appendingPathComponent(destRelative),
            sessionURL: sessionURL,
            omitted: &omitted
        )
    }

    #if os(macOS)
    private func transcodeJPEG(from: URL, destRelative: String, sessionURL: URL) throws -> String? {
        guard let image = NSImage(contentsOf: from) else { return nil }
        let size = image.size
        let scale = min(1, CGFloat(MediaBudget.stillMaxWidth) / max(size.width, size.height, 1))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let bitmap = NSImage(size: target)
        bitmap.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        bitmap.unlockFocus()
        guard let tiff = bitmap.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: MediaBudget.stillJPEGQuality]
              ) else {
            return nil
        }
        let dest = sessionURL.appendingPathComponent(destRelative)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try jpeg.write(to: dest)
        return destRelative
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
        try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: to.path) {
            try fileManager.removeItem(at: to)
        }
        try fileManager.copyItem(at: from, to: to)
        let prefix = sessionURL.path.hasSuffix("/") ? sessionURL.path : sessionURL.path + "/"
        return to.path.replacingOccurrences(of: prefix, with: "")
    }
}
