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
        let stillRelative = relativeClip
            .replacingOccurrences(of: "/clip.mp4", with: "/shot-1.jpg")
        if updated.stills.isEmpty {
            updated.stills = [stillRelative]
        }
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
        let requested = min(
            MediaBudget.clipMaxDuration,
            max(MediaBudget.clipMinDuration, slice.endMedia - slice.startMedia)
        )
        let duration = CMTime(
            seconds: min(requested, max(0, mediaDuration - slice.startMedia)),
            preferredTimescale: 600
        )
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw SessionRecorderError.writerFailed("AVAssetExportSession unavailable.")
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(start: start, duration: duration)
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
        guard let jpeg = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: MediaBudget.stillJPEGQuality]
        ) else {
            throw SessionRecorderError.writerFailed("JPEG encode failed.")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try jpeg.write(to: destination)
        #endif
    }
}
