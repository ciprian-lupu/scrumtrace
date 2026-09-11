import AVFoundation
import Combine
import AppKit
import CoreMedia

enum DrawTool: String, CaseIterable {
    case rectangle
    case arrow
    case pen
}

struct AnnotationStroke {
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
/// abort and persist on the posting thread (C1).
final class ShotTalkState: ObservableObject {
    @Published var tool: DrawTool = .rectangle
    @Published var note = ""
    @Published var holdingTalk = false
    @Published var canTalk = true
    @Published var source: ShotSource = .typed
    @Published var talkError: String?
    @Published var isTranscribing = false
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
        if Thread.isMainThread {
            canTalk = allowed
            if !allowed {
                abortTalk()
            }
        } else {
            Task { @MainActor [weak self] in
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
        guard allowsNewCapture() else {
            AgentLog.event("talk_start_fail", ["reason": "paused"])
            return
        }
        let url: URL
        do {
            url = try ExportRel.makePrivateTemporaryURL(prefix: "scrumtrace-note", ext: "wav")
        } catch {
            talkError = "Could not start Hold-to-Talk."
            AgentLog.event("talk_start_fail", ["reason": "temp"])
            return
        }
        ExportRel.unlinkLastComponentUnfollowed(url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else {
            ExportRel.removePrivateTemporaryURL(url)
            talkError = "Could not start Hold-to-Talk."
            AgentLog.event("talk_start_fail", ["reason": "recorder"])
            return
        }
        // Bind the recorder before record() so Pause can abort in-flight (C1).
        recorder = rec
        guard rec.record() else {
            recorder = nil
            ExportRel.removePrivateTemporaryURL(url)
            talkError = "Could not start Hold-to-Talk."
            AgentLog.event("talk_start_fail", ["reason": "record"])
            return
        }
        holdingTalk = true
        talkError = nil
        AgentLog.event("talk_press", [
            "host": String(format: "%.3f", CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))
        ])
        if !allowsNewCapture() {
            abortTalk()
        }
    }

    func abortTalk() {
        let active = holdingTalk || recorder != nil
        holdingTalk = false
        recorder?.stop()
        if let url = recorder?.url {
            ExportRel.removePrivateTemporaryURL(url)
        }
        recorder = nil
        if active {
            AgentLog.event("talk_abort", [:])
        }
    }

    func stopTalk() async {
        guard holdingTalk else { return }
        AgentLog.event("talk_release", [
            "host": String(format: "%.3f", CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))
        ])
        let live = allowsNewCapture()
        holdingTalk = false
        recorder?.stop()
        let url = recorder?.url
        // Detach before transcribe so persist()/abortTalk cannot delete the WAV
        // while Whisper is reading it (C1: finish the pre-pause annotation).
        recorder = nil
        guard let url else {
            AgentLog.event("talk_transcribe_fail", ["reason": "no_url"])
            return
        }
        defer { ExportRel.removePrivateTemporaryURL(url) }
        // Pause after release is not a new capture. Still transcribe audio
        // recorded while the gate was open.
        if !live {
            AgentLog.event("talk_abort", ["reason": "paused_after_release"])
        }
        guard live else { return }
        isTranscribing = true
        defer { isTranscribing = false }
        AgentLog.event("talk_transcribe_begin", [:])
        do {
            try await transcriber.prepare(model: whisperModel)
            let text = try await transcriber.transcribeVoiceNote(at: url)
            guard !text.isEmpty else {
                talkError = "No speech detected"
                AgentLog.event("talk_transcribe_empty", [:])
                return
            }
            AgentLog.event("talk_transcribe_ok", ["chars": String(text.count)])
            let hadText = !note.isEmpty
            note = hadText ? "\(note) \(text)" : text
            source = hadText ? .mixed : .voice
            if saved {
                onSave(note, canvas.snapshot(), source)
            }
        } catch {
            talkError = error.localizedDescription
            AgentLog.event("talk_transcribe_fail", ["error": AgentLog.sanitize(error.localizedDescription)])
        }
    }
}

final class ShotNoteWindow: NSPanel, NSTextFieldDelegate {
    private let talk: ShotTalkState
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private let tools = NSSegmentedControl(
        labels: ["Box", "Arrow", "Pen"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let noteField = NSTextField()
    private let talkButton = HoldTalkButton()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(
        screenshot: NSImage,
        transcriber: WhisperTranscriber,
        whisperModel: String = WhisperTranscriber.defaultStoredModel,
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
        talk.canTalk = talk.allowsNewCapture()
        title = "ScrumTrace shot"
        isFloatingPanel = true
        level = .modalPanel
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildChrome()
        talk.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshChrome() }
            }
            .store(in: &cancellables)
        refreshChrome()
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
            ) { [weak self] _ in
                // Stop/Quit posts on MainActor. Copy the field so an uncommitted
                // note is in the catalog before persistInterruptedCapture (C1).
                if let self, Thread.isMainThread {
                    self.talk.note = self.noteField.stringValue
                }
                self?.talk.persist()
            }
        )
    }

    deinit {
        talk.abortTalk()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func show() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: screen.midX - 370, y: screen.midY - 270))
        orderFrontRegardless()
        AgentLog.event("shot_window_shown", [
            "app_active": NSApp.isActive ? "1" : "0",
            "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        ])
    }

    override func becomeKey() {
        super.becomeKey()
        AgentLog.event("shot_window_key", [
            "app_active": NSApp.isActive ? "1" : "0",
            "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        ])
    }

    /// Close finishes the pre-pause annotation (C1). Persist is idempotent.
    override func close() {
        talk.note = noteField.stringValue
        talk.persist()
        super.close()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func controlTextDidChange(_ obj: Notification) {
        talk.note = noteField.stringValue
        if talk.source == .voice {
            talk.source = .mixed
        }
    }

    private func buildChrome() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 540))
        contentView = root

        let titleLabel = NSTextField(labelWithString: "Shot note")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.refusesFirstResponder = true

        tools.selectedSegment = 0
        tools.target = self
        tools.action = #selector(toolChanged)
        tools.refusesFirstResponder = true
        tools.setContentHuggingPriority(.required, for: .horizontal)

        talk.canvas.translatesAutoresizingMaskIntoConstraints = false
        talk.canvas.wantsLayer = true
        talk.canvas.layer?.cornerRadius = 8
        talk.canvas.layer?.masksToBounds = true

        noteField.placeholderString = "What should an agent notice here?"
        noteField.translatesAutoresizingMaskIntoConstraints = false
        noteField.delegate = self
        noteField.maximumNumberOfLines = 4
        noteField.lineBreakMode = .byWordWrapping
        noteField.cell?.wraps = true
        noteField.cell?.isScrollable = false
        noteField.preferredMaxLayoutWidth = 700

        talkButton.refusesFirstResponder = true
        talkButton.onPress = { [weak self] in
            self?.talk.startTalk()
        }
        talkButton.onRelease = { [weak self] in
            guard let self else { return }
            Task { await self.talk.stopTalk() }
        }

        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        saveButton.refusesFirstResponder = true

        let headerSpace = NSView()
        headerSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpace.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        let header = NSStackView(views: [titleLabel, headerSpace, tools])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.distribution = .fill

        let footerSpace = NSView()
        footerSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpace.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        let footer = NSStackView(views: [talkButton, footerSpace, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(talk.canvas)
        root.addSubview(noteField)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            talk.canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            talk.canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            talk.canvas.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            talk.canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            noteField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            noteField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            noteField.topAnchor.constraint(equalTo: talk.canvas.bottomAnchor, constant: 10),
            noteField.heightAnchor.constraint(equalToConstant: 64),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.topAnchor.constraint(equalTo: noteField.bottomAnchor, constant: 10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
    }

    private func refreshChrome() {
        talk.canvas.tool = talk.tool
        talk.canvas.sourceImage = talk.screenshot
        talk.canvas.needsDisplay = true
        switch talk.tool {
        case .rectangle: tools.selectedSegment = 0
        case .arrow: tools.selectedSegment = 1
        case .pen: tools.selectedSegment = 2
        }
        talkButton.isEnabled = talk.canTalk && !talk.isTranscribing
        if talk.isTranscribing {
            talkButton.setLabel("Transcribing…")
        } else if talk.holdingTalk {
            talkButton.setLabel("Release to transcribe")
        } else if let talkError = talk.talkError, !talkError.isEmpty {
            if talkError == "Could not start Hold-to-Talk." {
                talkButton.setLabel("Hold to talk — start failed")
            } else {
                talkButton.setLabel("Hold to talk — transcribe failed")
            }
        } else if talk.canTalk {
            talkButton.setLabel("Hold to talk")
        } else {
            talkButton.setLabel("Hold to talk (paused)")
        }
        if noteField.currentEditor() == nil, noteField.stringValue != talk.note {
            noteField.stringValue = talk.note
        }
    }

    @objc private func toolChanged() {
        switch tools.selectedSegment {
        case 1: talk.tool = .arrow
        case 2: talk.tool = .pen
        default: talk.tool = .rectangle
        }
        talk.canvas.tool = talk.tool
        talk.canvas.needsDisplay = true
    }

    @objc private func saveClicked() {
        talk.note = noteField.stringValue
        talk.persist()
    }
}

private final class HoldTalkButton: NSButton {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setLabel("Hold to talk")
        refusesFirstResponder = true
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setLabel(_ text: String) {
        title = text
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
        onPress()
        while true {
            guard let next = window?.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }
            if next.type == .leftMouseUp { break }
        }
        isHighlighted = false
        onRelease()
    }
}
