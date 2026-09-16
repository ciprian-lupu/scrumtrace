import Foundation

struct MeetingSlicer {
    func slice(
        shots: [ShotRecord],
        pins: [TimeInterval],
        transcript: FullTranscript,
        mediaDuration: TimeInterval
    ) -> [SliceRecord] {
        var candidates: [SliceRecord] = []
        for shot in shots {
            let window = TimelineMath.clampMediaWindow(
                center: shot.tMedia,
                duration: MediaBudget.clipMeanDuration,
                mediaDuration: mediaDuration
            )
            candidates.append(
                SliceRecord(
                    sliceId: "",
                    startMedia: window.start,
                    endMedia: window.end,
                    trigger: .shot,
                    associatedShotId: shot.id,
                    clipPath: nil,
                    stills: shot.stillCandidates,
                    analysisStatus: .pending,
                    score: 100
                )
            )
        }
        for pin in pins {
            let window = TimelineMath.clampMediaWindow(
                center: pin,
                duration: MediaBudget.clipMeanDuration,
                mediaDuration: mediaDuration
            )
            candidates.append(
                SliceRecord(
                    sliceId: "",
                    startMedia: window.start,
                    endMedia: window.end,
                    trigger: .pin,
                    associatedShotId: nil,
                    clipPath: nil,
                    stills: [],
                    analysisStatus: .pending,
                    score: 80
                )
            )
        }
        for planned in TranscriptWindowPlanner().plan(transcript: transcript, mediaDuration: mediaDuration) {
            candidates.append(
                SliceRecord(
                    sliceId: "",
                    startMedia: planned.startMedia,
                    endMedia: planned.endMedia,
                    trigger: .keyword,
                    associatedShotId: nil,
                    clipPath: nil,
                    stills: [],
                    analysisStatus: .pending,
                    score: 40 + planned.score
                )
            )
        }
        let merged = Self.mergeOverlapping(candidates, mediaDuration: mediaDuration)
        let capped = selectForCoverage(merged, mediaDuration: mediaDuration)
        return capped.enumerated().map { index, slice in
            var copy = slice
            let ordinal = index + 1
            copy.sliceId = String(format: "slice-%02d", ordinal)
            let folder = "archive/media-work/task-\(String(format: "%02d", ordinal))"
            copy.clipPath = "\(folder)/clip.mp4"
            return copy
        }
    }

    /// Human Shot stills stay on the merged slice even when the later window
    /// loses the clip center (D7). Unique paths, first-seen order.
    static func unionStills(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in lhs + rhs {
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            out.append(path)
        }
        return out
    }

    /// Internal for XCTest coverage. The preferred window is chosen from the
    /// original pair before `last` is mutated, so a later higher-priority Shot
    /// cannot lose its center merely because its score was copied first.
    static func mergeOverlapping(_ slices: [SliceRecord], mediaDuration: TimeInterval) -> [SliceRecord] {
        let sorted = slices.sorted {
            $0.startMedia == $1.startMedia ? $0.sliceId < $1.sliceId : $0.startMedia < $1.startMedia
        }
        var result: [SliceRecord] = []
        for slice in sorted {
            if var last = result.last, overlaps(last, slice) {
                let originalLast = last
                let preferred = preferredWindow(originalLast, slice)
                last.stills = Self.unionStills(last.stills, slice.stills)
                last.trigger = preferred.trigger
                last.associatedShotId = preferred.associatedShotId ?? originalLast.associatedShotId ?? slice.associatedShotId
                last.score = max(originalLast.score, slice.score)
                let combinedStart = min(last.startMedia, slice.startMedia)
                let combinedEnd = max(last.endMedia, slice.endMedia)
                if combinedEnd - combinedStart <= MediaBudget.clipMaxDuration {
                    last.startMedia = combinedStart
                    last.endMedia = combinedEnd
                } else {
                    let center = (preferred.startMedia + preferred.endMedia) / 2
                    let window = TimelineMath.clampMediaWindow(
                        center: center,
                        duration: MediaBudget.clipMaxDuration,
                        mediaDuration: mediaDuration
                    )
                    last.startMedia = window.start
                    last.endMedia = window.end
                }
                result[result.count - 1] = last
            } else {
                result.append(slice)
            }
        }
        return result
    }

    private static func preferredWindow(_ lhs: SliceRecord, _ rhs: SliceRecord) -> SliceRecord {
        if lhs.score != rhs.score { return lhs.score > rhs.score ? lhs : rhs }
        let leftPriority = triggerPriority(lhs.trigger)
        let rightPriority = triggerPriority(rhs.trigger)
        if leftPriority != rightPriority { return leftPriority > rightPriority ? lhs : rhs }
        // Equal-priority anchors are stable by timeline rather than collection
        // insertion order. This is important when a decoded manifest is rebuilt.
        if lhs.startMedia != rhs.startMedia { return lhs.startMedia < rhs.startMedia ? lhs : rhs }
        return (lhs.associatedShotId ?? "") <= (rhs.associatedShotId ?? "") ? lhs : rhs
    }

    private static func triggerPriority(_ trigger: SliceTrigger) -> Int {
        switch trigger {
        case .shot: return 3
        case .pin: return 2
        case .keyword: return 1
        }
    }

    private static func overlaps(_ a: SliceRecord, _ b: SliceRecord) -> Bool {
        a.startMedia < b.endMedia && b.startMedia < a.endMedia
    }

    /// Human anchors arrive first. Automatic candidates then receive a modest
    /// marginal bonus for an uncovered timeline region; no empty region creates
    /// a slice and all ties are stable.
    private func selectForCoverage(_ merged: [SliceRecord], mediaDuration: TimeInterval) -> [SliceRecord] {
        let ordered = merged.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.startMedia != $1.startMedia { return $0.startMedia < $1.startMedia }
            return ($0.associatedShotId ?? "") < ($1.associatedShotId ?? "")
        }
        var selected: [SliceRecord] = []
        for candidate in ordered where candidate.trigger == .shot || candidate.trigger == .pin {
            guard selected.count < MediaBudget.maxCandidateSlices else { break }
            selected.append(candidate)
        }
        var remaining = ordered.filter { candidate in
            !selected.contains { $0.startMedia == candidate.startMedia && $0.endMedia == candidate.endMedia && $0.score == candidate.score && $0.associatedShotId == candidate.associatedShotId }
        }
        let bins = max(1, min(6, Int((mediaDuration / 8 / 60).rounded(.up))))
        while selected.count < MediaBudget.maxCandidateSlices, !remaining.isEmpty {
            let covered = Set(selected.map { min(bins - 1, max(0, Int(($0.startMedia / max(mediaDuration, 1)) * Double(bins)))) })
            let bestIndex = remaining.indices.max { left, right in
                let lhs = remaining[left]
                let rhs = remaining[right]
                let leftBin = min(bins - 1, max(0, Int((lhs.startMedia / max(mediaDuration, 1)) * Double(bins))))
                let rightBin = min(bins - 1, max(0, Int((rhs.startMedia / max(mediaDuration, 1)) * Double(bins))))
                let leftScore = lhs.score + (covered.contains(leftBin) ? 0 : 3)
                let rightScore = rhs.score + (covered.contains(rightBin) ? 0 : 3)
                if leftScore != rightScore { return leftScore < rightScore }
                if lhs.startMedia != rhs.startMedia { return lhs.startMedia > rhs.startMedia }
                return (lhs.associatedShotId ?? "") > (rhs.associatedShotId ?? "")
            }!
            selected.append(remaining.remove(at: bestIndex))
        }
        return selected
    }
}
