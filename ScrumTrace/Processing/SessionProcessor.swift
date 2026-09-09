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

        if !manifest.hasCompleted(.transcribing) {
            await onStatus(.transcribing, "Transcribing locally with WhisperKit")
            manifest.pipelineStatus = .transcribing
            try vault.write(manifest: &manifest)
            var transcript = try await transcribe(sessionURL: sessionURL, model: whisperModel)
            transcript.sessionId = sessionId
            let data = try JSONEncoder().encode(transcript)
            try data.write(to: sessionURL.appendingPathComponent(ScrumTracePath.fullTranscript))
            manifest.markCompleted(.transcribing)
            try vault.write(manifest: &manifest)
        }

        let transcript = loadTranscript(sessionURL: sessionURL, sessionId: sessionId)

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
                    exported.append(try await exporter.export(
                        sessionURL: sessionURL,
                        slice: slice,
                        mediaDuration: manifest.duration.mediaSeconds
                    ))
                } else {
                    exported.append(slice)
                }
            }
            manifest.slices = exported
            manifest.markCompleted(.slicing)
            try vault.write(manifest: &manifest)
        }

        if !manifest.hasCompleted(.evaluating) {
            await onStatus(.evaluating, "Evaluating slices with the configured model")
            manifest.pipelineStatus = .evaluating
            let provider = AIEngine.make(configuration: configuration)
            var tasks: [TaskRecord] = []
            var updatedSlices: [SliceRecord] = []
            await withTaskGroup(of: (SliceRecord, [TaskRecord]).self) { group in
                var inflight = 0
                for slice in manifest.slices {
                    group.addTask {
                        await self.evaluateSlice(
                            slice: slice,
                            manifest: manifest,
                            transcript: transcript,
                            sessionURL: sessionURL,
                            provider: provider
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

        await onStatus(.synthesizing, "Writing AGENT_CONTEXT.md and SESSION_BRIEF.html")
        manifest.pipelineStatus = .synthesizing
        let excerpts = excerptMap(manifest: manifest, transcript: transcript)
        let markdown = agentRenderer.render(manifest: manifest)
        let prompt = agentRenderer.prompt(manifest: manifest)
        let html = briefRenderer.render(manifest: manifest, excerpts: excerpts)
        try markdown.write(to: sessionURL.appendingPathComponent(ScrumTracePath.agentContext), atomically: true, encoding: .utf8)
        try prompt.write(to: sessionURL.appendingPathComponent(ScrumTracePath.agentPrompt), atomically: true, encoding: .utf8)
        try html.write(to: sessionURL.appendingPathComponent(ScrumTracePath.sessionBrief), atomically: true, encoding: .utf8)
        _ = try zipper.zip(sessionURL: sessionURL, manifest: manifest)
        manifest.markCompleted(.synthesizing)
        manifest.pipelineStatus = manifest.slices.contains(where: { $0.analysisStatus == .offlineFailed })
            ? .offlineFailed
            : .completed
        manifest.markCompleted(.completed)
        try vault.write(manifest: &manifest)
        await onStatus(manifest.pipelineStatus, "Session pack ready")
        return manifest
    }

    private func transcribe(sessionURL: URL, model: String) async throws -> FullTranscript {
        if !transcriber.isReady {
            try await transcriber.prepare(model: model)
        }
        let wav = sessionURL.appendingPathComponent(ScrumTracePath.audioWav)
        if FileManager.default.fileExists(atPath: wav.path) {
            return try await transcriber.transcribeFile(at: wav)
        }
        return FullTranscript(sessionId: "", language: "en", segments: [])
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
        provider: any AIProvider
    ) async -> (SliceRecord, [TaskRecord]) {
        var slice = slice
        let excerpt = TranscriptQuery.excerpt(from: transcript, start: slice.startMedia, end: slice.endMedia)
        let shot = manifest.shots.first { $0.id == slice.associatedShotId }
        let images = slice.stills.map { sessionURL.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let request = SliceEvaluationRequest(
            product: manifest.productContext,
            slice: slice,
            transcriptExcerpt: excerpt,
            shotNote: shot?.note ?? "",
            windowContext: "",
            imageURLs: images
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
                sessionURL: sessionURL
            )
            return (slice, tasks)
        } catch {
            slice.analysisStatus = .offlineFailed
            if let shot {
                return (slice, [fallbackTask(shot: shot, slice: slice, error: error)])
            }
            return (slice, [fallbackOffline(slice: slice, error: error)])
        }
    }

    private func tasks(
        from response: CandidateEvaluationResponse,
        slice: SliceRecord,
        shot: ShotRecord?,
        product: ProductContext,
        transcript: FullTranscript,
        sessionURL: URL
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
            let evidence = (slice.stills + [slice.clipPath].compactMap { $0 } + [shot?.annotatedPath ?? shot?.rawPath].compactMap { $0 })
            let uniqueEvidence = Array(NSOrderedSet(array: evidence)) as? [String] ?? evidence
            out.append(
                TaskRecord(
                    taskId: String(format: "TASK-%02d", out.count + 1),
                    sourceSliceId: slice.sliceId,
                    kind: candidate.kind == .unknown ? .bug : candidate.kind,
                    status: status,
                    title: candidate.title.isEmpty ? "Untitled candidate \(index + 1)" : candidate.title,
                    observed: candidate.observed,
                    stated: candidate.stated,
                    inferred: candidate.inferred,
                    agentInstructions: AgentInstructionTemplate.render(
                        kind: candidate.kind,
                        product: product
                    ),
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
        let kept = tasks.filter { $0.status != .dropped }
        let limited = Array(kept.prefix(MediaBudget.maxTasks))
        return limited.enumerated().map { index, task in
            var copy = task
            copy.taskId = String(format: "TASK-%02d", index + 1)
            return copy
        }
    }

    private func fallbackTask(shot: ShotRecord, slice: SliceRecord, error: Error?) -> TaskRecord {
        TaskRecord(
            taskId: "TASK-SHOT",
            sourceSliceId: slice.sliceId,
            kind: .bug,
            status: .needsReview,
            title: shot.note.isEmpty ? "Human shot requires review" : shot.note,
            observed: "Human-captured frame at t_media \(shot.tMedia)s.",
            stated: shot.note,
            inferred: error.map { "Analysis unavailable: \($0.localizedDescription)" } ?? "Requires manual review.",
            agentInstructions: "[Requires Manual Review - API Offline] Inspect \(shot.annotatedPath ?? shot.rawPath).",
            quotes: [],
            evidenceMedia: [shot.annotatedPath ?? shot.rawPath, slice.clipPath].compactMap { $0 },
            confidence: 0
        )
    }

    private func fallbackOffline(slice: SliceRecord, error: Error) -> TaskRecord {
        TaskRecord(
            taskId: "TASK-OFFLINE",
            sourceSliceId: slice.sliceId,
            kind: .unknown,
            status: .needsReview,
            title: "Unanalyzed slice \(slice.sliceId)",
            observed: "Slice \(slice.startMedia)s–\(slice.endMedia)s was not evaluated.",
            stated: "",
            inferred: error.localizedDescription,
            agentInstructions: "[Requires Manual Review - API Offline]",
            quotes: [],
            evidenceMedia: slice.stills + [slice.clipPath].compactMap { $0 },
            confidence: 0
        )
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
