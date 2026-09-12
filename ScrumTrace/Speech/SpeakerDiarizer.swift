@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Session-local anonymous clustering. Voice embeddings are never persisted,
/// enrolled under a person's name, or sent to an AI provider.
actor SpeakerDiarizer {
    static let shared = SpeakerDiarizer()
    private var models: OfflineDiarizerModels?
    private var preparation: Task<OfflineDiarizerModels, Error>?
    static var modelDirectory: URL {
        WhisperTranscriber.modelDownloadBase.deletingLastPathComponent().appendingPathComponent("speaker-models", isDirectory: true)
    }
    var isReady: Bool { models != nil }

    func prepare() async throws {
        guard #available(macOS 15, *) else {
            throw SettingsValidationError("Local speaker analysis requires macOS 15 or later.")
        }
        if models != nil { return }
        if let preparation { models = try await preparation.value; return }
        let work = Task.detached {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            return try await OfflineDiarizerModels.load(from: Self.modelDirectory, configuration: configuration)
        }
        preparation = work
        do {
            models = try await work.value
            preparation = nil
            AgentLog.event("speaker_models_ready", [:])
        } catch {
            preparation = nil
            AgentLog.event("speaker_models_failed", [:])
            throw error
        }
    }

    /// The caller provides a private temporary file. Returned data contains
    /// intervals and anonymous IDs only; SDK embeddings are discarded here.
    func intervals(audioURL: URL, offset: Double = 0) async throws -> [SpeakerInterval] {
        if (try? SpeechSignal.isDigitalSilence(audioURL)) == true { return [] }
        try await prepare()
        guard let models else { throw SettingsValidationError("Speaker models are not ready.") }
        let manager = OfflineDiarizerManager()
        manager.initialize(models: models)
        do {
            let result = try await manager.process(audioURL)
            return result.segments.map {
                SpeakerInterval(start: max(0, Double($0.startTimeSeconds) + offset),
                                end: max(0, Double($0.endTimeSeconds) + offset), speakerID: $0.speakerId)
            }
        } catch OfflineDiarizationError.noSpeechDetected { return [] }
    }

    func analyze(_ transcript: FullTranscript, sessionURL: URL) async -> FullTranscript {
        var output = transcript
        var analysis: [SpeakerAnalysis] = []
        let layout = CaptureAudioLayout.load(sessionURL: sessionURL)
        let sources = Set(transcript.sources ?? transcript.segments.compactMap { SpeakerTimeline.source(of: $0) })
        for source in ["room", "system"] where sources.contains(source) {
            do {
                let intervals = try await analyzeSource(source, layout: layout, sessionURL: sessionURL)
                output = SpeakerTimeline.assigning(output, intervals: intervals, source: source)
                analysis.append(SpeakerAnalysis(source: source, status: intervals.isEmpty ? "no_speech" : "estimated"))
                AgentLog.event("speaker_analysis_ok", ["source": source, "turns": String(intervals.count)])
            } catch {
                analysis.append(SpeakerAnalysis(source: source, status: "failed"))
                AgentLog.event("speaker_analysis_failed", ["source": source])
            }
        }
        output.speakerAnalysis = analysis.isEmpty ? [SpeakerAnalysis(source: "unknown", status: "source_unknown")] : analysis
        return output
    }

    private func analyzeSource(_ source: String, layout: CaptureAudioLayout, sessionURL: URL) async throws -> [SpeakerInterval] {
        let useWav = source == "room" || !layout.microphoneWav
        if useWav, ExportRel.existingSessionFile(ScrumTracePath.audioWav, sessionURL: sessionURL) != nil {
            let audio = try ExportRel.copyContainedToTemporaryFile(relative: ScrumTracePath.audioWav, sessionURL: sessionURL, prefix: "scrumtrace-speakers")
            defer { ExportRel.removePrivateTemporaryURL(audio) }
            return try await intervals(audioURL: audio, offset: layout.wavStartMediaSeconds ?? 0)
        }
        guard source == "system" else { throw SettingsValidationError("Room microphone audio is unavailable.") }
        let movie = try ExportRel.copyContainedToTemporaryFile(relative: ScrumTracePath.sessionMovie, sessionURL: sessionURL, prefix: "scrumtrace-speaker-movie")
        defer { ExportRel.removePrivateTemporaryURL(movie) }
        let audio = try ExportRel.makePrivateTemporaryURL(prefix: "scrumtrace-speaker-audio", ext: "m4a")
        defer { ExportRel.removePrivateTemporaryURL(audio) }
        let extractor = WhisperTranscriber()
        let offset = try await SpeechSignal.audioStart(movie)
        try await extractor.extractAudio(from: movie, to: audio)
        return try await intervals(audioURL: audio, offset: offset)
    }
}

enum SpeechSignal {
    /// Only digital silence is skipped. Quiet real speech is left to the model.
    static func isDigitalSilence(_ url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { return false }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else { return false }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = channels[channel][frame]
                    if !sample.isFinite || abs(sample) > 0.0000001 { return false }
                }
            }
        }
        return true
    }

    static func audioStart(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let time = try await track.load(.timeRange).start.seconds
        return time.isFinite ? max(0, time) : 0
    }

    static func shifted(_ transcript: FullTranscript, by offset: Double) -> FullTranscript {
        guard offset.isFinite, offset > 0 else { return transcript }
        var result = transcript
        result.segments = transcript.segments.map { segment in
            var next = segment
            next.start += offset; next.end += offset
            next.words = segment.words.map { TranscriptWord(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
            return next
        }
        return result
    }
}
