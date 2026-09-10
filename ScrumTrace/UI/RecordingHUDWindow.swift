import AppKit
import Combine

/// Menu-bar companion HUD. AppKit controls that refuse first responder
/// so a click does not activate ScrumTrace and steal Keynote (Gate 0).
final class RecordingHUDWindow: NSPanel {
    private let controller: SessionController
    private var cancellables = Set<AnyCancellable>()
    private let visual = NSVisualEffectView()
    private let stack = NSStackView()
    private let dot = HUDPulseDot()
    private let mediaLabel = HUDLabel(size: 13, weight: .semibold, alpha: 1)
    private let wallLabel = HUDLabel(size: 9, weight: .medium, alpha: 0.45)
    private let statusLabel = HUDLabel(size: 11, weight: .medium, alpha: 0.9)
    private let shotButton = HUDTextButton(title: "Shot")
    private let pinButton = HUDTextButton(title: "Pin")
    private let pauseButton = HUDTextButton(title: "Pause")
    private let stopButton = HUDTextButton(title: "Stop")

    init(controller: SessionController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
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
        buildChrome()
        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        refresh()
        orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            positionOnActiveScreen()
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
        statusLabel.stringValue = controller.statusLine
        statusLabel.isHidden = !busy
        shotButton.isHidden = busy
        pinButton.isHidden = busy
        pauseButton.isHidden = busy
        stopButton.isHidden = busy
        shotButton.isEnabled = controller.captureState.allowsNewCapture
        pinButton.isEnabled = controller.captureState.allowsNewCapture
        pauseButton.setLabel(gatePaused ? "Resume" : "Pause")
        pauseButton.isEnabled = !gatePaused || controller.canResumeFromPause
        stopButton.isEnabled = true
    }

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

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        shotButton.target = self
        shotButton.action = #selector(shotClicked)
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)

        stack.addArrangedSubview(dot)
        stack.addArrangedSubview(mediaLabel)
        stack.addArrangedSubview(wallLabel)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(shotButton)
        stack.addArrangedSubview(pinButton)
        stack.addArrangedSubview(pauseButton)
        stack.addArrangedSubview(stopButton)
        stack.addArrangedSubview(statusLabel)

        let root = NSView()
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
            stack.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            stack.topAnchor.constraint(equalTo: visual.topAnchor),
            stack.bottomAnchor.constraint(equalTo: visual.bottomAnchor)
        ])
    }

    private func positionOnActiveScreen() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = NSSize(width: 580, height: 52)
        setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 18,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    @objc private func shotClicked() {
        controller.openShot()
    }

    @objc private func pinClicked() {
        controller.pin()
    }

    @objc private func pauseClicked() {
        controller.togglePause()
    }

    @objc private func stopClicked() {
        controller.stopRecording()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HUDLabel: NSTextField {
    init(size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
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
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class HUDTextButton: NSButton {
    private let ink = NSColor(red: 0.97, green: 0.93, blue: 0.86, alpha: 0.9)

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
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ink
            ]
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class HUDPulseDot: NSView {
    private let pulse = CABasicAnimation(keyPath: "opacity")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerRadius = 4.5
        layer?.backgroundColor = NSColor(red: 0.89, green: 0.23, blue: 0.18, alpha: 1).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 9).isActive = true
        heightAnchor.constraint(equalToConstant: 9).isActive = true
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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
