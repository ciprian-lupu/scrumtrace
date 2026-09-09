#if os(macOS)
import AppKit
#endif
import AVFoundation
import Foundation

struct ClipExporter {
    func export(
        sessionURL: URL,
        slice: SliceRecord,
        mediaDuration: TimeInterval
    ) async throws -> SliceRecord {
        let source = sessionURL.appendingPathComponent(ScrumTracePath.sessionMovie)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw SessionRecorderError.writerFailed("session.mp4 is missing.")
        }
        guard let relativeClip = slice.clipPath else {
            throw SessionRecorderError.writerFailed("Slice is missing clip_path.")
        }
        let clipURL = sessionURL.appendingPathComponent(relativeClip)
        try FileManager.default.createDirectory(
            at: clipURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await reencode(source: source, destination: clipURL, slice: slice, mediaDuration: mediaDuration)

        var updated = slice
        if updated.stills.isEmpty {
            updated.stills = [clipURL.deletingLastPathComponent().appendingPathComponent("shot-1.jpg").path]
        }
        let stillRelative = updated.stills[0]
        let stillURL = sessionURL.appendingPathComponent(stillRelative)
        try await extractStill(source: source, at: (slice.startMedia + slice.endMedia) / 2, to: stillURL)
        if !updated.stills.contains(stillRelative) {
            updated.stills.insert(stillRelative, at: 0)
        }
        return updated
    }

    private func reencode(
        source: URL,
        destination: URL,
        slice: SliceRecord,
        mediaDuration: TimeInterval
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        let start = CMTime(seconds: max(0, slice.startMedia), preferredTimescale: 600)
        let duration = CMTime(
            seconds: min(MediaBudget.clipMaxDuration, max(MediaBudget.clipMinDuration, slice.endMedia - slice.startMedia)),
            preferredTimescale: 600
        )
        let endLimit = CMTime(seconds: mediaDuration, preferredTimescale: 600)
        let actualDuration = CMTimeMinimum(duration, CMTimeSubtract(endLimit, start))

        guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .mp4) else {
            throw SessionRecorderError.writerFailed("Could not create clip writer.")
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: MediaBudget.clipWidth,
            AVVideoHeightKey: MediaBudget.clipHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: MediaBudget.clipVideoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: MediaBudget.clipAudioBitrate
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
        }
        guard writer.startWriting() else {
            throw SessionRecorderError.writerFailed(writer.error?.localizedDescription ?? "Clip writer failed.")
        }
        writer.startSession(atSourceTime: .zero)

        let reader = try AVAssetReader(asset: asset)
        let range = CMTimeRange(start: start, duration: actualDuration)
        reader.timeRange = range

        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
            let output = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            try await pump(reader: reader, output: output, writerInput: videoInput, writer: writer, shift: start)
        }

        writer.finishWriting {}
        while writer.status == .writing {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if writer.status == .failed {
            throw SessionRecorderError.writerFailed(writer.error?.localizedDescription ?? "Clip encode failed.")
        }
    }

    private func pump(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        writerInput: AVAssetWriterInput,
        writer: AVAssetWriter,
        shift: CMTime
    ) async throws {
        if reader.status == .unknown {
            reader.startReading()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.str8minds.ScrumTrace.clip")) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let shifted = CMTimeSubtract(pts, shift)
                        var timing = CMSampleTimingInfo(
                            duration: CMSampleBufferGetDuration(sample),
                            presentationTimeStamp: shifted,
                            decodeTimeStamp: .invalid
                        )
                        var copy: CMSampleBuffer?
                        CMSampleBufferCreateCopyWithNewTiming(
                            allocator: kCFAllocatorDefault,
                            sampleBuffer: sample,
                            sampleTimingEntryCount: 1,
                            sampleTimingArray: &timing,
                            sampleBufferOut: &copy
                        )
                        if let copy {
                            _ = writerInput.append(copy)
                        }
                    } else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    private func extractStill(source: URL, at media: TimeInterval, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: MediaBudget.stillMaxWidth, height: MediaBudget.stillMaxWidth)
        let time = CMTime(seconds: media, preferredTimescale: 600)
        let cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? SessionRecorderError.writerFailed("Still extract failed."))
                }
            }
        }
        #if os(macOS)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: MediaBudget.stillJPEGQuality]) else {
            throw SessionRecorderError.writerFailed("JPEG encode failed.")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: destination)
        #endif
    }
}
