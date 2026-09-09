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
                    stills: [shot.annotatedPath ?? shot.rawPath],
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
        for hit in TranscriptQuery.keywordHits(in: transcript) {
            let window = TimelineMath.clampMediaWindow(
                center: hit,
                duration: MediaBudget.clipMeanDuration,
                mediaDuration: mediaDuration
            )
            candidates.append(
                SliceRecord(
                    sliceId: "",
                    startMedia: window.start,
                    endMedia: window.end,
                    trigger: .keyword,
                    associatedShotId: nil,
                    clipPath: nil,
                    stills: [],
                    analysisStatus: .pending,
                    score: 40
                )
            )
        }
        let merged = mergeOverlapping(candidates)
        let capped = Array(merged.sorted { $0.score > $1.score }.prefix(MediaBudget.maxCandidateSlices))
        return capped.enumerated().map { index, slice in
            var copy = slice
            let ordinal = index + 1
            copy.sliceId = String(format: "slice-%02d", ordinal)
                    let folder = "archive/media-work/task-\(String(format: "%02d", ordinal))"
            copy.clipPath = "\(folder)/clip.mp4"
            if copy.stills.isEmpty {
                copy.stills = ["\(folder)/shot-1.jpg"]
            }
            return copy
        }
    }

    private func mergeOverlapping(_ slices: [SliceRecord]) -> [SliceRecord] {
        let sorted = slices.sorted { $0.startMedia < $1.startMedia }
        var result: [SliceRecord] = []
        for slice in sorted {
            if var last = result.last, overlaps(last, slice) {
                if slice.score > last.score {
                    last.trigger = slice.trigger
                    last.associatedShotId = slice.associatedShotId ?? last.associatedShotId
                    last.score = slice.score
                }
                last.startMedia = min(last.startMedia, slice.startMedia)
                last.endMedia = max(last.endMedia, slice.endMedia)
                if last.stills.isEmpty {
                    last.stills = slice.stills
                }
                result[result.count - 1] = last
            } else {
                result.append(slice)
            }
        }
        return result
    }

    private func overlaps(_ a: SliceRecord, _ b: SliceRecord) -> Bool {
        a.startMedia < b.endMedia && b.startMedia < a.endMedia
    }
}
