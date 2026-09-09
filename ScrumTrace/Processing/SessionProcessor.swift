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
        var manifest = try vault.loadManifest(id: sessionId)
        let sessionURL = vault.sessionURL(id: sessionId)

        var timing = PipelineTiming.load(sessionURL: sessionURL) ?? PipelineTiming()

        var justFinishedTranscribing = false
        if !manifest.hasCompleted(.transcribing) {
            await onStatus(.transcribing, "Transcribing locally with WhisperKit")
            manifest.pipelineStatus = .transcribing
            try vault.write(manifest: &manifest)
            let whisperStarted = Date()
            var transcript = await transcribe(sessionURL: sessionURL, model: whisperModel)
            transcript.sessionId = sessionId
            let data = try JSONEncoder().encode(transcript)
            try data.write(to: sessionURL.appendingPathComponent(ScrumTracePath.fullTranscript))
            timing.whisperWallSeconds = Date().timeIntervalSince(whisperStarted)
            timing.whisperSources = transcript.sources ?? []
            try timing.write(sessionURL: sessionURL)
            let hadAudio = FileManager.default.fileExists(
                atPath: sessionURL.appendingPathComponent(ScrumTracePath.audioWav).path
            ) || FileManager.default.fileExists(
                atPath: sessionURL.appendingPathComponent(ScrumTracePath.sessionMovie).path
            )
            // If Whisper never loaded, leave the stage open so Retry can try again.
            // Empty speech after a successful load still completes.
            if transcriber.isReady || !hadAudio {
                manifest.markCompleted(.transcribing)
                justFinishedTranscribing = true
            }
            try vault.write(manifest: &manifest)
        }

        let transcript = loadTranscript(sessionURL: sessionURL, sessionId: sessionId)

        if justFinishedTranscribing {
            manifest.completedStages.removeAll {
                $0 == .slicing || $0 == .evaluating || $0 == .synthesizing || $0 == .completed
            }
            manifest.tasks = []
            // Persist immediately so a crash during clip export cannot leave
            // slicing marked complete on disk while the new transcript is unused.
            try vault.write(manifest: &manifest)
        }

        if !manifest.hasCompleted(.slicing) {
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
                if FileManager.default.fileExists(atPath: sessionURL.appendingPathComponent(ScrumTracePath.sessionMovie).path) {
                    do {
                        let clipped = try await exporter.export(
                            sessionURL: sessionURL,
                            slice: slice,
                            mediaDuration: manifest.duration.mediaSeconds
                        )
                        exported.append(clipped.withExistingMedia(sessionURL: sessionURL))
                    } catch {
                        // Keep the slice (shot stills, transcript window). One bad
                        // clip must not abort the session.
                        exported.append(slice.withExistingMedia(sessionURL: sessionURL))
                    }
                } else {
                    exported.append(slice.withExistingMedia(sessionURL: sessionURL))
                }
            }
            manifest.slices = exported
            manifest.markCompleted(.slicing)
            try vault.write(manifest: &manifest)
        }

        let needsEvaluate = !manifest.hasCompleted(.evaluating)
            || manifest.slices.contains { $0.analysisStatus == .offlineFailed || $0.analysisStatus == .pending }
            || (manifest.uploadConsent.approved
                && manifest.slices.contains { $0.analysisStatus == .skipped })

        if needsEvaluate {
            if !manifest.uploadConsent.approved {
                await onStatus(.evaluating, "Upload not approved — local export only")
                manifest.tasks = localReviewTasks(manifest: manifest)
                for index in manifest.slices.indices {
                    manifest.slices[index].analysisStatus = .skipped
                }
                manifest.markCompleted(.evaluating)
                try vault.write(manifest: &manifest)
            } else if configuration.kind == .anthropic && (
                configuration.model.isEmpty
                    || AIProviderConfiguration.isRetiredAnthropic(configuration.model)
            ) {
                await onStatus(.evaluating, "Anthropic model missing or retired — local export only")
                manifest.tasks = localReviewTasks(manifest: manifest)
                for index in manifest.slices.indices {
                    manifest.slices[index].analysisStatus = .skipped
                }
                manifest.markCompleted(.evaluating)
                try vault.write(manifest: &manifest)
            } else if configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await onStatus(.evaluating, "API key missing — local export only")
                manifest.tasks = localReviewTasks(manifest: manifest)
                for index in manifest.slices.indices {
                    if manifest.slices[index].analysisStatus != .success {
                        manifest.slices[index].analysisStatus = .offlineFailed
                    }
                }
                manifest.markCompleted(.evaluating)
                manifest.pipelineStatus = .offlineFailed
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
                await withTaskGroup(of: (SliceRecord, [TaskRecord]).self) { group in
                    var inflight = 0
                    for slice in toRun {
                        group.addTask {
                            await self.evaluateSlice(
                                slice: slice,
                                manifest: manifest,
                                transcript: transcript,
                                sessionURL: sessionURL,
                                provider: provider,
                                configuration: configuration
                            )
                        }
                        inflight += 1
                        if inflight >= 3 {
                            if let result = await group.next() {
                                updatedSlices.append(result.0)
                                tasks.append(contentsOf: result.1)
                                inflight -= 1
                            }
                        }
                    }
                    for await result in group {
                        updatedSlices.append(result.0)
                        tasks.append(contentsOf: result.1)
                    }
                }
                manifest.slices = updatedSlices.sorted { $0.sliceId < $1.sliceId }
                manifest.tasks = rankedTasks(tasks)
                let anyFailed = manifest.slices.contains { $0.analysisStatus == .offlineFailed }
                manifest.markCompleted(.evaluating)
                if anyFailed {
                    manifest.pipelineStatus = .offlineFailed
                }
                try vault.write(manifest: &manifest)
            }
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
            sessionURL: sessionURL
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
        if let trial = try? zipper.writeZip(
            sessionURL: sessionURL,
            includeFullTranscript: projection.manifest.includeFullTranscriptInZip
        ), trial > MediaBudget.maxZipBytes {
            await onStatus(.synthesizing, "Re-encoding clips to fit the 35 MB pack")
            await exporter.tightenExportClips(sessionURL: sessionURL)
        }
        var zipResult = SessionPackZipper.Result(
            zipURL: sessionURL.appendingPathComponent(ScrumTracePath.packZip),
            byteCount: 0,
            omitted: projection.omitted
        )
        do {
            zipResult = try zipper.zip(sessionURL: sessionURL, manifest: projection.manifest)
        } catch {
            zipResult.omitted.append(
                OmittedAsset(path: "session-pack.zip", reason: "zip failed: \(error.localizedDescription)")
            )
            try? zipper.writeOmittedMarkdown(sessionURL: sessionURL, omitted: zipResult.omitted)
        }
        var zipBytes = zipResult.byteCount
        for pass in 0..<3 {
            projection.manifest = PackBudget.stripOmitted(zipResult.omitted, from: projection.manifest)
            projection.manifest.omitted = zipResult.omitted
            projection.manifest.tasks = EvidenceValidator.applyExportEvidence(
                tasks: projection.manifest.tasks,
                sessionURL: sessionURL
            )
            do {
                try writeExportDocuments(
                    sessionURL: sessionURL,
                    projected: projection.manifest,
                    excerpts: excerpts,
                    projector: projector
                )
                try zipper.writeOmittedMarkdown(sessionURL: sessionURL, omitted: zipResult.omitted)
                zipBytes = try zipper.writeZip(
                    sessionURL: sessionURL,
                    includeFullTranscript: projection.manifest.includeFullTranscriptInZip
                )
            } catch {
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
                break
            }
        }
        timing.zipBytes = zipBytes
        timing.omittedCount = zipResult.omitted.count
        try timing.write(sessionURL: sessionURL)
        manifest.omitted = zipResult.omitted
        // C5: canonical SoT must not keep `confirmed` after export evidence was dropped.
        manifest.tasks = projection.manifest.tasks
        manifest.markCompleted(.synthesizing)
        manifest.pipelineStatus = manifest.slices.contains(where: { $0.analysisStatus == .offlineFailed })
            ? .offlineFailed
            : .completed
        manifest.markCompleted(.completed)
        try vault.write(manifest: &manifest)
        await onStatus(manifest.pipelineStatus, "Session pack ready")
        return manifest
    }

    private func writeExportDocuments(
        sessionURL: URL,
        projected: SessionManifest,
        excerpts: [String: String],
        projector: ExportProjector
    ) throws {
        let markdown = agentRenderer.render(manifest: projected)
        let prompt = agentRenderer.prompt(manifest: projected)
        let html = briefRenderer.render(manifest: projected, excerpts: excerpts)
        try markdown.write(
            to: sessionURL.appendingPathComponent(ScrumTracePath.agentContext),
            atomically: true,
            encoding: .utf8
        )
        try prompt.write(
            to: sessionURL.appendingPathComponent(ScrumTracePath.agentPrompt),
            atomically: true,
            encoding: .utf8
        )
        try html.write(
            to: sessionURL.appendingPathComponent(ScrumTracePath.sessionBrief),
            atomically: true,
            encoding: .utf8
        )
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
        let wav = sessionURL.appendingPathComponent(ScrumTracePath.audioWav)
        let movie = sessionURL.appendingPathComponent(ScrumTracePath.sessionMovie)
        let wavExists = FileManager.default.fileExists(atPath: wav.path)
        let movieExists = FileManager.default.fileExists(atPath: movie.path)
        var passes: [TranscriptQuery.SourcePass] = []
        if wavExists {
            do {
                let speaker = layout.microphoneWav ? "room" : "system"
                let wavTranscript = try await transcriber.transcribeFile(at: wav)
                passes.append(TranscriptQuery.SourcePass(speaker: speaker, transcript: wavTranscript))
            } catch {
                // Keep shots/clips; Retry Analysis can transcribe again.
            }
        }
        if layout.shouldTranscribeMovie(wavExists: wavExists, movieExists: movieExists) {
            do {
                let movieTranscript = try await transcriber.transcribeMovieAudio(at: movie)
                passes.append(TranscriptQuery.SourcePass(speaker: "system", transcript: movieTranscript))
            } catch {
                // Movie audio is optional when the WAV pass already produced segments.
            }
        }
        if passes.isEmpty {
            return FullTranscript(sessionId: "", language: "en", segments: [])
        }
        return TranscriptQuery.merge(passes, sessionId: "")
    }

    private func loadTranscript(sessionURL: URL, sessionId: String) -> FullTranscript {
        let url = sessionURL.appendingPathComponent(ScrumTracePath.fullTranscript)
        guard let data = try? Data(contentsOf: url),
              let transcript = try? JSONDecoder().decode(FullTranscript.self, from: data) else {
            return FullTranscript(sessionId: sessionId, language: "en", segments: [])
        }
        return transcript
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
        let shot = linked.first
        let shotNote = linked.map(\.note).filter { !$0.isEmpty }.joined(separator: "\n")
        if let aborted = abortedForAuth(slice: slice, shot: shot, product: manifest.productContext) {
            return aborted
        }
        var excerpt = TranscriptQuery.excerpt(from: transcript, start: slice.startMedia, end: slice.endMedia)
        if !configuration.acceptsText {
            excerpt = ""
        }
        var images: [URL] = []
        var seenImage = Set<String>()
        func appendImage(_ relative: String) {
            let url = sessionURL.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path), seenImage.insert(url.path).inserted else { return }
            images.append(url)
        }
        if let shot {
            appendImage(shot.annotatedPath ?? shot.rawPath)
        }
        for still in slice.stills {
            appendImage(still)
        }
        if !configuration.acceptsImages {
            images = []
        }
        var mediaSent: [String] = []
        if configuration.acceptsImages && !images.isEmpty {
            mediaSent.append("stills")
        }
        if !excerpt.isEmpty {
            mediaSent.append("transcript")
        }
        var clipURL: URL?
        if ProviderWireMedia.willUploadClip(configuration: configuration), let clip = slice.clipPath {
            let url = sessionURL.appendingPathComponent(clip)
            if FileManager.default.fileExists(atPath: url.path) {
                clipURL = url
            }
        }
        // media_sent is what actually leaves the Mac. Shipped adapters never
        // attach MP4, even when the internal request carries clipURL.
        slice.mediaSent = mediaSent
        let hasStill = !images.isEmpty
        // No still + no wired video upload → needs_review, do not drop the slice.
        if !ProviderWireMedia.willUploadClip(configuration: configuration)
            && !hasStill && excerpt.isEmpty && shotNote.isEmpty {
            slice.analysisStatus = .skipped
            return (
                slice,
                [fallbackOffline(
                    slice: slice,
                    error: AIProviderError.emptyResponse,
                    product: manifest.productContext
                )]
            )
        }
        if let aborted = abortedForAuth(slice: slice, shot: shot, product: manifest.productContext) {
            return aborted
        }
        let request = SliceEvaluationRequest(
            product: manifest.productContext,
            slice: slice,
            transcriptExcerpt: excerpt,
            shotNote: shotNote,
            windowContext: vault.windowContext(
                sessionId: manifest.sessionId,
                start: slice.startMedia,
                end: slice.endMedia
            ),
            imageURLs: images,
            clipURL: clipURL
        )
        do {
            let response = try await provider.evaluate(request: request)
            slice.analysisStatus = .success
            let tasks = tasks(
                from: response,
                slice: slice,
                shot: shot,
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
            if let shot {
                return (slice, [fallbackTask(shot: shot, slice: slice, error: error)])
            }
            return (slice, [fallbackOffline(slice: slice, error: error, product: manifest.productContext)])
        }
    }

    private func tasks(
        from response: CandidateEvaluationResponse,
        slice: SliceRecord,
        shot: ShotRecord?,
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
            if shot != nil && status == .dropped {
                // D7: a human Shot on this slice must stay visible.
                status = .needsReview
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
                sessionURL: sessionURL
            )
            if !issues.isEmpty && status == .confirmed {
                status = .needsReview
            }
            let resolvedFrames = EvidenceValidator.existingPaths(candidate.frameReferences, sessionURL: sessionURL)
            let uniqueEvidence = uniquedPaths(
                resolvedFrames + slice.stills + [slice.clipPath].compactMap { $0 } + [shot?.annotatedPath ?? shot?.rawPath].compactMap { $0 }
            )
            var instructions = AgentInstructionTemplate.render(
                kind: candidate.kind,
                product: product
            )
            if status == .needsReview {
                let draft = candidate.agentInstructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !draft.isEmpty {
                    instructions += "\n\n## Model notes (untrusted)\n\(PromptTemplates.wrapUntrustedInline(draft))"
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
        if let shot, out.isEmpty {
            out.append(fallbackTask(shot: shot, slice: slice, error: nil))
        }
        return out
    }

    private func rankedTasks(_ tasks: [TaskRecord]) -> [TaskRecord] {
        TaskRanking.selectForPack(tasks)
    }

    private func fallbackTask(shot: ShotRecord, slice: SliceRecord, error: Error?) -> TaskRecord {
        var evidence = slice.stills
        evidence.append(shot.annotatedPath ?? shot.rawPath)
        if let clip = slice.clipPath {
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
            agentInstructions: "[Requires Manual Review - API Offline] Inspect the linked evidence only.",
            quotes: [],
            evidenceMedia: uniquedPaths(evidence),
            confidence: 0
        )
    }

    private func fallbackOffline(slice: SliceRecord, error: Error, product: ProductContext) -> TaskRecord {
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
            evidenceMedia: uniquedPaths(slice.stills + [slice.clipPath].compactMap { $0 }),
            confidence: 0
        )
    }

    /// Shots whose stills landed on this slice after overlap merge, plus `associatedShotId`.
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
            append(manifest.shots.first { $0.rawPath == still || $0.annotatedPath == still })
        }
        return out
    }

    private func uniquedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths where !path.isEmpty && seen.insert(path).inserted {
            out.append(path)
        }
        return out
    }

    private func abortedForAuth(
        slice: SliceRecord,
        shot: ShotRecord?,
        product: ProductContext
    ) -> (SliceRecord, [TaskRecord])? {
        guard evalAuthHasFailed() else { return nil }
        var slice = slice
        slice.analysisStatus = .offlineFailed
        let skipped = AIProviderError.httpStatus(
            401,
            "Skipped remaining slices after provider authentication failed."
        )
        if let shot {
            return (slice, [fallbackTask(shot: shot, slice: slice, error: skipped)])
        }
        return (slice, [fallbackOffline(slice: slice, error: skipped, product: product)])
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

    private func localReviewTasks(manifest: SessionManifest) -> [TaskRecord] {
        if manifest.shots.isEmpty {
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
                    agentInstructions: AgentInstructionTemplate.render(kind: .unknown, product: manifest.productContext),
                    quotes: [],
                    evidenceMedia: manifest.shots.map { $0.annotatedPath ?? $0.rawPath },
                    confidence: 0
                )
            ]
        }
        let tasks = manifest.shots.enumerated().map { index, shot in
            TaskRecord(
                taskId: String(format: "TASK-%02d", index + 1),
                sourceSliceId: manifest.slices.first(where: { $0.associatedShotId == shot.id })?.sliceId ?? "slice-shot",
                kind: .bug,
                status: .needsReview,
                title: shot.note.isEmpty ? "Human shot requires review" : shot.note,
                observed: "Human-captured frame at t_media \(shot.tMedia)s.",
                stated: shot.note,
                inferred: "Provider evaluation skipped.",
                agentInstructions: AgentInstructionTemplate.render(kind: .bug, product: manifest.productContext),
                quotes: [],
                evidenceMedia: [shot.annotatedPath ?? shot.rawPath],
                confidence: 0
            )
        }
        return TaskRanking.selectForPack(tasks)
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
