@preconcurrency import AVFoundation
import Foundation

/// Private working copies stay alive until the player or encoder is finished.
/// Both sources use the capture clock; the WAV is not assumed to start at zero.
struct SessionPlaybackMedia {
    let asset: AVAsset
    private let temporaryFiles: [URL]

    func cleanup() { temporaryFiles.forEach { ExportRel.removePrivateTemporaryURL($0) } }

    static func prepare(sessionURL: URL, privateMovie: URL? = nil) async throws -> SessionPlaybackMedia {
        var files: [URL] = []
        do {
            let movie: URL
            if let privateMovie { movie = privateMovie }
            else {
                movie = try ExportRel.copyContainedToTemporaryFile(relative: ScrumTracePath.sessionMovie, sessionURL: sessionURL, prefix: "scrumtrace-playback")
                files.append(movie)
            }
            let layout = CaptureAudioLayout.load(sessionURL: sessionURL)
            var microphone: URL?
            if layout.microphoneWav,
               ExportRel.existingSessionFile(ScrumTracePath.audioWav, sessionURL: sessionURL) != nil {
                microphone = try ExportRel.copyContainedToTemporaryFile(relative: ScrumTracePath.audioWav, sessionURL: sessionURL, prefix: "scrumtrace-playback-mic")
                files.append(microphone!)
            }
            let asset = try await compose(movie: movie, microphone: microphone, microphoneOffset: layout.wavStartMediaSeconds ?? 0)
            return SessionPlaybackMedia(asset: asset, temporaryFiles: files)
        } catch {
            files.forEach { ExportRel.removePrivateTemporaryURL($0) }
            throw error
        }
    }

    static func compose(movie: URL, microphone: URL?, microphoneOffset: Double) async throws -> AVAsset {
        let original = AVURLAsset(url: movie)
        guard let microphone else { return original }
        let composition = AVMutableComposition()
        let duration = try await original.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw SettingsValidationError("Recording has no playable duration.") }
        for type in [AVMediaType.video, .audio] {
            for track in try await original.loadTracks(withMediaType: type) {
                let range = try await track.load(.timeRange)
                guard let copied = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw SettingsValidationError("Could not prepare the recording for playback.")
                }
                try copied.insertTimeRange(range, of: track, at: range.start)
                if type == .video { copied.preferredTransform = try await track.load(.preferredTransform) }
            }
        }
        let wav = AVURLAsset(url: microphone)
        guard let track = try await wav.loadTracks(withMediaType: .audio).first else {
            throw SettingsValidationError("Microphone recording has no audio track.")
        }
        let range = try await track.load(.timeRange)
        let offset = microphoneOffset.isFinite ? max(0, microphoneOffset) : 0
        let available = min(range.duration.seconds, duration - offset)
        if available > 0,
           let copied = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try copied.insertTimeRange(CMTimeRange(start: range.start, duration: CMTime(seconds: available, preferredTimescale: 48_000)),
                                       of: track, at: CMTime(seconds: offset, preferredTimescale: 48_000))
        }
        return composition
    }

    static func audioMix(tracks: [AVAssetTrack]) -> AVAudioMix? {
        guard tracks.count > 1 else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1 / Float(tracks.count), at: .zero)
            return parameters
        }
        return mix
    }
}
