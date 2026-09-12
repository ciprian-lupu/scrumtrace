import Combine
import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
#endif

@MainActor
final class SessionController: ObservableObject {
    @Published var phase: PipelineStatus = .idle
    @Published var mediaElapsed: TimeInterval = 0
    @Published var wallElapsed: TimeInterval = 0
    @Published var statusLine: String = "Ready"
    @Published var lastError: String?
    @Published var lastSessionId: String?
    @Published var isBusy = false
    @Published var suppressHUD = false
    @Published private(set) var startInFlight = false

    let settings: AppSettings
    let vault: SessionVault
    let transcriber = WhisperTranscriber()
    let sampler = MetadataSampler()
    let privacy = PrivacyGuard()
    let clock = ClockSynchronizer()

    private var recorder: SessionRecorder?
    private var processor: SessionProcessor?
    private var hudTimer: Timer?
    private var hudTickCount = 0
    private var metadataTimer: Timer?
    private var pinTimes: [TimeInterval] = []
    private var pinTimesSessionId: String?
    private var sessionURL: URL?
    private var manifest: SessionManifest?
    private var shotWindow: ShotNoteWindow?
    private var pausedByPrivacy = false
    private var lastMetaSignature = ""
    private var terminateRequested = false
    let captureFreeze: CaptureFreeze

    init(settings: AppSettings, vault: SessionVault = SessionVault()) {
        self.settings = settings
        self.vault = vault
        self.processor = SessionProcessor(vault: vault, transcriber: transcriber)
        let freeze = CaptureFreeze(sampler: sampler)
        self.captureFreeze = freeze
        privacy.freezeCapture = { freeze.freeze() }
        privacy.onTrip = { [weak self] bundle in
            Task { @MainActor in
                self?.privacyPause(bundle: bundle)
            }
        }
        privacy.onClear = { [weak self] in
            Task { @MainActor in
                self?.privacyResume()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .scrumTraceCaptureFailed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.object as? String) ?? "Screen capture stopped."
            Task { @MainActor in
                self?.handleCaptureStreamFailure(message)
            }
        }
        vault.pruneAbandonedStarts()
        if let recent = vault.recentSessions(limit: 1).first {
            lastSessionId = recent.sessionId
            switch recent.pipelineStatus {
            case .idle, .completed:
                break
            case .recording, .paused, .transcribing, .slicing, .evaluating, .synthesizing, .offlineFailed:
                statusLine = "Last session is unfinished — Retry Analysis to finish"
                AgentLog.event("interrupted_session", ["status": recent.pipelineStatus.rawValue])
            }
        }
    }

    var isRecording: Bool {
        phase == .recording || phase == .paused
    }

    var canChangeCaptureSettings: Bool {
        !isRecording && !isBusy && !startInFlight
    }

    var hudShouldShow: Bool {
        (isRecording || isBusy || startInFlight) && !suppressHUD
    }

    func startRecording() {
        startRecording(product: settings.productContext)
    }

    func startRecording(product: ProductContext) {
        guard !isRecording, !isBusy, !startInFlight else {
            AgentLog.event("start_ignored", [
                "recording": isRecording ? "1" : "0",
                "busy": isBusy ? "1" : "0",
                "inflight": startInFlight ? "1" : "0",
            ])
            return
        }
        #if os(macOS)
        // Do not open System Settings or call ScreenCaptureKit here. Those
        // both look like "the app is asking again" when the user already
        // flipped a ScrumTrace row that belongs to a different binary.
        let readiness = CapturePermissions.readiness(requireMicrophone: settings.includeMicrophone)
        if !readiness.allowsStart {
            lastError = readiness.userMessage
            statusLine = readiness.menuLabel
            AgentLog.event("start_blocked", ["reason": CapturePermissions.readinessLabel()])
            return
        }
        #endif
        startInFlight = true
        captureFreeze.markStartInFlight(true)
        statusLine = "Starting capture…"
        AgentLog.event("start_requested", [:])
        Task { await startRecordingAsync(product: product) }
    }

    func stopRecording() {
        AgentLog.event("stop_clicked", [
            "session": manifest?.sessionId ?? "",
            "recording": isRecording ? "1" : "0",
            "busy": isBusy ? "1" : "0",
            "inflight": startInFlight ? "1" : "0"
        ])
        // Freeze before the unstructured Task hop so HUD/menu Stop cannot
        // leave a window where SCStream still appends (C1).
        recorder?.freezeWriters()
        sampler.isSuspended = true
        NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.paused)
        Task { await stopRecordingAsync() }
    }

    /// SCStream died. Freeze already happened on the writer queue. Finish the
    /// session through Stop so Whisper still runs on whatever was captured.
    private func handleCaptureStreamFailure(_ message: String) {
        guard isRecording else { return }
        lastError = message
        statusLine = "Capture ended: \(message)"
        AgentLog.event("capture_stream_failed", ["error": AgentLog.sanitize(message)])
        stopRecording()
    }

    func togglePause() {
        guard isRecording else { return }
        // Follow the writer, not `phase`. Privacy freeze pauses the recorder
        // before MainActor sets `.paused`; Opt+⌘P must not take the Pause
        // branch and clear `pausedByPrivacy` (C1).
        if captureState == .paused {
            if privacy.isCurrentlyTripped || privacy.currentCredentialApp() != nil {
                statusLine = "Still auto-paused for a password manager"
                AgentLog.event("resume_blocked", ["reason": "privacy"])
                return
            }
            if !unpauseCaptureIfPrivacyClear() {
                statusLine = "Still auto-paused for a password manager"
                AgentLog.event("resume_blocked", ["reason": "privacy"])
                return
            }
            pausedByPrivacy = false
            phase = .recording
            statusLine = "Recording"
            AgentLog.event("resume_ok", ["source": "toggle"])
            log(.resume, [:])
            persistLivePipelineStatus()
            NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.recording)
            kickMetadataSample()
        } else {
            pausedByPrivacy = false
            recorder?.setPaused(true)
            sampler.isSuspended = true
            phase = .paused
            statusLine = "Paused — nothing is written"
            AgentLog.event("pause_ok", [
                "source": "toggle",
                "t_media": String(clock.currentMediaSeconds())
            ])
            log(.pause, [:])
            persistLivePipelineStatus()
            NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.paused)
        }
    }

    func pin() {
        if !isRecording {
            AgentLog.event("pin_ignored", ["reason": "not_recording"])
        }
        guard isRecording else { return }
        guard captureState.allowsNewCapture else {
            AgentLog.event("pin_ignored", ["reason": "paused"])
            return
        }
        let media = clock.currentMediaSeconds()
        pinTimes.append(media)
        pinTimesSessionId = manifest?.sessionId
        AgentLog.event("pin_ok", ["t_media": String(format: "%.2f", media)])
        log(.pin, ["t_media": String(format: "%.2f", media)])
        statusLine = "Pinned \(Self.clock(media))"
        flashStatus()
    }

    var captureState: CaptureSessionState {
        // Privacy freeze can pause the recorder on a background queue before
        // MainActor updates `phase`. Shot/Pin/Hold-to-Talk must follow the writer.
        if recorder?.isPaused == true {
            return .paused
        }
        return phase == .paused ? .paused : (phase == .recording ? .recording : .paused)
    }

    var canResumeFromPause: Bool {
        phase == .paused
            && !privacy.isCurrentlyTripped
            && privacy.currentCredentialApp() == nil
    }

    func openShot() {
        if !isRecording {
            AgentLog.event("shot_ignored", ["reason": "not_recording"])
        }
        guard isRecording else { return }
        guard captureState.allowsNewCapture else {
            statusLine = "Paused — Shot is disabled"
            AgentLog.event("shot_ignored", ["reason": "paused"])
            return
        }
        AgentLog.event("shot_begin", ["session": manifest?.sessionId ?? ""])
        Task { await captureShot() }
    }

    func retryAnalysis() {
        guard let id = lastSessionId ?? manifest?.sessionId else {
            AgentLog.event("retry_ignored", ["reason": "no_session"])
            return
        }
        retryAnalysis(sessionId: id)
    }

    func retryAnalysis(sessionId: String) {
        guard !isBusy, !isRecording, !startInFlight else {
            statusLine = isBusy ? "Already processing a session" : "Stop recording before retry"
            AgentLog.event("retry_ignored", [
                "reason": isBusy ? "busy" : "recording",
                "session": sessionId
            ])
            return
        }
        guard AgentLog.setSessionContext(sessionId) else {
            statusLine = "Could not bind retry diagnostics to this session"
            AgentLog.event("retry_ignored", ["reason": "session_context"])
            return
        }
        isBusy = true
        AgentLog.event("retry_begin", ["session": sessionId])
        lastSessionId = sessionId
        Task { await runProcessor(sessionId: sessionId) }
    }

    func updateSpeakers(sessionId: String, names: [String: String]? = nil, assignments: [Int: String] = [:], reanalyze: Bool = false) async throws -> FullTranscript {
        guard canChangeCaptureSettings, let processor else {
            throw SettingsValidationError("Wait for recording or analysis to finish.")
        }
        let previousPhase = phase
        isBusy = true
        lastSessionId = sessionId
        defer { isBusy = false; phase = previousPhase }
        do {
            let transcript = try await processor.updateSpeakers(sessionId: sessionId, names: names, assignments: assignments, reanalyze: reanalyze) { [weak self] phase, message in
                self?.phase = phase
                self?.statusLine = message
            }
            statusLine = "Speaker review saved locally; export updated"
            return transcript
        } catch {
            statusLine = "Could not finish updating the speaker export"
            throw error
        }
    }

    func revealLast() {
        if let id = lastSessionId ?? manifest?.sessionId {
            vault.revealInFinder(sessionId: id)
        }
    }

    /// Opt+⌘P already froze writers on the Carbon thread. Do not treat that
    /// freeze as Resume (`captureState` follows `recorder.isPaused`).
    func applyHotkeyPause(didFreezeWriters: Bool) {
        if startInFlight && !isRecording {
            captureFreeze.holdPauseThroughStart()
            sampler.isSuspended = true
            AgentLog.event("pause_ok", [
                "source": "hotkey_hold_start",
                "t_media": String(clock.currentMediaSeconds())
            ])
            return
        }
        guard isRecording else { return }
        if didFreezeWriters {
            pausedByPrivacy = false
            sampler.isSuspended = true
            phase = .paused
            statusLine = "Paused — nothing is written"
            AgentLog.event("pause_ok", [
                "source": "hotkey",
                "t_media": String(clock.currentMediaSeconds())
            ])
            log(.pause, ["source": "hotkey"])
            persistLivePipelineStatus()
            return
        }
        togglePause()
    }

    /// Process is quitting: freeze capture. Do not start Whisper/AI on a dying process.
    func haltCaptureForTermination() {
        terminateRequested = true
        AgentLog.event("halt", ["recording": isRecording ? "1" : "0", "inflight": startInFlight ? "1" : "0"])
        if !isRecording {
            // Start is awaiting Screen Recording permission / startCapture.
            // Freeze the attached recorder so writers cannot outlive Quit.
            if startInFlight {
                captureFreeze.freeze()
                privacy.stop()
            }
            return
        }
        privacy.stop()
        sampler.isSuspended = true
        hudTimer?.invalidate()
        hudTimer = nil
        metadataTimer?.invalidate()
        metadataTimer = nil
        recorder?.freezeWriters()
        do {
            try recorder?.persistCaptureLayout()
        } catch {
            lastError = error.localizedDescription
        }
        NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.paused)
        NotificationCenter.default.post(name: .scrumTraceSessionEnding, object: nil)
        persistInterruptedCapture()
        let rec = recorder
        recorder = nil
        captureFreeze.attach(nil)
        phase = .idle
        isBusy = false
        statusLine = "Stopped"
        // Close the movie/WAV before the process is killed. Do not start Whisper/AI.
        let lock = DispatchSemaphore(value: 0)
        let stopBox = HaltStopBox()
        Task.detached {
            do {
                try await rec?.stop()
            } catch {
                stopBox.message = error.localizedDescription
            }
            lock.signal()
        }
        let waitResult = lock.wait(timeout: .now() + 5)
        if let message = stopBox.message {
            lastError = message
            AgentLog.event("halt_stop_fail", ["error": AgentLog.sanitize(message)])
            log(.error, ["reason": "quit-stop", "error": message])
        } else if waitResult == .timedOut {
            lastError = "Quit wait for movie close timed out."
            AgentLog.event("halt_stop_timeout", [:])
            log(.error, ["reason": "quit-stop-timeout"])
        } else {
            AgentLog.event("halt_stop_ok", [:])
        }
        if let sessionId = manifest?.sessionId {
            AgentLog.clearSessionContext(matching: sessionId)
        }
        AgentLog.setRecording(false, sessionId: nil)
    }

    private func persistInterruptedCapture() {
        guard var local = manifest else { return }
        local.duration = DurationPair(
            wallSeconds: clock.currentWallSeconds(),
            mediaSeconds: clock.currentMediaSeconds()
        )
        local.pauses = clock.snapshotPauses()
        local.pipelineStatus = .idle
        do {
            try vault.write(manifest: &local)
        } catch {
            lastError = error.localizedDescription
        }
        manifest = local
        log(.stop, ["reason": "quit"])
    }

    private func startRecordingAsync(product: ProductContext) async {
        defer { startInFlight = false }
        defer { captureFreeze.markStartInFlight(false) }
        guard !isRecording, !isBusy else {
            AgentLog.event("start_aborted", [
                "recording": isRecording ? "1" : "0",
                "busy": isBusy ? "1" : "0"
            ])
            return
        }
        lastError = nil
        var abandonedId: String?
        do {
            let created = try vault.createSession(product: product)
            abandonedId = created.manifest.sessionId
            guard AgentLog.setSessionContext(created.manifest.sessionId) else {
                throw SessionRecorderError.writerFailed(
                    "Could not bind diagnostics to the new session."
                )
            }
            sessionURL = created.url
            var createdManifest = created.manifest
            createdManifest.includeFullTranscriptInZip = settings.includeFullTranscriptInZip
            try vault.write(manifest: &createdManifest)
            manifest = createdManifest
            lastMetaSignature = ""
            pausedByPrivacy = false
            clock.reset()
            // Do not touch Accessibility on Record. Silent AX checks belong
            // in MetadataSampler.readFrontmost. prompt:true lives only on
            // the Settings button. Screen Recording is preflighted above.
            let recorder = SessionRecorder(sessionURL: created.url, clock: clock)
            captureFreeze.attach(recorder)
            // Tick before startCapture: a credential app during the permission
            // sheet must freeze writers, not wait until start() returns (C1).
            privacy.start()
            statusLine = "Starting ScreenCaptureKit…"
            let pauseGate: @Sendable () -> Bool = { [privacy, captureFreeze] in
                privacy.isCurrentlyTripped || privacy.currentCredentialApp() != nil || captureFreeze.isHeldThroughStart
            }
            // Lock before startCapture so a crash mid-start is visible to the
            // LaunchAgent (CL-05). Keep it through Whisper so a rebuild cannot
            // pkill during finishWriting or processing.
            AgentLog.setRecording(true, sessionId: created.manifest.sessionId)
            // Await (do not Task.detached.value from MainActor). A detached
            // wrapper that MainActor waits on deadlocks if SCKit hops to main.
            try await recorder.start(
                shouldPauseCapture: pauseGate,
                captureArea: settings.captureArea,
                showCursor: settings.showCursor,
                includeMicrophone: settings.includeMicrophone
            )
            abandonedId = nil
            self.recorder = recorder
            lastSessionId = created.manifest.sessionId
            AgentLog.event("start_ok", [
                "session": created.manifest.sessionId,
                "area": settings.captureArea.isEntireDisplay ? "full" : "region"
            ])
            pinTimes = []
            pinTimesSessionId = created.manifest.sessionId
            // Quit may have frozen writers while start() was still awaiting.
            // Do not unpause, and finish through halt instead of the privacy timer.
            if terminateRequested {
                phase = .paused
                haltCaptureForTermination()
                return
            }
            if let writeFail = recorder.audioWriteFailure {
                lastError = writeFail
                phase = .recording
                statusLine = writeFail
                AgentLog.event("start_audio_write_fail", ["error": AgentLog.sanitize(writeFail)])
                stopRecording()
                return
            }
            if captureFreeze.consumeHoldThroughStart() {
                recorder.setPaused(true)
                sampler.isSuspended = true
                pausedByPrivacy = false
                phase = .paused
                statusLine = "Paused — nothing is written"
                log(.pause, ["source": "hotkey"])
                persistLivePipelineStatus()
                NotificationCenter.default.post(
                    name: .scrumTraceCaptureGate,
                    object: CaptureSessionState.paused
                )
            } else if let bundle = privacy.currentCredentialApp() {
                recorder.setPaused(true)
                sampler.isSuspended = true
                pausedByPrivacy = true
                phase = .paused
                statusLine = "Auto-paused for \(bundle)"
                log(.privacyPause, ["bundle": bundle])
                NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.paused)
            } else {
                if recorder.isPaused {
                    recorder.setPaused(false)
                }
                // CaptureFreeze can land between currentCredentialApp() == nil
                // and this unpause. Do not unsuspend metadata from `phase`
                // alone — that would clear a freeze that just posted (C1).
                if unpauseCaptureIfPrivacyClear() {
                    phase = .recording
                    statusLine = settings.captureArea.isEntireDisplay
                        ? "Recording"
                        : "Recording \(settings.captureArea.summary)"
                    NotificationCenter.default.post(
                        name: .scrumTraceCaptureGate,
                        object: CaptureSessionState.recording
                    )
                } else {
                    pausedByPrivacy = true
                    phase = .paused
                    let bundle = privacy.currentCredentialApp() ?? "a password manager"
                    statusLine = "Auto-paused for \(bundle)"
                    log(.privacyPause, ["bundle": bundle])
                    NotificationCenter.default.post(
                        name: .scrumTraceCaptureGate,
                        object: CaptureSessionState.paused
                    )
                }
            }
            if var local = manifest {
                local.pipelineStatus = phase
                do {
                    try vault.write(manifest: &local)
                } catch {
                    lastError = error.localizedDescription
                }
                manifest = local
            }
            startTimer()
            log(.start, [:])
            let transcriber = self.transcriber
            transcriber.setLanguage(settings.speechLanguage)
            let model = settings.whisperModel
            Task.detached {
                do {
                    try await transcriber.prepare(model: model)
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run { [weak self] in
                        self?.lastError = message
                    }
                }
            }
        } catch {
            privacy.stop()
            captureFreeze.attach(nil)
            clock.reset()
            if let id = abandonedId {
                if manifest?.sessionId == id {
                    manifest = nil
                }
                if sessionURL?.lastPathComponent == id {
                    sessionURL = nil
                }
                vault.removeAbandonedSession(id: id)
                AgentLog.clearSessionContext(matching: id)
            }
            lastError = error.localizedDescription
            statusLine = error.localizedDescription
            AgentLog.setRecording(false, sessionId: nil)
            AgentLog.event("start_fail", ["error": AgentLog.sanitize(error.localizedDescription)])
            #if os(macOS)
            Self.presentStartFailureAlert(error.localizedDescription)
            #endif
        }
    }

    private func stopRecordingAsync() async {
        guard isRecording else {
            AgentLog.event("stop_ignored", ["reason": "not_recording"])
            return
        }
        isBusy = true
        statusLine = "Stopping capture"
        AgentLog.event("stop_requested", ["session": manifest?.sessionId ?? ""])
        privacy.stop()
        sampler.isSuspended = true
        // Freeze writers immediately without resuming a paused session (C1).
        recorder?.freezeWriters()
        NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.paused)
        NotificationCenter.default.post(name: .scrumTraceSessionEnding, object: nil)
        phase = .transcribing
        do {
            if let recorder {
                try await Self.stopWithTimeout(recorder)
            }
            AgentLog.event("stop_capture_ok", ["session": manifest?.sessionId ?? ""])
        } catch {
            lastError = error.localizedDescription
            AgentLog.event("stop_capture_fail", ["error": AgentLog.sanitize(error.localizedDescription)])
        }
        do {
            try recorder?.reclaimLiveCaptureIfRewritten()
        } catch {
            lastError = error.localizedDescription
        }
        hudTimer?.invalidate()
        hudTimer = nil
        metadataTimer?.invalidate()
        metadataTimer = nil
        var local = manifest
        local?.pipelineStatus = .transcribing
        local?.duration = DurationPair(
            wallSeconds: clock.currentWallSeconds(),
            mediaSeconds: clock.currentMediaSeconds()
        )
        local?.pauses = clock.snapshotPauses()
        if var local {
            do {
                try vault.write(manifest: &local)
            } catch {
                lastError = error.localizedDescription
                statusLine = "Could not persist session catalog; Stop still continues with in-memory shots."
            }
            manifest = local
            log(.stop, recorder?.captureFailureReason.map { ["error": $0] } ?? [:])
            await runProcessor(sessionId: local.sessionId)
        } else {
            isBusy = false
            phase = .offlineFailed
            statusLine = "Session manifest missing after stop"
            AgentLog.event("stop_manifest_missing", [:])
            if let sessionId = lastSessionId ?? sessionURL?.lastPathComponent {
                AgentLog.clearSessionContext(matching: sessionId)
            }
        }
        recorder = nil
        captureFreeze.attach(nil)
        AgentLog.setRecording(false, sessionId: nil)
    }

    static let stopCaptureTimeoutSeconds: TimeInterval = 30

    /// `SCStream.stopCapture` / `finishWriting` have no deadline of their own. A
    /// hung teardown must not leave the HUD on "Stopping capture" with Start and
    /// Retry disabled forever; processing continues on whatever reached disk.
    private static func stopWithTimeout(_ recorder: SessionRecorder) async throws {
        // Not a task group: `stop()` ends in a non-cancellable finishWriting
        // continuation, and a group would keep waiting on it after cancelAll().
        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            let once = StopResumeOnce()
            Task.detached {
                do {
                    try await recorder.stop()
                    once.resume(continuation, .success(()))
                } catch {
                    once.resume(continuation, .failure(error))
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(stopCaptureTimeoutSeconds * 1_000_000_000))
                let fired = once.resume(continuation, .failure(NSError(
                    domain: "ScrumTrace",
                    code: 13,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Capture teardown timed out after \(Int(stopCaptureTimeoutSeconds))s; processing what was written."
                    ]
                )))
                if fired {
                    AgentLog.event("stop_capture_timeout", ["seconds": String(Int(stopCaptureTimeoutSeconds))])
                }
            }
        }
        try outcome.get()
    }

    private func runProcessor(sessionId: String) async {
        isBusy = true
        defer {
            AgentLog.clearSessionContext(matching: sessionId)
        }
        AgentLog.event("processor_begin", ["session": sessionId])
        do {
            var local = try? vault.loadManifest(id: sessionId)
            if let memory = manifest, memory.sessionId == sessionId {
                if let disk = local {
                    local = Self.mergeLiveCatalog(disk: disk, memory: memory)
                } else {
                    local = memory
                }
            }
            if var local {
                local.includeFullTranscriptInZip = settings.includeFullTranscriptInZip
                let capabilities = settings.providerConfiguration()
                let hasAPIKey = !capabilities.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // No key means nothing can leave this Mac; asking a first-time
                // local-only user to approve an upload would only confuse them.
                if !hasAPIKey {
                    AgentLog.event("consent_skipped", ["reason": "key_missing"])
                } else if local.uploadConsent.needsReprompt(
                    provider: settings.provider.rawValue,
                    endpoint: settings.baseURL,
                    model: settings.model,
                    acceptsVideo: ProviderWireMedia.willUploadClip(configuration: capabilities)
                ) {
                    let previous = local.uploadConsent
                    let askedBefore = !previous.provider.isEmpty
                    local.uploadConsent = requestUploadConsent()
                    if askedBefore && (
                        previous.provider != local.uploadConsent.provider
                        || previous.endpoint != local.uploadConsent.endpoint
                        || previous.model != local.uploadConsent.model
                        || previous.includesClipAudio != local.uploadConsent.includesClipAudio
                        || previous.includesClipVideo != local.uploadConsent.includesClipVideo
                    ) {
                        local.completedStages.removeAll {
                            $0 == .evaluating || $0 == .synthesizing || $0 == .completed
                        }
                        local.tasks = []
                        for index in local.slices.indices {
                            local.slices[index].analysisStatus = .pending
                        }
                    }
                }
                try vault.write(manifest: &local)
                manifest = local
            }
            let storedPins = vault.loadPinTimes(sessionId: sessionId)
            let livePins = pinTimesSessionId == sessionId ? pinTimes : []
            let pins = Self.mergePins(livePins, storedPins)
            transcriber.setLanguage(settings.speechLanguage)
            let result = try await processor?.process(
                sessionId: sessionId,
                pinTimes: pins,
                configuration: settings.providerConfiguration(),
                whisperModel: settings.whisperModel,
                identifySpeakers: settings.identifySpeakers,
                onStatus: { [weak self] status, line in
                    AgentLog.event("pipeline_status", [
                        "status": status.rawValue,
                        "line": AgentLog.sanitize(line)
                    ])
                    self?.phase = status
                    self?.statusLine = line
                }
            )
            if let result {
                AgentLog.event("processor_ok", [
                    "session": result.sessionId,
                    "phase": result.pipelineStatus.rawValue
                ])
                manifest = result
                lastSessionId = result.sessionId
                phase = result.pipelineStatus
                vault.revealInFinder(sessionId: result.sessionId)
            } else {
                AgentLog.event("processor_fail", ["session": sessionId, "error": "processor_missing"])
            }
        } catch {
            lastError = error.localizedDescription
            phase = .offlineFailed
            statusLine = error.localizedDescription
            AgentLog.event("processor_fail", [
                "session": sessionId,
                "error": AgentLog.sanitize(error.localizedDescription)
            ])
        }
        isBusy = false
    }

    private func requestUploadConsent() -> UploadConsent {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Send stills and transcript excerpts off this Mac?"
        let capabilities = settings.providerConfiguration()
        let uploadsClip = ProviderWireMedia.willUploadClip(configuration: capabilities)
        let payload: String
        if uploadsClip {
            payload = "Stills and transcript excerpts, and clip audio will leave this Mac, plus window titles, scrubbed URLs, Shot notes, product context, and the 720p clip video. Clip audio includes the room microphone and call audio."
        } else {
            payload = "Stills and transcript excerpts will leave this Mac, plus window titles, scrubbed URLs, Shot notes, and product context. Clip video and the master movie are not uploaded."
        }
        alert.informativeText = """
        Destination: \(settings.provider.title)
        \(settings.baseURL)
        Model: \(settings.model.isEmpty ? "(none)" : settings.model)

        \(payload) The archive (session.mp4, full transcript, raw events) stays local. Keychain storage is not consent. This sheet runs at Stop before transcription.
        """
        alert.addButton(withTitle: "Approve upload")
        alert.addButton(withTitle: "Local export only")
        let approved = alert.runModal() == .alertFirstButtonReturn
        AgentLog.event("consent_result", [
            "approved": approved ? "1" : "0",
            "provider": settings.provider.rawValue,
            "clip": (approved && uploadsClip) ? "1" : "0"
        ])
        return UploadConsent(
            approved: approved,
            approvedAt: Date(),
            provider: settings.provider.rawValue,
            endpoint: settings.baseURL,
            model: settings.model,
            includesClipAudio: approved && uploadsClip,
            includesClipVideo: approved && uploadsClip,
            includesStills: approved
        )
        #else
        return .denied
        #endif
    }

    private func captureShot() async {
        guard let sessionURL, let manifest else { return }
        suppressHUD = true
        NotificationCenter.default.post(name: .scrumTraceHUDSuppress, object: nil)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)
        defer {
            suppressHUD = false
            NotificationCenter.default.post(name: .scrumTraceHUDSuppress, object: nil)
        }
        if !captureState.allowsNewCapture {
            AgentLog.event("shot_fail", ["reason": "paused"])
        }
        guard captureState.allowsNewCapture else { return }
        let media = clock.currentMediaSeconds()
        guard let image = ScreenSnap.capture(area: settings.captureArea) else {
            lastError = "Could not capture the display."
            statusLine = "Shot failed: could not capture the display."
            AgentLog.event("shot_fail", ["reason": "display"])
            return
        }
        // Pause can land during CGDisplayCreateImage. Do not persist that frame (C1).
        if !captureState.allowsNewCapture {
            AgentLog.event("shot_fail", ["reason": "paused"])
        }
        guard captureState.allowsNewCapture else { return }
        let index = vault.nextShotIndex(sessionId: manifest.sessionId)
        let stem = String(format: "%03d", index)
        let rawPath = "\(ScrumTracePath.shots)/\(stem).png"
        let annotatedPath = "\(ScrumTracePath.shots)/\(stem).annotated.png"
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            lastError = "Could not encode the Shot PNG."
            AgentLog.event("shot_fail", ["reason": "encode"])
            return
        }
        do {
            try ExportRel.writeContainedData(png, relative: rawPath, sessionURL: sessionURL)
        } catch {
            lastError = error.localizedDescription
            statusLine = "Could not write the Shot PNG."
            AgentLog.event("shot_fail", [
                "reason": "write",
                "error": AgentLog.sanitize(error.localizedDescription)
            ])
            return
        }
        let record = ShotRecord(
            id: String(format: "shot-%03d", index),
            tMedia: media,
            rawPath: rawPath,
            annotatedPath: nil,
            note: "",
            source: .typed
        )
        // Persist the raw frame immediately so Stop/Quit cannot drop an unsaved Shot window.
        // `manifest` is already unwrapped by the function guard.
        var local = manifest
        if let idx = local.shots.firstIndex(where: { $0.id == record.id }) {
            local.shots[idx] = record
        } else {
            local.shots.append(record)
        }
        do {
            try vault.write(manifest: &local)
        } catch {
            lastError = error.localizedDescription
            statusLine = "Shot frame captured; catalog write failed. Save still."
        }
        self.manifest = local
        let meta = await sampler.sample()
        // Re-check after the 200 ms AX wait: Pause can land while we were sampling (C1).
        if captureState.allowsNewCapture {
            if let url = meta?.url {
                log(.url, ["url": url, "title": meta?.windowTitle ?? ""])
            } else if let meta {
                log(.window, ["app": meta.appName, "title": meta.windowTitle])
            }
        }
        shotWindow = ShotNoteWindow(
            screenshot: image,
            transcriber: transcriber,
            whisperModel: settings.whisperModel,
            allowsNewCapture: { [weak self] in
                self?.captureState.allowsNewCapture == true
            }
        ) { [weak self] note, annotated, source in
            self?.finishShot(
                record: record,
                note: note,
                annotated: annotated,
                source: source,
                annotatedPath: annotatedPath
            )
        }
        shotWindow?.show()
    }

    private func finishShot(
        record: ShotRecord,
        note: String,
        annotated: NSImage,
        source: ShotSource,
        annotatedPath: String
    ) {
        guard let sessionURL, var manifest else { return }
        if let tiff = annotated.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            do {
                try ExportRel.writeContainedData(png, relative: annotatedPath, sessionURL: sessionURL)
            } catch {
                lastError = error.localizedDescription
                statusLine = "Could not write the annotated Shot."
                return
            }
        } else {
            lastError = "Could not encode the annotated Shot."
            AgentLog.event("shot_fail", ["reason": "annotate_encode"])
            return
        }
        let jsonRel = "\(ScrumTracePath.shots)/\(stemFrom(record.id)).json"
        var stored = record
        stored.note = note
        stored.source = source
        stored.annotatedPath = annotatedPath
        var sidecarFailed = false
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(stored)
            try ExportRel.writeContainedData(data, relative: jsonRel, sessionURL: sessionURL)
        } catch {
            sidecarFailed = true
            lastError = error.localizedDescription
        }
        if let idx = manifest.shots.firstIndex(where: { $0.id == stored.id }) {
            manifest.shots[idx] = stored
        } else {
            manifest.shots.append(stored)
        }
        self.manifest = manifest
        do {
            try vault.write(manifest: &manifest)
            if sidecarFailed {
                statusLine = "Shot annotated; sidecar JSON write failed."
            } else {
                lastError = nil
                statusLine = "Shot \(stored.id) saved"
            }
        } catch {
            lastError = error.localizedDescription
            statusLine = "Shot annotated; catalog write failed. Stop still keeps this Shot."
        }
        AgentLog.event("shot_save", [
            "id": stored.id,
            "source": source.rawValue,
            "note_chars": String(note.count),
            "t_media": String(stored.tMedia)
        ])
        log(.shot, ["id": stored.id, "note": note])
        shotWindow = nil
    }

    private func privacyPause(bundle: String) {
        guard isRecording else { return }
        if !privacy.isCurrentlyTripped && privacy.currentCredentialApp() == nil {
            // CaptureFreeze paused the writer on the timer queue. If the
            // credential app is already gone before this MainActor hop,
            // do not stick in a paused writer with phase still `.recording`.
            unstickWriterIfPrivacyMissed()
            return
        }
        if phase == .paused {
            // User Pause already owns the session. Do not steal Resume by
            // setting `pausedByPrivacy`, and do not overwrite the HUD line.
            if pausedByPrivacy {
                statusLine = "Still auto-paused for a password manager"
            }
            return
        }
        pausedByPrivacy = true
        recorder?.setPaused(true)
        sampler.isSuspended = true
        phase = .paused
        statusLine = "Auto-paused for \(bundle)"
        AgentLog.event("privacy_pause", ["bundle": bundle])
        log(.privacyPause, ["bundle": bundle])
        persistLivePipelineStatus()
        NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.paused)
    }

    private func privacyResume() {
        guard isRecording else { return }
        if privacy.isCurrentlyTripped || privacy.currentCredentialApp() != nil { return }
        if pausedByPrivacy, phase == .paused {
            if !unpauseCaptureIfPrivacyClear() { return }
            pausedByPrivacy = false
            phase = .recording
            statusLine = "Recording"
            AgentLog.event("privacy_resume", [:])
            log(.resume, ["reason": "privacy_clear"])
            persistLivePipelineStatus()
            NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.recording)
            kickMetadataSample()
            return
        }
        unstickWriterIfPrivacyMissed()
    }

    /// Unpause writers and metadata only when a credential app is not frontmost.
    /// Re-check after unpause and after unsuspend: CaptureFreeze can freeze on
    /// the privacy timer between the MainActor check and `setPaused(false)` (C1).
    private func unpauseCaptureIfPrivacyClear() -> Bool {
        if privacy.isCurrentlyTripped || privacy.currentCredentialApp() != nil {
            recorder?.setPaused(true)
            sampler.isSuspended = true
            return false
        }
        recorder?.setPaused(false)
        if privacy.isCurrentlyTripped || privacy.currentCredentialApp() != nil {
            recorder?.setPaused(true)
            sampler.isSuspended = true
            return false
        }
        sampler.isSuspended = false
        if privacy.isCurrentlyTripped || privacy.currentCredentialApp() != nil || recorder?.isPaused == true {
            recorder?.setPaused(true)
            sampler.isSuspended = true
            return false
        }
        return true
    }

    /// Writer paused by CaptureFreeze, phase not yet `.paused`, credential app gone.
    /// Do not treat a user Pause (`phase == .paused`, `pausedByPrivacy == false`) as this.
    private func unstickWriterIfPrivacyMissed() {
        guard !pausedByPrivacy, phase == .recording, recorder?.isPaused == true else { return }
        if privacy.isCurrentlyTripped || privacy.currentCredentialApp() != nil { return }
        if !unpauseCaptureIfPrivacyClear() { return }
        statusLine = "Recording"
        NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.recording)
        kickMetadataSample()
    }

    private func startTimer() {
        wallElapsed = clock.currentWallSeconds()
        mediaElapsed = clock.currentMediaSeconds()
        hudTickCount = 0
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.wallElapsed = self.clock.currentWallSeconds()
                self.mediaElapsed = self.clock.currentMediaSeconds()
                self.hudTickCount += 1
                if self.isRecording && self.hudTickCount % 300 == 0 {
                    self.persistLivePipelineStatus()
                }
            }
        }
        metadataTimer?.invalidate()
        metadataTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.sampleMetadataTick()
            }
        }
        kickMetadataSample()
    }

    private func sampleMetadataTick() async {
        guard captureState.allowsNewCapture else { return }
        guard let meta = await sampler.sample() else { return }
        // Re-check after the 200 ms AX wait: Pause can land while we were sampling (C1).
        guard captureState.allowsNewCapture else { return }
        let signature = "\(meta.bundleIdentifier)|\(meta.windowTitle)|\(meta.url ?? "")"
        guard signature != lastMetaSignature else { return }
        lastMetaSignature = signature
        AgentLog.event("meta_frontmost", [
            "bundle": meta.bundleIdentifier,
            "has_url": (meta.url?.isEmpty == false) ? "1" : "0"
        ])
        if let url = meta.url, !url.isEmpty {
            log(.url, ["url": url, "title": meta.windowTitle, "app": meta.appName])
        } else {
            log(.window, ["app": meta.appName, "title": meta.windowTitle])
        }
    }

    /// The 2 s timer would miss the Keynote/browser window that is already
    /// front at Start or the instant Pause lifts (D12).
    private func kickMetadataSample() {
        Task { await sampleMetadataTick() }
    }

    private func log(_ kind: SessionEventKind, _ payload: [String: String]) {
        guard shouldPersistEvent(kind) else { return }
        guard let id = manifest?.sessionId else { return }
        let event = SessionEvent(
            tWall: clock.currentWallSeconds(),
            tMedia: clock.currentMediaSeconds(),
            kind: kind,
            payload: payload
        )
        do {
            try vault.appendEvent(event, sessionId: id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func shouldPersistEvent(_ kind: SessionEventKind) -> Bool {
        switch kind {
        case .start, .stop, .pause, .resume, .shot, .privacyPause, .error:
            return true
        case .pin, .url, .window:
            return captureState.allowsNewCapture
        }
    }

    /// Recent menu reads disk. Pause must not leave `pipeline_status: recording`
    /// while the HUD already follows a paused writer (privacy freeze).
    private func persistLivePipelineStatus() {
        guard var local = manifest else { return }
        if isRecording {
            local.pipelineStatus = captureState == .paused ? .paused : .recording
            local.pauses = clock.snapshotPauses()
            local.duration = DurationPair(
                wallSeconds: clock.currentWallSeconds(),
                mediaSeconds: clock.currentMediaSeconds()
            )
        } else {
            local.pipelineStatus = phase
        }
        do {
            try vault.write(manifest: &local)
        } catch {
            lastError = error.localizedDescription
        }
        manifest = local
    }

    private func flashStatus() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self else { return }
            // Pause/privacy can land while this task is sleeping. Restoring
            // "Recording" then would look like the session is still live.
            guard self.phase == .recording, self.captureState.allowsNewCapture else { return }
            self.statusLine = "Recording"
        }
    }

    #if os(macOS)
    fileprivate static func presentStartFailureAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Recording did not start"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func openScreenCaptureSettings() {
        SystemPrivacySettings.openScreenRecording()
    }

    static func openMicrophoneSettings() {
        SystemPrivacySettings.openMicrophone()
    }

    func relaunchForPermissions() {
        guard canChangeCaptureSettings else {
            AgentLog.event("relaunch_ignored", ["reason": "session_active"])
            return
        }
        CapturePermissions.relaunchRunningApp()
    }
    #endif

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    nonisolated static func mergePins(_ live: [TimeInterval], _ stored: [TimeInterval]) -> [TimeInterval] {
        var seen = Set<String>()
        var out: [TimeInterval] = []
        for value in live + stored {
            let key = String(format: "%.2f", value)
            if seen.insert(key).inserted {
                out.append(value)
            }
        }
        return out.sorted()
    }

    /// Disk catalog can lag a failed `vault.write` during Shot. Prefer in-memory shots.
    nonisolated static func mergeLiveCatalog(disk: SessionManifest, memory: SessionManifest) -> SessionManifest {
        var local = disk
        for shot in memory.shots {
            if let idx = local.shots.firstIndex(where: { $0.id == shot.id }) {
                local.shots[idx] = shot
            } else {
                local.shots.append(shot)
            }
        }
        local.duration = memory.duration
        local.pauses = memory.pauses
        local.pipelineStatus = memory.pipelineStatus
        return local
    }

    private func stemFrom(_ shotId: String) -> String {
        shotId.replacingOccurrences(of: "shot-", with: "")
    }
}

#if os(macOS)
enum SystemPrivacySettings {
    static func openScreenRecording() {
        open(
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            fallback: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    static func openMicrophone() {
        open(
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            fallback: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    private static func open(_ primary: String, fallback: String) {
        if let url = URL(string: primary), NSWorkspace.shared.open(url) {
            return
        }
        if let url = URL(string: fallback) {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif

/// Stop's teardown-vs-timeout race must resume its continuation exactly once.
private final class StopResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    @discardableResult
    func resume(
        _ continuation: CheckedContinuation<Result<Void, Error>, Never>,
        _ value: Result<Void, Error>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        continuation.resume(returning: value)
        return true
    }
}

enum ScreenSnap {
    static func capture(area: CaptureArea = .entireDisplay) -> NSImage? {
        #if os(macOS)
        let preferred = area.displayID == 0 ? CGMainDisplayID() : CGDirectDisplayID(area.displayID)
        let image = CGDisplayCreateImage(preferred) ?? CGDisplayCreateImage(CGMainDisplayID())
        guard let cg = image else { return nil }
        let cropped = crop(cg, to: area)
        let scaled = downscale(cropped, maxEdge: MediaBudget.stillMaxWidth)
        return NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height))
        #else
        return nil
        #endif
    }

    static func crop(_ image: CGImage, to area: CaptureArea) -> CGImage {
        guard !area.isEntireDisplay else { return image }
        let rect = area.pixelCrop(imageWidth: image.width, imageHeight: image.height)
        return image.cropping(to: rect) ?? image
    }

    /// CG-09: Shot PNGs are capped at `stillMaxWidth` so 20 Retina captures
    /// do not add tens of megabytes to `archive/`.
    static func downscale(_ image: CGImage, maxEdge: Int) -> CGImage {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxEdge else { return image }
        let scale = CGFloat(maxEdge) / CGFloat(longest)
        let nw = max(Int((CGFloat(w) * scale).rounded(.toNearestOrEven)), 2)
        let nh = max(Int((CGFloat(h) * scale).rounded(.toNearestOrEven)), 2)
        let evenW = nw - nw % 2
        let evenH = nh - nh % 2
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: evenW,
            height: evenH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: evenW, height: evenH))
        return ctx.makeImage() ?? image
    }
}

/// Carries `stop()` failure off `Task.detached` onto MainActor halt (C2).
private final class HaltStopBox: @unchecked Sendable {
    var message: String?
}
