import Foundation

/// Resumable pipeline: transcribing → slicing → evaluating → synthesizing → completed.
/// Network failures mark slices `offline_failed` and still emit Markdown/HTML.
final class SessionProcessor: @unchecked Sendable {
    private let vault: SessionVault
    private let transcriber: WhisperTranscriber
    private let slicer = MeetingSlicer()
    private let exporter = ClipExporter()
    private let briefRenderer = SessionBriefRenderer()
    private let agentRenderer = AgentContextRenderer()
    private let zipper = SessionPackZipper()
    private let evalLock = NSLock()
    private var evalAuthFailed = false
    /// Last transcript this processor wrote. `loadTranscript` prefers disk,
    /// then this, so a decode miss cannot slice as if the room was silent.
    private var writtenTranscript: FullTranscript?

    init(vault: SessionVault, transcriber: WhisperTranscriber) {
        self.vault = vault
        self.transcriber = transcriber
    }

    func process(
        sessionId: String,
        pinTimes: [TimeInterval],
        configuration: AIProviderConfiguration,
        whisperModel: String,
        onStatus: @escaping @MainActor (PipelineStatus, String) -> Void
    ) async throws -> SessionManifest {
        let sessionURL = vault.sessionURL(id: sessionId)
        try requireUsableSession(sessionURL, id: sessionId)
        var manifest = try vault.loadManifest(id: sessionId)
        if writtenTranscript?.sessionId != sessionId {
            writtenTranscript = nil
        }

        var timing = PipelineTiming.load(sessionURL: sessionURL) ?? PipelineTiming()

        var justFinishedTranscribing = false
        if !manifest.hasCompleted(.transcribing) {
            await onStatus(.transcribing, "Transcribing locally with WhisperKit")
            manifest.pipelineStatus = .transcribing
            try vault.write(manifest: &manifest)
            let whisperStarted = Date()
            var transcript = await transcribe(sessionURL: sessionURL, model: whisperModel)
            transcript.sessionId = sessionId
            try requireUsableSession(sessionURL, id: sessionId)
            let persistablePass = !(transcript.sources ?? []).isEmpty || !transcript.segments.isEmpty
            // A failed Whisper pass must not replace a transcript already on
            // disk. Retry can transcribe again; slicing waits until this stage
            // completes (C5 / D14).
            if persistablePass
                || ExportRel.existingSessionFile(ScrumTracePath.fullTranscript, sessionURL: sessionURL) == nil {
                let data = try JSONEncoder().encode(transcript)
                try ExportRel.writeContainedData(
                    data,
                    relative: ScrumTracePath.fullTranscript,
                    sessionURL: sessionURL
                )
                writtenTranscript = transcript
            }
            timing.whisperWallSeconds = Date().timeIntervalSince(whisperStarted)
            timing.whisperSources = transcript.sources ?? []
            try timing.write(sessionURL: sessionURL)
            let hadAudio = ExportRel.existingSessionFile(ScrumTracePath.audioWav, sessionURL: sessionURL) != nil
                || ExportRel.existingSessionFile(ScrumTracePath.sessionMovie, sessionURL: sessionURL) != nil
            // If Whisper never loaded, or every audio pass threw, leave the
            // stage open so Retry can try again. Empty speech after a
            // successful load still completes (sources is non-empty).
            if transcriber.isReady || !hadAudio {
                let ranAPass = !(transcript.sources ?? []).isEmpty || !transcript.segments.isEmpty
                if !hadAudio || ranAPass {
                    manifest.markCompleted(.transcribing)
                    justFinishedTranscribing = true
                }
            }
            try vault.write(manifest: &manifest)
        }

        let transcript = loadTranscript(sessionURL: sessionURL, sessionId: sessionId)
        var recoveredReadableTranscript = false
        if manifest.hasCompleted(.transcribing), transcriptArchiveUnreadable(sessionURL: sessionURL) {
            // Corrupt archive/full_transcript.json must not slice as silence (C5).
            if let written = writtenTranscript, written.sessionId == sessionId {
                let data = try JSONEncoder().encode(written)
                try ExportRel.writeContainedData(
                    data,
                    relative: ScrumTracePath.fullTranscript,
                    sessionURL: sessionURL
                )
                recoveredReadableTranscript = true
            } else {
                manifest.completedStages.removeAll {
                    $0 == .transcribing || $0 == .slicing || $0 == .evaluating
                        || $0 == .synthesizing || $0 == .completed
                }
                manifest.pipelineStatus = .transcribing
                manifest.tasks = []
                try vault.write(manifest: &manifest)
            }
        }

        if justFinishedTranscribing || recoveredReadableTranscript {
            manifest.completedStages.removeAll {
                $0 == .slicing || $0 == .evaluating || $0 == .synthesizing || $0 == .completed
            }
            manifest.tasks = []
            // Persist immediately so a crash during clip export cannot leave
            // slicing marked complete on disk while the new transcript is unused.
            try vault.write(manifest: &manifest)
        }

        try requireUsableSession(sessionURL, id: sessionId)
        if !manifest.hasCompleted(.slicing) {
            if manifest.hasCompleted(.transcribing) {
                refreshShotsFromDisk(sessionId: sessionId, manifest: &manifest)
                await onStatus(.slicing, "Cutting evidence windows to the media budget")
                manifest.pipelineStatus = .slicing
                let slices = slicer.slice(
                    shots: manifest.shots,
                    pins: pinTimes,
                    transcript: transcript,
                    mediaDuration: manifest.duration.mediaSeconds
                )
                var exported: [SliceRecord] = []
                for slice in slices {
                    if ExportRel.existingSessionFile(ScrumTracePath.sessionMovie, sessionURL: sessionURL) != nil {
                        do {
                            let clipped = try await exporter.export(
                                sessionURL: sessionURL,
                                slice: slice,
                                mediaDuration: manifest.duration.mediaSeconds
                            )
                            exported.append(clipped.withExistingMedia(sessionURL: sessionURL))
                        } catch {
                            // Keep the slice (shot stills, transcript window). One bad
                            // clip must not abort the session. Do not keep a stale
                            // export clip path from a prior projection (C5).
                            var failed = slice
                            failed.exportClipPath = nil
                            exported.append(failed.withExistingMedia(sessionURL: sessionURL))
                        }
                    } else {
                        exported.append(slice.withExistingMedia(sessionURL: sessionURL))
                    }
                }
                manifest.slices = exported
                manifest.markCompleted(.slicing)
                try vault.write(manifest: &manifest)
            }
        }

        try requireUsableSession(sessionURL, id: sessionId)
        let needsEvaluate = !manifest.hasCompleted(.evaluating)
            || manifest.slices.contains { $0.analysisStatus == .offlineFailed || $0.analysisStatus == .pending }
            || (manifest.uploadConsent.approved
                && manifest.slices.contains { $0.analysisStatus == .skipped })

        if needsEvaluate {
            if !manifest.hasCompleted(.transcribing) {
                // Retry Analysis transcribes first. Do not mark evaluating
                // complete from an empty transcript that Whisper never produced.
                // Synthesize is also withheld until transcribing completes (below).
            } else if !manifest.uploadConsent.approved {
                await onStatus(.evaluating, "Upload not approved — local export only")
                abandonEvaluate(manifest: &manifest, failedStatus: .skipped, markOffline: false)
                try vault.write(manifest: &manifest)
            } else if configuration.kind == .anthropic && (
                configuration.model.isEmpty
                    || AIProviderConfiguration.isRetiredAnthropic(configuration.model)
            ) {
                await onStatus(.evaluating, "Anthropic model missing or retired — local export only")
                abandonEvaluate(manifest: &manifest, failedStatus: .skipped, markOffline: false)
                try vault.write(manifest: &manifest)
            } else if configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await onStatus(.evaluating, "API key missing — local export only")
                abandonEvaluate(manifest: &manifest, failedStatus: .offlineFailed, markOffline: true)
                try vault.write(manifest: &manifest)
            } else {
                resetEvalAuthGate()
                await onStatus(.evaluating, "Evaluating slices with the configured model")
                manifest.pipelineStatus = .evaluating
                let provider = AIEngine.make(configuration: configuration)
                var tasks = manifest.tasks.filter { task in
                    manifest.slices.first { $0.sliceId == task.sourceSliceId }?.analysisStatus == .success
                }
                var updatedSlices: [SliceRecord] = manifest.slices.filter {
                    $0.analysisStatus == .success
                }
                let toRun = manifest.slices.filter { $0.analysisStatus != .success }
                // Serial: a 401 must not leave other slices uploading stills (Gate 5).
                // Persist after each slice so a crash does not re-upload successes (D14).
                for slice in toRun {
                    let result = await self.evaluateSlice(
                        slice: slice,
                        manifest: manifest,
                        transcript: transcript,
                        sessionURL: sessionURL,
                        provider: provider,
                        configuration: configuration
                    )
                    updatedSlices.append(result.0)
                    tasks.append(contentsOf: result.1)
                    // Unique IDs only — do not rank/drop until every slice is in
                    // (a crash must not lose extras that later ranking needs).
                    tasks = uniquedTaskIds(tasks)
                    let done = Set(updatedSlices.map(\.sliceId))
                    let remaining = toRun.filter { !done.contains($0.sliceId) }
                    manifest.slices = (updatedSlices + remaining).sorted { $0.sliceId < $1.sliceId }
                    // Keep the full candidate list on disk. Rank only after every
                    // slice so a crash cannot drop extras that later ranking needs.
                    manifest.tasks = tasks
                    try vault.write(manifest: &manifest)
                }
                manifest.slices = updatedSlices.sorted { $0.sliceId < $1.sliceId }
                mergeUncoveredReview(manifest: &manifest, kept: tasks)
                let anyFailed = manifest.slices.contains { $0.analysisStatus == .offlineFailed }
                manifest.markCompleted(.evaluating)
                if anyFailed {
                    manifest.pipelineStatus = .offlineFailed
                }
                try vault.write(manifest: &manifest)
            }
        }

        try requireUsableSession(sessionURL, id: sessionId)
        guard manifest.hasCompleted(.transcribing) else {
            // Do not stamp synthesizing/completed while Whisper never produced
            // a usable pass. Retry Analysis transcribes first (D14).
            await onStatus(
                .transcribing,
                "Transcription incomplete — Retry Analysis to transcribe again"
            )
            manifest.pipelineStatus = .transcribing
            try vault.write(manifest: &manifest)
            return manifest
        }
        await onStatus(.synthesizing, "Writing AGENT_CONTEXT.md and SESSION_BRIEF.html")
        manifest.pipelineStatus = .synthesizing
        let excerpts = excerptMap(manifest: manifest, transcript: transcript)
        let projector = ExportProjector()
        var projection = try projector.project(
            sessionURL: sessionURL,
            manifest: manifest,
            includeFullTranscript: manifest.includeFullTranscriptInZip
        )
        projection.manifest.tasks = EvidenceValidator.applyExportEvidence(
            tasks: projection.manifest.tasks,
            sessionURL: sessionURL,
            transcript: transcript,
            slices: projection.manifest.slices,
            shots: projection.manifest.shots,
            omitted: projection.manifest.omitted
        )
        manifest.omitted = projection.omitted
        // Docs first: a zip failure must not skip SESSION_BRIEF.html / AGENT_CONTEXT.md.
        try writeExportDocuments(
            sessionURL: sessionURL,
            projected: projection.manifest,
            excerpts: excerpts,
            projector: projector
        )
        try zipper.writeOmittedMarkdown(sessionURL: sessionURL, omitted: projection.omitted)
        do {
            let trial = try zipper.writeZip(
                sessionURL: sessionURL,
                includeFullTranscript: projection.manifest.includeFullTranscriptInZip
            )
            if trial > MediaBudget.maxZipBytes {
                await onStatus(.synthesizing, "Re-encoding clips to fit the 35 MB pack")
                await exporter.tightenExportClips(sessionURL: sessionURL)
            }
        } catch {
            try throwIfExportEscapes(sessionURL: sessionURL, error)
            // Trial weigh failed; zip() below still measures and omits.
        }
        var zipResult = SessionPackZipper.Result(
            zipURL: sessionURL.appendingPathComponent(ScrumTracePath.packZip),
            byteCount: 0,
            omitted: projection.omitted
        )
        do {
            zipResult = try zipper.zip(sessionURL: sessionURL, manifest: projection.manifest)
        } catch {
            try throwIfExportEscapes(sessionURL: sessionURL, error)
            zipResult.omitted.append(
                OmittedAsset(path: "session-pack.zip", reason: "zip failed: \(error.localizedDescription)")
            )
            try zipper.writeOmittedMarkdown(sessionURL: sessionURL, omitted: zipResult.omitted)
            zipResult.byteCount = zipper.discardPackIfOverBudget(sessionURL: sessionURL)
        }
        var zipBytes = zipResult.byteCount
        for pass in 0..<3 {
            projection.manifest = PackBudget.stripOmitted(zipResult.omitted, from: projection.manifest)
            projection.manifest.omitted = zipResult.omitted
            projection.manifest.tasks = EvidenceValidator.applyExportEvidence(
                tasks: projection.manifest.tasks,
                sessionURL: sessionURL,
                transcript: transcript,
                slices: projection.manifest.slices,
                shots: projection.manifest.shots,
                omitted: projection.manifest.omitted
            )
            // C5: demoted tasks must hit AGENT_CONTEXT / BRIEF / the projection
            // even if rebuilding the pack file fails. Do not swallow this write
            // with the pack rebuild.
            try writeExportDocuments(
                sessionURL: sessionURL,
                projected: projection.manifest,
                excerpts: excerpts,
                projector: projector
            )
            try zipper.writeOmittedMarkdown(sessionURL: sessionURL, omitted: zipResult.omitted)
            do {
                zipBytes = try zipper.writeZip(
                    sessionURL: sessionURL,
                    includeFullTranscript: projection.manifest.includeFullTranscriptInZip
                )
            } catch {
                try throwIfExportEscapes(sessionURL: sessionURL, error)
                zipBytes = zipResult.byteCount
                break
            }
            if zipBytes <= MediaBudget.maxZipBytes {
                break
            }
            if pass == 2 { break }
            do {
                zipResult = try zipper.zip(sessionURL: sessionURL, manifest: projection.manifest)
            } catch {
                try throwIfExportEscapes(sessionURL: sessionURL, error)
                zipResult.omitted.append(
                    OmittedAsset(path: "session-pack.zip", reason: "zip failed: \(error.localizedDescription)")
                )
                projection.manifest = PackBudget.stripOmitted(zipResult.omitted, from: projection.manifest)
                projection.manifest.omitted = zipResult.omitted
                projection.manifest.tasks = EvidenceValidator.applyExportEvidence(
                    tasks: projection.manifest.tasks,
                    sessionURL: sessionURL,
                    transcript: transcript,
                    slices: projection.manifest.slices,
                    shots: projection.manifest.shots,
                    omitted: projection.manifest.omitted
                )
                try writeExportDocuments(
                    sessionURL: sessionURL,
                    projected: projection.manifest,
                    excerpts: excerpts,
                    projector: projector
                )
                try zipper.writeOmittedMarkdown(sessionURL: sessionURL, omitted: zipResult.omitted)
                break
            }
        }
        zipBytes = zipper.discardPackIfOverBudget(sessionURL: sessionURL)
        // writeZip can recreate an over-budget pack after zip() already
        // omitted. Discard removes that file; OMITTED.md / AGENT_CONTEXT
        // must not still imply the zip is in the folder (Gate 6).
        if zipBytes == 0 || zipBytes > MediaBudget.maxZipBytes {
            if !zipResult.omitted.contains(where: {
                ExportRel.toExportRoot($0.path) == "session-pack.zip"
            }) {
                zipResult.omitted.append(
                    OmittedAsset(
                        path: "session-pack.zip",
                        reason: zipBytes == 0
                            ? "Pack exceeded 35 MB after rebuild; zip was removed. Folder handoff kept."
                            : "Pack still \(zipBytes) bytes after dropping all droppable export media; protected docs remain."
                    )
                )
            }
            projection.manifest.omitted = zipResult.omitted
            try writeExportDocuments(
                sessionURL: sessionURL,
                projected: projection.manifest,
                excerpts: excerpts,
                projector: projector
            )
            try zipper.writeOmittedMarkdown(sessionURL: sessionURL, omitted: zipResult.omitted)
        }
        timing.zipBytes = zipBytes
        timing.omittedCount = zipResult.omitted.count
        try timing.write(sessionURL: sessionURL)
        manifest.omitted = zipResult.omitted
        // C5: canonical SoT must not keep `confirmed` after export evidence was dropped.
        // D10: keep archive evidence paths; copy status only from the projection.
        manifest.tasks = EvidenceValidator.mergeCanonicalStatuses(
            canonical: manifest.tasks,
            projected: projection.manifest.tasks
        )
        manifest.markCompleted(.synthesizing)
        manifest.pipelineStatus = manifest.slices.contains(where: { $0.analysisStatus == .offlineFailed })
            ? .offlineFailed
            : .completed
        manifest.markCompleted(.completed)
        try vault.write(manifest: &manifest)
        await onStatus(manifest.pipelineStatus, "Session pack ready")
        return manifest
    }

    /// C2: a leftover export/ symlink is not a "zip failed, keep going" event.
    private func throwIfExportEscapes(sessionURL: URL, _ error: Error) throws {
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        PackBudget.removeEscapingExportLinks(exportDir: exportDir)
        if PackBudget.exportStillContainsSymlink(exportDir: exportDir) {
            throw error
        }
    }

    private func writeExportDocuments(
        sessionURL: URL,
        projected: SessionManifest,
        excerpts: [String: String],
        projector: ExportProjector
    ) throws {
        PackBudget.removeEscapingExportLinks(
            exportDir: sessionURL.appendingPathComponent(ScrumTracePath.export)
        )
        if PackBudget.exportStillContainsSymlink(
            exportDir: sessionURL.appendingPathComponent(ScrumTracePath.export)
        ) {
            throw SessionRecorderError.writerFailed("export/ is a symbolic link.")
        }
        let markdown = agentRenderer.render(manifest: projected, sessionURL: sessionURL)
        let prompt = agentRenderer.prompt(manifest: projected, sessionURL: sessionURL)
        let html = briefRenderer.render(manifest: projected, excerpts: excerpts, sessionURL: sessionURL)
        try ExportRel.writeExportText(markdown, relative: ScrumTracePath.agentContext, sessionURL: sessionURL)
        try ExportRel.writeExportText(prompt, relative: ScrumTracePath.agentPrompt, sessionURL: sessionURL)
        try ExportRel.writeExportText(html, relative: ScrumTracePath.sessionBrief, sessionURL: sessionURL)
        try projector.writeProjectionManifest(projected, sessionURL: sessionURL)
    }

    private func transcribe(sessionURL: URL, model: String) async -> FullTranscript {
        do {
            if !transcriber.isReady {
                try await transcriber.prepare(model: model)
            }
        } catch {
            return FullTranscript(sessionId: "", language: "en", segments: [])
        }
        let layout = CaptureAudioLayout.load(sessionURL: sessionURL)
        let wavExists = ExportRel.existingSessionFile(ScrumTracePath.audioWav, sessionURL: sessionURL) != nil
        let movieExists = ExportRel.existingSessionFile(ScrumTracePath.sessionMovie, sessionURL: sessionURL) != nil
        let wav = sessionURL.appendingPathComponent(ScrumTracePath.audioWav)
        let movie = sessionURL.appendingPathComponent(ScrumTracePath.sessionMovie)
        var passes: [TranscriptQuery.SourcePass] = []
        var requiredFailed = false
        if wavExists {
            do {
                let speaker = layout.microphoneWav ? "room" : "system"
                let wavTranscript = try await transcriber.transcribeFile(at: wav, sessionURL: sessionURL)
                passes.append(TranscriptQuery.SourcePass(speaker: speaker, transcript: wavTranscript))
            } catch {
                // Keep shots/clips; Retry Analysis can transcribe again.
                requiredFailed = true
            }
        }
        if layout.shouldTranscribeMovie(wavExists: wavExists, movieExists: movieExists) {
            do {
                let movieTranscript = try await transcriber.transcribeMovieAudio(at: movie, sessionURL: sessionURL)
                passes.append(TranscriptQuery.SourcePass(speaker: "system", transcript: movieTranscript))
            } catch {
                requiredFailed = true
            }
        }
        if passes.isEmpty || requiredFailed {
            return FullTranscript(sessionId: "", language: "en", segments: [])
        }
        return TranscriptQuery.merge(passes, sessionId: "")
    }

    private func loadTranscript(sessionURL: URL, sessionId: String) -> FullTranscript {
        if ExportRel.existingSessionFile(ScrumTracePath.fullTranscript, sessionURL: sessionURL) != nil,
           let data = ExportRel.readContainedData(
            relative: ScrumTracePath.fullTranscript,
            sessionURL: sessionURL
           ),
           let transcript = try? JSONDecoder().decode(FullTranscript.self, from: data) {
            return transcript
        }
        if let written = writtenTranscript, written.sessionId == sessionId {
            return written
        }
        return FullTranscript(sessionId: sessionId, language: "en", segments: [])
    }

    /// Completed transcribing with a missing or non-JSON archive transcript
    /// is not a silent room. Retry must run Whisper again (C5 / D14).
    private func transcriptArchiveUnreadable(sessionURL: URL) -> Bool {
        guard ExportRel.existingSessionFile(ScrumTracePath.fullTranscript, sessionURL: sessionURL) != nil else {
            return true
        }
        guard let data = ExportRel.readContainedData(
            relative: ScrumTracePath.fullTranscript,
            sessionURL: sessionURL
        ) else {
            return true
        }
        return (try? JSONDecoder().decode(FullTranscript.self, from: data)) == nil
    }

    private func evaluateSlice(
        slice: SliceRecord,
        manifest: SessionManifest,
        transcript: FullTranscript,
        sessionURL: URL,
        provider: any AIProvider,
        configuration: AIProviderConfiguration
    ) async -> (SliceRecord, [TaskRecord]) {
        var slice = slice
        let linked = shotsLinked(to: slice, in: manifest)
        let shotNote = linked
            .filter { $0.tMedia >= slice.startMedia && $0.tMedia <= slice.endMedia }
            .filter { $0.id == slice.associatedShotId }
            .map(\.note)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if let aborted = abortedForAuth(
            slice: slice,
            shots: linked,
            product: manifest.productContext,
            sessionURL: sessionURL
        ) {
            return aborted
        }
        var excerpt = TranscriptQuery.excerpt(from: transcript, start: slice.startMedia, end: slice.endMedia)
        if !configuration.acceptsText {
            excerpt = ""
        }
        var images: [URL] = []
        var seenImage = Set<String>()
        func appendImage(_ relative: String) {
            guard !EvidenceValidator.ownedByOtherAssociatedShot(
                relative,
                slice: slice,
                shots: linked
            ) else { return }
            guard EvidenceValidator.framesOverlapSlice(
                [relative],
                slice: slice,
                shots: linked,
                sessionURL: sessionURL
            ) else { return }
            guard let contained = ExportRel.existingSessionFile(relative, sessionURL: sessionURL) else { return }
            let url = sessionURL.appendingPathComponent(contained)
            guard seenImage.insert(url.path).inserted else { return }
            images.append(url)
        }
        for shot in linked {
            for path in shot.stillCandidates {
                appendImage(path)
            }
        }
        for still in slice.stills {
            appendImage(still)
        }
        if !configuration.acceptsImages {
            images = []
        } else {
            // media_sent is what actually leaves the Mac (C4). Skip stills
            // jpegPayload cannot openat-read or JPEG-encode.
            images = images.filter { url in
                ImageBase64.jpegPayload(url: url, sessionRoot: sessionURL) != nil
            }
        }
        var mediaSent: [String] = []
        if configuration.acceptsImages && !images.isEmpty {
            mediaSent.append("stills")
        }
        if !excerpt.isEmpty {
            mediaSent.append("transcript")
        }
        var clipURL: URL?
        if ProviderWireMedia.willUploadClip(configuration: configuration),
           let clip = slice.exportClipPath ?? slice.clipPath,
           let contained = ExportRel.existingSessionFile(clip, sessionURL: sessionURL) {
            clipURL = sessionURL.appendingPathComponent(contained)
        }
        // media_sent is what actually leaves the Mac. Shipped adapters never
        // attach MP4, even when the internal request carries clipURL.
        slice.mediaSent = mediaSent
        let hasStill = !images.isEmpty
        // No still + no wired video upload → needs_review, do not drop the slice.
        if !ProviderWireMedia.willUploadClip(configuration: configuration)
            && !hasStill && excerpt.isEmpty && shotNote.isEmpty {
            slice.analysisStatus = .skipped
            let skipped = AIProviderError.skippedNoSendableMedia
            return (slice, reviewTasks(
                shots: linked,
                slice: slice,
                error: skipped,
                product: manifest.productContext,
                sessionURL: sessionURL
            ))
        }
        if let aborted = abortedForAuth(
            slice: slice,
            shots: linked,
            product: manifest.productContext,
            sessionURL: sessionURL
        ) {
            return aborted
        }
        var promptSlice = slice
        promptSlice.stills = slice.stills.filter {
            EvidenceValidator.framesOverlapSlice(
                [$0],
                slice: slice,
                shots: linked,
                sessionURL: sessionURL
            ) && !EvidenceValidator.ownedByOtherAssociatedShot($0, slice: slice, shots: linked)
        }
        let request = SliceEvaluationRequest(
            product: manifest.productContext,
            slice: promptSlice,
            transcriptExcerpt: excerpt,
            shotNote: shotNote,
            windowContext: vault.windowContext(
                sessionId: manifest.sessionId,
                start: slice.startMedia,
                end: slice.endMedia
            ),
            imageURLs: images,
            clipURL: clipURL,
            sessionURL: sessionURL
        )
        if let aborted = abortedForAuth(
            slice: slice,
            shots: linked,
            product: manifest.productContext,
            sessionURL: sessionURL
        ) {
            return aborted
        }
        do {
            let response = try await provider.evaluate(request: request)
            slice.analysisStatus = .success
            let tasks = tasks(
                from: response,
                slice: slice,
                shots: linked,
                product: manifest.productContext,
                transcript: transcript,
                sessionURL: sessionURL,
                forceReview: !ProviderWireMedia.willUploadClip(configuration: configuration) && !hasStill
            )
            return (slice, tasks)
        } catch {
            if AIProviderError.isAuthFailure(error) {
                markEvalAuthFailed()
            }
            slice.analysisStatus = .offlineFailed
            return (slice, reviewTasks(
                shots: linked,
                slice: slice,
                error: error,
                product: manifest.productContext,
                sessionURL: sessionURL
            ))
        }
    }

    private func tasks(
        from response: CandidateEvaluationResponse,
        slice: SliceRecord,
        shots: [ShotRecord],
        product: ProductContext,
        transcript: FullTranscript,
        sessionURL: URL,
        forceReview: Bool
    ) -> [TaskRecord] {
        var out: [TaskRecord] = []
        for (index, candidate) in response.candidates.enumerated() {
            var status: TaskStatus
            switch candidate.decision {
            case .keep:
                status = candidate.confidence < MediaBudget.keepConfidenceFloor ? .needsReview : .confirmed
            case .needsReview:
                status = .needsReview
            case .drop:
                status = .dropped
            }
            if forceReview && status == .confirmed {
                status = .needsReview
            }
            if status == .dropped {
                continue
            }
            let issues = EvidenceValidator.canConfirm(
                candidate: candidate,
                slice: slice,
                transcript: transcript,
                sessionURL: sessionURL,
                shots: shots
            )
            if !issues.isEmpty && status == .confirmed {
                status = .needsReview
            }
            let cited = EvidenceValidator.existingPaths(candidate.frameReferences, sessionURL: sessionURL)
            let resolvedFrames = cited
                .filter { EvidenceValidator.framesOverlapSlice([$0], slice: slice, shots: shots, sessionURL: sessionURL) }
                .filter { !EvidenceValidator.ownedByOtherAssociatedShot($0, slice: slice, shots: shots) }
            if resolvedFrames.isEmpty, !cited.isEmpty {
                let citedOther = cited.filter {
                    EvidenceValidator.ownedByOtherAssociatedShot($0, slice: slice, shots: shots)
                }
                if citedOther.count == cited.count {
                    continue
                }
            }
            let uniqueEvidence = uniquedPaths(
                resolvedFrames
                    + slice.stills.filter { still in
                        guard EvidenceValidator.framesOverlapSlice(
                            [still],
                            slice: slice,
                            shots: shots,
                            sessionURL: sessionURL
                        ) else { return false }
                        return !EvidenceValidator.ownedByOtherAssociatedShot(still, slice: slice, shots: shots)
                    }
                    + [slice.exportClipPath ?? slice.clipPath].compactMap { $0 }
                    + shots.flatMap { shot in
                        guard let associated = slice.associatedShotId, shot.id == associated else {
                            return []
                        }
                        return ([shot.exportPath].compactMap { $0 } + shot.stillCandidates)
                            .filter {
                                EvidenceValidator.framesOverlapSlice(
                                    [$0],
                                    slice: slice,
                                    shots: shots,
                                    sessionURL: sessionURL
                                )
                            }
                    },
                sessionURL: sessionURL
            )
            var instructions = AgentInstructionTemplate.render(
                kind: candidate.kind,
                product: product
            )
            if status == .needsReview {
                let draft = candidate.agentInstructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !draft.isEmpty {
                    instructions += "\(AgentInstructionTemplate.modelNotesMarker)\(PromptTemplates.wrapUntrustedInline(draft))"
                }
            }
            out.append(
                TaskRecord(
                    taskId: String(format: "TASK-%02d", out.count + 1),
                    sourceSliceId: slice.sliceId,
                    kind: candidate.kind,
                    status: status,
                    title: candidate.title.isEmpty ? "Untitled candidate \(index + 1)" : candidate.title,
                    observed: candidate.observed,
                    stated: candidate.stated,
                    inferred: candidate.inferred,
                    agentInstructions: instructions,
                    quotes: candidate.quotes,
                    evidenceMedia: uniqueEvidence,
                    confidence: candidate.confidence
                )
            )
        }
        if out.isEmpty {
            // Empty `candidates[]` is not an explicit drop. Keep a review row so a
            // transcript-only keyword slice cannot vanish (D7). All-drop with no
            // Shot still omits — those candidates were decided. All-drop with a
            // Shot becomes Shot review rows, not resurrected `drop` candidates (C5).
            if response.candidates.isEmpty || !shots.isEmpty {
                out.append(
                    contentsOf: reviewTasks(
                        shots: shots,
                        slice: slice,
                        error: AIProviderError.noKeepableCandidate,
                        product: product,
                        sessionURL: sessionURL
                    )
                )
            }
        }
        return out
    }

    /// D7: overlapping Shots that merged onto one slice each stay visible.
    private func reviewTasks(
        shots: [ShotRecord],
        slice: SliceRecord,
        error: Error?,
        product: ProductContext,
        sessionURL: URL
    ) -> [TaskRecord] {
        if shots.isEmpty {
            let err = error ?? AIProviderError.noKeepableCandidate
            return [fallbackOffline(slice: slice, error: err, product: product, sessionURL: sessionURL)]
        }
        return shots.enumerated().map { index, shot in
            var task = fallbackTask(shot: shot, slice: slice, error: error, product: product, sessionURL: sessionURL)
            task.taskId = String(format: "TASK-%02d", index + 1)
            return task
        }
    }

    private func rankedTasks(_ tasks: [TaskRecord]) -> [TaskRecord] {
        TaskRanking.selectForPack(tasks)
    }

    /// Stable unique `TASK-NN` ids without dropping or reordering by pack rank.
    private func uniquedTaskIds(_ tasks: [TaskRecord]) -> [TaskRecord] {
        tasks.enumerated().map { index, task in
            var copy = task
            copy.taskId = String(format: "TASK-%02d", index + 1)
            return copy
        }
    }

    private func fallbackTask(
        shot: ShotRecord,
        slice: SliceRecord,
        error: Error?,
        product: ProductContext,
        sessionURL: URL
    ) -> TaskRecord {
        // D7: a merge-clamped Shot still gets a review row. C5: that row
        // must not inherit this slice's clip or another moment's stills.
        let inWindow = shot.tMedia >= slice.startMedia && shot.tMedia <= slice.endMedia
        var evidence = shot.stillCandidates.filter { still in
            !inWindow || EvidenceValidator.framesOverlapSlice(
                [still],
                slice: slice,
                shots: [shot],
                sessionURL: sessionURL
            )
        }
        if let exportPath = shot.exportPath {
            evidence.append(exportPath)
        }
        if inWindow, let clip = slice.exportClipPath ?? slice.clipPath {
            evidence.append(clip)
        }
        return TaskRecord(
            taskId: "TASK-SHOT",
            sourceSliceId: slice.sliceId,
            kind: .bug,
            status: .needsReview,
            title: shot.note.isEmpty ? "Human shot requires review" : shot.note,
            observed: "Human-captured frame at t_media \(shot.tMedia)s.",
            stated: shot.note,
            inferred: error.map { "Analysis unavailable: \($0.localizedDescription)" } ?? "Requires manual review.",
            agentInstructions: "[Requires Manual Review - API Offline] \(AgentInstructionTemplate.render(kind: .bug, product: product))",
            quotes: [],
            evidenceMedia: uniquedPaths(evidence, sessionURL: sessionURL),
            confidence: 0
        )
    }

    private func fallbackOffline(
        slice: SliceRecord,
        error: Error,
        product: ProductContext,
        sessionURL: URL
    ) -> TaskRecord {
        TaskRecord(
            taskId: "TASK-OFFLINE",
            sourceSliceId: slice.sliceId,
            kind: .unknown,
            status: .needsReview,
            title: "Unanalyzed slice \(slice.sliceId)",
            observed: "Slice \(slice.startMedia)s–\(slice.endMedia)s was not evaluated.",
            stated: "",
            inferred: error.localizedDescription,
            agentInstructions: "[Requires Manual Review - API Offline] \(AgentInstructionTemplate.render(kind: .unknown, product: product))",
            quotes: [],
            evidenceMedia: uniquedPaths(
                slice.stills.filter {
                    EvidenceValidator.framesOverlapSlice(
                        [$0],
                        slice: slice,
                        shots: [],
                        sessionURL: sessionURL
                    )
                } + [slice.exportClipPath ?? slice.clipPath].compactMap { $0 },
                sessionURL: sessionURL
            ),
            confidence: 0
        )
    }

    /// Shots on this slice after overlap merge: associated id, still-path
    /// overlap, or `t_media` inside the (possibly clamped) window (D7).
    private func shotsLinked(to slice: SliceRecord, in manifest: SessionManifest) -> [ShotRecord] {
        var out: [ShotRecord] = []
        var seen = Set<String>()
        func append(_ shot: ShotRecord?) {
            guard let shot, seen.insert(shot.id).inserted else { return }
            out.append(shot)
        }
        if let id = slice.associatedShotId {
            append(manifest.shots.first { $0.id == id })
        }
        for still in slice.stills {
            append(manifest.shots.first { shot in
                shot.stillCandidates.contains(still) || shot.rawPath == still || shot.annotatedPath == still
            })
        }
        for shot in manifest.shots where shot.tMedia >= slice.startMedia && shot.tMedia <= slice.endMedia {
            append(shot)
        }
        return out
    }

    private func uniquedPaths(_ paths: [String], sessionURL: URL) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths where !path.isEmpty {
            guard let contained = ExportRel.existingSessionFile(path, sessionURL: sessionURL),
                  ExportRel.isVisualEvidence(contained),
                  seen.insert(contained).inserted else { continue }
            out.append(contained)
        }
        return out
    }

    private func abortedForAuth(
        slice: SliceRecord,
        shots: [ShotRecord],
        product: ProductContext,
        sessionURL: URL
    ) -> (SliceRecord, [TaskRecord])? {
        guard evalAuthHasFailed() else { return nil }
        var slice = slice
        slice.analysisStatus = .offlineFailed
        let skipped = AIProviderError.httpStatus(
            401,
            "Skipped remaining slices after provider authentication failed."
        )
        return (slice, reviewTasks(
            shots: shots,
            slice: slice,
            error: skipped,
            product: product,
            sessionURL: sessionURL
        ))
    }

    private func resetEvalAuthGate() {
        evalLock.lock()
        evalAuthFailed = false
        evalLock.unlock()
    }

    private func evalAuthHasFailed() -> Bool {
        evalLock.lock()
        defer { evalLock.unlock() }
        return evalAuthFailed
    }

    private func markEvalAuthFailed() {
        evalLock.lock()
        evalAuthFailed = true
        evalLock.unlock()
    }

    /// Re-check after Whisper / clip encode. A planted session-folder symlink
    /// must not receive the transcript, clips, or zip (C2).
    private func requireUsableSession(_ sessionURL: URL, id: String) throws {
        guard ExportRel.isUsableSessionRoot(sessionURL) else {
            throw SessionVaultError.sessionMissing(id)
        }
        if (try? sessionURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.sessionMissing(id)
        }
    }

    /// D14: a denied retry or missing key must not erase slices that already evaluated.
    private func abandonEvaluate(
        manifest: inout SessionManifest,
        failedStatus: SliceAnalysisStatus,
        markOffline: Bool
    ) {
        let kept = manifest.tasks.filter { task in
            manifest.slices.first { $0.sliceId == task.sourceSliceId }?.analysisStatus == .success
        }
        for index in manifest.slices.indices where manifest.slices[index].analysisStatus != .success {
            manifest.slices[index].analysisStatus = failedStatus
        }
        // D7: pin/keyword clips still in export/ must not vanish because a Shot
        // already produced a kept task (or because consent was denied on retry).
        mergeUncoveredReview(manifest: &manifest, kept: kept)
        manifest.markCompleted(.evaluating)
        if markOffline {
            manifest.pipelineStatus = .offlineFailed
        }
    }

    /// Shots whose slice was dropped by the 12-window cap, and pin/keyword
    /// windows with no keepable candidate, still get a review row (D7).
    /// A Shot whose stills were clamped out of an evaluated slice is not
    /// "covered" by that slice's task list.
    private func mergeUncoveredReview(manifest: inout SessionManifest, kept: [TaskRecord]) {
        let local = localReviewTasks(manifest: manifest)
        let covered = Set(kept.map(\.sourceSliceId))
        let keptShotStems = shotStems(kept.flatMap(\.evidenceMedia))
        let extra = local.filter { task in
            if TaskRanking.isShotBacked(task) {
                return shotStems(task.evidenceMedia).isDisjoint(with: keptShotStems)
            }
            return !covered.contains(task.sourceSliceId)
        }
        manifest.tasks = rankedTasks(kept + extra)
    }

    private func shotStems(_ paths: [String]) -> Set<String> {
        Set(paths.compactMap { path in
            guard path.lowercased().contains("shots/") else { return nil }
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        })
    }

    private func localReviewTasks(manifest: SessionManifest) -> [TaskRecord] {
        let prefix = "[Requires Manual Review - API Offline] "
        let sessionURL = vault.sessionURL(id: manifest.sessionId)
        var coveredIds = Set<String>()
        var tasks: [TaskRecord] = []
        for shot in manifest.shots {
            let slice = sliceMatching(shot, in: manifest)
            if let id = slice?.sliceId, !id.isEmpty {
                coveredIds.insert(id)
            }
            tasks.append(
                TaskRecord(
                    taskId: String(format: "TASK-%02d", tasks.count + 1),
                    sourceSliceId: slice?.sliceId ?? "slice-\(shot.id)",
                    kind: .bug,
                    status: .needsReview,
                    title: shot.note.isEmpty ? "Human shot requires review" : shot.note,
                    observed: "Human-captured frame at t_media \(shot.tMedia)s.",
                    stated: shot.note,
                    inferred: "Provider evaluation skipped.",
                    agentInstructions: prefix + AgentInstructionTemplate.render(kind: .bug, product: manifest.productContext),
                    quotes: [],
                    evidenceMedia: uniquedPaths(
                        [shot.exportPath].compactMap { $0 }
                            + shot.stillCandidates
                            + (slice?.stills ?? []).filter { still in
                                guard let slice else { return false }
                                guard shot.tMedia >= slice.startMedia && shot.tMedia <= slice.endMedia else {
                                    return false
                                }
                                return shot.stillCandidates.contains(still)
                                    || shot.rawPath == still
                                    || shot.annotatedPath == still
                            }
                            + [slice?.exportClipPath, slice?.clipPath].compactMap { $0 }.filter { _ in
                                guard let slice else { return false }
                                return shot.tMedia >= slice.startMedia && shot.tMedia <= slice.endMedia
                            },
                        sessionURL: sessionURL
                    ),
                    confidence: 0
                )
            )
        }
        let uncovered = manifest.slices.filter { slice in
            !coveredIds.contains(slice.sliceId)
                && (!slice.stills.isEmpty
                    || !(slice.clipPath ?? "").isEmpty
                    || !(slice.exportClipPath ?? "").isEmpty)
        }
        for slice in uncovered {
            tasks.append(
                TaskRecord(
                    taskId: String(format: "TASK-%02d", tasks.count + 1),
                    sourceSliceId: slice.sliceId,
                    kind: .unknown,
                    status: .needsReview,
                    title: "Unanalyzed slice \(slice.sliceId)",
                    observed: "Slice \(slice.startMedia)s–\(slice.endMedia)s was not evaluated.",
                    stated: "",
                    inferred: "Triggered by \(slice.trigger.rawValue). Provider evaluation skipped.",
                    agentInstructions: prefix + AgentInstructionTemplate.render(kind: .unknown, product: manifest.productContext),
                    quotes: [],
                    evidenceMedia: uniquedPaths(
                        slice.stills.filter {
                            EvidenceValidator.framesOverlapSlice(
                                [$0],
                                slice: slice,
                                shots: shotsLinked(to: slice, in: manifest),
                                sessionURL: sessionURL
                            )
                        } + [slice.exportClipPath ?? slice.clipPath].compactMap { $0 },
                        sessionURL: sessionURL
                    ),
                    confidence: 0
                )
            )
        }
        if tasks.isEmpty {
            return [
                TaskRecord(
                    taskId: "TASK-01",
                    sourceSliceId: manifest.slices.first?.sliceId ?? "slice-00",
                    kind: .unknown,
                    status: .needsReview,
                    title: "Requires Manual Review - API Offline",
                    observed: "No provider upload was approved for this session.",
                    stated: "",
                    inferred: "Evaluation did not run. Local stills and clips stay on this Mac. Inspect this export folder after synthesis.",
                    agentInstructions: prefix + AgentInstructionTemplate.render(kind: .unknown, product: manifest.productContext),
                    quotes: [],
                    evidenceMedia: uniquedPaths(
                        manifest.slices.flatMap { slice in
                            slice.stills.filter {
                                EvidenceValidator.framesOverlapSlice(
                                    [$0],
                                    slice: slice,
                                    shots: shotsLinked(to: slice, in: manifest),
                                    sessionURL: sessionURL
                                )
                            } + [slice.exportClipPath ?? slice.clipPath].compactMap { $0 }
                        },
                        sessionURL: sessionURL
                    ),
                    confidence: 0
                )
            ]
        }
        return TaskRanking.selectForPack(tasks)
    }

    /// Match a Shot to its slice by `associated_shot_id`, then still-path
    /// overlap after an overlapping merge dropped the second shot's id (D7).
    /// Do not use `t_media` here: a capped-out Shot can sit inside another
    /// window and would be treated as covered, then vanish from extras.
    private func sliceMatching(_ shot: ShotRecord, in manifest: SessionManifest) -> SliceRecord? {
        if let match = manifest.slices.first(where: { $0.associatedShotId == shot.id }) {
            return match
        }
        return manifest.slices.first { slice in
            slice.stills.contains { still in
                shot.stillCandidates.contains(still) || shot.rawPath == still || shot.annotatedPath == still
            }
        }
    }

    /// Save during Whisper can land annotated PNGs after the initial manifest load.
    private func refreshShotsFromDisk(sessionId: String, manifest: inout SessionManifest) {
        func upsert(_ shot: ShotRecord) {
            if let idx = manifest.shots.firstIndex(where: { $0.id == shot.id }) {
                let current = manifest.shots[idx]
                if shot.annotatedPath != nil || current.annotatedPath == nil {
                    manifest.shots[idx] = shot
                }
            } else {
                manifest.shots.append(shot)
            }
        }
        // Corrupt catalog must not skip sidecar JSON already on disk (D7).
        if let latest = try? vault.loadManifest(id: sessionId) {
            for shot in latest.shots {
                upsert(shot)
            }
        }
        for shot in vault.loadShotSidecars(sessionId: sessionId) {
            upsert(shot)
        }
    }

    private func excerptMap(manifest: SessionManifest, transcript: FullTranscript) -> [String: String] {
        var map: [String: String] = [:]
        for task in manifest.tasks {
            if let slice = manifest.slices.first(where: { $0.sliceId == task.sourceSliceId }) {
                map[task.taskId] = TranscriptQuery.excerpt(
                    from: transcript,
                    start: slice.startMedia,
                    end: slice.endMedia
                )
            }
        }
        return map
    }
}
