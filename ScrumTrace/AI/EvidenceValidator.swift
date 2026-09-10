import Foundation

struct EvidenceIssue: Sendable, Hashable {
    var reason: String
}

enum EvidenceValidator {
    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func quoteMatchesTranscript(_ quote: QuoteRecord, transcript: FullTranscript) -> Bool {
        let needle = normalize(quote.text)
        guard !needle.isEmpty else { return false }
        return transcript.segments.contains { segment in
            segment.end >= quote.tMediaStart
                && segment.start <= quote.tMediaEnd
                && normalize(segment.text).contains(needle)
        }
    }

    /// Model `frame_references` are untrusted strings: basename, `shots/…`, or archive paths.
    static func resolvePath(_ path: String, sessionURL: URL) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        var tries: [String] = [
            trimmed,
            ExportRel.sessionPath(trimmed),
            "archive/shots/\(name)",
            "archive/shots/\(stem).png",
            "archive/shots/\(stem).annotated.png",
            "export/shots/\(stem).jpg",
            "export/shots/\(stem).annotated.jpg"
        ]
        if trimmed.hasPrefix("./") {
            tries.insert(String(trimmed.dropFirst(2)), at: 1)
        }
        var seen = Set<String>()
        for rel in tries where seen.insert(rel).inserted {
            if let existing = ExportRel.existingSessionFile(rel, sessionURL: sessionURL),
               ExportRel.isVisualEvidence(existing) {
                return existing
            }
        }
        for folder in [ScrumTracePath.shots, ScrumTracePath.mediaWork, ScrumTracePath.exportShots, ScrumTracePath.media] {
            if ExportRel.containsSymlinkComponent(folder, sessionURL: sessionURL) {
                continue
            }
            if let match = firstMatch(name: name, stem: stem, in: sessionURL.appendingPathComponent(folder), sessionURL: sessionURL),
               ExportRel.isVisualEvidence(match) {
                return match
            }
        }
        return nil
    }

    static func existingPaths(_ paths: [String], sessionURL: URL) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths {
            guard let resolved = resolvePath(path, sessionURL: sessionURL) else { continue }
            if seen.insert(resolved).inserted {
                out.append(resolved)
            }
        }
        return out
    }

    static func canConfirm(
        candidate: CandidateRecord,
        slice: SliceRecord,
        transcript: FullTranscript,
        sessionURL: URL,
        shots: [ShotRecord] = []
    ) -> [EvidenceIssue] {
        var issues: [EvidenceIssue] = []
        if candidate.decision != .keep {
            issues.append(EvidenceIssue(reason: "decision is not keep"))
        }
        if candidate.confidence < MediaBudget.keepConfidenceFloor {
            issues.append(EvidenceIssue(reason: "confidence below 0.55"))
        }
        let inferred = normalize(candidate.inferred)
        if !inferred.isEmpty {
            if normalize(candidate.observed) == inferred || normalize(candidate.stated) == inferred {
                issues.append(EvidenceIssue(reason: "inferred copied into observed/stated"))
            }
        }
        let frames = existingPaths(candidate.frameReferences, sessionURL: sessionURL)
            .filter { !ownedByOtherAssociatedShot($0, slice: slice, shots: shots) }
        if frames.isEmpty {
            issues.append(EvidenceIssue(reason: "no valid frame_references on disk"))
        } else if !framesOverlapSlice(frames, slice: slice, shots: shots, sessionURL: sessionURL) {
            issues.append(EvidenceIssue(reason: "frame_references outside this slice window"))
        }
        for quote in candidate.quotes {
            if quote.tMediaStart > quote.tMediaEnd {
                issues.append(EvidenceIssue(reason: "quote times are inverted"))
                continue
            }
            if quote.tMediaEnd < slice.startMedia || quote.tMediaStart > slice.endMedia {
                issues.append(EvidenceIssue(reason: "quote outside slice window"))
            }
            if !quoteMatchesTranscript(quote, transcript: transcript) {
                issues.append(EvidenceIssue(reason: "quote not found in transcript window"))
            }
        }
        if slice.sliceId.isEmpty {
            issues.append(EvidenceIssue(reason: "missing source_slice_id"))
        }
        if candidate.kind == .unknown {
            issues.append(EvidenceIssue(reason: "unknown task kind"))
        }
        return issues
    }

    /// C5: a still from another moment is not evidence for this slice, even
    /// when the PNG exists under archive/shots. After overlap-merge clamps the
    /// window, unioned Shot stills whose `t_media` fell outside are dropped.
    static func framesOverlapSlice(
        _ frames: [String],
        slice: SliceRecord,
        shots: [ShotRecord],
        sessionURL: URL
    ) -> Bool {
        var allowed: [String] = []
        allowed.append(contentsOf: sliceClipPaths(slice))
        for still in slice.stills {
            if let owner = shotOwning(still, in: shots) {
                if owner.tMedia < slice.startMedia || owner.tMedia > slice.endMedia {
                    continue
                }
                allowed.append(still)
                continue
            }
            // Unowned `shots/` paths belong to a Shot that was not matched
            // in this list. Do not treat them as this window (C5). Clip-grab
            // extras live under media-work / media, not shots/.
            if !shots.isEmpty {
                let contained = (ExportRel.existingSessionFile(still, sessionURL: sessionURL) ?? still)
                    .lowercased()
                if contained.contains("shots/") {
                    continue
                }
            }
            allowed.append(still)
        }
        for shot in shots {
            guard shot.tMedia >= slice.startMedia && shot.tMedia <= slice.endMedia else { continue }
            allowed.append(contentsOf: shot.stillCandidates)
            if let exportPath = shot.exportPath {
                allowed.append(exportPath)
            }
            if !shot.rawPath.isEmpty {
                allowed.append(shot.rawPath)
            }
            if let annotated = shot.annotatedPath {
                allowed.append(annotated)
            }
        }
        let allowedResolved = Set(existingPaths(allowed, sessionURL: sessionURL))
        let allowedContained = Set(allowed.compactMap { ExportRel.existingSessionFile($0, sessionURL: sessionURL) })
        return frames.contains { frame in
            allowedResolved.contains(frame) || allowedContained.contains(frame)
        }
    }

    /// A stale `export_clip_path` must not hide the archive clip after omit (C5).
    static func sliceClipPaths(_ slice: SliceRecord) -> [String] {
        var paths: [String] = []
        if let exported = slice.exportClipPath, !exported.isEmpty {
            paths.append(exported)
        }
        if let clip = slice.clipPath, !clip.isEmpty, !paths.contains(clip) {
            paths.append(clip)
        }
        return paths
    }

    /// C3: leftover omit matches files under `export/`. A stale
    /// `export_clip_path` must not hide `clip_path`'s mapped export MP4.
    static func exportRelativeClipPaths(for slice: SliceRecord) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in sliceClipPaths(slice) {
            if let mapped = ExportRel.mediaWorkToExportClip(path), seen.insert(mapped).inserted {
                out.append(mapped)
            }
        }
        return out
    }

    /// C3: a stale `export_path` must not hide annotated/raw JPEG under `export/shots/`.
    static func exportRelativeStillPaths(for shot: ShotRecord) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        var candidates: [String] = []
        if let exported = shot.exportPath, !exported.isEmpty {
            candidates.append(exported)
        }
        if let annotated = shot.annotatedPath, !annotated.isEmpty {
            candidates.append(annotated)
        }
        if !shot.rawPath.isEmpty {
            candidates.append(shot.rawPath)
        }
        for path in candidates {
            if let mapped = ExportRel.shotsArchiveToExport(path), seen.insert(mapped).inserted {
                out.append(mapped)
            }
        }
        return out
    }

    /// Task `evidence_media` may still be archive-relative when omit runs.
    static func exportRelativeHandoffPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func append(_ path: String) {
            guard seen.insert(path).inserted else { return }
            out.append(path)
        }
        for path in paths {
            append(ExportRel.sessionPath(path))
            if let mapped = ExportRel.mediaWorkToExport(path) {
                append(mapped)
            }
            if let mapped = ExportRel.shotsArchiveToExport(path) {
                append(mapped)
            }
        }
        return out
    }

    /// Shot JPEGs, PNGs, and `001.annotated.jpg` collapse to the same stem so
    /// mergeUncoveredReview does not emit a second D7 row for the annotated twin.
    static func shotStillStem(_ path: String) -> String? {
        guard path.lowercased().contains("shots/") else { return nil }
        var stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let suffix = ".annotated"
        if stem.lowercased().hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        return stem.isEmpty ? nil : stem
    }

    private static func shotOwning(_ path: String, in shots: [ShotRecord]) -> ShotRecord? {
        shots.first { shot in
            let paths = shot.stillCandidates
                + [shot.rawPath]
                + [shot.annotatedPath, shot.exportPath].compactMap { $0 }
            if paths.contains { candidate in
                !candidate.isEmpty && (candidate == path || isSameSessionPath(path, candidate))
            } {
                return true
            }
            guard let want = shotStillStem(path) else { return false }
            return paths.contains { candidate in
                shotStillStem(candidate) == want
            }
        }
    }

    /// C5: an evaluated candidate belongs to `associated_shot_id`. Another
    /// merged in-window Shot's PNG is not this candidate's evidence (D7 rows
    /// cover that Shot). A keyword or pin window with no associated Shot must
    /// not inherit every in-window Shot still either. Match archive and
    /// export path forms.
    static func ownedByOtherAssociatedShot(
        _ still: String,
        slice: SliceRecord,
        shots: [ShotRecord]
    ) -> Bool {
        guard let owner = shotOwning(still, in: shots) else { return false }
        guard let associated = slice.associatedShotId else { return true }
        return owner.id != associated
    }

    /// Clip path still counts as this window after omit deletes the MP4.
    private static func citesSliceWindow(
        _ path: String,
        slice: SliceRecord,
        shots: [ShotRecord],
        sessionURL: URL
    ) -> Bool {
        if framesOverlapSlice([path], slice: slice, shots: shots, sessionURL: sessionURL) {
            return true
        }
        return sliceClipPaths(slice).contains { isSameSessionPath(path, $0) }
    }

    private static func isSameSessionPath(_ lhs: String, _ rhs: String) -> Bool {
        ExportRel.sessionPath(lhs) == ExportRel.sessionPath(rhs)
            || ExportRel.toExportRoot(ExportRel.sessionPath(lhs))
                == ExportRel.toExportRoot(ExportRel.sessionPath(rhs))
    }

    /// C5: after projection/omit, `confirmed` requires a real file under `export/`.
    /// Quotes are re-checked (inverted times, slice window, transcript overlap)
    /// so a demotion at zip time cannot leave a `confirmed` row without evidence.
    static func applyExportEvidence(
        tasks: [TaskRecord],
        sessionURL: URL,
        transcript: FullTranscript? = nil,
        slices: [SliceRecord] = [],
        shots: [ShotRecord] = [],
        omitted: [OmittedAsset] = []
    ) -> [TaskRecord] {
        let sliceById = Dictionary(slices.map { ($0.sliceId, $0) }, uniquingKeysWith: { _, latest in latest })
        return tasks.map { task in
            var copy = task
            var seen = Set<String>()
            copy.evidenceMedia = task.evidenceMedia.compactMap { path -> String? in
                let packed: String?
                if let rel = ExportRel.packMediaHandoff(path, sessionURL: sessionURL, omitted: omitted) {
                    packed = rel
                } else if task.status != .confirmed {
                    packed = reviewPackHandoff(path, sessionURL: sessionURL, omitted: omitted)
                } else {
                    packed = nil
                }
                guard let packed, seen.insert(packed).inserted else { return nil }
                guard let slice = sliceById[task.sourceSliceId] else {
                    return packed
                }
                if framesOverlapSlice([path, packed], slice: slice, shots: shots, sessionURL: sessionURL) {
                    if task.status == .confirmed,
                       ownedByOtherAssociatedShot(path, slice: slice, shots: shots)
                        || ownedByOtherAssociatedShot(packed, slice: slice, shots: shots) {
                        return nil
                    }
                    return packed
                }
                // D7: a merge-clamped Shot review row has only that Shot's
                // stills. Keep them. A row that cited this slice's clip — even
                // if omit later deleted the MP4 — must not keep another
                // moment's PNG (C5).
                guard let owner = shotOwning(path, in: shots) ?? shotOwning(packed, in: shots),
                      owner.tMedia < slice.startMedia || owner.tMedia > slice.endMedia else {
                    return nil
                }
                let citedClip = task.evidenceMedia.contains { other in
                    citesSliceWindow(
                        other,
                        slice: slice,
                        shots: shots,
                        sessionURL: sessionURL
                    )
                }
                return citedClip ? nil : packed
            }
            if copy.status == .confirmed {
                if copy.evidenceMedia.isEmpty || copy.sourceSliceId.isEmpty {
                    copy.status = .needsReview
                } else if copy.confidence < MediaBudget.keepConfidenceFloor {
                    copy.status = .needsReview
                } else {
                    if !copy.quotes.isEmpty, sliceById[copy.sourceSliceId] == nil {
                        copy.status = .needsReview
                    }
                    for quote in copy.quotes {
                        if quote.tMediaStart > quote.tMediaEnd {
                            copy.status = .needsReview
                            break
                        }
                        if let slice = sliceById[copy.sourceSliceId],
                           quote.tMediaEnd < slice.startMedia || quote.tMediaStart > slice.endMedia {
                            copy.status = .needsReview
                            break
                        }
                        // C5: quotes must hit a transcript segment. Missing
                        // transcript cannot keep `confirmed`.
                        guard let transcript else {
                            copy.status = .needsReview
                            break
                        }
                        if !quoteMatchesTranscript(quote, transcript: transcript) {
                            copy.status = .needsReview
                            break
                        }
                    }
                }
                let inferred = normalize(copy.inferred)
                if copy.status == .confirmed, !inferred.isEmpty {
                    if normalize(copy.observed) == inferred || normalize(copy.stated) == inferred {
                        copy.status = .needsReview
                    }
                }
            }
            return copy
        }
    }

    /// D7: `needs_review` may still name archive stills after JPEG transcode.
    /// `confirmed` must not use that mapping — a same-stem export JPEG can
    /// belong to another task (C2/C5).
    private static func reviewPackHandoff(
        _ path: String,
        sessionURL: URL,
        omitted: [OmittedAsset]
    ) -> String? {
        for candidate in exportRelativeHandoffPaths([path]) {
            if let rel = ExportRel.packMediaHandoff(candidate, sessionURL: sessionURL, omitted: omitted) {
                return rel
            }
        }
        return nil
    }

    /// D10: canonical `session.manifest.json` keeps archive evidence paths.
    /// C5: status still follows the export projection after omit/demotion.
    static func mergeCanonicalStatuses(
        canonical: [TaskRecord],
        projected: [TaskRecord]
    ) -> [TaskRecord] {
        let byId = Dictionary(projected.map { ($0.taskId, $0) }, uniquingKeysWith: { _, latest in latest })
        return canonical.map { task in
            var copy = task
            if let projected = byId[task.taskId] {
                copy.status = projected.status
            } else if copy.status == .confirmed {
                copy.status = .needsReview
            }
            return copy
        }
    }

    static func exportFileExists(_ path: String, sessionURL: URL) -> Bool {
        guard let relative = ExportRel.existingSessionFile(ExportRel.sessionPath(path), sessionURL: sessionURL) else {
            return false
        }
        return ExportRel.isUnderExport(relative)
    }

    private static func firstMatch(name: String, stem: String, in root: URL, sessionURL: URL) -> String? {
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
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
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if url.lastPathComponent == name || url.deletingPathExtension().lastPathComponent == stem {
                guard let rel = ExportRel.unfollowedRelative(url, sessionRoot: sessionURL),
                      !ExportRel.containsSymlinkComponent(rel, sessionURL: sessionURL),
                      let existing = ExportRel.existingSessionFile(rel, sessionURL: sessionURL) else {
                    continue
                }
                return existing
            }
        }
        return nil
    }
}
