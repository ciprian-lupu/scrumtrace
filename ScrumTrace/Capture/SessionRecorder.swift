import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

enum SessionRecorderError: LocalizedError {
    case permissionDenied
    case relaunchRequired
    case microphoneDenied
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return CaptureReadiness.screenDenied.userMessage
        case .relaunchRequired:
            return CaptureReadiness.screenGrantedNeedsRelaunch.userMessage
        case .microphoneDenied:
            return CaptureReadiness.microphoneDenied.userMessage
        case .writerFailed(let message):
            return message
        }
    }
}

/// ScreenCaptureKit coordinator. While paused, screen frames, system audio,
/// microphone PCM, and metadata are discarded — nothing is written to MP4 or WAV.
/// System audio goes to the movie AAC track. Room mic goes to `archive/audio.wav`.
final class SessionRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let clock: ClockSynchronizer
    private let sessionURL: URL
    private static let writerKey = DispatchSpecificKey<UInt8>()
    private let writerQueue = DispatchQueue(label: "com.str8minds.ScrumTrace.writer")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var wavFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var engine: AVAudioEngine?
    private var engineConfigObserver: NSObjectProtocol?
    private var paused = false
    private var started = false
    private var microphoneWav = false
    /// Unique names used for AVAssetWriter / AVAudioFile create. After the
    /// immediate renameat onto `session.mp4` / `audio.wav`, finishWriting may
    /// still recreate the original UUID path — reclaim the larger file.
    private var liveMovieRel: String?
    private var liveWavRel: String?
    private var captureWriteFailed = false
    private var captureWriteMessage: String?
    /// Consecutive `CMSampleBufferCreateCopyWithNewTiming` failures. One
    /// dropped frame is a glitch; a streak means the master clock is gone (D2).
    private var remapFailStreak = 0
    /// Consecutive WAV format-parse failures. One odd buffer is a glitch;
    /// a streak means room/system audio is not being persisted (C1).
    private var wavFormatFailStreak = 0
    /// Consecutive `isReadyForMoreMediaData == false` while the writer is
    /// `.writing`. Brief backpressure is realtime; a half-second stall
    /// means the master movie is no longer receiving samples (C1).
    private var videoBackpressureStreak = 0
    private var audioBackpressureStreak = 0
    /// Consecutive `CMSampleBufferDataIsReady == false`. One late buffer is
    /// realtime; a half-second streak means screen/system/mic samples are
    /// being dropped while CaptureSessionState is still recording (C1).
    private var videoSampleNotReadyStreak = 0
    private var audioSampleNotReadyStreak = 0
    private var wavSampleNotReadyStreak = 0
    /// Consecutive `AVAssetWriter.status != .writing` while capture is live.
    /// `.unknown` can be a glitch; a stall means the master movie stopped (C1).
    private var videoWriterNotWritingStreak = 0
    private var audioWriterNotWritingStreak = 0
    /// Consecutive successful WAV conversions that produced zero frames.
    /// One primed converter output is expected; a stall means room/system
    /// audio is no longer reaching `archive/audio.wav` (C1).
    private var wavEmptyConvertStreak = 0
    private var remapFailStallStart: CMTime = .invalid
    private var wavFormatFailStallStart: CMTime = .invalid
    private var videoBackpressureStallStart: CMTime = .invalid
    private var audioBackpressureStallStart: CMTime = .invalid
    private var videoSampleNotReadyStallStart: CMTime = .invalid
    private var audioSampleNotReadyStallStart: CMTime = .invalid
    private var wavSampleNotReadyStallStart: CMTime = .invalid
    private var videoWriterNotWritingStallStart: CMTime = .invalid
    private var audioWriterNotWritingStallStart: CMTime = .invalid
    private var wavEmptyConvertStallStart: CMTime = .invalid
    private var loggedFirstVideo = false
    private var loggedFirstAudio = false
    private var loggedFirstWav = false
    private var wavStartMediaSeconds: TimeInterval?
    private var wavFramesWritten: AVAudioFramePosition = 0
    private var loggedWavAhead = false
    private var micWatchTimer: DispatchSourceTimer?

    init(sessionURL: URL, clock: ClockSynchronizer) {
        self.sessionURL = sessionURL
        self.clock = clock
        super.init()
        writerQueue.setSpecific(key: Self.writerKey, value: 1)
    }

    /// Mic-tap `async` blocks retain `self`. If that block is the last retain,
    /// `deinit` runs on `writerQueue` and `sync` would deadlock.
    private func syncWriter<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.writerKey) != nil {
            return try body()
        }
        return try writerQueue.sync(execute: body)
    }

    var isPaused: Bool {
        syncWriter { paused }
    }

    /// Disk-full / AVAudioFile / AVAssetWriter failure. Start checks this if
    /// the capture-failed notification landed before `phase` was `.recording`.
    var audioWriteFailure: String? {
        syncWriter { captureWriteMessage }
    }

    /// Writer failure text for the archive `.stop` event (TASK-02).
    var captureFailureReason: String? {
        syncWriter { captureWriteMessage }
    }

    func start(shouldPauseCapture: @escaping @Sendable () -> Bool = { false },
               captureArea: CaptureArea = .entireDisplay,
               showCursor: Bool = true,
               includeMicrophone: Bool = true) async throws {
        // Never call SCShareableContent unless Screen Recording was attached
        // at process start. A Settings toggle that flipped mid-process, or a
        // grant for a different Debug copy, makes this API show the system
        // sheet again on every Record.
        if !CapturePermissions.screenGrantedAtLaunch {
            if CapturePermissions.currentScreenGranted() {
                AgentLog.event("recorder_blocked", ["reason": "relaunchRequired"])
                throw SessionRecorderError.relaunchRequired
            }
            AgentLog.event("recorder_blocked", ["reason": "permissionDenied"])
            throw SessionRecorderError.permissionDenied
        }
        try await requestPermission(includeMicrophone: includeMicrophone)
        AgentLog.event("recorder_sckit_begin", [
            "area": captureArea.isEntireDisplay ? "full" : "region",
            "display": captureArea.isEntireDisplay ? "all" : String(captureArea.displayID),
            "width": String(captureArea.isEntireDisplay ? 0 : Int(captureArea.widthPoints.rounded())),
            "height": String(captureArea.isEntireDisplay ? 0 : Int(captureArea.heightPoints.rounded())),
            "cursor": showCursor ? "1" : "0",
            "mic": includeMicrophone ? "1" : "0"
        ])
        // Never fetch shareable content on the MainActor. TCC presents a sheet
        // that cannot drain if Record is waiting on this same run loop — the
        // app beachballs and has to be force-quit.
        let content: SCShareableContent
        do {
            content = try await Self.shareableContentOffMain()
            AgentLog.event("recorder_sckit_ok", ["displays": String(content.displays.count)])
        } catch {
            AgentLog.event("recorder_sckit_fail", ["error": error.localizedDescription])
            if !CGPreflightScreenCaptureAccess() {
                throw SessionRecorderError.permissionDenied
            }
            throw SessionRecorderError.writerFailed(error.localizedDescription)
        }
        guard let display = Self.display(in: content, matching: captureArea) else {
            throw SessionRecorderError.writerFailed("No display available for capture.")
        }
        let regionFitsDisplay = !captureArea.isEntireDisplay
            && display.displayID == captureArea.displayID
        let rawSize = regionFitsDisplay
            ? captureArea.pixelSize(
                displayPixelWidth: display.width,
                displayPixelHeight: display.height
            )
            : (width: display.width, height: display.height)
        let size = Self.evenCaptureSize(width: rawSize.width, height: rawSize.height)
        let excluded = content.applications.filter { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        clock.markRecordingStarted()
        do {
            // DispatchQueue.sync is synchronous — `await` here does not compile.
            // Keep prepareWriters in this catch so a thrown writer still hits
            // abortFailedStart before SessionController deletes the session folder.
            try syncWriter {
                try self.prepareWriters(width: size.width, height: size.height)
            }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = size.width
            config.height = size.height
            if regionFitsDisplay {
                config.sourceRect = captureArea.sourceRect()
            }
            config.minimumFrameInterval = CMTime(
                value: Int64(MediaBudget.archiveFrameStep),
                timescale: Int32(MediaBudget.archiveFrameTimescale)
            )
            config.queueDepth = 8
            config.showsCursor = showCursor
            config.capturesAudio = true
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            if #available(macOS 15.0, *) {
                config.captureMicrophone = includeMicrophone
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
            var mic = false
            if includeMicrophone {
                if #available(macOS 15.0, *) {
                    do {
                        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: writerQueue)
                        mic = true
                    } catch {
                        do {
                            try startMicrophoneFallback()
                            mic = true
                        } catch {
                            mic = false
                        }
                    }
                } else {
                    do {
                        try startMicrophoneFallback()
                        mic = true
                    } catch {
                        mic = false
                    }
                }
            }
            // Evaluate the privacy gate after writers exist and before the
            // first SCStream buffer: a credential app that was already front
            // (or that appeared during the permission sheet) must not hit disk.
            let pauseNow = shouldPauseCapture()
            syncWriter {
                self.microphoneWav = mic
                self.stream = stream
                self.started = true
                if pauseNow {
                    self.paused = true
                    self.clock.beginPause()
                }
            }
            // Dual-pass Whisper reads this after crash/Quit. Write it before
            // the first buffer so a missing file cannot default to a room mic.
            try persistCaptureLayout()
            startMicRevocationWatch()
            try await Self.startCaptureOffMain(stream)
            // startCapture can run for a long time. Freeze or a credential
            // app that appeared while the stream was starting must still
            // win — do not return with writers live (C1).
            if shouldPauseCapture() {
                syncWriter {
                    if !self.paused {
                        self.paused = true
                        self.clock.beginPause()
                    }
                }
            }
        } catch {
            await abortFailedStart()
            throw error
        }
    }

    private static func display(in content: SCShareableContent, matching area: CaptureArea) -> SCDisplay? {
        if !area.isEntireDisplay {
            if let match = content.displays.first(where: { $0.displayID == area.displayID }) {
                return match
            }
        }
        return content.displays.first
    }

    /// Even pixel size shared by SCStream and AVAssetWriter, capped at 3840×2160.
    static func evenCaptureSize(width: Int, height: Int) -> (width: Int, height: Int) {
        var w = max(width, 2)
        var h = max(height, 2)
        let maxW = MediaBudget.archiveMaxWidth
        let maxH = MediaBudget.archiveMaxHeight
        if w > maxW {
            h = max(Int((Double(h) * Double(maxW) / Double(w)).rounded()), 2)
            w = maxW
        }
        if h > maxH {
            w = max(Int((Double(w) * Double(maxH) / Double(h)).rounded()), 2)
            h = maxH
        }
        w -= w % 2
        h -= h % 2
        return (max(w, 2), max(h, 2))
    }

    /// `start()` failed after writers or the mic fallback existed. Stop the
    /// tap and cancel writers so a discarded recorder cannot keep capturing.
    private func abortFailedStart() async {
        clock.markRecordingStopped()
        let snapshot = syncWriter { () -> (stream: SCStream?, engine: AVAudioEngine?) in
            self.started = false
            self.paused = true
            let stream = self.stream
            self.stream = nil
            let engine = self.engine
            self.engine = nil
            self.clearEngineObserver()
            self.stopMicRevocationWatch()
            return (stream, engine)
        }
        if let live = snapshot.stream {
            do {
                try await live.stopCapture()
            } catch {
                do {
                    try await live.stopCapture()
                } catch {
                    // start() still rethrows the original error. Keep retrying
                    // stopCapture so a live SCStream cannot keep the capture
                    // indicator after abort (C1).
                    Task.detached {
                        do {
                            try await live.stopCapture()
                        } catch {
                            NotificationCenter.default.post(
                                name: .scrumTraceCaptureFailed,
                                object: "Could not stop ScreenCaptureKit: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            }
        }
        snapshot.engine?.stop()
        syncWriter {
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.closeWavWriter()
            if let writer = self.writer, writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
            }
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.discardLiveCaptureLocked()
        }
    }

    func setPaused(_ next: Bool) {
        // sync: Pause must apply before the next SCStream/mic buffer on this queue.
        // async left a window where paused samples were still appended (C1).
        syncWriter {
            guard self.paused != next else { return }
            self.paused = next
            self.resetStallCountersLocked()
            if next {
                self.clock.beginPause()
            } else {
                self.clock.endPause()
            }
        }
    }

    /// Drop every capture source immediately without opening a Pause interval.
    func freezeWriters() {
        syncWriter {
            self.paused = true
            self.started = false
            self.resetStallCountersLocked()
            self.clock.markRecordingStopped()
        }
    }

    /// Dual-pass Whisper needs this before `stopCapture` / `finishWriting`.
    /// Quit only waits 5s; the layout must already be on disk (Gate 3).
    func persistCaptureLayout(microphoneWav: Bool? = nil) throws {
        let snapshot = syncWriter { (self.microphoneWav, self.wavStartMediaSeconds) }
        let mic = microphoneWav ?? snapshot.0
        let layout = CaptureAudioLayout(
            microphoneWav: mic,
            systemAudioInMovie: true,
            wavStartMediaSeconds: snapshot.1
        )
        try layout.write(sessionURL: sessionURL)
    }

    func stop() async throws {
        let snapshot = syncWriter { () -> (stream: SCStream?, mic: Bool, engine: AVAudioEngine?) in
            // Freeze t_wall / t_media at Stop so finishWriting is not counted,
            // and do not resume writers if the user stopped while paused (C1).
            self.clock.markRecordingStopped()
            self.paused = true
            self.started = false
            let captured = self.stream
            self.stream = nil
            let engine = self.engine
            self.engine = nil
            self.clearEngineObserver()
            return (captured, self.microphoneWav, engine)
        }
        do {
            try persistCaptureLayout(microphoneWav: snapshot.mic)
        } catch {
            // Tear down the stream even if archive/capture-layout.json cannot be written.
        }
        if let live = snapshot.stream {
            try await live.stopCapture()
        }
        snapshot.engine?.stop()
        do {
            try persistCaptureLayout(microphoneWav: snapshot.mic)
        } catch {
            // finishWriting still runs; reclaim persist below is the last try.
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                self.stopMicRevocationWatch()
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.closeWavWriter()
                if let writer = self.writer, writer.status == .writing {
                    writer.finishWriting {
                        continuation.resume()
                    }
                    return
                }
                continuation.resume()
            }
        }
        var stopError: Error?
        do {
            try reclaimLiveCaptureIfRewritten()
        } catch {
            stopError = error
            do {
                try reclaimLiveCaptureIfRewritten()
            } catch {
                stopError = error
            }
        }
        do {
            try persistCaptureLayout(microphoneWav: snapshot.mic)
        } catch {
            if stopError == nil { stopError = error }
        }
        if let stopError {
            throw stopError
        }
    }

    /// If AVAssetWriter / AVAudioFile reopened the UUID path at finishWriting,
    /// keep the larger regular file on the canonical archive names (C2).
    /// Forget the live name only after adopt succeeds so Stop can retry
    /// instead of leaving Whisper on a truncated `session.mp4`.
    func reclaimLiveCaptureIfRewritten() throws {
        try syncWriter {
            try self.reclaimLiveCaptureIfRewrittenLocked()
        }
    }

    private func reclaimLiveCaptureIfRewrittenLocked() throws {
        var firstError: Error?
        if let rel = liveMovieRel {
            do {
                try adoptLargerLiveFile(rel, destRelative: ScrumTracePath.sessionMovie)
                liveMovieRel = nil
            } catch {
                firstError = error
            }
        }
        if let rel = liveWavRel {
            do {
                try adoptLargerLiveFile(rel, destRelative: ScrumTracePath.audioWav)
                liveWavRel = nil
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func adoptLargerLiveFile(_ rel: String, destRelative: String) throws {
        let live = sessionURL.appendingPathComponent(rel)
        let dest = sessionURL.appendingPathComponent(destRelative)
        guard ExportRel.isContainedRegularFile(live, sessionRoot: sessionURL) else { return }
        let liveBytes = ExportRel.regularFileByteCount(live, sessionRoot: sessionURL) ?? 0
        let destBytes = ExportRel.regularFileByteCount(dest, sessionRoot: sessionURL) ?? 0
        if liveBytes > destBytes {
            try ExportRel.moveIntoSession(from: live, relative: destRelative, sessionURL: sessionURL)
        } else {
            do {
                try ExportRel.removeItemIfRegularFile(live, sessionRoot: sessionURL)
            } catch {
                ExportRel.unlinkLastComponentUnfollowed(live)
            }
            if ExportRel.isContainedRegularFile(live, sessionRoot: sessionURL) {
                throw SessionRecorderError.writerFailed("Could not drop leftover live capture file.")
            }
        }
    }

    /// Cancel / deinit: drop leftover UUID files that are not the only
    /// complete movie/WAV. Do not overwrite session.mp4, and do not delete
    /// a larger live file after a failed Stop reclaim (Gate 3).
    private func discardLiveCaptureLocked() {
        if let rel = liveMovieRel {
            discardLiveIfNotLargerThanCanonical(rel, destRelative: ScrumTracePath.sessionMovie)
        }
        if let rel = liveWavRel {
            discardLiveIfNotLargerThanCanonical(rel, destRelative: ScrumTracePath.audioWav)
        }
        liveMovieRel = nil
        liveWavRel = nil
    }

    private func discardLiveIfNotLargerThanCanonical(_ rel: String, destRelative: String) {
        let live = sessionURL.appendingPathComponent(rel)
        let dest = sessionURL.appendingPathComponent(destRelative)
        let liveBytes = ExportRel.regularFileByteCount(live, sessionRoot: sessionURL) ?? 0
        let destBytes = ExportRel.regularFileByteCount(dest, sessionRoot: sessionURL) ?? 0
        if liveBytes > destBytes {
            return
        }
        try? ExportRel.removeItemIfRegularFile(live, sessionRoot: sessionURL)
    }

    /// After `renameat` onto `session.mp4` / `audio.wav`, those UUID names
    /// must stay gone. If AVAssetWriter recreates them mid-session, Stop's
    /// reclaim is too late — fail instead of splitting the master movie (C1).
    private func liveCaptureWasRewritten() -> Bool {
        if let rel = liveMovieRel {
            let live = sessionURL.appendingPathComponent(rel)
            if ExportRel.isContainedRegularFile(live, sessionRoot: sessionURL) {
                failCaptureWrite("Could not write archive/session.mp4: writer reopened a live capture path.")
                return true
            }
        }
        if let rel = liveWavRel {
            let live = sessionURL.appendingPathComponent(rel)
            if ExportRel.isContainedRegularFile(live, sessionRoot: sessionURL) {
                failCaptureWrite("Could not write archive/audio.wav: WAV writer reopened a live capture path.")
                return true
            }
        }
        return false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Pause drops every ScreenCaptureKit output: screen, system audio, microphone.
        guard !paused, started else { return }
        if liveCaptureWasRewritten() { return }
        let sampleClock = stream.synchronizationClock
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = sampleClock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        if clock.isInsidePause(hostTime: host) {
            AgentLog.event("resume_edge_drop", ["type": String(type.rawValue)])
            return
        }
        switch type {
        case .screen:
            appendVideo(sampleBuffer, sampleClock: sampleClock)
        case .audio:
            appendAudioToMovie(sampleBuffer, sampleClock: sampleClock)
            if !microphoneWav {
                writeWav(from: sampleBuffer, sampleClock: sampleClock)
            }
        case .microphone:
            writeWav(from: sampleBuffer, sampleClock: sampleClock)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        freezeWriters()
        NotificationCenter.default.post(
            name: .scrumTraceCaptureFailed,
            object: error.localizedDescription
        )
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer, sampleClock: CMClock?) {
        guard !paused, started else { return }
        guard isCompleteScreenFrame(sampleBuffer) else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            noteVideoSampleNotReady()
            return
        }
        videoSampleNotReadyStreak = 0
        videoSampleNotReadyStallStart = .invalid
        guard let writer, let videoInput else {
            failCaptureWrite("Could not write archive/session.mp4: movie writer is missing.")
            return
        }
        if writer.status == .failed {
            failCaptureWrite(
                "Could not write archive/session.mp4: \(writer.error?.localizedDescription ?? "AVAssetWriter failed.")"
            )
            return
        }
        guard writer.status == .writing else {
            noteVideoWriterNotWriting()
            return
        }
        videoWriterNotWritingStreak = 0
        videoWriterNotWritingStallStart = .invalid
        guard videoInput.isReadyForMoreMediaData else {
            noteVideoBackpressure()
            return
        }
        videoBackpressureStreak = 0
        videoBackpressureStallStart = .invalid
        guard let remapped = remappedBuffer(sampleBuffer, sampleClock: sampleClock) else {
            noteRemapFailure()
            return
        }
        remapFailStreak = 0
        remapFailStallStart = .invalid
        if !videoInput.append(remapped) {
            failCaptureWrite(
                "Could not write archive/session.mp4: \(writer.error?.localizedDescription ?? "AVAssetWriter rejected a video sample.")"
            )
            return
        }
        if !loggedFirstVideo {
            loggedFirstVideo = true
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(remapped))
            AgentLog.event("recorder_first_sample", [
                "type": "screen",
                "media_seconds": String(format: "%.3f", pts)
            ])
        }
    }

    private func appendAudioToMovie(_ sampleBuffer: CMSampleBuffer, sampleClock: CMClock?) {
        guard !paused, started else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            noteAudioSampleNotReady()
            return
        }
        audioSampleNotReadyStreak = 0
        audioSampleNotReadyStallStart = .invalid
        guard let writer, let audioInput else {
            failCaptureWrite("Could not write archive/session.mp4: movie writer is missing.")
            return
        }
        if writer.status == .failed {
            failCaptureWrite(
                "Could not write archive/session.mp4: \(writer.error?.localizedDescription ?? "AVAssetWriter failed.")"
            )
            return
        }
        guard writer.status == .writing else {
            noteAudioWriterNotWriting()
            return
        }
        audioWriterNotWritingStreak = 0
        audioWriterNotWritingStallStart = .invalid
        guard audioInput.isReadyForMoreMediaData else {
            noteAudioBackpressure()
            return
        }
        audioBackpressureStreak = 0
        audioBackpressureStallStart = .invalid
        guard let remapped = remappedBuffer(sampleBuffer, sampleClock: sampleClock) else {
            noteRemapFailure()
            return
        }
        remapFailStreak = 0
        remapFailStallStart = .invalid
        if !audioInput.append(remapped) {
            failCaptureWrite(
                "Could not write archive/session.mp4: \(writer.error?.localizedDescription ?? "AVAssetWriter rejected an audio sample.")"
            )
            return
        }
        if !loggedFirstAudio {
            loggedFirstAudio = true
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(remapped))
            AgentLog.event("recorder_first_sample", [
                "type": "audio",
                "media_seconds": String(format: "%.3f", pts)
            ])
        }
    }

    private func remappedBuffer(_ sampleBuffer: CMSampleBuffer, sampleClock: CMClock?) -> CMSampleBuffer? {
        let media = clock.mediaTime(forSampleBuffer: sampleBuffer, sampleClock: sampleClock)
        var timing = CMSampleTimingInfo()
        let hasTiming = CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let wholeDuration = CMSampleBufferGetDuration(sampleBuffer)
        if hasTiming, timing.duration.flags.contains(.valid), CMTimeGetSeconds(timing.duration) > 0 {
            if numSamples > 1, wholeDuration.flags.contains(.valid) {
                let per = CMTimeGetSeconds(timing.duration)
                let all = CMTimeGetSeconds(wholeDuration)
                if all > 0, per >= all * 0.9 {
                    timing.duration = CMTimeMultiplyByFloat64(wholeDuration, multiplier: 1.0 / Double(numSamples))
                }
            }
            timing.presentationTimeStamp = media
            timing.decodeTimeStamp = .invalid
        } else if CMSampleBufferGetNumSamples(sampleBuffer) == 1 {
            timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: media,
                decodeTimeStamp: .invalid
            )
        } else {
            return nil
        }
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        guard status == noErr else { return nil }
        return output
    }

    private func noteRemapFailure() {
        advanceStall(
            streak: &remapFailStreak,
            start: &remapFailStallStart,
            failAfterFrames: 12,
            message: "Could not timestamp capture samples for the master clock."
        )
    }

    private func noteWavFormatFailure() {
        advanceStall(
            streak: &wavFormatFailStreak,
            start: &wavFormatFailStallStart,
            failAfterFrames: 12,
            message: "Could not decode audio samples for archive/audio.wav."
        )
    }

    private func noteVideoBackpressure() {
        advanceStall(
            streak: &videoBackpressureStreak,
            start: &videoBackpressureStallStart,
            failAfterFrames: MediaBudget.captureStallFrames,
            message: "Could not write archive/session.mp4: video writer was not ready."
        )
    }

    private func noteAudioBackpressure() {
        advanceStall(
            streak: &audioBackpressureStreak,
            start: &audioBackpressureStallStart,
            failAfterFrames: MediaBudget.captureStallFrames,
            message: "Could not write archive/session.mp4: audio writer was not ready."
        )
    }

    private func noteVideoSampleNotReady() {
        advanceStall(
            streak: &videoSampleNotReadyStreak,
            start: &videoSampleNotReadyStallStart,
            failAfterFrames: MediaBudget.captureStallFrames,
            message: "Could not write archive/session.mp4: video sample was not ready."
        )
    }

    private func noteAudioSampleNotReady() {
        advanceStall(
            streak: &audioSampleNotReadyStreak,
            start: &audioSampleNotReadyStallStart,
            failAfterFrames: MediaBudget.captureStallFrames,
            message: "Could not write archive/session.mp4: audio sample was not ready."
        )
    }

    private func noteWavSampleNotReady() {
        advanceStall(
            streak: &wavSampleNotReadyStreak,
            start: &wavSampleNotReadyStallStart,
            failAfterFrames: MediaBudget.captureStallFrames,
            message: "Could not write archive/audio.wav: audio sample was not ready."
        )
    }

    private func noteVideoWriterNotWriting() {
        advanceStall(
            streak: &videoWriterNotWritingStreak,
            start: &videoWriterNotWritingStallStart,
            failAfterFrames: MediaBudget.captureStallFrames,
            message: "Could not write archive/session.mp4: video writer was not writing."
        )
    }

    private func noteAudioWriterNotWriting() {
        advanceStall(
            streak: &audioWriterNotWritingStreak,
            start: &audioWriterNotWritingStallStart,
            failAfterFrames: MediaBudget.captureStallFrames,
            message: "Could not write archive/session.mp4: audio writer was not writing."
        )
    }

    private func noteWavEmptyConvert() {
        advanceStall(
            streak: &wavEmptyConvertStreak,
            start: &wavEmptyConvertStallStart,
            failAfterFrames: MediaBudget.captureStallFrames,
            message: "Could not write archive/audio.wav: converted audio was empty."
        )
    }

    private func advanceStall(
        streak: inout Int,
        start: inout CMTime,
        failAfterFrames: Int,
        message: String
    ) {
        streak += 1
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if !start.flags.contains(.valid) {
            start = now
        }
        if streak >= failAfterFrames
            && CMTimeGetSeconds(CMTimeSubtract(now, start)) >= MediaBudget.captureStallSeconds {
            failCaptureWrite(message)
        }
    }

    private func resetStallCountersLocked() {
        remapFailStreak = 0
        wavFormatFailStreak = 0
        videoBackpressureStreak = 0
        audioBackpressureStreak = 0
        videoSampleNotReadyStreak = 0
        audioSampleNotReadyStreak = 0
        wavSampleNotReadyStreak = 0
        videoWriterNotWritingStreak = 0
        audioWriterNotWritingStreak = 0
        wavEmptyConvertStreak = 0
        remapFailStallStart = .invalid
        wavFormatFailStallStart = .invalid
        videoBackpressureStallStart = .invalid
        audioBackpressureStallStart = .invalid
        videoSampleNotReadyStallStart = .invalid
        audioSampleNotReadyStallStart = .invalid
        wavSampleNotReadyStallStart = .invalid
        videoWriterNotWritingStallStart = .invalid
        audioWriterNotWritingStallStart = .invalid
        wavEmptyConvertStallStart = .invalid
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            return false
        }
        return true
    }

    private func writeWav(from sampleBuffer: CMSampleBuffer, sampleClock: CMClock?) {
        guard !paused, started else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            noteWavSampleNotReady()
            return
        }
        wavSampleNotReadyStreak = 0
        wavSampleNotReadyStallStart = .invalid
        guard let wavFile else {
            failCaptureWrite("Could not write archive/audio.wav: WAV writer is missing.")
            return
        }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            noteWavFormatFailure()
            return
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            noteWavFormatFailure()
            return
        }
        wavFormatFailStreak = 0
        wavFormatFailStallStart = .invalid
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else {
            noteWavEmptyConvert()
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            failCaptureWrite("Could not write archive/audio.wav: PCM buffer allocation failed.")
            return
        }
        buffer.frameLength = frames
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard copied == noErr else {
            failCaptureWrite("Could not write archive/audio.wav: PCM copy failed.")
            return
        }
        let mediaSeconds = CMTimeGetSeconds(clock.mediaTime(forSampleBuffer: sampleBuffer, sampleClock: sampleClock))
        let target = wavFile.processingFormat
        if buffer.format == target {
            wavEmptyConvertStreak = 0
            wavEmptyConvertStallStart = .invalid
            persistWav(buffer, file: wavFile, mediaSeconds: mediaSeconds)
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else {
            failCaptureWrite("Could not write archive/audio.wav: format conversion failed.")
            return
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            failCaptureWrite("Could not write archive/audio.wav: \(error.localizedDescription)")
            return
        }
        if converted.frameLength > 0 {
            wavEmptyConvertStreak = 0
            wavEmptyConvertStallStart = .invalid
            persistWav(converted, file: wavFile, mediaSeconds: mediaSeconds)
            return
        }
        noteWavEmptyConvert()
    }

    /// CL-02: `AVAudioFile` finalizes RIFF sizes on close. `kill -9` cannot.
    private func closeWavWriter() {
        wavFile = nil
    }

    /// TCC-6: mid-session Microphone revocation is not delivered as an SCStream
    /// error. Poll `authorizationStatus` while writers are live.
    private func startMicRevocationWatch() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.checkMicAuthorizationLocked()
        }
        timer.resume()
        syncWriter {
            self.micWatchTimer?.cancel()
            self.micWatchTimer = timer
        }
    }

    private func stopMicRevocationWatch() {
        micWatchTimer?.cancel()
        micWatchTimer = nil
    }

    private func checkMicAuthorizationLocked() {
        guard started, !captureWriteFailed else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            failCaptureWrite("Microphone access was revoked.")
        case .authorized, .notDetermined:
            break
        @unknown default:
            break
        }
    }

    /// WAV and movie writes share one failure so Start's `audioWriteFailure`
    /// catch covers a disk-full AVAssetWriter during startCapture (C1).
    private func failCaptureWrite(_ message: String) {
        let shouldNotify: Bool = syncWriter {
            guard !self.captureWriteFailed else { return false }
            self.captureWriteFailed = true
            self.captureWriteMessage = message
            return true
        }
        guard shouldNotify else { return }
        AgentLog.event("capture_write_fail", ["error": AgentLog.sanitize(message)])
        freezeWriters()
        NotificationCenter.default.post(
            name: .scrumTraceCaptureFailed,
            object: message
        )
    }

    private func persistWav(_ buffer: AVAudioPCMBuffer, file: AVAudioFile, mediaSeconds: TimeInterval?) {
        do {
            if let media = mediaSeconds {
                if wavStartMediaSeconds == nil {
                    wavStartMediaSeconds = media
                    try? persistCaptureLayout()
                }
                if let start = wavStartMediaSeconds {
                    let expected = Int64(((media - start) * 16_000).rounded())
                    let gap = expected - wavFramesWritten
                    if gap > 320 {
                        let silenceCount = AVAudioFrameCount(gap)
                        if let silence = AVAudioPCMBuffer(
                            pcmFormat: file.processingFormat,
                            frameCapacity: silenceCount
                        ) {
                            silence.frameLength = silence.frameCapacity
                            Self.zeroFillPCM(silence)
                            try file.write(from: silence)
                            wavFramesWritten += AVAudioFramePosition(silence.frameLength)
                        }
                    } else if gap < -320 && !loggedWavAhead {
                        loggedWavAhead = true
                        AgentLog.event("wav_ahead_frames", ["frames": String(gap)])
                    }
                }
            }
            try file.write(from: buffer)
            wavFramesWritten += AVAudioFramePosition(buffer.frameLength)
            if !loggedFirstWav {
                loggedFirstWav = true
                let logged = mediaSeconds ?? clock.currentMediaSeconds()
                AgentLog.event("recorder_first_sample", [
                    "type": "wav",
                    "media_seconds": String(format: "%.3f", logged)
                ])
            }
        } catch {
            failCaptureWrite("Could not write archive/audio.wav: \(error.localizedDescription)")
        }
    }

    private func prepareWriters(width: Int, height: Int) throws {
        let movieRel: String
        let wavRel: String
        do {
            movieRel = try ExportRel.prepareContainedWrite(
                relative: ScrumTracePath.sessionMovie,
                sessionURL: sessionURL
            )
            wavRel = try ExportRel.prepareContainedWrite(
                relative: ScrumTracePath.audioWav,
                sessionURL: sessionURL
            )
        } catch {
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }
        let movieURL = sessionURL.appendingPathComponent(movieRel)
        let wavURL = sessionURL.appendingPathComponent(wavRel)
        try ExportRel.removeItemIfRegularFile(movieURL, sessionRoot: sessionURL)
        try ExportRel.removeItemIfRegularFile(wavURL, sessionRoot: sessionURL)
        if (try? movieURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || (try? wavURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }
        // AVAssetWriter / AVAudioFile follow a dest symlink planted between
        // unlink and create. Create unique live names, then renameat onto
        // session.mp4 / audio.wav immediately after startWriting — not at Stop.
        let liveMovieRel: String
        let liveWavRel: String
        do {
            liveMovieRel = try ExportRel.prepareContainedWrite(
                relative: "archive/scrumtrace-live-\(UUID().uuidString).mp4",
                sessionURL: sessionURL
            )
            liveWavRel = try ExportRel.prepareContainedWrite(
                relative: "archive/scrumtrace-live-\(UUID().uuidString).wav",
                sessionURL: sessionURL
            )
        } catch {
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }
        let liveMovieURL = sessionURL.appendingPathComponent(liveMovieRel)
        let liveWavURL = sessionURL.appendingPathComponent(liveWavRel)
        try ExportRel.removeItemIfRegularFile(liveMovieURL, sessionRoot: sessionURL)
        try ExportRel.removeItemIfRegularFile(liveWavURL, sessionRoot: sessionURL)
        if (try? liveMovieURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || (try? liveWavURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }

        let w = max(width - width % 2, 2)
        let h = max(height - height % 2, 2)
        let writer = try AVAssetWriter(outputURL: liveMovieURL, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: MediaBudget.archiveVideoBitrate,
                // AVVideoDataRateLimitsKey uses bytes/second + duration.
                AVVideoDataRateLimitsKey: [
                    MediaBudget.archiveVideoMaxBitrate / 8,
                    1
                ],
                AVVideoMaxKeyFrameIntervalKey: MediaBudget.archiveKeyFrameInterval,
                AVVideoExpectedSourceFrameRateKey: MediaBudget.archiveExpectedFrameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw SessionRecorderError.writerFailed("AVAssetWriter rejected inputs.")
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            try? ExportRel.removeItemIfRegularFile(liveMovieURL, sessionRoot: sessionURL)
            throw SessionRecorderError.writerFailed(writer.error?.localizedDescription ?? "Writer failed.")
        }
        guard ExportRel.isContainedRegularFile(liveMovieURL, sessionRoot: sessionURL) else {
            writer.cancelWriting()
            try? ExportRel.removeItemIfRegularFile(liveMovieURL, sessionRoot: sessionURL)
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }
        do {
            try ExportRel.moveIntoSession(from: liveMovieURL, relative: movieRel, sessionURL: sessionURL)
        } catch {
            writer.cancelWriting()
            try? ExportRel.removeItemIfRegularFile(liveMovieURL, sessionRoot: sessionURL)
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }
        guard ExportRel.isContainedRegularFile(movieURL, sessionRoot: sessionURL) else {
            writer.cancelWriting()
            try? ExportRel.removeItemIfRegularFile(movieURL, sessionRoot: sessionURL)
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }
        self.liveMovieRel = liveMovieRel
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        wavFile = try AVAudioFile(forWriting: liveWavURL, settings: wavSettings)
        guard ExportRel.isContainedRegularFile(liveWavURL, sessionRoot: sessionURL) else {
            writer.cancelWriting()
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            wavFile = nil
            discardLiveCaptureLocked()
            try? ExportRel.removeItemIfRegularFile(movieURL, sessionRoot: sessionURL)
            try? ExportRel.removeItemIfRegularFile(liveWavURL, sessionRoot: sessionURL)
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }
        do {
            try ExportRel.moveIntoSession(from: liveWavURL, relative: wavRel, sessionURL: sessionURL)
        } catch {
            writer.cancelWriting()
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            wavFile = nil
            discardLiveCaptureLocked()
            try? ExportRel.removeItemIfRegularFile(movieURL, sessionRoot: sessionURL)
            try? ExportRel.removeItemIfRegularFile(liveWavURL, sessionRoot: sessionURL)
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }
        guard ExportRel.isContainedRegularFile(wavURL, sessionRoot: sessionURL) else {
            writer.cancelWriting()
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            wavFile = nil
            discardLiveCaptureLocked()
            try? ExportRel.removeItemIfRegularFile(movieURL, sessionRoot: sessionURL)
            try? ExportRel.removeItemIfRegularFile(wavURL, sessionRoot: sessionURL)
            throw SessionRecorderError.writerFailed("archive capture paths escaped the session folder.")
        }
        self.liveWavRel = liveWavRel
        self.wavStartMediaSeconds = nil
        self.wavFramesWritten = 0
        self.loggedWavAhead = false
        self.loggedFirstVideo = false
        self.loggedFirstAudio = false
        self.loggedFirstWav = false
        // Do not clear a privacy freeze from the permission sheet. If writers
        // are already paused, open the t_media interval now that
        // markRecordingStarted has run (C1 / D4).
        if paused {
            clock.beginPause()
        }
        started = false
    }

    private func startMicrophoneFallback() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SessionRecorderError.writerFailed("No usable microphone input format.")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            // The tap reuses `buffer`. Copy before hopping queues or pause-dropped
            // frames can still scribble into a later WAV write (C1).
            guard let copy = Self.copyPCM(buffer) else {
                self.failCaptureWrite("Could not copy microphone PCM.")
                return
            }
            // Host time on this thread. After the queue hop it is too late.
            let host: CMTime? = when.isHostTimeValid
                ? CMClockMakeHostTimeFromSystemUnits(when.hostTime)
                : CMClockGetTime(CMClockGetHostTimeClock())
            self.writerQueue.async {
                guard !self.paused, self.started else { return }
                if let host, self.clock.isInsidePause(hostTime: host) {
                    AgentLog.event("resume_edge_drop", ["type": "engine"])
                    return
                }
                self.writeEngineBuffer(copy, hostTime: host)
            }
        }
        try engine.start()
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            AgentLog.event("mic_engine_config_change", [:])
            self?.failCaptureWrite("Microphone input changed. Stop and start a new session.")
        }
        syncWriter {
            if let previous = self.engineConfigObserver {
                NotificationCenter.default.removeObserver(previous)
            }
            self.engineConfigObserver = token
            self.engine = engine
        }
    }

    private func clearEngineObserver() {
        if let token = engineConfigObserver {
            NotificationCenter.default.removeObserver(token)
            engineConfigObserver = nil
        }
    }

    /// Snapshot a tap buffer. AVAudioEngine reuses the pointer after the callback returns.
    static func copyPCM(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
            return copy
        }
        if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
            return copy
        }
        if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
            return copy
        }
        let srcBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let dstBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        var copied = false
        for index in 0..<min(srcBuffers.count, dstBuffers.count) {
            guard let srcData = srcBuffers[index].mData, let dstData = dstBuffers[index].mData else { continue }
            memcpy(dstData, srcData, Int(srcBuffers[index].mDataByteSize))
            dstBuffers[index].mDataByteSize = srcBuffers[index].mDataByteSize
            copied = true
        }
        return copied ? copy : nil
    }

    /// AVAudioPCMBuffer allocation is not guaranteed to zero int16 frames.
    static func zeroFillPCM(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        if let data = buffer.floatChannelData {
            for channel in 0..<channels {
                data[channel].initialize(repeating: 0, count: frames)
            }
            return
        }
        if let data = buffer.int16ChannelData {
            for channel in 0..<channels {
                data[channel].initialize(repeating: 0, count: frames)
            }
            return
        }
        if let data = buffer.int32ChannelData {
            for channel in 0..<channels {
                data[channel].initialize(repeating: 0, count: frames)
            }
            return
        }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in 0..<buffers.count {
            guard let bytes = buffers[index].mData else { continue }
            memset(bytes, 0, Int(buffers[index].mDataByteSize))
        }
    }

    private func writeEngineBuffer(_ buffer: AVAudioPCMBuffer, hostTime: CMTime?) {
        guard !paused, started else { return }
        guard let wavFile else {
            failCaptureWrite("Could not write archive/audio.wav: WAV writer is missing.")
            return
        }
        let frames = buffer.frameLength
        guard frames > 0 else {
            noteWavEmptyConvert()
            return
        }
        let mediaSeconds = hostTime.map { CMTimeGetSeconds(clock.mediaTime(forHostTime: $0)) }
            ?? clock.currentMediaSeconds()
        let target = wavFile.processingFormat
        if buffer.format == target {
            wavEmptyConvertStreak = 0
            wavEmptyConvertStallStart = .invalid
            persistWav(buffer, file: wavFile, mediaSeconds: mediaSeconds)
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else {
            failCaptureWrite("Could not write archive/audio.wav: format conversion failed.")
            return
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            failCaptureWrite("Could not write archive/audio.wav: \(error.localizedDescription)")
            return
        }
        if converted.frameLength > 0 {
            wavEmptyConvertStreak = 0
            wavEmptyConvertStallStart = .invalid
            persistWav(converted, file: wavFile, mediaSeconds: mediaSeconds)
            return
        }
        noteWavEmptyConvert()
    }

    /// Microphone only. Screen Recording is preflighted before this runs so
    /// we never pop the looping Screen Recording sheet from Record.
    /// `requestAccess` on an already-denied client re-prompts every Start.
    private func requestPermission(includeMicrophone: Bool = true) async throws {
        guard includeMicrophone else {
            AgentLog.event("mic_skipped", [:])
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            AgentLog.event("mic_already_authorized", [:])
            return
        case .notDetermined:
            AgentLog.event("mic_request", [:])
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            AgentLog.event("mic_request_done", ["granted": granted ? "1" : "0"])
            if !granted {
                throw SessionRecorderError.microphoneDenied
            }
        case .denied, .restricted:
            AgentLog.event("mic_denied", [:])
            throw SessionRecorderError.microphoneDenied
        @unknown default:
            AgentLog.event("mic_unknown", [:])
            throw SessionRecorderError.microphoneDenied
        }
    }

    private static func shareableContentOffMain() async throws -> SCShareableContent {
        try await Task.detached(priority: .userInitiated) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }.value
    }

    private static func startCaptureOffMain(_ stream: SCStream) async throws {
        try await Task.detached(priority: .userInitiated) {
            try await stream.startCapture()
        }.value
    }

    deinit {
        let snapshot = syncWriter { () -> (stream: SCStream?, engine: AVAudioEngine?) in
            self.paused = true
            self.started = false
            let stream = self.stream
            self.stream = nil
            let engine = self.engine
            self.engine = nil
            self.clearEngineObserver()
            self.stopMicRevocationWatch()
            self.closeWavWriter()
            if let writer = self.writer, writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
            }
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.discardLiveCaptureLocked()
            return (stream, engine)
        }
        snapshot.engine?.stop()
        if let live = snapshot.stream {
            Task.detached {
                do {
                    try await live.stopCapture()
                } catch {
                    do {
                        try await live.stopCapture()
                    } catch {
                        NotificationCenter.default.post(
                            name: .scrumTraceCaptureFailed,
                            object: "Could not stop ScreenCaptureKit: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
    }
}
