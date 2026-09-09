import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum DrawTool: String, CaseIterable {
    case rectangle
    case arrow
    case pen
}

struct AnnotationStroke: Identifiable {
    var id = UUID()
    var tool: DrawTool
    var points: [CGPoint]
}

final class AnnotationCanvas: NSView {
    var strokes: [AnnotationStroke] = []
    var current: AnnotationStroke?
    var tool: DrawTool = .rectangle
    var sourceImage: NSImage?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        sourceImage?.draw(in: bounds)
        NSColor(red: 0.89, green: 0.18, blue: 0.16, alpha: 0.95).setStroke()
        for stroke in strokes + [current].compactMap({ $0 }) {
            path(for: stroke).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        current = AnnotationStroke(tool: tool, points: [point])
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard var stroke = current else { return }
        if stroke.tool == .pen {
            stroke.points.append(point)
        } else if stroke.points.count == 1 {
            stroke.points.append(point)
        } else {
            stroke.points[1] = point
        }
        current = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let current {
            strokes.append(current)
        }
        current = nil
        needsDisplay = true
    }

    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(bounds)
        image.unlockFocus()
        return image
    }

    private func path(for stroke: AnnotationStroke) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        guard let first = stroke.points.first else { return path }
        switch stroke.tool {
        case .pen:
            path.move(to: first)
            for point in stroke.points.dropFirst() {
                path.line(to: point)
            }
        case .rectangle:
            let last = stroke.points.last ?? first
            path.appendRect(CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            ))
        case .arrow:
            let last = stroke.points.last ?? first
            path.move(to: first)
            path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head: CGFloat = 14
            path.move(to: last)
            path.line(to: CGPoint(x: last.x - head * cos(angle - .pi / 6), y: last.y - head * sin(angle - .pi / 6)))
            path.move(to: last)
            path.line(to: CGPoint(x: last.x - head * cos(angle + .pi / 6), y: last.y - head * sin(angle + .pi / 6)))
        }
        return path
    }
}

struct ShotNoteView: View {
    let screenshot: NSImage
    let transcriber: WhisperTranscriber
    var whisperModel: String = "large-v3-turbo"
    var allowsNewCapture: () -> Bool = { true }
    let onSave: (String, NSImage, ShotSource) -> Void

    @State private var tool: DrawTool = .rectangle
    @State private var note = ""
    @State private var holdingTalk = false
    @State private var canTalk = true
    @State private var recorder: AVAudioRecorder?
    @State private var source: ShotSource = .typed
    private let canvas = AnnotationCanvas()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Shot note")
                    .font(.headline)
                Spacer()
                Picker("Tool", selection: $tool) {
                    Text("Box").tag(DrawTool.rectangle)
                    Text("Arrow").tag(DrawTool.arrow)
                    Text("Pen").tag(DrawTool.pen)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            CanvasHost(canvas: canvas, screenshot: screenshot, tool: tool)
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            TextField("What should an agent notice here?", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack {
                Button(holdingTalk ? "Release to transcribe" : (canTalk ? "Hold to talk" : "Hold to talk (paused)")) {}
                    .disabled(!canTalk)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in startTalk() }
                            .onEnded { _ in Task { await stopTalk() } }
                    )
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 720, height: 520)
        .onAppear {
            canvas.sourceImage = screenshot
            canvas.tool = tool
            canTalk = allowsNewCapture()
        }
        .onChange(of: tool) { canvas.tool = tool }
        .onReceive(NotificationCenter.default.publisher(for: .scrumTraceCaptureGate)) { _ in
            canTalk = allowsNewCapture()
            if !canTalk {
                abortTalk()
            }
        }
    }

    private func startTalk() {
        guard !holdingTalk else { return }
        guard allowsNewCapture() else { return }
        holdingTalk = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scrumtrace-note.wav")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.record()
    }

    private func abortTalk() {
        guard holdingTalk else { return }
        holdingTalk = false
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
    }

    private func stopTalk() async {
        guard holdingTalk else { return }
        let live = allowsNewCapture()
        holdingTalk = false
        recorder?.stop()
        guard let url = recorder?.url else { return }
        defer {
            try? FileManager.default.removeItem(at: url)
            recorder = nil
        }
        guard live else { return }
        try? await transcriber.prepare(model: whisperModel)
        if let text = try? await transcriber.transcribeVoiceNote(at: url), !text.isEmpty {
            note = note.isEmpty ? text : "\(note) \(text)"
            source = note.isEmpty ? .voice : .mixed
        }
    }

    private func save() {
        let image = canvas.snapshot()
        let resolved: ShotSource
        if source == .voice && !note.isEmpty {
            resolved = .voice
        } else if source == .mixed {
            resolved = .mixed
        } else {
            resolved = .typed
        }
        onSave(note, image, resolved)
    }
}

struct CanvasHost: NSViewRepresentable {
    let canvas: AnnotationCanvas
    let screenshot: NSImage
    let tool: DrawTool

    func makeNSView(context: Context) -> AnnotationCanvas {
        canvas.sourceImage = screenshot
        canvas.tool = tool
        return canvas
    }

    func updateNSView(_ nsView: AnnotationCanvas, context: Context) {
        nsView.tool = tool
        nsView.sourceImage = screenshot
        nsView.needsDisplay = true
    }
}

final class ShotNoteWindow: NSPanel {
    private var hosting: NSHostingView<ShotNoteView>?

    init(
        screenshot: NSImage,
        transcriber: WhisperTranscriber,
        whisperModel: String = "large-v3-turbo",
        allowsNewCapture: @escaping () -> Bool = { true },
        onSave: @escaping (String, NSImage, ShotSource) -> Void
    ) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "ScrumTrace shot"
        isFloatingPanel = true
        level = .modalPanel
        hidesOnDeactivate = false
        let root = ShotNoteView(
            screenshot: screenshot,
            transcriber: transcriber,
            whisperModel: whisperModel,
            allowsNewCapture: allowsNewCapture,
            onSave: { [weak self] note, image, source in
                onSave(note, image, source)
                self?.orderOut(nil)
            }
        )
        let view = NSHostingView(rootView: root)
        contentView = view
        hosting = view
    }

    func show() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: screen.midX - 370, y: screen.midY - 270))
        orderFrontRegardless()
    }
}
