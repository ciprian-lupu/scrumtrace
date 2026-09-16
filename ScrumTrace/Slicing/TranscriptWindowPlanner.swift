import Foundation

/// Pure, deterministic transcript planning. This is intentionally a scorer,
/// not a summarizer: original text is retained for every eventual export.
struct TranscriptWindowPlanner {
    struct PlannedWindow: Sendable, Hashable {
        var startMedia: TimeInterval
        var endMedia: TimeInterval
        var score: Double
        var stableKey: String
    }

    func plan(transcript: FullTranscript, mediaDuration: TimeInterval) -> [PlannedWindow] {
        guard mediaDuration > 0 else { return [] }
        let segments = TranscriptQuery.collapseDuplicates(
            transcript.segments
                .filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        )
        guard !segments.isEmpty else { return [] }

        // Neighbourhoods stop at a real pause. This retains procedural phases
        // spread across a long meeting instead of rewarding repeated keywords.
        var groups: [[TranscriptSegment]] = []
        for segment in segments {
            if var last = groups.last,
               let end = last.last?.end,
               segment.start - end <= 55 {
                last.append(segment)
                groups[groups.count - 1] = last
            } else {
                groups.append([segment])
            }
        }

        var planned: [PlannedWindow] = []
        for (index, group) in groups.enumerated() {
            let text = group.map(\.text).joined(separator: " ")
            let groupScore = score(text)
            // A useful non-keyword passage is better than an empty temporal
            // bin, but filler-only groups are deliberately not candidates.
            guard groupScore >= 1.25 else { continue }
            let strongest = group.enumerated().max { left, right in
                let ls = score(left.element.text)
                let rs = score(right.element.text)
                if ls != rs { return ls < rs }
                return left.element.start > right.element.start
            }!.element
            let center = (strongest.start + strongest.end) / 2
            let window = TimelineMath.clampMediaWindow(
                center: center,
                duration: MediaBudget.clipMeanDuration,
                mediaDuration: mediaDuration
            )
            planned.append(PlannedWindow(
                startMedia: window.start,
                endMedia: window.end,
                score: groupScore + min(2, Double(group.count) * 0.15),
                stableKey: String(format: "%012.3f-%03d", strongest.start, index)
            ))
        }
        return planned.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.stableKey < right.stableKey
        }
    }

    /// Case/diacritic folding is for scoring only. Output always takes source
    /// text from `FullTranscript` unchanged.
    private func score(_ raw: String) -> Double {
        let text = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard words.count >= 3 else { return 0 }
        let instruction = ["run", "then", "first", "next", "after", "before", "verify", "check", "test", "deploy", "import", "configure", "execute", "dry", "ruleaza", "apoi", "intai", "dupa", "inainte", "verifica", "testeaza", "configureaza", "executa", "importa"]
        let prerequisite = ["requires", "require", "need", "must", "only if", "provided", "schema", "column", "environment", "prerequisite", "trebuie", "necesita", "coloana", "mediu", "inainte"]
        let result = ["result", "success", "worked", "works", "output", "done", "completed", "visible", "confirm", "rezultat", "reusit", "functioneaza", "gata", "confirmat"]
        let decision = ["decide", "decision", "agree", "question", "follow", "owner", "decidem", "hotaram", "intrebare", "urmeaza"]
        var total = 0.0
        for cue in instruction where text.contains(cue) { total += 1.15 }
        for cue in prerequisite where text.contains(cue) { total += 1.0 }
        for cue in result where text.contains(cue) { total += 0.9 }
        for cue in decision where text.contains(cue) { total += 0.75 }
        if raw.range(of: #"(?<!\w)(--?[A-Za-z][\w-]*|[A-Za-z_][A-Za-z0-9_]*=|\$[A-Za-z_]|[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)"#, options: .regularExpression) != nil {
            total += 1.2
        }
        let unique = Set(words).count
        if unique * 2 < words.count { total -= 1.5 }
        let filler = words.filter { ["um", "uh", "yeah", "da", "ok", "okay"].contains($0) }.count
        total -= Double(filler) * 0.3
        return total
    }
}
