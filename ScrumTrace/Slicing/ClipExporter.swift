#if os(macOS)
import AppKit
#endif
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct ClipExporter {
    func export(
        sessionURL: URL,
        slice: SliceRecord,
        mediaDuration: TimeInterval
    ) async throws -> SliceRecord {
        let source = sessionURL.appendingPathComponent(ScrumTracePath.sessionMovie)
        guard ExportRel.existingSessionFile(ScrumTracePath.sessionMovie, sessionURL: sessionURL) != nil else {
            throw SessionRecorderError.writerFailed("session.mp4 is missing.")
        }
        guard let relativeClip = slice.clipPath else {
            throw SessionRecorderError.writerFailed("Slice is missing clip_path.")
        }
        guard let parts = ExportRel.normalizedComponents(relativeClip) else {
            throw SessionRecorderError.writerFailed("Slice clip_path escaped the session folder.")
        }
        let containedClip = parts.joined(separator: "/")
        guard ExportRel.isAllowedClipDest(containedClip) else {
            throw SessionRecorderError.writerFailed("Slice clip_path is not a working or export clip.")
        }
        let prepared: String
        do {
            prepared = try ExportRel.prepareContainedWrite(relative: containedClip, sessionURL: sessionURL)
        } catch {
            throw SessionRecorderError.writerFailed("Slice clip_path escaped the session folder.")
        }
        let clipURL = sessionURL.appendingPathComponent(prepared)
        try await reencode(source: source, destination: clipURL, slice: slice, mediaDuration: mediaDuration)

        var updated = slice
        updated.clipPath = prepared
        guard prepared.hasSuffix("/clip.mp4") else {
            return updated
        }
        let stillRelative = containedClip.replacingOccurrences(of: "/clip.mp4", with: "/shot-1.jpg")
        guard stillRelative != containedClip else {
            return updated
        }
        do {
            let jpeg = try await extractStill(source: source, at: (slice.startMedia + slice.endMedia) / 2)
            try ExportRel.writeContainedData(jpeg, relative: stillRelative, sessionURL: sessionURL)
            if !updated.stills.contains(stillRelative) {
                updated.stills.insert(stillRelative, at: 0)
            }
        } catch {
            // Shot stills on the slice remain; do not fail the whole session for one frame grab.
        }
        return updated
    }

    /// Spec C3: if the measured pack is over 35 MB, encode harder before omitting.
    func tightenExportClips(sessionURL: URL) async {
        let exportDir = sessionURL.appendingPathComponent(ScrumTracePath.export)
        let media = sessionURL.appendingPathComponent(ScrumTracePath.media)
        guard let enumerator = FileManager.default.enumerator(
            at: media,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "mp4" else { continue }
            guard ExportRel.containedExportMember(file: url, exportDir: exportDir) != nil else { continue }
            files.append(url)
        }
        files.sort { lhs, rhs in
            let left = (try? FileManager.default.attributesOfItem(atPath: lhs.path)[.size] as? NSNumber)?.intValue ?? 0
            let right = (try? FileManager.default.attributesOfItem(atPath: rhs.path)[.size] as? NSNumber)?.intValue ?? 0
            return left > right
        }
        // Leave the smallest clip at H.264 Main 720p so Gate 4 still has a
        // Chrome-playable sample. Larger clips are the ones worth shrinking.
        for url in files.dropLast() {
            try? await tighten(file: url)
        }
    }

    /// Working clips live under `archive/media-work/`. Tighten rewrites
    /// `export/media/` only. Never overwrite `archive/session.mp4`.
    private func tighten(file url: URL) async throws {
        let presets = [AVAssetExportPreset640x480, AVAssetExportPresetLowQuality]
        for preset in presets {
            let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            let temp = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).mp4")
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.outputURL = temp
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            let duration = (try? await asset.load(.duration)) ?? .invalid
            session.fileLengthLimit = Int64(
                Double(MediaBudget.clipVideoBitrate / 4) / 8.0 * max(CMTimeGetSeconds(duration), 1)
            )
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: temp)
                continue
            }
            let after = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.intValue ?? before
            if after < before {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
                return
            }
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func reencode(
        source: URL,
        destination: URL,
        slice: SliceRecord,
        mediaDuration: TimeInterval
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        let range = try clipTimeRange(slice: slice, mediaDuration: mediaDuration)
        let asset = AVURLAsset(url: source)
        do {
            try await writeMainProfileClip(asset: asset, destination: destination, timeRange: range)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try await exportPresetClip(asset: asset, destination: destination, timeRange: range)
        }
    }

    private func clipTimeRange(slice: SliceRecord, mediaDuration: TimeInterval) throws -> CMTimeRange {
        let start = CMTime(seconds: max(0, slice.startMedia), preferredTimescale: 600)
        let requested = min(
            MediaBudget.clipMaxDuration,
            max(MediaBudget.clipMinDuration, slice.endMedia - slice.startMedia)
        )
        let duration = CMTime(
            seconds: min(requested, max(0, mediaDuration - slice.startMedia)),
            preferredTimescale: 600
        )
        guard CMTimeGetSeconds(duration) > 0.05 else {
            throw SessionRecorderError.writerFailed("Clip time range is empty.")
        }
        return CMTimeRange(start: start, duration: duration)
    }

    /// Spec encode target: H.264 Main, 720p, 1.2 Mbps + 96 kbps AAC.
    /// `tracks(withMediaType:)` is empty until loaded on macOS 14 — always `loadTracks`.
    private func writeMainProfileClip(
        asset: AVURLAsset,
        destination: URL,
        timeRange: CMTimeRange
    ) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw SessionRecorderError.writerFailed("session.mp4 has no video track.")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let assetDuration = try await asset.load(.duration)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
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
        guard writer.canAdd(videoInput) else {
            throw SessionRecorderError.writerFailed("Clip writer rejected video.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioTracks.first != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: MediaBudget.clipAudioBitrate
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: MediaBudget.clipWidth, height: MediaBudget.clipHeight)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        let coverDuration = assetDuration.flags.contains(.valid) && CMTimeGetSeconds(assetDuration) > 0
            ? assetDuration
            : CMTimeAdd(timeRange.start, timeRange.duration)
        instruction.timeRange = CMTimeRange(start: .zero, duration: coverDuration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(
            Self.fitTransform(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                render: composition.renderSize
            ),
            at: .zero
        )
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = composition
        guard reader.canAdd(videoOutput) else {
            throw SessionRecorderError.writerFailed("Clip reader rejected video.")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first, audioInput != nil {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            )
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        guard writer.startWriting() else {
            writer.cancelWriting()
            throw SessionRecorderError.writerFailed(
                writer.error?.localizedDescription ?? "Clip writer failed to start."
            )
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw SessionRecorderError.writerFailed(
                reader.error?.localizedDescription ?? "Clip reader failed to start."
            )
        }
        writer.startSession(atSourceTime: timeRange.start)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ClipResumeOnce()
            let state = ClipCopyState()
            let queue = DispatchQueue(label: "com.str8minds.ScrumTrace.clip")
            let group = DispatchGroup()

            func fail(_ error: Error) {
                // Do not cancelWriting or resume from requestMediaDataWhenReady —
                // that can deadlock AVAssetWriter. Finish in group.notify.
                state.setError(error)
                reader.cancelReading()
            }

            func copySamples(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
                group.enter()
                var left = false
                func leaveOnce() {
                    guard !left else { return }
                    left = true
                    input.markAsFinished()
                    group.leave()
                }
                input.requestMediaDataWhenReady(on: queue) {
                    if state.peekError() != nil {
                        leaveOnce()
                        return
                    }
                    while input.isReadyForMoreMediaData {
                        if reader.status == .failed {
                            fail(
                                reader.error
                                    ?? SessionRecorderError.writerFailed("Clip reader failed while copying.")
                            )
                            leaveOnce()
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            leaveOnce()
                            return
                        }
                        if !input.append(sample) {
                            fail(
                                writer.error
                                    ?? SessionRecorderError.writerFailed("Clip writer rejected a sample.")
                            )
                            leaveOnce()
                            return
                        }
                    }
                }
            }

            copySamples(output: videoOutput, input: videoInput)
            if let audioInput, let audioOutput {
                copySamples(output: audioOutput, input: audioInput)
            }

            group.notify(queue: queue) {
                guard !once.hasResumed else { return }
                if let error = state.peekError() {
                    writer.cancelWriting()
                    once.resumeThrowing(continuation, error)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        once.resume(continuation)
                    } else {
                        once.resumeThrowing(
                            continuation,
                            writer.error
                                ?? SessionRecorderError.writerFailed("Clip finish failed.")
                        )
                    }
                }
            }
        }
    }

    private func exportPresetClip(asset: AVURLAsset, destination: URL, timeRange: CMTimeRange) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw SessionRecorderError.writerFailed("AVAssetExportSession unavailable.")
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = timeRange
        let seconds = max(CMTimeGetSeconds(timeRange.duration), 1)
        let bytesPerSecond = Double(MediaBudget.clipVideoBitrate + MediaBudget.clipAudioBitrate) / 8.0
        session.fileLengthLimit = Int64(bytesPerSecond * seconds * 1.25)
        // macOS 14: exportAsynchronously. Do not call the later export-to-as API.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        if session.status != .completed {
            throw SessionRecorderError.writerFailed(session.error?.localizedDescription ?? "Clip export failed.")
        }
    }

    private static func fitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        render: CGSize
    ) -> CGAffineTransform {
        let mapped = naturalSize.applying(preferredTransform)
        let src = CGSize(width: abs(mapped.width), height: abs(mapped.height))
        let scale = min(render.width / max(src.width, 1), render.height / max(src.height, 1))
        let tx = (render.width - src.width * scale) / 2
        let ty = (render.height - src.height * scale) / 2
        return preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    private func extractStill(source: URL, at media: TimeInterval) async throws -> Data {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: MediaBudget.stillMaxWidth, height: MediaBudget.stillMaxWidth)
        let time = CMTime(seconds: media, preferredTimescale: 600)
        // macOS 13+: async image(at:). Do not use the cancelled CGImage copy API.
        let cgImage = try await generator.image(at: time).image
        #if os(macOS)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: MediaBudget.stillJPEGQuality]
        ) else {
            throw SessionRecorderError.writerFailed("JPEG encode failed.")
        }
        return jpeg
        #else
        throw SessionRecorderError.writerFailed("JPEG encode requires macOS.")
        #endif
    }
}

/// Clip reader/writer callbacks must not resume the continuation twice.
private final class ClipResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    var hasResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    func resume(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume()
    }

    func resumeThrowing(_ continuation: CheckedContinuation<Void, Error>, _ error: Error) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

/// Shared error from clip copy callbacks; consumed only after both inputs leave.
private final class ClipCopyState: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func setError(_ error: Error) {
        lock.lock()
        if self.error == nil {
            self.error = error
        }
        lock.unlock()
    }

    func peekError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
