import AVFoundation
import CoreMedia

/// Owned by the recorder's serial writer queue. Host-time intervals also cover
/// buffers captured while muted but delivered after Unmute.
struct RecordingAudioMute {
    private struct Interval { var start: Double; var end: Double? }
    private var allIntervals: [Interval] = []
    private var micIntervals: [Interval] = []
    private(set) var allMuted = false
    private(set) var micMuted = false

    mutating func set(all: Bool, microphone: Bool, at hostSeconds: Double) {
        Self.update(&allIntervals, wasMuted: allMuted, muted: all, at: hostSeconds)
        Self.update(&micIntervals, wasMuted: micMuted, muted: microphone, at: hostSeconds)
        allMuted = all
        micMuted = microphone
    }

    private static func update(_ intervals: inout [Interval], wasMuted: Bool, muted: Bool, at time: Double) {
        guard wasMuted != muted else { return }
        if muted { intervals.append(Interval(start: time)) }
        else if !intervals.isEmpty { intervals[intervals.count - 1].end = time }
    }

    func shouldSilence(microphone: Bool, start: Double, duration: Double) -> Bool {
        if allMuted || (microphone && micMuted) { return true }
        let intervals = allIntervals + (microphone ? micIntervals : [])
        guard start.isFinite, duration.isFinite, duration >= 0 else { return !intervals.isEmpty }
        return intervals.contains { start < ($0.end ?? .infinity) && start + duration >= $0.start }
    }

    static func silencePCM(_ buffer: AVAudioPCMBuffer) {
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let bytes = audio.mData { memset(bytes, 0, Int(audio.mDataByteSize)) }
        }
    }

    /// Allocate new zeroed PCM storage; never overwrite ScreenCaptureKit's shared buffers.
    static func silentCopy(of sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger) != 0,
              let source = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let size = CMBlockBufferGetDataLength(source)
        var data: CMBlockBuffer?
        guard size > 0,
              CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &data) == noErr,
              let data,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: size) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample))
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: format,
            sampleCount: CMSampleBufferGetNumSamples(sample), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &result) == noErr else { return nil }
        return result
    }
}
