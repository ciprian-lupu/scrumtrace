#if os(macOS)
import AppKit
import CoreGraphics

/// Screen-region picker in the style of macOS Screenshot / Screen Recording (⇧⌘5).
enum CaptureAreaPicker {
    enum Mode: Equatable {
        case choose
        case record
    }

    enum Outcome: Equatable {
        case cancelled
        case selected(CaptureArea)
        case record(CaptureArea)
    }

    @MainActor
    static func present(current: CaptureArea, completion: @escaping (CaptureArea) -> Void) {
        present(current: current, mode: .choose) { outcome in
            switch outcome {
            case .cancelled:
                completion(current)
            case .selected(let area), .record(let area):
                completion(area)
            }
        }
    }

    @MainActor
    static func present(
        current: CaptureArea,
        mode: Mode,
        completion: @escaping (Outcome) -> Void
    ) {
        CaptureAreaPickerController.shared.begin(current: current, mode: mode, completion: completion)
    }
}

@MainActor
private final class CaptureAreaPickerController {
    static let shared = CaptureAreaPickerController()

    private var windows: [CaptureAreaPickerWindow] = []
    private var completion: ((CaptureAreaPicker.Outcome) -> Void)?
    private var monitor: Any?
    private var mode: CaptureAreaPicker.Mode = .choose
    private weak var lastEditedWindow: CaptureAreaPickerWindow?

    func begin(
        current: CaptureArea,
        mode: CaptureAreaPicker.Mode,
        completion: @escaping (CaptureAreaPicker.Outcome) -> Void
    ) {
        cancel()
        self.mode = mode
        self.completion = completion
        NSApp.activate(ignoringOtherApps: true)
        windows = NSScreen.screens.map { screen in
            let window = CaptureAreaPickerWindow(screen: screen, current: current, mode: mode)
            window.onUseSelection = { [weak self, weak window] in
                self?.confirmSelection(from: window)
            }
            window.onUseEntire = { [weak self] in
                self?.finish(.entireDisplay)
            }
            window.onCancel = { [weak self] in
                self?.cancel()
            }
            window.onEdited = { [weak self, weak window] in
                self?.lastEditedWindow = window
                window?.makeKey()
            }
            window.orderFrontRegardless()
            return window
        }
        let starter = windows.first(where: {
            if let area = $0.proposedArea(), !area.isEntireDisplay { return true }
            return false
        }) ?? windows.first(where: { $0.screen == NSScreen.main }) ?? windows.first
        starter?.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:
                self.cancel()
                return nil
            case 49:
                self.finish(.entireDisplay)
                return nil
            case 36, 76:
                let key = self.windows.first(where: { $0.isKeyWindow })
                self.confirmSelection(from: key)
                return nil
            default:
                return event
            }
        }
        AgentLog.event("capture_area_picker", [
            "action": "open",
            "mode": mode == .record ? "record" : "choose"
        ])
    }

    private func finish(_ area: CaptureArea) {
        let done = completion
        let mode = self.mode
        teardown()
        AgentLog.event("capture_area_picker", [
            "action": "confirm",
            "full": area.isEntireDisplay ? "1" : "0",
            "display": area.isEntireDisplay ? "all" : String(area.displayID),
            "mode": mode == .record ? "record" : "choose"
        ])
        switch mode {
        case .choose:
            done?(.selected(area))
        case .record:
            done?(.record(area))
        }
    }

    private func confirmSelection(from preferred: CaptureAreaPickerWindow? = nil) {
        if preferred != nil {
            finish(preferred?.proposedArea() ?? .entireDisplay)
            return
        }
        if let edited = lastEditedWindow?.proposedArea(), !edited.isEntireDisplay {
            finish(edited)
            return
        }
        let areas = windows.compactMap { $0.proposedArea() }
        if let region = areas.first(where: { !$0.isEntireDisplay }) {
            finish(region)
            return
        }
        finish(.entireDisplay)
    }

    private func cancel() {
        let done = completion
        teardown()
        guard let done else { return }
        AgentLog.event("capture_area_picker", ["action": "cancel"])
        done(.cancelled)
    }

    private func teardown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        lastEditedWindow = nil
        completion = nil
    }
}

private final class CaptureAreaPickerWindow: NSWindow {
    var onUseSelection: (() -> Void)?
    var onUseEntire: (() -> Void)?
    var onCancel: (() -> Void)?
    var onEdited: (() -> Void)?
    private let pickerView: CaptureAreaPickerView

    init(screen: NSScreen, current: CaptureArea, mode: CaptureAreaPicker.Mode) {
        pickerView = CaptureAreaPickerView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            current: current,
            screen: screen,
            mode: mode
        )
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false
        animationBehavior = .none
        pickerView.onUseSelection = { [weak self] in
            self?.onUseSelection?()
        }
        pickerView.onUseEntire = { [weak self] in
            self?.onUseEntire?()
        }
        pickerView.onCancel = { [weak self] in
            self?.onCancel?()
        }
        pickerView.onEdited = { [weak self] in
            self?.onEdited?()
        }
        contentView = pickerView
    }

    override var canBecomeKey: Bool { true }

    func proposedArea() -> CaptureArea? {
        pickerView.proposedArea()
    }
}

private enum CaptureHandle: CaseIterable {
    case n, s, e, w, ne, nw, se, sw
}

private enum CaptureDrag {
    case none
    case drawing
    case moving
    case resizing(CaptureHandle)
}

private final class CaptureAreaPickerView: NSView {
    var onUseSelection: (() -> Void)?
    var onUseEntire: (() -> Void)?
    var onCancel: (() -> Void)?
    var onEdited: (() -> Void)?

    private let screen: NSScreen
    private let mode: CaptureAreaPicker.Mode
    private var liveRect: NSRect?
    private var drag: CaptureDrag = .none
    private var dragStart: NSPoint = .zero
    private var dragOriginRect: NSRect = .zero

    private let toolbar = NSVisualEffectView()
    private let recordButton = NSButton()
    private let entireButton = NSButton()
    private let cancelButton = NSButton()

    init(frame: NSRect, current: CaptureArea, screen: NSScreen, mode: CaptureAreaPicker.Mode) {
        self.screen = screen
        self.mode = mode
        self.liveRect = Self.rect(for: current, on: screen, in: frame) ?? frame
        super.init(frame: frame)
        wantsLayer = true
        setupButtons()
        layoutButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NSCursor.crosshair.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard let hole = liveRect else { return }
        addCursorRect(hole, cursor: .openHand)
        for handle in CaptureHandle.allCases {
            addCursorRect(handleRect(handle, in: hole), cursor: cursor(for: handle))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let hole = liveRect {
            dim.append(NSBezierPath(rect: hole))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        if let hole = liveRect {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: hole.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            var dashes: [CGFloat] = [6, 4]
            border.setLineDash(&dashes, count: 2, phase: 0)
            border.stroke()
            NSColor.white.setFill()
            for handle in CaptureHandle.allCases {
                NSBezierPath(rect: handleRect(handle, in: hole)).fill()
            }
            let label = "\(Int(hole.width.rounded()))×\(Int(hole.height.rounded()))"
            let text = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
            )
            text.draw(at: NSPoint(x: hole.minX + 8, y: hole.maxY + 8))
        }
        let hintText: String
        switch mode {
        case .record:
            hintText = "Drag to select the capture area. Drag the box or handles to adjust. Return records this display. Space = entire display. Esc cancels."
        case .choose:
            hintText = "Drag to select the capture area. Drag the box or handles to adjust. Return uses this display. Space = entire display. Esc cancels."
        }
        let hint = NSAttributedString(
            string: hintText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
        let size = hint.size()
        hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 40))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if let hole = liveRect, let handle = hitHandle(point, in: hole) {
            drag = .resizing(handle)
            dragStart = point
            dragOriginRect = hole
            return
        }
        if let hole = liveRect, hole.contains(point) {
            drag = .moving
            dragStart = point
            dragOriginRect = hole
            NSCursor.closedHand.set()
            return
        }
        drag = .drawing
        dragStart = point
        liveRect = NSRect(origin: point, size: .zero)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            break
        case .drawing:
            liveRect = normalizedRect(from: dragStart, to: point).intersection(bounds)
        case .moving:
            var next = dragOriginRect
            next.origin.x += point.x - dragStart.x
            next.origin.y += point.y - dragStart.y
            liveRect = clamp(next)
        case .resizing(let handle):
            liveRect = clamp(resized(dragOriginRect, handle: handle, to: point))
        }
        needsDisplay = true
        layoutButtons()
        window?.invalidateCursorRects(for: self)
        onEdited?()
    }

    override func mouseUp(with event: NSEvent) {
        if case .drawing = drag, let hole = liveRect, hole.width < 160 || hole.height < 90 {
            liveRect = nil
        } else if var hole = liveRect {
            hole.size.width = max(160, floor(hole.width / 2) * 2)
            hole.size.height = max(90, floor(hole.height / 2) * 2)
            liveRect = clamp(hole)
        }
        drag = .none
        NSCursor.crosshair.set()
        needsDisplay = true
        layoutButtons()
        window?.invalidateCursorRects(for: self)
        onEdited?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func proposedArea() -> CaptureArea? {
        area(from: liveRect)
    }

    private func setupButtons() {
        let recordTitle: String
        switch mode {
        case .choose:
            recordTitle = "Use this area"
        case .record:
            recordTitle = "Record"
        }
        configure(recordButton, title: recordTitle, action: #selector(confirmSelection))
        configure(entireButton, title: "Entire Display", action: #selector(confirmEntire))
        configure(cancelButton, title: "Cancel", action: #selector(cancelSelection))
        if mode == .record {
            recordButton.keyEquivalent = "\r"
        }
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 10
        toolbar.layer?.masksToBounds = true
        addSubview(toolbar)
        toolbar.addSubview(recordButton)
        toolbar.addSubview(entireButton)
        toolbar.addSubview(cancelButton)
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.focusRingType = .none
    }

    private func layoutButtons() {
        let bar = toolbarRect()
        toolbar.frame = bar
        let inset: CGFloat = 6
        let gap: CGFloat = 6
        let width = (bar.width - inset * 2 - gap * 2) / 3
        let height = max(24, bar.height - inset * 2)
        recordButton.frame = NSRect(x: inset, y: inset, width: width, height: height)
        entireButton.frame = NSRect(x: inset + width + gap, y: inset, width: width, height: height)
        cancelButton.frame = NSRect(x: inset + (width + gap) * 2, y: inset, width: width, height: height)
    }

    private func toolbarRect() -> NSRect {
        let size = NSSize(width: 440, height: 44)
        if let hole = liveRect {
            let below = NSRect(
                x: hole.midX - size.width / 2,
                y: hole.minY - size.height - 12,
                width: size.width,
                height: size.height
            )
            if below.minY > 16 {
                return below.intersection(bounds.insetBy(dx: 16, dy: 16))
            }
            let above = NSRect(
                x: hole.midX - size.width / 2,
                y: hole.maxY + 12,
                width: size.width,
                height: size.height
            )
            if above.maxY < bounds.maxY - 16 {
                return above.intersection(bounds.insetBy(dx: 16, dy: 16))
            }
        }
        return NSRect(x: bounds.midX - size.width / 2, y: 28, width: size.width, height: size.height)
    }

    @objc private func confirmSelection() {
        onUseSelection?()
    }

    @objc private func confirmEntire() {
        onUseEntire?()
    }

    @objc private func cancelSelection() {
        onCancel?()
    }

    private func area(from rect: NSRect?) -> CaptureArea? {
        guard let selection = rect, selection.width >= 160, selection.height >= 90 else {
            return nil
        }
        if selection.width >= bounds.width - 2 && selection.height >= bounds.height - 2 {
            return .entireDisplay
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
        let localYTop = bounds.height - selection.minY - selection.height
        return CaptureArea(
            capturesFullDisplay: false,
            displayID: displayID,
            originX: Double(max(0, selection.minX)),
            originY: Double(max(0, localYTop)),
            widthPoints: Double(floor(selection.width / 2) * 2),
            heightPoints: Double(floor(selection.height / 2) * 2),
            backingScale: Double(screen.backingScaleFactor)
        )
    }

    private func hitHandle(_ point: NSPoint, in hole: NSRect) -> CaptureHandle? {
        for handle in CaptureHandle.allCases {
            if handleRect(handle, in: hole).insetBy(dx: -3, dy: -3).contains(point) {
                return handle
            }
        }
        return nil
    }

    private func handleRect(_ handle: CaptureHandle, in hole: NSRect) -> NSRect {
        let size: CGFloat = 8
        let half = size / 2
        let x: CGFloat
        let y: CGFloat
        switch handle {
        case .n:
            x = hole.midX
            y = hole.maxY
        case .s:
            x = hole.midX
            y = hole.minY
        case .e:
            x = hole.maxX
            y = hole.midY
        case .w:
            x = hole.minX
            y = hole.midY
        case .ne:
            x = hole.maxX
            y = hole.maxY
        case .nw:
            x = hole.minX
            y = hole.maxY
        case .se:
            x = hole.maxX
            y = hole.minY
        case .sw:
            x = hole.minX
            y = hole.minY
        }
        return NSRect(x: x - half, y: y - half, width: size, height: size)
    }

    private func cursor(for handle: CaptureHandle) -> NSCursor {
        switch handle {
        case .n, .s:
            return .resizeUpDown
        case .e, .w:
            return .resizeLeftRight
        case .ne, .nw, .se, .sw:
            return cornerResizeCursor(for: handle)
        }
    }

    private func cornerResizeCursor(for handle: CaptureHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch handle {
            case .ne, .sw:
                return .frameResize(position: .topRight, directions: .all)
            case .nw, .se:
                return .frameResize(position: .topLeft, directions: .all)
            case .n, .s, .e, .w:
                return .crosshair
            }
        }
        return .crosshair
    }

    private func resized(_ rect: NSRect, handle: CaptureHandle, to point: NSPoint) -> NSRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY
        switch handle {
        case .n:
            maxY = point.y
        case .s:
            minY = point.y
        case .e:
            maxX = point.x
        case .w:
            minX = point.x
        case .ne:
            maxX = point.x
            maxY = point.y
        case .nw:
            minX = point.x
            maxY = point.y
        case .se:
            maxX = point.x
            minY = point.y
        case .sw:
            minX = point.x
            minY = point.y
        }
        return normalizedRect(
            from: NSPoint(x: minX, y: minY),
            to: NSPoint(x: maxX, y: maxY)
        )
    }

    private func clamp(_ rect: NSRect) -> NSRect {
        var next = rect.intersection(bounds)
        if next.width < 160 {
            next.size.width = 160
        }
        if next.height < 90 {
            next.size.height = 90
        }
        if next.maxX > bounds.maxX {
            next.origin.x = bounds.maxX - next.width
        }
        if next.maxY > bounds.maxY {
            next.origin.y = bounds.maxY - next.height
        }
        next.origin.x = max(bounds.minX, next.origin.x)
        next.origin.y = max(bounds.minY, next.origin.y)
        return next
    }

    private func normalizedRect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    private static func rect(for area: CaptureArea, on screen: NSScreen, in bounds: NSRect) -> NSRect? {
        guard !area.isEntireDisplay else { return nil }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
        guard displayID == area.displayID else { return nil }
        let height = CGFloat(area.heightPoints)
        let width = CGFloat(area.widthPoints)
        let y = bounds.height - CGFloat(area.originY) - height
        return NSRect(x: area.originX, y: y, width: width, height: height).intersection(bounds)
    }
}
#endif
