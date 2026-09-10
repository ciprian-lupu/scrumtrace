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
        if let clip = slice.exportClipPath ?? slice.clipPath {
            allowed.append(clip)
        }
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

    private static func shotOwning(_ path: String, in shots: [ShotRecord]) -> ShotRecord? {
        shots.first { shot in
            let paths = shot.stillCandidates
                + [shot.rawPath]
                + [shot.annotatedPath, shot.exportPath].compactMap { $0 }
            return paths.contains { candidate in
                !candidate.isEmpty && (candidate == path || isSameSessionPath(path, candidate))
            }
        }
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
        if let clip = slice.exportClipPath ?? slice.clipPath, isSameSessionPath(path, clip) {
            return true
        }
        return false
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
            copy.evidenceMedia = task.evidenceMedia.filter { path in
                guard ExportRel.packMediaHandoff(path, sessionURL: sessionURL, omitted: omitted) != nil else {
                    return false
                }
                guard let slice = sliceById[task.sourceSliceId] else {
                    return true
                }
                if framesOverlapSlice([path], slice: slice, shots: shots, sessionURL: sessionURL) {
                    return true
                }
                // D7: a merge-clamped Shot review row has only that Shot's
                // stills. Keep them. A row that cited this slice's clip — even
                // if omit later deleted the MP4 — must not keep another
                // moment's PNG (C5).
                guard let owner = shotOwning(path, in: shots),
                      owner.tMedia < slice.startMedia || owner.tMedia > slice.endMedia else {
                    return false
                }
                return !task.evidenceMedia.contains { other in
                    citesSliceWindow(
                        other,
                        slice: slice,
                        shots: shots,
                        sessionURL: sessionURL
                    )
                }
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
