import AppKit
import SwiftUI

enum TranscriptionReviewText {
    static func fullText(_ transcript: FullTranscript?) -> String {
        guard let transcript else { return "Result file is unavailable." }
        let timed = transcript.segments.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let untimed = transcript.untimedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [timed, untimed].filter { !$0.isEmpty }
        return parts.isEmpty ? "No recognized speech." : parts.joined(separator: "\n\n")
    }
}

/// Archive-only comparison inspection. It never starts an engine or sends a
/// request; the player is the existing private room/call playback component.
struct TranscriptionReviewView: View {
    @ObservedObject var controller: SessionController
    let sessionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [TranscriptionRun] = []
    @State private var selectedID = ""
    @State private var message = ""
    @StateObject private var preview = SpeakerPreviewModel()

    private var selectedRun: TranscriptionRun? { runs.first { $0.id == selectedID } }
    private var transcript: FullTranscript? {
        guard let selectedRun else { return nil }
        return TranscriptionRunStore.loadTranscript(id: selectedRun.id, sessionURL: controller.vault.sessionURL(id: sessionID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review transcription results").font(.title2)
                Spacer()
                Button("Keep current transcript") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Saved result", selection: $selectedID) {
                ForEach(runs) { run in
                    Text("\(run.configuration.name) · \(run.status.rawValue)").tag(run.id)
                }
            }
            if let run = selectedRun {
                let timed = transcript?.hasTimedSegments == true
                SpeakerVideoPlayer(player: preview.player).frame(height: 210)
                Text(preview.message).font(.caption).foregroundStyle(.secondary)
                Text("Profile: \(run.configuration.name) · requested: \(run.configuration.requestedModel) · resolved: \(run.resolvedModel ?? "not reported")")
                    .font(.caption).textSelection(.enabled)
                Text("Status: \(run.status.rawValue) · duration: \(Int(run.processingSeconds ?? 0))s · timestamps: \(timed ? "available" : "unavailable")")
                    .font(.caption).textSelection(.enabled)
                if let diagnostic = run.diagnostic, !diagnostic.isEmpty {
                    Text("Diagnostic: \(diagnostic)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Audio: \(run.inputs.map { "\($0.source) · \($0.transform) · \($0.bytes) bytes" }.joined(separator: "; "))")
                    .font(.caption).textSelection(.enabled)
                Text("Transcript").font(.headline)
                ScrollView { Text(TranscriptionReviewText.fullText(transcript)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.vertical, 4) }
                    .frame(minHeight: 190)
                HStack {
                    Button("Use selected transcript") {
                        guard let selectedRun else { return }
                        controller.selectPrimaryTranscription(sessionId: sessionID, runID: selectedRun.id)
                        if controller.lastError == nil { message = "Selected transcript is now primary. Run Retry Analysis to regenerate dependent outputs." }
                    }
                    .disabled(!timed || controller.isBusy)
                    Spacer()
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                ContentUnavailableView("No saved results", systemImage: "waveform", description: Text(message))
            }
        }
        .padding(20).frame(minWidth: 760, idealWidth: 820, minHeight: 620)
        .onAppear { reload() }
        .task { await preview.load(sessionURL: controller.vault.sessionURL(id: sessionID)) }
        .onDisappear { preview.stop() }
    }

    private func reload() {
        do {
            runs = try TranscriptionRunStore.load(sessionURL: controller.vault.sessionURL(id: sessionID))
            selectedID = runs.first?.id ?? ""
            message = runs.isEmpty ? "No comparisons have been saved for this session." : ""
        } catch { message = error.localizedDescription }
    }
}

@MainActor
final class TranscriptionReviewPresenter {
    private var window: NSWindow?

    func show(controller: SessionController, sessionID: String) {
        window?.close()
        let hosting = NSHostingController(rootView: TranscriptionReviewView(controller: controller, sessionID: sessionID))
        hosting.sizingOptions = []
        let created = NSWindow(contentViewController: hosting)
        created.title = "ScrumTrace — Transcription results"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.setContentSize(NSSize(width: 820, height: 690))
        created.contentMinSize = NSSize(width: 700, height: 560)
        created.isReleasedWhenClosed = false
        created.center()
        window = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }
}
