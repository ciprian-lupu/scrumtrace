import AppKit
import Combine

/// Frame math for the floating processing panel, testable without a window.
enum ProcessingPanelLayout {
    static let width: CGFloat = 380
    static let topInset: CGFloat = 18
    static let sideInset: CGFloat = 18
    static let minimumVisibleEdge: CGFloat = 40
    static let frameKey = "scrumtrace.processing.frame"

    /// Top-right of the visible frame.
    static func defaultFrame(on visibleFrame: NSRect, size: NSSize) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - size.width - sideInset,
            y: visibleFrame.maxY - size.height - topInset,
            width: size.width,
            height: size.height
        )
    }

    /// A saved origin is reused only when a usable part of the panel at `size` is still on some screen. Only the
    /// origin is remembered; the height always follows the content.
    static func restoredFrame(saved: NSRect?, size: NSSize, screens: [NSRect]) -> NSRect? {
        guard let saved, saved.width > 0, saved.height > 0 else { return nil }
        let candidate = NSRect(origin: NSPoint(x: saved.minX, y: saved.maxY - size.height), size: size)
        for screen in screens {
            let visible = candidate.intersection(screen)
            if visible.width >= minimumVisibleEdge, visible.height >= min(minimumVisibleEdge, size.height) - 0.5 {
                return candidate
            }
        }
        return nil
    }

    static func encode(_ frame: NSRect) -> String { NSStringFromRect(frame) }

    static func decode(_ text: String?) -> NSRect? {
        guard let text, !text.isEmpty else { return nil }
        let rect = NSRectFromString(text)
        return rect.isEmpty ? nil : rect
    }
}

/// The floating processing panel: the recording being worked on, its date, the seven stages with the current one
/// highlighted and timed, what to expect, real progress, and Finish later / Retry / Close. Shown by the menu-bar
/// controller while a run goes on, where the recording pill would be, and hidden from screen sharing like the pill.
///
/// Same focus rules as the HUD (Gate 0): a non-activating panel that never becomes key, whose controls refuse
/// first responder, so a click never takes Keynote's focus. It never opens or fronts the main window.
final class ProcessingPanelWindow: NSPanel {
    private let controller: SessionController
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private let visual = PanelBackdrop()
    private let stack = NSStackView()
    private let titleLabel = PanelLabel(size: 13, weight: .semibold, alpha: 1)
    private let subtitleLabel = PanelLabel(size: 11, weight: .regular, alpha: 0.7)
    private let elapsedLabel = PanelLabel(size: 11, weight: .medium, alpha: 0.6, monospaced: true)
    private let footerLabel = PanelLabel(size: 11, weight: .regular, alpha: 0.85)
    private let progress = NSProgressIndicator()
    private let finishLaterButton = PanelTextButton(title: ProcessingPanelState.finishLaterTitle)
    private let retryButton = PanelTextButton(title: ProcessingPanelState.retryTitle)
    private let closeButton = PanelTextButton(title: ProcessingPanelState.closeTitle)
    private var rows: [ProcessingStage: ProcessingPanelRowView] = [:]
    private var isApplyingFrame = false
    /// What the panel last drew, so tests can read it without a view tree.
    private(set) var state: ProcessingPanelState?

    init(controller: SessionController, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: ProcessingPanelLayout.width, height: 200)),
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
        // Invisible to screen sharing (Meet, Teams, Zoom) and to any display capture, like the pill.
        sharingType = .none
        isMovableByWindowBackground = false
        buildChrome()
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
                restoreFrame()
            }
            refresh()
            orderFrontRegardless()
        } else {
            orderOut(nil)
        }
    }

    func refresh() {
        guard let status = controller.processing else {
            state = nil
            return
        }
        let next = ProcessingPanelState.make(status, modelStillLoading: controller.transcriber.isPreparing)
        state = next
        titleLabel.stringValue = next.title
        titleLabel.toolTip = status.sessionId
        subtitleLabel.stringValue = next.subtitle ?? ""
        subtitleLabel.isHidden = next.subtitle == nil
        elapsedLabel.stringValue = next.totalElapsed
        for row in next.rows {
            rows[row.stage]?.apply(row)
        }
        let active = next.rows.first { $0.state == .active }
        if let fraction = active?.fraction {
            progress.isIndeterminate = false
            progress.doubleValue = fraction
            progress.isHidden = false
            progress.stopAnimation(nil)
        } else if next.isRunning {
            progress.isIndeterminate = true
            progress.isHidden = false
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
            progress.isHidden = true
        }
        footerLabel.stringValue = next.footer ?? ""
        footerLabel.isHidden = next.footer == nil
        finishLaterButton.isHidden = !next.showsFinishLater
        retryButton.isHidden = !next.showsRetry
        closeButton.isHidden = !next.showsClose
        fitHeight()
    }

    // MARK: Actions

    @objc private func finishLaterClicked() {
        controller.finishLater()
    }

    @objc private func retryClicked() {
        controller.retryFromProcessingPanel()
    }

    @objc private func closeClicked() {
        controller.dismissProcessing()
    }

    // MARK: Frame

    private func fitHeight() {
        stack.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        guard abs(height - frame.height) > 0.5 else { return }
        // Keep the top edge where it is; the panel grows downwards.
        let target = NSRect(x: frame.minX, y: frame.maxY - height, width: ProcessingPanelLayout.width, height: height)
        applyFrame(target)
    }

    private func applyFrame(_ target: NSRect) {
        isApplyingFrame = true
        setFrame(target, display: true)
        isApplyingFrame = false
    }

    private func restoreFrame() {
        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: ProcessingPanelLayout.width, height: max(120, ceil(stack.fittingSize.height)))
        let screens = NSScreen.screens.map(\.visibleFrame)
        let saved = ProcessingPanelLayout.decode(defaults.string(forKey: ProcessingPanelLayout.frameKey))
        let target: NSRect
        if let restored = ProcessingPanelLayout.restoredFrame(saved: saved, size: size, screens: screens) {
            target = restored
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
            target = ProcessingPanelLayout.defaultFrame(on: visible, size: size)
        }
        applyFrame(target)
    }

    @objc private func frameDidChange(_ note: Notification) {
        guard !isApplyingFrame else { return }
        defaults.set(ProcessingPanelLayout.encode(frame), forKey: ProcessingPanelLayout.frameKey)
    }

    // MARK: Chrome

    private func buildChrome() {
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 14
        visual.layer?.masksToBounds = true
        visual.layer?.borderWidth = 1
        visual.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        visual.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The title wraps onto a second line rather than losing the date, which is the point of the panel.
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 3
        titleLabel.preferredMaxLayoutWidth = ProcessingPanelLayout.width - 28 - 64
        titleLabel.setAccessibilityIdentifier("processing.title")
        subtitleLabel.maximumNumberOfLines = 2
        footerLabel.maximumNumberOfLines = 3
        footerLabel.setAccessibilityIdentifier("processing.footer")
        for label in [titleLabel, subtitleLabel, footerLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let header = NSStackView(views: [titleLabel, elapsedLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.setAccessibilityIdentifier("processing.progress")

        finishLaterButton.target = self
        finishLaterButton.action = #selector(finishLaterClicked)
        finishLaterButton.toolTip = ProcessingPanelState.finishLaterHelp
        finishLaterButton.setAccessibilityIdentifier("processing.finishLater")
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.setAccessibilityIdentifier("processing.retry")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.setAccessibilityIdentifier("processing.close")
        let buttons = NSStackView(views: [finishLaterButton, retryButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(subtitleLabel)
        for stage in ProcessingStage.allCases {
            let row = ProcessingPanelRowView()
            row.setAccessibilityIdentifier("processing.stage.\(stage.rawValue)")
            rows[stage] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        stack.addArrangedSubview(progress)
        stack.addArrangedSubview(footerLabel)
        stack.addArrangedSubview(buttons)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        progress.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        footerLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let root = PanelRootView()
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
            stack.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: ProcessingPanelLayout.width)
        ])
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One stage: a mark, the title, the elapsed time on the right and a detail line under it.
final class ProcessingPanelRowView: NSView {
    private let dot = PanelPulseDot()
    private let title = PanelLabel(size: 12, weight: .medium, alpha: 0.95)
    private let elapsed = PanelLabel(size: 11, weight: .medium, alpha: 0.6, monospaced: true)
    private let detail = PanelLabel(size: 10.5, weight: .regular, alpha: 0.7)
    private(set) var row: ProcessingPanelRow?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let line = NSStackView(views: [dot, title, elapsed])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 7
        line.translatesAutoresizingMaskIntoConstraints = false
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.maximumNumberOfLines = 3
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSStackView(views: [line, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalTo: column.widthAnchor),
            detail.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 18),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ row: ProcessingPanelRow) {
        self.row = row
        title.stringValue = row.title
        elapsed.stringValue = row.elapsed ?? ""
        detail.stringValue = row.detail ?? ""
        detail.isHidden = row.detail == nil
        dot.apply(row.state)
        let dimmed = row.state == .pending
        title.alphaValue = dimmed ? 0.45 : 1
        elapsed.alphaValue = dimmed ? 0.45 : 1
        title.font = NSFont.systemFont(ofSize: 12, weight: row.state == .active ? .semibold : .medium)
        setAccessibilityValue(ProcessingStageChip.spoken(row.state))
    }
}

/// Content view: a press on the background drags the panel. Never a first responder, so Keynote keeps focus.
private final class PanelRootView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class PanelBackdrop: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }
}

private final class PanelLabel: NSTextField {
    init(size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, monospaced: Bool = false) {
        super.init(frame: .zero)
        isBezeled = false
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        refusesFirstResponder = true
        focusRingType = .none
        lineBreakMode = .byWordWrapping
        font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        textColor = NSColor(red: 0.97, green: 0.93, blue: 0.86, alpha: alpha)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }

    /// Labels are not interactive: presses go to the panel background.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class PanelTextButton: NSButton {
    private let ink = NSColor(red: 0.97, green: 0.93, blue: 0.86, alpha: 0.95)

    init(title: String) {
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = true
        refusesFirstResponder = true
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink]
        )
        translatesAutoresizingMaskIntoConstraints = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The stage mark: a hollow dot while pending, a pulsing accent dot while active, green when done, grey when
/// skipped, red when failed.
private final class PanelPulseDot: NSView {
    private let pulse = CABasicAnimation(keyPath: "opacity")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 10),
            heightAnchor.constraint(equalToConstant: 10)
        ])
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ state: ProcessingPanelRow.State) {
        layer?.removeAnimation(forKey: "pulse")
        layer?.opacity = 1
        layer?.borderWidth = 0
        switch state {
        case .pending:
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        case .active:
            layer?.backgroundColor = NSColor(red: 0.42, green: 0.62, blue: 0.88, alpha: 1).cgColor
            layer?.add(pulse, forKey: "pulse")
        case .done:
            layer?.backgroundColor = NSColor(red: 0.36, green: 0.72, blue: 0.42, alpha: 1).cgColor
        case .skipped:
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        case .failed:
            layer?.backgroundColor = NSColor(red: 0.89, green: 0.23, blue: 0.18, alpha: 1).cgColor
        }
    }
}
