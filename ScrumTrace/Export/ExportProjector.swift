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
                fromRelative: shot.rawPath,
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
                    fromRelative: annotated,
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
                    fromRelative: clip,
                    destRelative: dest,
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
                    fromRelative: still,
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
                   ExportRel.existingSessionFile(session, sessionURL: sessionURL) != nil {
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
            _ = try copyIfPresent(
                fromRelative: ScrumTracePath.fullTranscript,
                destRelative: "export/full_transcript.json",
                sessionURL: sessionURL,
                omitted: &omitted
            )
        }

        projected.omitted = omitted.map {
            OmittedAsset(path: ExportRel.omittedHandoffPath($0.path), reason: $0.reason)
        }
        PackBudget.removeEscapingExportLinks(
            exportDir: sessionURL.appendingPathComponent(ScrumTracePath.export)
        )
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
        let data = try encoder.encode(manifest)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionVaultError.writeFailed(ScrumTracePath.exportManifest)
        }
        try ExportRel.writeExportText(text, relative: ScrumTracePath.exportManifest, sessionURL: sessionURL)
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
        fromRelative: String,
        destRelative: String,
        sessionURL: URL,
        omitted: inout [OmittedAsset]
    ) throws -> String? {
        guard let fromRel = ExportRel.existingSessionFile(fromRelative, sessionURL: sessionURL) else {
            omitted.append(unreadableSource(fromRelative, sessionURL: sessionURL))
            return nil
        }
        let from = sessionURL.appendingPathComponent(fromRel)
        #if os(macOS)
        if let jpegRelative = try transcodeJPEG(from: from, destRelative: destRelative, sessionURL: sessionURL) {
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
            fromRelative: fromRel,
            destRelative: destRelative,
            sessionURL: sessionURL,
            omitted: &omitted
        )
    }

    #if os(macOS)
    private func transcodeJPEG(from: URL, destRelative: String, sessionURL: URL) throws -> String? {
        guard ExportRel.isContainedRegularFile(from, sessionRoot: sessionURL),
              let destRel = ExportRel.containedRelative(destRelative, sessionURL: sessionURL),
              ExportRel.isUnderExport(destRel) else {
            return nil
        }
        guard let image = NSImage(contentsOf: from) else { return nil }
        guard let jpeg = ImageBase64.jpegData(
            from: image,
            maxEdge: CGFloat(MediaBudget.stillMaxWidth),
            quality: MediaBudget.stillJPEGQuality
        ) else { return nil }
        do {
            try ExportRel.writeContainedData(jpeg, relative: destRel, sessionURL: sessionURL)
            return destRel
        } catch {
            return nil
        }
    }
    #endif

    private func unreadableSource(_ relative: String, sessionURL: URL) -> OmittedAsset {
        let url = sessionURL.appendingPathComponent(relative)
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if isLink || ExportRel.containsSymlinkComponent(relative, sessionURL: sessionURL) {
            return OmittedAsset(path: relative, reason: "Source is not a contained regular file")
        }
        return OmittedAsset(path: relative, reason: "Source missing in archive")
    }

    private func copyIfPresent(
        fromRelative: String,
        destRelative: String,
        sessionURL: URL,
        omitted: inout [OmittedAsset]
    ) throws -> String? {
        guard let fromRel = ExportRel.existingSessionFile(fromRelative, sessionURL: sessionURL) else {
            omitted.append(unreadableSource(fromRelative, sessionURL: sessionURL))
            return nil
        }
        let destSession = ExportRel.sessionPath(destRelative)
        guard ExportRel.isUnderExport(destSession) else {
            omitted.append(OmittedAsset(path: destRelative, reason: "Copy destination escaped export/"))
            return nil
        }
        let prepared: String
        do {
            prepared = try ExportRel.prepareContainedWrite(relative: destSession, sessionURL: sessionURL)
        } catch {
            omitted.append(OmittedAsset(path: destRelative, reason: "Copy destination escaped export/"))
            return nil
        }
        let from = sessionURL.appendingPathComponent(fromRel)
        let dest = sessionURL.appendingPathComponent(prepared)
        if (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            omitted.append(OmittedAsset(path: destRelative, reason: "Copy destination escaped export/"))
            return nil
        }
        if ExportRel.isContainedRegularFile(dest, sessionRoot: sessionURL) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: from, to: dest)
        return prepared
    }
}
