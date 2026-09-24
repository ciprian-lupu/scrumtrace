import Foundation

/// A deterministic overview of the kept evidence. No additional provider call,
/// no invented decisions, owners, deadlines, or speech outside selected clips.
struct BriefPresentation {
    let manifest: SessionManifest
    let transcript: FullTranscript?
    let sessionURL: URL

    private var confirmed: [TaskRecord] { manifest.tasks.filter { $0.status == .confirmed } }
    private var review: [TaskRecord] { manifest.tasks.filter { $0.status == .needsReview } }
    private func escape(_ text: String) -> String { HTMLEscaper.escape(text) }

    var statusHTML: String {
        let speech: String
        if let procedure = manifest.localProcedure {
            switch procedure.transcriptStatus {
            case "timed_transcript":
                speech = procedure.partial
                    ? "Timed transcript available · local outline is partial and needs review."
                    : "Timed transcript available · local outline needs human semantic review."
            case "untimed_text_review_only":
                speech = "Transcript text has no usable media timing · it was not asserted as a timed procedure."
            case "no_speech":
                speech = "No speech detected in the captured audio."
            default:
                speech = manifest.hasCompleted(.transcribing)
                    ? "No usable transcript · captured anchors remain available for review."
                    : "Transcription incomplete · use Retry Analysis in ScrumTrace."
            }
        } else if let transcript, transcript.hasUsableText {
            speech = transcript.needsTranscriptionRetry || !manifest.hasCompleted(.transcribing)
                ? "Partial transcript · retry the missing source in ScrumTrace."
                : "Transcript available · \(transcript.segments.count) \(transcript.segments.count == 1 ? "passage" : "passages")."
        } else if let analysis = transcript?.transcriptionAnalysis, !analysis.isEmpty,
                  analysis.allSatisfy({ $0.status == "no_speech" }) {
            speech = "No speech detected in the captured audio."
        } else {
            speech = "No usable transcript · use Retry Analysis in ScrumTrace."
        }
        let speakers: String
        if transcript?.hasUsableText != true {
            speakers = "No transcript passages to attribute."
        } else if transcript?.speakerAnalysis?.contains(where: { $0.status == "failed" }) == true {
            speakers = "Speaker analysis incomplete · review in ScrumTrace."
        } else if transcript?.speakers?.isEmpty != false {
            speakers = "Individual speakers have not been identified."
        } else {
            speakers = "Session-local labels · estimates unless a passage is reviewed."
        }
        let analysis: String
        let successful = manifest.slices.filter { $0.analysisStatus == .success }.count
        let failed = manifest.slices.filter { $0.analysisStatus == .offlineFailed }.count
        if failed > 0 {
            analysis = "Analysis incomplete · \(failed) evidence windows need a retry."
        } else if successful > 0 {
            analysis = "AI evaluated \(successful) of \(manifest.slices.count) evidence windows."
        } else if !manifest.uploadConsent.approved {
            analysis = "Local export only · sending evidence for AI analysis was not approved."
        } else if manifest.slices.isEmpty {
            analysis = "No evidence windows were selected for AI analysis."
        } else if manifest.localProcedure != nil {
            analysis = "Provider analysis not run or unavailable. A local extractive outline is available for human review."
        } else {
            analysis = "AI analysis has not completed. Review the session in ScrumTrace."
        }
        return """
        <section id="processing" class="brief-panel" aria-labelledby="processing-title">
          <h2 id="processing-title">Processing status</h2>
          <dl class="status-grid">
            <div><dt>Transcript</dt><dd>\(escape(speech))</dd></div>
            <div><dt>Speakers</dt><dd>\(escape(speakers))</dd></div>
            <div><dt>AI analysis</dt><dd>\(escape(analysis))</dd></div>
          </dl>
        </section>
        """
    }

    var summaryHTML: String {
        if !ComparisonReport.rows(manifest).isEmpty { return localProcedureHTML + ComparisonReport.html(manifest) }
        let introduction: String
        if !confirmed.isEmpty {
            introduction = "Highlights from the selected evidence. Follow each item to its supporting clip, image and quotes."
        } else if manifest.slices.contains(where: { $0.analysisStatus == .success }) {
            introduction = "No confirmed findings from this analysis. Check the review items before drawing conclusions."
        } else if manifest.localProcedure != nil {
            introduction = "Provider findings are separate. The local extractive outline needs human review and does not establish a complete procedure."
        } else {
            introduction = "A discussion summary is not available because AI analysis has not completed. Captures and notes remain available for review."
        }
        let highlights = confirmed.prefix(5).map { linkedItem($0, includeStatement: false) }.joined()
        return localProcedureHTML + """
        <section id="summary" class="brief-panel" aria-labelledby="summary-title">
          <h2 id="summary-title">Session summary</h2>
          <p>\(escape(introduction))</p>
          <p class="muted">\(manifest.shots.count) captures · \(manifest.slices.count) selected \(manifest.slices.count == 1 ? "window" : "windows") · \(confirmed.count) confirmed findings · \(review.count) to review</p>
          \(highlights.isEmpty ? "" : "<ul class=\"brief-list\">\(highlights)</ul>")
        </section>
        <div class="outcome-grid">
          \(outcome(id: "decisions", title: "Decisions", kinds: [.decision], empty: "No decisions supported by confirmed evidence."))
          \(outcome(id: "actions", title: "Next actions", kinds: [.actionItem, .bug, .improvement], empty: "No actions supported by confirmed evidence."))
          \(outcome(id: "questions", title: "Open questions", kinds: [.openQuestion], empty: "No open questions captured in confirmed evidence."))
        </div>
        """
    }

    private var localProcedureHTML: String {
        guard let procedure = manifest.localProcedure else { return "" }
        let rows = procedure.steps.map { step in
            let citation = "t_media \(clock(step.start))–\(clock(step.end)) · \(step.source) · \(step.reviewState)"
            let gaps = step.missingEvidenceReasons.isEmpty ? "" : "<p class=\"muted\">Gap: \(escape(step.missingEvidenceReasons.joined(separator: "; ")))</p>"
            let label = escape(step.kind.replacingOccurrences(of: "_", with: " "))
            let evidence = step.evidencePaths.compactMap { sourcePath -> (String, LocalProcedureEvidenceTime?)? in
                guard let path = ExportRel.packMediaHandoff(sourcePath, sessionURL: sessionURL, omitted: manifest.omitted) else { return nil }
                return (path, procedure.evidenceTimes.first { $0.path == sourcePath })
            }.map { path, timestamp -> String in
                let rel = escape(path)
                let timing = timestamp.map {
                    "<span class=\"muted\">Generated still requested at t_media \(escape(clock($0.requestedMedia))); captured at t_media \(escape(clock($0.actualMedia))).</span>"
                } ?? ""
                if path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") || path.hasSuffix(".png") {
                    return "<span><a class=\"still\" href=\"\(rel)\" data-lightbox><img src=\"\(rel)\" alt=\"Available visual evidence for passage \(step.order)\"></a>\(timing)</span>"
                }
                return "<span><a href=\"\(rel)\">Available clip evidence</a>\(timing)</span>"
            }.joined(separator: " ")
            let media = evidence.isEmpty ? "" : "<div class=\"evidence\">\(evidence)</div>"
            return "<li><strong>\(step.order). \(label)</strong> <span class=\"when\">\(escape(citation))</span><blockquote>\(escape(step.excerpt))</blockquote>\(media)\(gaps)</li>"
        }.joined()
        let partial = (procedure.partial || procedure.sizeLimitExceeded)
            ? "<p class=\"muted\">Partial outline · \(procedure.omittedEntryCount) entries omitted/unavailable. This is not a completeness claim.</p>"
                + (procedure.sizeLimitExceeded ? "<p class=\"muted\">The configured local outline size limit was exceeded; this export is not marked ready.</p>" : "")
            : ""
        return "<section id=\"local-outline\" class=\"brief-panel\"><h2>Local extractive outline</h2><p>\(procedure.steps.count) passages · \(procedure.anchors.count) human anchors · \(procedure.selectedWindowCount) selected windows. Chronology and window overlap do not prove semantic order or visual coverage.</p>\(partial)<ol>\(rows)</ol></section>"
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }

    private func outcome(id: String, title: String, kinds: [TaskKind], empty: String) -> String {
        let tasks = confirmed.filter { kinds.contains($0.kind) }
        let content = tasks.isEmpty ? "<p class=\"muted\">\(escape(empty))</p>"
            : "<ul class=\"brief-list\">\(tasks.map { linkedItem($0, includeStatement: true) }.joined())</ul>"
        return """
        <section id="\(id)" class="brief-panel" aria-labelledby="\(id)-title">
          <h2 id="\(id)-title">\(title)</h2>\(content)
        </section>
        """
    }

    private func linkedItem(_ task: TaskRecord, includeStatement: Bool) -> String {
        let statement = includeStatement && !task.stated.isEmpty
            ? "<p>\(escape(task.stated))</p>" : ""
        return "<li><a href=\"#\(escape(task.taskId))\">\(escape(task.title))</a>\(statement)</li>"
    }

    var speakersHTML: String {
        // Normal export rendering uses persisted, projected local excerpts. It
        // does not reopen the private archive to reconstruct transcript turns.
        guard let transcript else {
            let count = Set((manifest.localProcedure?.steps ?? []).compactMap(\.speaker)).count
            let summary = count == 0
                ? "No speaker labels were stored with the selected local passages."
                : "\(count) source speaker \(count == 1 ? "label appears" : "labels appear") in the selected local passages; identities are not independently verified."
            return """
            <section id="speakers" class="brief-panel" aria-labelledby="speakers-title">
              <h2 id="speakers-title">Speakers in selected evidence</h2>
              <p class="muted">\(escape(summary))</p>
            </section>
            """
        }
        let turns = manifest.tasks.filter { $0.status != .dropped }.flatMap { task -> [TranscriptSegment] in
            guard let slice = manifest.slices.first(where: { $0.sliceId == task.sourceSliceId }) else { return [] }
            return SpeakerTimeline.turns(in: transcript, start: slice.startMedia, end: slice.endMedia)
        }
        let ids = Set(turns.flatMap { ($0.speakerCandidates ?? []) + [$0.speaker].compactMap { $0 } })
        let profiles = (transcript.speakers ?? []).filter { ids.contains($0.id) }
        let rows = profiles.map { profile in
            let label = profile.source == "room" ? "Room microphone" : "Call audio"
            return "<li><strong>\(escape(profile.displayName))</strong><span class=\"muted\"> · \(label)</span></li>"
        }.joined()
        return """
        <section id="speakers" class="brief-panel" aria-labelledby="speakers-title">
          <h2 id="speakers-title">Speakers in selected evidence</h2>
          \(rows.isEmpty ? "<p class=\"muted\">No identified speakers in the available transcript excerpts.</p>" : "<ul class=\"brief-list\">\(rows)</ul><p class=\"muted\">Speaker labels are estimates unless the passage was manually reviewed. Names can be corrected in ScrumTrace.</p>")
        </section>
        """
    }

    var downloadsHTML: String {
        var files = [(ScrumTracePath.packZip, "Download session pack", true),
                     (ScrumTracePath.agentContext, "Agent context", false),
                     (ScrumTracePath.agentPrompt, "Agent instructions", false)]
        if manifest.includeFullTranscriptInZip {
            files.append((ScrumTracePath.export + "/full_transcript.json", "Full transcript (JSON)", false))
        }
        let links = files.compactMap { path, label, download -> String? in
            guard !manifest.omitted.contains(where: { ExportRel.toExportRoot($0.path) == ExportRel.toExportRoot(path) }),
                  ExportRel.existingSessionFile(path, sessionURL: sessionURL) != nil else { return nil }
            let rel = ExportRel.toExportRoot(path)
            return "<a class=\"export-link\" href=\"\(escape(rel))\"\(download ? " download" : "")>\(label)</a>"
        }.joined()
        return """
        <section id="exports" class="brief-panel" aria-labelledby="exports-title">
          <h2 id="exports-title">Use this session</h2>
          <p>Share the export folder or the session pack with your coding agent. Keep media beside this HTML file for playback.</p>
          <p class="muted">The ZIP download is available in the original export folder. An extracted pack can be shared as a folder.</p>\n          <div class="export-links">\(links.isEmpty ? "<p class=\"muted\">Export files are being prepared.</p>" : links)</div>
        </section>
        """
    }

    static let css = """
    header.slate{grid-template-columns:minmax(0,1fr);align-items:start;gap:16px}
    header.slate h1{overflow-wrap:anywhere}header.slate h1 em{font:14px var(--mono,monospace);line-height:1.6;letter-spacing:normal}
    .brief-panel{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:20px;margin:0 0 20px;min-width:0}
    .brief-panel h2{font-size:1.3rem;margin:0 0 12px}.brief-panel p{line-height:1.55}
    .status-grid,.outcome-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}
    .status-grid{margin:0}.status-grid dt{font-weight:600;margin-bottom:8px}.status-grid dd{margin:0;color:var(--muted);line-height:1.5}
    .brief-nav,.export-links{display:flex;flex-wrap:wrap;gap:10px;margin:0 0 22px}.export-links{margin:0}
    .brief-nav a,.export-link{display:inline-block;padding:10px 14px;border:1px solid var(--line);border-radius:8px;color:var(--paper);text-decoration:none}
    .brief-nav a:hover,.export-link:hover{border-color:var(--amber)}a:focus-visible,summary:focus-visible{outline:3px solid var(--amber);outline-offset:4px}
    .brief-list{padding-left:20px;line-height:1.5}.brief-list li+li{margin-top:12px}.brief-list a{color:var(--paper);text-decoration:underline;text-underline-offset:3px}
    .brief-list p{font-size:.9rem;color:var(--muted);margin:6px 0}.muted{color:var(--muted)}
    .take h3{font-size:1.4rem;line-height:1.3;margin:12px 0}.take h3,.brief-list a,.meta a,figcaption{overflow-wrap:anywhere}.clip-transcript{width:100%;margin-top:14px}
    .clip-transcript summary{cursor:pointer;padding:10px 0}.clip-meta{font-size:.85rem;color:var(--muted)}
    @media(max-width:900px){.status-grid,.outcome-grid{grid-template-columns:1fr}.shell{padding:24px 5vw 60px;margin-left:12px}.sprocket{display:none}}
    """
}
