import SwiftUI
@preconcurrency import AVKit

/// What the speaker review reads from the vault. The sheet runs every read off the main actor; tests replace them.
struct SpeakerReviewLoader: Sendable {
    /// The picker's sessions: every manifest that decodes, newest first, at most 100. Async, so a reader that waits
    /// suspends instead of holding a thread.
    var recentSessions: @Sendable (SessionVault) async -> [SessionManifest]
    /// One session's manifest, or nil when it cannot be read.
    var manifest: @Sendable (SessionVault, String) -> SessionManifest?
    /// The saved transcript of one session folder.
    var transcript: @Sendable (URL) -> FullTranscript?

    static let live = SpeakerReviewLoader(
        recentSessions: { $0.recentSessions(limit: 100) },
        manifest: { vault, id in try? vault.loadManifest(id: id) },
        transcript: { SpeakerTimeline.load(sessionURL: $0) }
    )

    /// True when the picker would list a session: some manifest in the vault decodes. Folder names start with the
    /// date, so the newest folders are tried first and this usually decodes a single manifest. It reads files, so call
    /// it off the main actor.
    static func hasReviewableSession(in vault: SessionVault) -> Bool {
        vault.listedSessionIds().sorted(by: >).contains { (try? vault.loadManifest(id: $0)) != nil }
    }
}

struct SpeakerReviewView: View {
    @ObservedObject var controller: SessionController
    /// Selected when the sheet opens. Nil keeps the previous choice: the last session, else the newest.
    var initialSessionId: String? = nil
    var loader: SpeakerReviewLoader = .live
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionManifest] = []
    @State private var selected = ""
    @State private var transcript: FullTranscript?
    @State private var names: [String: String] = [:]
    @State private var assignments: [Int: String] = [:]
    @State private var message = ""
    @State private var confirmingReanalysis = false
    /// True until the picker's list has been read.
    @State private var isLoadingSessions = true
    /// The session whose transcript is being read, or nil.
    @State private var loadingTranscriptId: String?
    @StateObject private var preview = SpeakerPreviewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review speakers").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(controller.isBusy || changed)
            }
            Picker("Session", selection: $selected) {
                ForEach(sessions, id: \.sessionId) { session in Text(session.sessionId).tag(session.sessionId) }
            }
            .disabled(controller.isBusy || changed || isLoadingSessions)
            if let transcript = displayedTranscript {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        SpeakerVideoPlayer(player: preview.player).frame(height: 190)
                        Text(currentSpeaker(transcript)).font(.caption).frame(minHeight: 28, alignment: .leading)
                        if !preview.message.isEmpty { Text(preview.message).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Names for this session").font(.headline)
                        if (transcript.speakers ?? []).isEmpty {
                            Text("No speaker labels yet. Use Analyze speakers locally below to separate the voices, then name them here.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(transcript.speakers ?? []) { speaker in
                                        TextField(speaker.label, text: Binding(get: { names[speaker.id] ?? "" }, set: { names[speaker.id] = String($0.prefix(80)) }))
                                            .help(speaker.label)
                                    }
                                }
                            }.frame(maxHeight: 140)
                        }
                        Text("Estimates need review. Select a passage to listen; use its menu to correct the speaker. Room and call voices have separate numbering.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 260).disabled(controller.isBusy)
                }
                if let analysis = transcript.speakerAnalysis {
                    Text(analysis.map { "\($0.source): \($0.status.replacingOccurrences(of: "_", with: " "))" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                            turnRow(index: index, segment: segment, transcript: transcript)
                        }
                    }
                }.frame(minHeight: 180)
            } else if loadingTranscriptId != nil || (isLoadingSessions && selected.isEmpty) {
                ProgressView(loadingTranscriptId != nil ? "Loading transcript…" : "Loading recordings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No transcript yet", systemImage: "waveform", description: Text("Finish transcription with Retry Analysis, then reopen this session."))
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Analyze speakers locally…") { confirmingReanalysis = true }
                    .disabled(controller.isBusy || transcript == nil || changed)
                Spacer()
                if changed { Button("Discard edits") { resetEdits() }.disabled(controller.isBusy) }
                Button(controller.isBusy ? "Updating…" : "Save names and corrections") { update(reanalyze: false) }
                    .disabled(controller.isBusy || !changed)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20).frame(minWidth: 760, idealWidth: 800, minHeight: 650)
        .interactiveDismissDisabled(controller.isBusy || changed)
        .task { await loadSessions() }
        .task(id: selected) {
            await loadTranscript()
            guard !selected.isEmpty, !Task.isCancelled else { return }
            await preview.load(sessionURL: controller.vault.sessionURL(id: selected))
        }
        .onDisappear { preview.stop() }
        .alert("Analyze speakers again?", isPresented: $confirmingReanalysis) {
            Button("Analyze locally") { update(reanalyze: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This estimates speakers from the room and call audio and refreshes the local export with both audio sources. It replaces previous speaker names and corrections for successfully analyzed sources. The first run downloads public models; recording audio is not uploaded.")
        }
    }

    /// The sessions the picker lists and the one it opens on. `initialSessionId` is listed and selected
    /// when its manifest loads, even when it is older than the recent list. Without it, or when it cannot
    /// be listed, the choice is the previous one: the last session, else the newest.
    static func pickerSessions(
        recent: [SessionManifest],
        initialSessionId: String?,
        lastSessionId: String?,
        loadManifest: (String) -> SessionManifest?
    ) -> (sessions: [SessionManifest], selected: String) {
        var sessions = recent
        if let initialSessionId, !sessions.contains(where: { $0.sessionId == initialSessionId }),
           let older = loadManifest(initialSessionId) {
            sessions.append(older)
        }
        let selected = sessions.first(where: { $0.sessionId == initialSessionId })?.sessionId
            ?? sessions.first(where: { $0.sessionId == lastSessionId })?.sessionId
            ?? sessions.first?.sessionId ?? ""
        return (sessions, selected)
    }

    /// Reads the picker's list off the main actor. The session `initialSessionId` asks for is read on its own first
    /// and selected, so its transcript starts loading before every manifest in the vault has been decoded.
    private func loadSessions() async {
        let vault = controller.vault
        let loader = loader
        let requested = initialSessionId
        let lastSessionId = controller.lastSessionId
        var requestedManifest: SessionManifest?
        if let requested {
            requestedManifest = await Task.detached(priority: .userInitiated) { loader.manifest(vault, requested) }.value
            guard !Task.isCancelled else { return }
            if let requestedManifest {
                sessions = [requestedManifest]
                selected = requestedManifest.sessionId
            }
        }
        let recent = await Task.detached(priority: .utility) { await loader.recentSessions(vault) }.value
        guard !Task.isCancelled else { return }
        let known = requestedManifest
        let picker = Self.pickerSessions(
            recent: recent,
            initialSessionId: requested,
            lastSessionId: lastSessionId,
            loadManifest: { id in known?.sessionId == id ? known : nil }
        )
        sessions = picker.sessions
        // The requested session selected above stays selected, so its transcript is not read again.
        if !picker.sessions.contains(where: { $0.sessionId == selected }) {
            selected = picker.selected
        }
        isLoadingSessions = false
    }

    /// Reads the selected session's transcript off the main actor. Nothing of the previous session stays on screen
    /// meanwhile, and names and corrections change in the same main-actor step as the transcript, so an edit never
    /// lands on another session.
    private func loadTranscript() async {
        let id = selected
        preview.stop()
        transcript = nil
        names = [:]
        assignments = [:]
        guard !id.isEmpty else {
            loadingTranscriptId = nil
            return
        }
        loadingTranscriptId = id
        let url = controller.vault.sessionURL(id: id)
        let loader = loader
        let loaded = await Task.detached(priority: .userInitiated) { loader.transcript(url) }.value
        // A newer selection started its own read.
        guard !Task.isCancelled, selected == id else { return }
        show(loaded)
        loadingTranscriptId = nil
    }

    /// Shows `loaded` with the names it holds and no pending corrections.
    private func show(_ loaded: FullTranscript?) {
        transcript = loaded
        resetEdits()
    }

    /// Back to the names and speakers of the transcript on screen, which is the saved one.
    private func resetEdits() {
        names = (transcript?.speakers ?? []).reduce(into: [:]) { $0[$1.id] = $1.name ?? "" }
        assignments = [:]
    }

    private var displayedTranscript: FullTranscript? {
        guard let transcript else { return nil }
        let named = SpeakerTimeline.names(names, appliedTo: transcript)
        return (try? SpeakerTimeline.correcting(assignments, in: named)) ?? named
    }

    private var changed: Bool {
        !assignments.isEmpty || (transcript?.speakers ?? []).contains { (names[$0.id] ?? "") != ($0.name ?? "") }
    }

    private func currentSpeaker(_ transcript: FullTranscript) -> String {
        let active = transcript.segments.filter { $0.start <= preview.time && $0.end > preview.time }
        let labels = Set(active.map { SpeakerTimeline.displaySpeaker($0, in: SpeakerTimeline.names(names, appliedTo: transcript)) }).sorted()
        return labels.isEmpty ? "No attributed speech at this time" : labels.joined(separator: " / ")
    }

    private func turnRow(index: Int, segment: TranscriptSegment, transcript: FullTranscript) -> some View {
        HStack(alignment: .top) {
            Button {
                preview.seek(to: segment.start)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(String(format: "%.1f", segment.start))s–\(String(format: "%.1f", segment.end))s")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(SpeakerTimeline.displaySpeaker(segment, in: SpeakerTimeline.names(names, appliedTo: transcript)))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    // Older saved transcripts may contain decoder control tokens.
                    // Clean their presentation without rewriting the private archive.
                    Text(segment.text.replacingOccurrences(of: #"<\|[^<>]*\|>"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(segment.start <= preview.time && segment.end > preview.time ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(preview.player == nil)
            Menu(assignments[index] == nil ? "Correct" : "Edited") {
                Button("Speaker unclear") { assignments[index] = "unclear" }
                ForEach((transcript.speakers ?? []).filter { $0.source == SpeakerTimeline.source(of: segment) }) { speaker in
                    Button(names[speaker.id]?.isEmpty == false ? names[speaker.id]! : speaker.label) { assignments[index] = speaker.id }
                }
                if assignments[index] != nil { Button("Undo edit") { assignments[index] = nil } }
            }.frame(width: 85).disabled(controller.isBusy)
        }
    }

    private func update(reanalyze: Bool) {
        message = reanalyze ? "Analyzing locally; first use can take several minutes…" : "Saving and rebuilding the local export…"
        Task {
            do {
                // The controller returns the transcript it saved, so nothing is read again on the main actor.
                let saved = try await controller.updateSpeakers(sessionId: selected, names: reanalyze ? nil : names, assignments: reanalyze ? [:] : assignments, reanalyze: reanalyze)
                show(saved)
                let failed = transcript?.speakerAnalysis?.contains { $0.status == "failed" || $0.status == "source_unknown" } == true
                message = failed ? "Export updated, but some speaker analysis is unavailable. Review unclear passages or try analysis again." : "Saved locally. The transcript, brief and session pack are updated."
            } catch {
                message = "Could not finish updating the export: \(error.localizedDescription). Saved transcript changes, if any, can be recovered by reopening this session."
            }
        }
    }
}

/// Use the native player directly. The SwiftUI VideoPlayer bridge aborts while
/// resolving _AVKit_SwiftUI superclass metadata on the tested macOS 26.6 build.
struct SpeakerVideoPlayer: NSViewRepresentable {
    var player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

@MainActor
final class SpeakerPreviewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var time: Double = 0
    @Published var message = ""
    private var media: SessionPlaybackMedia?
    private var observer: Any?
    private var generation = UUID()

    func load(sessionURL: URL) async {
        stop()
        let request = generation
        message = "Preparing synchronized video, room and call audio…"
        do {
            let prepared = try await SessionPlaybackMedia.prepare(sessionURL: sessionURL)
            let item = AVPlayerItem(asset: prepared.asset)
            do { item.audioMix = SessionPlaybackMedia.audioMix(tracks: try await prepared.asset.loadTracks(withMediaType: .audio)) }
            catch { prepared.cleanup(); throw error }
            guard request == generation, !Task.isCancelled else { prepared.cleanup(); return }
            media = prepared
            let next = AVPlayer(playerItem: item)
            player = next
            observer = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in self?.time = time.seconds }
            }
            message = "Private recording · room + call audio"
        } catch { if request == generation { message = "Video playback is unavailable. You can still review the saved transcript." } }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
        time = seconds
    }

    func stop() {
        generation = UUID()
        if let observer { player?.removeTimeObserver(observer); self.observer = nil }
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        media?.cleanup(); media = nil; time = 0
    }
}
