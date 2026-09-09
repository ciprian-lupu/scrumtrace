import Combine
import Foundation
#if os(macOS)
import AppKit
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

    let settings: AppSettings
    let vault: SessionVault
    let transcriber = WhisperTranscriber()
    let sampler = MetadataSampler()
    let privacy = PrivacyGuard()
    let clock = ClockSynchronizer()

    private var recorder: SessionRecorder?
    private var processor: SessionProcessor?
    private var hudTimer: Timer?
    private var metadataTimer: Timer?
    private var pinTimes: [TimeInterval] = []
    private var sessionURL: URL?
    private var manifest: SessionManifest?
    private var shotWindow: ShotNoteWindow?
    private var pausedByPrivacy = false
    private var lastMetaSignature = ""

    init(settings: AppSettings = .shared, vault: SessionVault = SessionVault()) {
        self.settings = settings
        self.vault = vault
        self.processor = SessionProcessor(vault: vault, transcriber: transcriber)
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
        if let recent = vault.recentSessions(limit: 1).first {
            lastSessionId = recent.sessionId
        }
    }

    var isRecording: Bool {
        phase == .recording || phase == .paused
    }

    var hudShouldShow: Bool {
        (isRecording || isBusy) && !suppressHUD
    }

    func startRecording() {
        guard !isRecording, !isBusy else { return }
        Task { await startRecordingAsync() }
    }

    func stopRecording() {
        Task { await stopRecordingAsync() }
    }

    func togglePause() {
        guard isRecording else { return }
        if phase == .paused {
            if privacy.isCurrentlyTripped {
                statusLine = "Still auto-paused for a password manager"
                return
            }
            pausedByPrivacy = false
            recorder?.setPaused(false)
            sampler.isSuspended = false
            phase = .recording
            statusLine = "Recording"
            log(.resume, [:])
            NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.recording)
        } else {
            pausedByPrivacy = false
            recorder?.setPaused(true)
            sampler.isSuspended = true
            phase = .paused
            statusLine = "Paused — nothing is written"
            log(.pause, [:])
            NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.paused)
        }
    }

    func pin() {
        guard captureState.allowsNewCapture else { return }
        let media = clock.currentMediaSeconds()
        pinTimes.append(media)
        log(.pin, ["t_media": String(format: "%.2f", media)])
        statusLine = "Pinned \(Self.clock(media))"
        flashStatus()
    }

    var captureState: CaptureSessionState {
        phase == .paused ? .paused : (phase == .recording ? .recording : .paused)
    }

    var canResumeFromPause: Bool {
        phase == .paused && !privacy.isCurrentlyTripped
    }

    func openShot() {
        guard captureState.allowsNewCapture else {
            statusLine = "Paused — Shot is disabled"
            return
        }
        Task { await captureShot() }
    }

    func retryAnalysis() {
        guard let id = lastSessionId ?? manifest?.sessionId else { return }
        retryAnalysis(sessionId: id)
    }

    func retryAnalysis(sessionId: String) {
        guard !isBusy, !isRecording else {
            statusLine = isBusy ? "Already processing a session" : "Stop recording before retry"
            return
        }
        lastSessionId = sessionId
        Task { await runProcessor(sessionId: sessionId) }
    }

    func revealLast() {
        if let id = lastSessionId ?? manifest?.sessionId {
            vault.revealInFinder(sessionId: id)
        }
    }

    /// Process is quitting: freeze capture. Do not start Whisper/AI on a dying process.
    func haltCaptureForTermination() {
        guard isRecording else { return }
        privacy.stop()
        sampler.isSuspended = true
        hudTimer?.invalidate()
        hudTimer = nil
        metadataTimer?.invalidate()
        metadataTimer = nil
        recorder?.freezeWriters()
        persistInterruptedCapture()
        let rec = recorder
        recorder = nil
        phase = .idle
        isBusy = false
        statusLine = "Stopped"
        // Close the movie/WAV before the process is killed. Do not start Whisper/AI.
        let lock = DispatchSemaphore(value: 0)
        Task.detached {
            try? await rec?.stop()
            lock.signal()
        }
        _ = lock.wait(timeout: .now() + 5)
    }

    private func persistInterruptedCapture() {
        guard var local = manifest else { return }
        local.duration = DurationPair(
            wallSeconds: clock.currentWallSeconds(),
            mediaSeconds: clock.currentMediaSeconds()
        )
        local.pauses = clock.snapshotPauses()
        try? vault.write(manifest: &local)
        manifest = local
        log(.stop, ["reason": "quit"])
    }

    private func startRecordingAsync() async {
        guard !isRecording, !isBusy else { return }
        lastError = nil
        do {
            let created = try vault.createSession(product: settings.productContext)
            sessionURL = created.url
            var createdManifest = created.manifest
            createdManifest.includeFullTranscriptInZip = settings.includeFullTranscriptInZip
            try vault.write(manifest: &createdManifest)
            manifest = createdManifest
            lastSessionId = created.manifest.sessionId
            pinTimes = []
            lastMetaSignature = ""
            pausedByPrivacy = false
            clock.reset()
            let recorder = SessionRecorder(sessionURL: created.url, clock: clock)
            try await recorder.start()
            self.recorder = recorder
            phase = .recording
            statusLine = "Recording"
            privacy.start()
            sampler.isSuspended = false
            startTimer()
            log(.start, [:])
            let model = settings.whisperModel
            Task {
                try? await transcriber.prepare(model: model)
            }
        } catch {
            lastError = error.localizedDescription
            statusLine = error.localizedDescription
        }
    }

    private func stopRecordingAsync() async {
        guard isRecording else { return }
        isBusy = true
        statusLine = "Stopping capture"
        phase = .transcribing
        privacy.stop()
        sampler.isSuspended = true
        // Freeze writers immediately without resuming a paused session (C1).
        recorder?.freezeWriters()
        do {
            try await recorder?.stop()
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
            try? vault.write(manifest: &local)
            manifest = local
            log(.stop, [:])
            await runProcessor(sessionId: local.sessionId)
        } else {
            isBusy = false
            phase = .offlineFailed
            statusLine = "Session manifest missing after stop"
        }
        recorder = nil
    }

    private func runProcessor(sessionId: String) async {
        isBusy = true
        do {
            if var local = try? vault.loadManifest(id: sessionId) {
                local.includeFullTranscriptInZip = settings.includeFullTranscriptInZip
                let capabilities = settings.providerConfiguration()
                if local.uploadConsent.needsReprompt(
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
            }
            let storedPins = vault.loadPinTimes(sessionId: sessionId)
            let pins = Self.mergePins(pinTimes, storedPins)
            let result = try await processor?.process(
                sessionId: sessionId,
                pinTimes: pins,
                configuration: settings.providerConfiguration(),
                whisperModel: settings.whisperModel,
                onStatus: { [weak self] status, line in
                    self?.phase = status
                    self?.statusLine = line
                }
            )
            if let result {
                manifest = result
                lastSessionId = result.sessionId
                phase = result.pipelineStatus
                vault.revealInFinder(sessionId: result.sessionId)
            }
        } catch {
            lastError = error.localizedDescription
            phase = .offlineFailed
            statusLine = error.localizedDescription
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
            payload = "Stills, transcript excerpts, and clip audio will leave this Mac."
        } else {
            payload = "Stills and transcript excerpts will leave this Mac. Clip video and the master movie are not uploaded."
        }
        alert.informativeText = """
        Destination: \(settings.provider.title)
        \(settings.baseURL)
        Model: \(settings.model.isEmpty ? "(none)" : settings.model)

        \(payload) The archive (session.mp4, full transcript, raw events) stays local. Keychain storage is not consent.
        """
        alert.addButton(withTitle: "Approve upload")
        alert.addButton(withTitle: "Local export only")
        let approved = alert.runModal() == .alertFirstButtonReturn
        return UploadConsent(
            approved: approved,
            approvedAt: Date(),
            provider: settings.provider.rawValue,
            endpoint: settings.baseURL,
            model: settings.model,
            includesClipAudio: approved && uploadsClip,
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
        guard captureState.allowsNewCapture else { return }
        let media = clock.currentMediaSeconds()
        guard let image = ScreenSnap.capture() else {
            lastError = "Could not capture the display."
            return
        }
        let index = vault.nextShotIndex(sessionId: manifest.sessionId)
        let stem = String(format: "%03d", index)
        let rawPath = "\(ScrumTracePath.shots)/\(stem).png"
        let annotatedPath = "\(ScrumTracePath.shots)/\(stem).annotated.png"
        let rawURL = sessionURL.appendingPathComponent(rawPath)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: rawURL)
        let record = ShotRecord(
            id: String(format: "shot-%03d", index),
            tMedia: media,
            rawPath: rawPath,
            annotatedPath: annotatedPath,
            note: "",
            source: .typed
        )
        // Persist the raw frame immediately so Stop/Quit cannot drop an unsaved Shot window.
        if var local = manifest {
            if let idx = local.shots.firstIndex(where: { $0.id == record.id }) {
                local.shots[idx] = record
            } else {
                local.shots.append(record)
            }
            try? vault.write(manifest: &local)
            self.manifest = local
        }
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
            Task { @MainActor in
                self?.finishShot(
                    record: record,
                    note: note,
                    annotated: annotated,
                    source: source,
                    annotatedPath: annotatedPath
                )
            }
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
        let url = sessionURL.appendingPathComponent(annotatedPath)
        if let tiff = annotated.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        let json: [String: Any] = [
            "id": record.id,
            "t_media": record.tMedia,
            "note": note,
            "source": source.rawValue
        ]
        let jsonURL = sessionURL.appendingPathComponent("\(ScrumTracePath.shots)/\(stemFrom(record.id)).json")
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: jsonURL)
        }
        var stored = record
        stored.note = note
        stored.source = source
        stored.annotatedPath = annotatedPath
        if let idx = manifest.shots.firstIndex(where: { $0.id == stored.id }) {
            manifest.shots[idx] = stored
        } else {
            manifest.shots.append(stored)
        }
        try? vault.write(manifest: &manifest)
        self.manifest = manifest
        log(.shot, ["id": stored.id, "note": note])
        statusLine = "Shot \(stored.id) saved"
        shotWindow = nil
    }

    private func privacyPause(bundle: String) {
        guard isRecording else { return }
        if phase == .paused {
            statusLine = "Still auto-paused for a password manager"
            return
        }
        pausedByPrivacy = true
        recorder?.setPaused(true)
        sampler.isSuspended = true
        phase = .paused
        statusLine = "Auto-paused for \(bundle)"
        log(.privacyPause, ["bundle": bundle])
        NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.paused)
    }

    private func privacyResume() {
        guard pausedByPrivacy, phase == .paused, isRecording else { return }
        if privacy.isCurrentlyTripped { return }
        pausedByPrivacy = false
        recorder?.setPaused(false)
        sampler.isSuspended = false
        phase = .recording
        statusLine = "Recording"
        log(.resume, ["reason": "privacy_clear"])
        NotificationCenter.default.post(name: .scrumTraceCaptureGate, object: CaptureSessionState.recording)
    }

    private func startTimer() {
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.wallElapsed = self.clock.currentWallSeconds()
                self.mediaElapsed = self.clock.currentMediaSeconds()
            }
        }
        metadataTimer?.invalidate()
        metadataTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.sampleMetadataTick()
            }
        }
    }

    private func sampleMetadataTick() async {
        guard captureState.allowsNewCapture else { return }
        guard let meta = await sampler.sample() else { return }
        // Re-check after the 200 ms AX wait: Pause can land while we were sampling (C1).
        guard captureState.allowsNewCapture else { return }
        let signature = "\(meta.bundleIdentifier)|\(meta.windowTitle)|\(meta.url ?? "")"
        guard signature != lastMetaSignature else { return }
        lastMetaSignature = signature
        if let url = meta.url, !url.isEmpty {
            log(.url, ["url": url, "title": meta.windowTitle, "app": meta.appName])
        } else {
            log(.window, ["app": meta.appName, "title": meta.windowTitle])
        }
    }

    private func log(_ kind: SessionEventKind, _ payload: [String: String]) {
        switch kind {
        case .start, .stop, .pause, .resume, .shot, .privacyPause, .error:
            break
        case .pin, .url, .window:
            guard captureState.allowsNewCapture else { return }
        }
        guard let id = manifest?.sessionId else { return }
        let event = SessionEvent(
            tWall: clock.currentWallSeconds(),
            tMedia: clock.currentMediaSeconds(),
            kind: kind,
            payload: payload
        )
        try? vault.appendEvent(event, sessionId: id)
    }

    private func flashStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.phase == .recording else { return }
            self.statusLine = "Recording"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    static func mergePins(_ live: [TimeInterval], _ stored: [TimeInterval]) -> [TimeInterval] {
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

    private func stemFrom(_ shotId: String) -> String {
        shotId.replacingOccurrences(of: "shot-", with: "")
    }
}

enum ScreenSnap {
    static func capture() -> NSImage? {
        #if os(macOS)
        let display = CGMainDisplayID()
        guard let cg = CGDisplayCreateImage(display) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return nil
        #endif
    }
}
