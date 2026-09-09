import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum SessionRecorderError: LocalizedError {
    case notRecording
    case permissionDenied
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRecording: return "Recorder is not running."
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
    private var firstVideoPTS: CMTime?
    private var firstAudioPTS: CMTime?
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
        clock.markRecordingStarted()
        try await writerQueue.sync {
            try self.prepareWriters()
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SessionRecorderError.writerFailed("No display available for capture.")
        }
        let excluded = content.applications.filter { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 8
        config.showsCursor = true
        config.capturesAudio = true
        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        if #available(macOS 15.0, *) {
            do {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: writerQueue)
                microphoneWav = true
            } catch {
                do {
                    try startMicrophoneFallback()
                    microphoneWav = true
                } catch {
                    microphoneWav = false
                }
            }
        } else {
            try startMicrophoneFallback()
            microphoneWav = true
        }
        try await stream.startCapture()
        self.stream = stream
        started = true
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

    func stop() async throws {
        writerQueue.sync { self.paused = true }
        if let stream {
            try await stream.stopCapture()
        }
        stream = nil
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
        started = false
        let layout = CaptureAudioLayout(
            microphoneWav: microphoneWav,
            systemAudioInMovie: true
        )
        try? layout.write(sessionURL: sessionURL)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Pause drops every ScreenCaptureKit output: screen, system audio, microphone.
        guard !paused else { return }
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
        guard let remapped = remappedBuffer(sampleBuffer, first: &firstVideoPTS) else { return }
        _ = videoInput.append(remapped)
    }

    private func appendAudioToMovie(_ sampleBuffer: CMSampleBuffer) {
        guard !paused, started, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if let writer, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData {
            if let remapped = remappedBuffer(sampleBuffer, first: &firstAudioPTS) {
                _ = audioInput.append(remapped)
            }
        }
    }

    private func remappedBuffer(_ sampleBuffer: CMSampleBuffer, first: inout CMTime?) -> CMSampleBuffer? {
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if first == nil { first = sourcePTS }
        let media = clock.mediaTime(forSampleBuffer: sampleBuffer)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
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
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
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
        if error == nil {
            try? wavFile.write(from: converted)
        }
    }

    private func prepareWriters() throws {
        let movieURL = sessionURL.appendingPathComponent(ScrumTracePath.sessionMovie)
        let wavURL = sessionURL.appendingPathComponent(ScrumTracePath.audioWav)
        try? FileManager.default.removeItem(at: movieURL)
        try? FileManager.default.removeItem(at: wavURL)

        let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
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
        firstVideoPTS = nil
        firstAudioPTS = nil
        paused = false
        microphoneWav = false
    }

    private func startMicrophoneFallback() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.writerQueue.async {
                guard !self.paused else { return }
                self.writeEngineBuffer(buffer, time: time)
            }
        }
        try engine.start()
        self.engine = engine
    }

    private func writeEngineBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let wavFile else { return }
        let host = CMClockMakeHostTimeFromSystemUnits(time.hostTime)
        _ = clock.mediaTime(forHostTime: host)
        let target = wavFile.processingFormat
        if buffer.format == target {
            try? wavFile.write(from: buffer)
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameCapacity) else { return }
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
        if error == nil {
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
