import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

enum SessionRecorderError: LocalizedError {
    case permissionDenied
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required in System Settings."
        case .writerFailed(let message): return message
        }
    }
}

/// ScreenCaptureKit coordinator. While paused, screen frames, system audio,
/// microphone PCM, and metadata are discarded — nothing is written to MP4 or WAV.
/// System audio goes to the movie AAC track. Room mic goes to `archive/audio.wav`.
final class SessionRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let clock: ClockSynchronizer
    private let sessionURL: URL
    private let writerQueue = DispatchQueue(label: "com.str8minds.ScrumTrace.writer")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var wavFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var engine: AVAudioEngine?
    private var paused = false
    private var started = false
    private var microphoneWav = false

    init(sessionURL: URL, clock: ClockSynchronizer) {
        self.sessionURL = sessionURL
        self.clock = clock
        super.init()
    }

    var isPaused: Bool {
        writerQueue.sync { paused }
    }

    func start() async throws {
        try await requestPermission()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SessionRecorderError.writerFailed("No display available for capture.")
        }
        let size = Self.evenCaptureSize(width: display.width, height: display.height)
        let excluded = content.applications.filter { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        clock.markRecordingStarted()
        // DispatchQueue.sync is synchronous — `await` here does not compile.
        try writerQueue.sync {
            try self.prepareWriters(width: size.width, height: size.height)
        }

        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 8
        config.showsCursor = true
        config.capturesAudio = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        var mic = false
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
        writerQueue.sync {
            self.microphoneWav = mic
            self.stream = stream
            self.started = true
        }
        do {
            try await stream.startCapture()
        } catch {
            writerQueue.sync { self.started = false }
            throw error
        }
    }

    /// Even pixel size shared by SCStream and AVAssetWriter, capped at 1920×1080.
    static func evenCaptureSize(width: Int, height: Int) -> (width: Int, height: Int) {
        var w = max(width, 2)
        var h = max(height, 2)
        if w > 1920 {
            h = max(Int((Double(h) * 1920.0 / Double(w)).rounded()), 2)
            w = 1920
        }
        if h > 1080 {
            w = max(Int((Double(w) * 1080.0 / Double(h)).rounded()), 2)
            h = 1080
        }
        w -= w % 2
        h -= h % 2
        return (max(w, 2), max(h, 2))
    }

    func setPaused(_ next: Bool) {
        // sync: Pause must apply before the next SCStream/mic buffer on this queue.
        // async left a window where paused samples were still appended (C1).
        writerQueue.sync {
            guard self.paused != next else { return }
            self.paused = next
            if next {
                self.clock.beginPause()
            } else {
                self.clock.endPause()
            }
        }
    }

    /// Drop every capture source immediately without opening a Pause interval.
    func freezeWriters() {
        writerQueue.sync {
            self.paused = true
            self.started = false
            self.clock.markRecordingStopped()
        }
    }

    func stop() async throws {
        let live = writerQueue.sync { () -> SCStream? in
            // Freeze t_wall / t_media at Stop so finishWriting is not counted,
            // and do not resume writers if the user stopped while paused (C1).
            self.clock.markRecordingStopped()
            self.paused = true
            self.started = false
            let captured = self.stream
            self.stream = nil
            return captured
        }
        if let live {
            try await live.stopCapture()
        }
        engine?.stop()
        engine = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.wavFile = nil
                if let writer = self.writer, writer.status == .writing {
                    writer.finishWriting {
                        continuation.resume()
                    }
                    return
                }
                continuation.resume()
            }
        }
        let layout = CaptureAudioLayout(
            microphoneWav: microphoneWav,
            systemAudioInMovie: true
        )
        try layout.write(sessionURL: sessionURL)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Pause drops every ScreenCaptureKit output: screen, system audio, microphone.
        guard !paused, started else { return }
        switch type {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            appendAudioToMovie(sampleBuffer)
            if !microphoneWav {
                writeWav(from: sampleBuffer)
            }
        case .microphone:
            writeWav(from: sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ScrumTrace stream stopped: \(error.localizedDescription)")
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !paused, started, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer, writer.status == .writing, let videoInput, videoInput.isReadyForMoreMediaData else { return }
        guard let remapped = remappedBuffer(sampleBuffer) else { return }
        _ = videoInput.append(remapped)
    }

    private func appendAudioToMovie(_ sampleBuffer: CMSampleBuffer) {
        guard !paused, started, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if let writer, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData {
            if let remapped = remappedBuffer(sampleBuffer) {
                _ = audioInput.append(remapped)
            }
        }
    }

    private func remappedBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let media = clock.mediaTime(forSampleBuffer: sampleBuffer)
        let rawDuration = CMSampleBufferGetDuration(sampleBuffer)
        let duration: CMTime
        if rawDuration.flags.contains(.valid), CMTimeGetSeconds(rawDuration) > 0 {
            duration = rawDuration
        } else {
            duration = CMTime(value: 1, timescale: 30)
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: media,
            decodeTimeStamp: .invalid
        )
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

    private func writeWav(from sampleBuffer: CMSampleBuffer) {
        guard !paused, started else { return }
        guard let wavFile else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard copied == noErr else { return }
        let target = wavFile.processingFormat
        if buffer.format == target {
            try? wavFile.write(from: buffer)
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { return }
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
        if error == nil, converted.frameLength > 0 {
            try? wavFile.write(from: converted)
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

        let w = max(width - width % 2, 2)
        let h = max(height - height % 2, 2)
        let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
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
            throw SessionRecorderError.writerFailed(writer.error?.localizedDescription ?? "Writer failed.")
        }
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
        wavFile = try AVAudioFile(forWriting: wavURL, settings: wavSettings)
        paused = false
        started = false
    }

    private func startMicrophoneFallback() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // The tap reuses `buffer`. Copy before hopping queues or pause-dropped
            // frames can still scribble into a later WAV write (C1).
            guard let copy = Self.copyPCM(buffer) else { return }
            self.writerQueue.async {
                guard !self.paused, self.started else { return }
                self.writeEngineBuffer(copy)
            }
        }
        try engine.start()
        self.engine = engine
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
        for index in 0..<min(srcBuffers.count, dstBuffers.count) {
            guard let srcData = srcBuffers[index].mData, let dstData = dstBuffers[index].mData else { continue }
            memcpy(dstData, srcData, Int(srcBuffers[index].mDataByteSize))
            dstBuffers[index].mDataByteSize = srcBuffers[index].mDataByteSize
        }
        return copy
    }

    private func writeEngineBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !paused, started, let wavFile else { return }
        let frames = buffer.frameLength
        guard frames > 0 else { return }
        let target = wavFile.processingFormat
        if buffer.format == target {
            try? wavFile.write(from: buffer)
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { return }
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
        if error == nil, converted.frameLength > 0 {
            try? wavFile.write(from: converted)
        }
    }

    private func requestPermission() async throws {
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                throw SessionRecorderError.permissionDenied
            }
        }
        // Mic is optional: deny → system-audio WAV only. Screen permission is required.
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
}
