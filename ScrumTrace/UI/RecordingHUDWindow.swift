import AppKit
import Combine

/// Pure frame math for the recording HUD so it can be tested without a window.
enum RecordingHUDLayout {
    /// Expanded chrome at scale 1: clock, wall clock, Shot / Pin / Pause / Stop.
    static let baseSize = NSSize(width: 720, height: 52)
    static let minScale: CGFloat = 0.6
    static let maxScale: CGFloat = 2.0
    /// Distance from the top of the screen's visible frame on first show.
    static let topInset: CGFloat = 18
    /// How much of the HUD must stay on a screen for a saved frame to be reused.
    static let minimumVisibleEdge: CGFloat = 40

    static let frameKey = "scrumtrace.hud.frame"

    static func scale(forHeight height: CGFloat) -> CGFloat {
        min(max(height / baseSize.height, minScale), maxScale)
    }

    static func minSize() -> NSSize {
        NSSize(width: baseSize.width * minScale, height: baseSize.height * minScale)
    }

    static func maxSize() -> NSSize {
        NSSize(width: baseSize.width * maxScale, height: baseSize.height * maxScale)
    }

    /// Top-centre of the given visible frame.
    static func defaultFrame(on visibleFrame: NSRect, size: NSSize = baseSize) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - topInset,
            width: size.width,
            height: size.height
        )
    }

    /// A saved frame is reused only when a usable part of it is still on some screen.
    static func restoredFrame(saved: NSRect?, screens: [NSRect]) -> NSRect? {
        guard let saved, saved.width > 0, saved.height > 0 else { return nil }
        let scale = scale(forHeight: saved.height)
        let size = NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
        let candidate = NSRect(origin: saved.origin, size: size)
        for screen in screens {
            let visible = candidate.intersection(screen)
            let neededHeight = min(minimumVisibleEdge, size.height) - 0.5
            if visible.width >= minimumVisibleEdge, visible.height >= neededHeight {
                return candidate
            }
        }
        return nil
    }

    /// The minified pill keeps the expanded frame's top edge and horizontal centre.
    static func minifiedFrame(expanded: NSRect, width: CGFloat) -> NSRect {
        NSRect(
            x: expanded.midX - width / 2,
            y: expanded.maxY - expanded.height,
            width: width,
            height: expanded.height
        )
    }

    /// The expanded frame that a moved minified pill stands for.
    static func expandedFrame(minified: NSRect, scale: CGFloat) -> NSRect {
        let size = NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
        return NSRect(
            x: minified.midX - size.width / 2,
            y: minified.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func encode(_ frame: NSRect) -> String { NSStringFromRect(frame) }

    static func decode(_ text: String?) -> NSRect? {
        guard let text, !text.isEmpty else { return nil }
        let rect = NSRectFromString(text)
        return rect.isEmpty ? nil : rect
    }
}

/// Menu-bar companion HUD. AppKit controls that refuse first responder
/// so a click does not activate ScrumTrace and steal Keynote (Gate 0).
///
/// The panel can be dragged by its background, resized from its edges (the
/// whole pill scales, aspect locked), and minified to dot + clock with the
/// chevron or a double-click. Its frame is remembered across recordings; each
/// recording starts expanded so Stop is always one click away.
/// It is excluded from screen sharing and display capture, so people on a
/// call see the demo but never the pill.
final class RecordingHUDWindow: NSPanel {
    private let controller: SessionController
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private let visual = HUDBackdrop()
    private let stack = NSStackView()
    private let dot = HUDPulseDot()
    private let mediaLabel = HUDLabel(size: 13, weight: .semibold, alpha: 1)
    private let wallLabel = HUDLabel(size: 9, weight: .medium, alpha: 0.45)
    private let statusLabel = HUDLabel(size: 11, weight: .medium, alpha: 0.9, compressible: true)
    private let divider = NSBox()
    private let shotButton = HUDTextButton(title: "Shot")
    private let pinButton = HUDTextButton(title: "Pin")
    private let pauseButton = HUDTextButton(title: "Pause")
    private let stopButton = HUDTextButton(title: "Stop")
    private let minifyButton = HUDSymbolButton(symbol: "chevron.left", help: "Minify")
    private let expandButton = HUDSymbolButton(symbol: "chevron.right", help: "Expand")
    private var dividerHeight: NSLayoutConstraint?

    private(set) var isMinified = false
    private(set) var scale: CGFloat = 1
    /// Frame of the expanded pill; kept while minified so Expand goes back to it.
    private var expandedFrame: NSRect
    private var isApplyingFrame = false

    init(controller: SessionController, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
        self.expandedFrame = NSRect(origin: .zero, size: RecordingHUDLayout.baseSize)
        super.init(
            contentRect: NSRect(origin: .zero, size: RecordingHUDLayout.baseSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        // Invisible to screen sharing (Meet, Teams, Zoom) and to any display capture.
        sharingType = .none
        isMovableByWindowBackground = false
        minSize = RecordingHUDLayout.minSize()
        maxSize = RecordingHUDLayout.maxSize()
        aspectRatio = RecordingHUDLayout.baseSize
        buildChrome()
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange(_:)), name: NSWindow.didResizeNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange(_:)), name: NSWindow.didMoveNotification, object: self
        )
        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        refresh()
        orderOut(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            if !isVisible {
                // A new recording: remembered place and size, always expanded.
                isMinified = false
                restoreFrame()
            }
            refresh()
            orderFrontRegardless()
        } else {
            orderOut(nil)
        }
    }

    func refresh() {
        let gatePaused = controller.captureState == .paused
        let isLiveRecording = controller.phase == .recording && !gatePaused
        dot.setLive(isLiveRecording)
        if controller.isBusy {
            dot.setBusy()
        } else if gatePaused {
            dot.setPaused()
        } else {
            dot.setRecording()
        }
        mediaLabel.stringValue = SessionController.clock(controller.mediaElapsed)
        wallLabel.stringValue = "w \(SessionController.clock(controller.wallElapsed))"
        let busy = controller.isBusy
        let starting = controller.startInFlight
        if starting {
            dot.setBusy()
        }
        statusLabel.stringValue = controller.statusLine
        statusLabel.toolTip = controller.statusLine
        let controls = !busy && !starting && !isMinified
        statusLabel.isHidden = (!busy && !starting) || isMinified
        wallLabel.isHidden = isMinified
        divider.isHidden = isMinified
        shotButton.isHidden = !controls
        pinButton.isHidden = !controls
        pauseButton.isHidden = !controls
        stopButton.isHidden = !controls
        minifyButton.isHidden = isMinified
        expandButton.isHidden = !isMinified
        shotButton.isEnabled = controller.captureState.allowsNewCapture
        pinButton.isEnabled = controller.captureState.allowsNewCapture
        pauseButton.setLabel(gatePaused ? "Resume" : "Pause")
        pauseButton.isEnabled = !gatePaused || controller.canResumeFromPause
        stopButton.isEnabled = true
        if isMinified {
            fitMinifiedWidth()
        }
    }

    // MARK: Minify / expand

    func setMinified(_ minified: Bool) {
        guard minified != isMinified else { return }
        isMinified = minified
        if minified {
            expandedFrame = frame
            styleMask.remove(.resizable)
            resizeIncrements = NSSize(width: 1, height: 1)
            minSize = NSSize(width: 1, height: 1)
            refresh()
        } else {
            styleMask.insert(.resizable)
            minSize = RecordingHUDLayout.minSize()
            maxSize = RecordingHUDLayout.maxSize()
            aspectRatio = RecordingHUDLayout.baseSize
            refresh()
            let target = RecordingHUDLayout.expandedFrame(minified: frame, scale: scale)
            applyFrame(target)
            expandedFrame = target
            persistFrame()
        }
    }

    private func fitMinifiedWidth() {
        stack.layoutSubtreeIfNeeded()
        let width = ceil(stack.fittingSize.width)
        let target = RecordingHUDLayout.minifiedFrame(expanded: frame, width: width)
        if abs(target.width - frame.width) > 0.5 || abs(target.minX - frame.minX) > 0.5 {
            applyFrame(target)
        }
    }

    private func applyFrame(_ target: NSRect) {
        isApplyingFrame = true
        setFrame(target, display: true)
        isApplyingFrame = false
    }

    // MARK: Frame memory

    private func restoreFrame() {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let saved = RecordingHUDLayout.decode(defaults.string(forKey: RecordingHUDLayout.frameKey))
        let target: NSRect
        if let restored = RecordingHUDLayout.restoredFrame(saved: saved, screens: screens) {
            target = restored
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: RecordingHUDLayout.baseSize)
            target = RecordingHUDLayout.defaultFrame(on: visible)
        }
        styleMask.insert(.resizable)
        minSize = RecordingHUDLayout.minSize()
        maxSize = RecordingHUDLayout.maxSize()
        aspectRatio = RecordingHUDLayout.baseSize
        applyFrame(target)
        expandedFrame = target
        applyScale(RecordingHUDLayout.scale(forHeight: target.height))
    }

    private func persistFrame() {
        defaults.set(RecordingHUDLayout.encode(expandedFrame), forKey: RecordingHUDLayout.frameKey)
    }

    @objc private func frameDidChange(_ note: Notification) {
        guard !isApplyingFrame else { return }
        if isMinified {
            expandedFrame = RecordingHUDLayout.expandedFrame(minified: frame, scale: scale)
        } else {
            expandedFrame = frame
            let next = RecordingHUDLayout.scale(forHeight: frame.height)
            if abs(next - scale) > 0.001 {
                applyScale(next)
            }
        }
        persistFrame()
    }

    // MARK: Scale

    private func applyScale(_ next: CGFloat) {
        scale = next
        mediaLabel.apply(scale: next)
        wallLabel.apply(scale: next)
        statusLabel.apply(scale: next)
        shotButton.apply(scale: next)
        pinButton.apply(scale: next)
        pauseButton.apply(scale: next)
        stopButton.apply(scale: next)
        minifyButton.apply(scale: next)
        expandButton.apply(scale: next)
        dot.apply(scale: next)
        dividerHeight?.constant = 16 * next
        stack.spacing = 10 * next
        stack.edgeInsets = NSEdgeInsets(top: 8 * next, left: 14 * next, bottom: 8 * next, right: 14 * next)
        visual.layer?.cornerRadius = 22 * next
    }

    // MARK: Chrome

    private func buildChrome() {
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 22
        visual.layer?.masksToBounds = true
        visual.layer?.borderWidth = 1
        visual.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        visual.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        let height = divider.heightAnchor.constraint(equalToConstant: 16)
        height.isActive = true
        dividerHeight = height
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        shotButton.target = self
        shotButton.action = #selector(shotClicked)
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        minifyButton.target = self
        minifyButton.action = #selector(minifyClicked)
        expandButton.target = self
        expandButton.action = #selector(expandClicked)

        stack.addArrangedSubview(dot)
        stack.addArrangedSubview(mediaLabel)
        stack.addArrangedSubview(wallLabel)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(shotButton)
        stack.addArrangedSubview(pinButton)
        stack.addArrangedSubview(pauseButton)
        stack.addArrangedSubview(stopButton)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(minifyButton)
        stack.addArrangedSubview(expandButton)

        let root = HUDRootView()
        root.onDoubleClick = { [weak self] in
            guard let self else { return }
            AgentLog.event(self.isMinified ? "hud_expand" : "hud_minify", ["via": "double_click"])
            self.setMinified(!self.isMinified)
        }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(visual)
        visual.addSubview(stack)
        contentView = root
        NSLayoutConstraint.activate([
            visual.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            visual.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            visual.topAnchor.constraint(equalTo: root.topAnchor),
            visual.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: visual.trailingAnchor),
            stack.topAnchor.constraint(equalTo: visual.topAnchor),
            stack.bottomAnchor.constraint(equalTo: visual.bottomAnchor)
        ])
    }

    @objc private func shotClicked() {
        AgentLog.event("hud_shot", [:])
        controller.openShot()
    }

    @objc private func pinClicked() {
        AgentLog.event("hud_pin", [:])
        controller.pin()
    }

    @objc private func pauseClicked() {
        AgentLog.event("hud_pause", [:])
        controller.togglePause()
    }

    @objc private func stopClicked() {
        AgentLog.event("hud_stop", [:])
        controller.stopRecording()
    }

    @objc private func minifyClicked() {
        AgentLog.event("hud_minify", ["via": "button"])
        setMinified(true)
    }

    @objc private func expandClicked() {
        AgentLog.event("hud_expand", ["via": "button"])
        setMinified(false)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Content view: a press on the pill background drags the panel, a double-click
/// toggles minified. Never a first responder, so Keynote keeps focus.
private final class HUDRootView: NSView {
    var onDoubleClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.performDrag(with: event)
    }
}

/// Backdrop that lets presses fall through to the root view.
private final class HUDBackdrop: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }
}

private final class HUDLabel: NSTextField {
    private let baseSize: CGFloat
    private let weight: NSFont.Weight

    init(size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, compressible: Bool = false) {
        self.baseSize = size
        self.weight = weight
        super.init(frame: .zero)
        isBezeled = false
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        refusesFirstResponder = true
        focusRingType = .none
        font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        textColor = NSColor(red: 0.97, green: 0.93, blue: 0.86, alpha: alpha)
        setContentHuggingPriority(.required, for: .horizontal)
        if compressible {
            lineBreakMode = .byTruncatingTail
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            setContentCompressionResistancePriority(.required, for: .horizontal)
        }
    }

    /// Labels are not interactive: presses go to the pill background.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(scale: CGFloat) {
        font = NSFont.monospacedDigitSystemFont(ofSize: baseSize * scale, weight: weight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class HUDTextButton: NSButton {
    private let ink = NSColor(red: 0.97, green: 0.93, blue: 0.86, alpha: 0.9)
    private var label = ""
    private var scale: CGFloat = 1

    init(title: String) {
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        setButtonType(.momentaryChange)
        setLabel(title)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setLabel(_ text: String) {
        label = text
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11 * scale, weight: .semibold),
                .foregroundColor: ink
            ]
        )
    }

    func apply(scale: CGFloat) {
        self.scale = scale
        setLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class HUDSymbolButton: NSButton {
    private let symbol: String

    init(symbol: String, help: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        setButtonType(.momentaryChange)
        title = ""
        toolTip = help
        imagePosition = .imageOnly
        contentTintColor = NSColor(red: 0.97, green: 0.93, blue: 0.86, alpha: 0.7)
        apply(scale: 1)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(scale: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11 * scale, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class HUDPulseDot: NSView {
    private let pulse = CABasicAnimation(keyPath: "opacity")
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerRadius = 4.5
        layer?.backgroundColor = NSColor(red: 0.89, green: 0.23, blue: 0.18, alpha: 1).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let width = widthAnchor.constraint(equalToConstant: 9)
        let height = heightAnchor.constraint(equalToConstant: 9)
        NSLayoutConstraint.activate([width, height])
        widthConstraint = width
        heightConstraint = height
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(scale: CGFloat) {
        widthConstraint?.constant = 9 * scale
        heightConstraint?.constant = 9 * scale
        layer?.cornerRadius = 4.5 * scale
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setLive(_ live: Bool) {
        if live {
            if layer?.animation(forKey: "pulse") == nil {
                layer?.add(pulse, forKey: "pulse")
            }
        } else {
            layer?.removeAnimation(forKey: "pulse")
            layer?.opacity = 1
        }
    }

    func setBusy() {
        layer?.backgroundColor = NSColor(red: 0.42, green: 0.62, blue: 0.88, alpha: 1).cgColor
    }

    func setPaused() {
        layer?.backgroundColor = NSColor(red: 0.94, green: 0.64, blue: 0.22, alpha: 1).cgColor
    }

    func setRecording() {
        layer?.backgroundColor = NSColor(red: 0.89, green: 0.23, blue: 0.18, alpha: 1).cgColor
    }
}
