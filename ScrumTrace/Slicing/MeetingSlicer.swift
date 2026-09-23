import CryptoKit
import Foundation

struct MeetingSlicer {
    func slice(
        shots: [ShotRecord],
        pins: [TimeInterval],
        transcript: FullTranscript,
        mediaDuration: TimeInterval
    ) -> [SliceRecord] {
        guard mediaDuration.isFinite, mediaDuration > 0 else { return [] }
        var candidates: [SliceRecord] = []
        for shot in shots where shot.tMedia.isFinite && shot.tMedia >= 0 && shot.tMedia <= mediaDuration {
            let window = TimelineMath.clampMediaWindow(center: shot.tMedia, duration: MediaBudget.clipMeanDuration, mediaDuration: mediaDuration)
            candidates.append(SliceRecord(sliceId: "", startMedia: window.start, endMedia: window.end, trigger: .shot, associatedShotId: shot.id, clipPath: nil, stills: shot.stillCandidates, analysisStatus: .pending, score: 100, anchorIds: [shot.id]))
        }
        let sortedPins = pins.filter { $0.isFinite && $0 >= 0 && $0 <= mediaDuration }.sorted()
        let pinRows = LocalProcedureBuilder.pinRows(sortedPins)
        for pin in pinRows {
            let window = TimelineMath.clampMediaWindow(center: pin.time, duration: MediaBudget.clipMeanDuration, mediaDuration: mediaDuration)
            candidates.append(SliceRecord(sliceId: "", startMedia: window.start, endMedia: window.end, trigger: .pin, associatedShotId: nil, clipPath: nil, stills: [], analysisStatus: .pending, score: 80, anchorIds: [pin.id]))
        }
        let procedure = LocalProcedureBuilder.build(transcript: transcript, shots: shots, pins: sortedPins, slices: [], duration: mediaDuration, context: .empty)
        for step in procedure.steps where step.kind == "action_excerpt" {
            let center = (step.start + step.end) / 2
            let window = TimelineMath.clampMediaWindow(center: center, duration: MediaBudget.clipMeanDuration, mediaDuration: mediaDuration)
            candidates.append(SliceRecord(sliceId: "", startMedia: window.start, endMedia: window.end, trigger: .keyword, associatedShotId: step.shotIds.first, clipPath: nil, stills: shots.filter { step.shotIds.contains($0.id) }.flatMap(\.stillCandidates), analysisStatus: .pending, score: 40, anchorIds: [step.id] + step.shotIds + step.pinIds))
        }
        let occupied = occupiedBins(transcript: transcript, duration: mediaDuration)
        for bin in occupied {
            let center = mediaDuration * (Double(bin) + 0.5) / 12
            let window = TimelineMath.clampMediaWindow(center: center, duration: MediaBudget.clipMeanDuration, mediaDuration: mediaDuration)
            let represented = candidates.contains { $0.startMedia < window.end && $0.endMedia > window.start }
            if !represented {
                candidates.append(SliceRecord(sliceId: "", startMedia: window.start, endMedia: window.end, trigger: .keyword, associatedShotId: nil, clipPath: nil, stills: [], analysisStatus: .pending, score: 1, anchorIds: []))
            }
        }
        let merged = mergeOverlapping(candidates, mediaDuration: mediaDuration)
        let humanAnchorIDs = Set(shots.filter { $0.tMedia.isFinite && $0.tMedia >= 0 && $0.tMedia <= mediaDuration }.map(\.id) + pinRows.map(\.id))
        let actionStepIDs = Set(procedure.steps.filter { $0.kind == "action_excerpt" }.map(\.id))
        let selected = coverageSelection(merged, transcript: transcript, duration: mediaDuration, humanAnchorIDs: humanAnchorIDs, actionStepIDs: actionStepIDs)
        return selected.enumerated().map { index, item in
            var copy = item
            let ordinal = index + 1
            copy.sliceId = String(format: "slice-%02d", ordinal)
            copy.clipPath = "archive/media-work/task-\(String(format: "%02d", ordinal))/clip.mp4"
            return copy
        }
    }

    static func unionStills(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        return (lhs + rhs).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func mergeOverlapping(_ slices: [SliceRecord], mediaDuration: TimeInterval) -> [SliceRecord] {
        let sorted = slices.sorted {
            if $0.startMedia == $1.startMedia { return $0.sliceId < $1.sliceId }
            return $0.startMedia < $1.startMedia
        }
        var result: [SliceRecord] = []
        for candidate in sorted {
            guard var last = result.last, overlaps(last, candidate) else {
                result.append(candidate); continue
            }
            let combinedStart = min(last.startMedia, candidate.startMedia)
            let combinedEnd = max(last.endMedia, candidate.endMedia)
            guard combinedEnd - combinedStart <= MediaBudget.clipMaxDuration else {
                // Overlapping windows whose union is too long remain distinct;
                // clamping a merged window would silently lose anchor coverage.
                result.append(candidate)
                continue
            }
            // Capture priority before mutating the union. The old implementation
            // compared against the already-updated score and could lose a later,
            // higher-priority anchor's source label and center.
            let preferred = candidate.score > last.score ? candidate : last
            last.startMedia = combinedStart
            last.endMedia = combinedEnd
            last.stills = Self.unionStills(last.stills, candidate.stills)
            last.anchorIds = Array(Set(last.anchorIds + candidate.anchorIds)).sorted()
            last.trigger = preferred.trigger
            last.associatedShotId = preferred.associatedShotId ?? last.associatedShotId ?? candidate.associatedShotId
            last.score = preferred.score
            result[result.count - 1] = last
        }
        return result
    }

    private func coverageSelection(
        _ slices: [SliceRecord],
        transcript: FullTranscript,
        duration: TimeInterval,
        humanAnchorIDs: Set<String>,
        actionStepIDs: Set<String>
    ) -> [SliceRecord] {
        let occupied = occupiedBins(transcript: transcript, duration: duration)
        var remaining = slices
        var selected: [SliceRecord] = []
        var coveredAnchors = Set<String>()
        var coveredActions = Set<String>()
        var coveredBins = Set<Int>()
        while !remaining.isEmpty && selected.count < MediaBudget.maxCandidateSlices {
            let evaluated: [(SliceRecord, Int, Int, Int)] = remaining.map { item in
                let itemAnchors = Set(item.anchorIds)
                let anchors = itemAnchors.intersection(humanAnchorIDs).subtracting(coveredAnchors).count
                let actions = itemAnchors.intersection(actionStepIDs).subtracting(coveredActions).count
                let binSet = Set(binRange(item, duration: duration).filter { occupied.contains($0) }).subtracting(coveredBins)
                return (item, anchors, actions, binSet.count)
            }
            let best = evaluated.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
                if lhs.3 != rhs.3 { return lhs.3 > rhs.3 }
                if lhs.0.score != rhs.0.score { return lhs.0.score > rhs.0.score }
                if lhs.0.startMedia != rhs.0.startMedia { return lhs.0.startMedia < rhs.0.startMedia }
                let left = lhs.0.anchorIds.sorted().joined(separator: "|")
                let right = rhs.0.anchorIds.sorted().joined(separator: "|")
                if left != right { return left < right }
                return lhs.0.trigger.rawValue < rhs.0.trigger.rawValue
            }.first!
            let item = best.0
            // A duplicate with no marginal signal cannot consume capacity.
            let itemAnchors = Set(item.anchorIds)
            let duplicateWithoutNewSupport = best.1 + best.2 + best.3 == 0 && selected.contains { prior in
                let priorAnchors = Set(prior.anchorIds)
                return overlapRatio(prior, item) >= 0.8 && priorAnchors.isSuperset(of: itemAnchors)
            }
            if duplicateWithoutNewSupport {
                remaining.removeAll { $0 == item }
                continue
            }
            selected.append(item)
            coveredAnchors.formUnion(item.anchorIds)
            coveredActions.formUnion(Set(item.anchorIds).intersection(actionStepIDs))
            coveredBins.formUnion(binRange(item, duration: duration))
            remaining.removeAll { $0 == item }
        }
        return selected.sorted {
            if $0.startMedia == $1.startMedia { return $0.anchorIds.sorted().joined() < $1.anchorIds.sorted().joined() }
            return $0.startMedia < $1.startMedia
        }
    }

    private func occupiedBins(transcript: FullTranscript, duration: TimeInterval) -> Set<Int> {
        guard duration.isFinite, duration > 0 else { return [] }
        return Set(transcript.segments.filter {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration
        }.map { min(11, max(0, Int($0.start / duration * 12))) })
    }

    private func binRange(_ slice: SliceRecord, duration: TimeInterval) -> [Int] {
        guard duration > 0 else { return [] }
        let first = min(11, max(0, Int(slice.startMedia / duration * 12)))
        let last = min(11, max(first, Int(max(slice.startMedia, slice.endMedia - 0.001) / duration * 12)))
        return Array(first...last)
    }

    private func overlaps(_ a: SliceRecord, _ b: SliceRecord) -> Bool { a.startMedia < b.endMedia && b.startMedia < a.endMedia }

    private func overlapRatio(_ a: SliceRecord, _ b: SliceRecord) -> Double {
        let shorter = min(a.endMedia - a.startMedia, b.endMedia - b.startMedia)
        guard shorter > 0 else { return 0 }
        return max(0, min(a.endMedia, b.endMedia) - max(a.startMedia, b.startMedia)) / shorter
    }
}
