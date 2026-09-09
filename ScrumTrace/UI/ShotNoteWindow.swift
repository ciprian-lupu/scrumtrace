import AVFoundation
import Combine
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
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return sourceImage ?? NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
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

/// Note / Hold-to-Talk state lives on a class so Pause and Stop observers can
/// abort and persist on the posting thread (C1). SwiftUI `onReceive` can hop.
final class ShotTalkState: ObservableObject {
    @Published var tool: DrawTool = .rectangle
    @Published var note = ""
    @Published var holdingTalk = false
    @Published var canTalk = true
    @Published var source: ShotSource = .typed
    let canvas = AnnotationCanvas()
    let screenshot: NSImage
    let transcriber: WhisperTranscriber
    var whisperModel: String
    var allowsNewCapture: () -> Bool
    var onSave: (String, NSImage, ShotSource) -> Void
    var recorder: AVAudioRecorder?
    private var saved = false

    init(
        screenshot: NSImage,
        transcriber: WhisperTranscriber,
        whisperModel: String,
        allowsNewCapture: @escaping () -> Bool,
        onSave: @escaping (String, NSImage, ShotSource) -> Void
    ) {
        self.screenshot = screenshot
        self.transcriber = transcriber
        self.whisperModel = whisperModel
        self.allowsNewCapture = allowsNewCapture
        self.onSave = onSave
        canvas.sourceImage = screenshot
    }

    func applyCaptureGate(_ posted: CaptureSessionState? = nil) {
        // Privacy freeze posts from a background queue. Prefer the posted
        // gate so we do not read MainActor `phase` off-thread (C1).
        let allowed = posted?.allowsNewCapture ?? allowsNewCapture()
        if !allowed {
            abortTalk()
        }
        if Thread.isMainThread {
            canTalk = allowed
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.canTalk = allowed
                if !allowed {
                    self.abortTalk()
                }
            }
        }
    }

    func persist() {
        abortTalk()
        guard !saved else { return }
        saved = true
        let resolved: ShotSource
        if source == .voice && !note.isEmpty {
            resolved = .voice
        } else if source == .mixed {
            resolved = .mixed
        } else {
            resolved = .typed
        }
        onSave(note, canvas.snapshot(), resolved)
    }

    func startTalk() {
        guard !holdingTalk, recorder == nil else { return }
        guard allowsNewCapture() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scrumtrace-note-\(UUID().uuidString).wav"
        )
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        // Bind the recorder before record() so Pause can abort in-flight (C1).
        recorder = rec
        guard rec.record() else {
            recorder = nil
            try? FileManager.default.removeItem(at: url)
            return
        }
        holdingTalk = true
        if !allowsNewCapture() {
            abortTalk()
        }
    }

    func abortTalk() {
        holdingTalk = false
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
    }

    func stopTalk() async {
        guard holdingTalk else { return }
        let live = allowsNewCapture()
        holdingTalk = false
        recorder?.stop()
        guard let url = recorder?.url else { return }
        defer {
            try? FileManager.default.removeItem(at: url)
            recorder = nil
        }
        guard live, !saved else { return }
        try? await transcriber.prepare(model: whisperModel)
        guard allowsNewCapture(), !saved else { return }
        if let text = try? await transcriber.transcribeVoiceNote(at: url), !text.isEmpty {
            guard !saved else { return }
            let hadText = !note.isEmpty
            note = hadText ? "\(note) \(text)" : text
            source = hadText ? .mixed : .voice
        }
    }
}

struct ShotNoteView: View {
    @ObservedObject var session: ShotTalkState

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Shot note")
                    .font(.headline)
                Spacer()
                Picker("Tool", selection: $session.tool) {
                    Text("Box").tag(DrawTool.rectangle)
                    Text("Arrow").tag(DrawTool.arrow)
                    Text("Pen").tag(DrawTool.pen)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            CanvasHost(canvas: session.canvas, screenshot: session.screenshot, tool: session.tool)
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            TextField("What should an agent notice here?", text: $session.note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack {
                Button(session.holdingTalk ? "Release to transcribe" : (session.canTalk ? "Hold to talk" : "Hold to talk (paused)")) {}
                    .disabled(!session.canTalk)
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
            session.canvas.sourceImage = session.screenshot
            session.canvas.tool = session.tool
            session.canTalk = session.allowsNewCapture()
        }
        .onChange(of: session.tool) { _, newValue in
            session.canvas.tool = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrumTraceCaptureGate)) { notification in
            session.applyCaptureGate(notification.object as? CaptureSessionState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrumTraceSessionEnding)) { _ in
            session.persist()
        }
        .onDisappear {
            abortTalk()
        }
    }

    private func startTalk() {
        session.startTalk()
    }

    private func abortTalk() {
        session.abortTalk()
    }

    private func stopTalk() async {
        await session.stopTalk()
    }

    private func save() {
        session.persist()
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
    private let talk: ShotTalkState
    private var observers: [NSObjectProtocol] = []

    init(
        screenshot: NSImage,
        transcriber: WhisperTranscriber,
        whisperModel: String = "large-v3-turbo",
        allowsNewCapture: @escaping () -> Bool = { true },
        onSave: @escaping (String, NSImage, ShotSource) -> Void
    ) {
        let talk = ShotTalkState(
            screenshot: screenshot,
            transcriber: transcriber,
            whisperModel: whisperModel,
            allowsNewCapture: allowsNewCapture,
            onSave: { _, _, _ in }
        )
        self.talk = talk
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        talk.onSave = { [weak self] note, image, source in
            onSave(note, image, source)
            self?.orderOut(nil)
        }
        title = "ScrumTrace shot"
        isFloatingPanel = true
        level = .modalPanel
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = ShotNoteView(session: talk)
        let view = NSHostingView(rootView: root)
        contentView = view
        hosting = view
        // queue: nil — run on the posting thread so Stop/Quit persist the
        // annotation before persistInterruptedCapture (C1).
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .scrumTraceCaptureGate,
                object: nil,
                queue: nil
            ) { [weak talk] notification in
                talk?.applyCaptureGate(notification.object as? CaptureSessionState)
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .scrumTraceSessionEnding,
                object: nil,
                queue: nil
            ) { [weak talk] _ in
                talk?.persist()
            }
        )
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func show() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: screen.midX - 370, y: screen.midY - 270))
        orderFrontRegardless()
    }

    /// Close finishes the pre-pause annotation (C1). Persist is idempotent.
    override func close() {
        talk.persist()
        super.close()
    }

    override var canBecomeMain: Bool { false }
}
