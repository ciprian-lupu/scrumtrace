#if os(macOS)
import AppKit
import CoreGraphics

/// Full-screen drag overlay, same idea as the macOS region screenshot (⇧⌘4).
enum CaptureAreaPicker {
    static func present(current: CaptureArea, completion: @escaping (CaptureArea) -> Void) {
        CaptureAreaPickerController.shared.begin(current: current, completion: completion)
    }
}

@MainActor
private final class CaptureAreaPickerController {
    static let shared = CaptureAreaPickerController()

    private var windows: [CaptureAreaPickerWindow] = []
    private var completion: ((CaptureArea) -> Void)?
    private var monitor: Any?

    func begin(current: CaptureArea, completion: @escaping (CaptureArea) -> Void) {
        cancel(keep: current)
        self.completion = completion
        NSApp.activate(ignoringOtherApps: true)
        windows = NSScreen.screens.map { screen in
            let window = CaptureAreaPickerWindow(screen: screen, current: current)
            window.onConfirm = { [weak self] area in
                self?.finish(area)
            }
            window.onCancel = { [weak self] in
                self?.cancel(keep: current)
            }
            window.orderFrontRegardless()
            return window
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:
                self.cancel(keep: current)
                return nil
            case 49:
                self.finish(.entireDisplay)
                return nil
            case 36, 76:
                if let window = self.windows.first(where: { $0.proposedArea() != nil }),
                   let area = window.proposedArea() {
                    self.finish(area)
                } else {
                    self.finish(current)
                }
                return nil
            default:
                return event
            }
        }
        AgentLog.event("capture_area_picker", ["action": "open"])
    }

    private func finish(_ area: CaptureArea) {
        let done = completion
        teardown()
        AgentLog.event("capture_area_picker", [
            "action": "confirm",
            "full": area.isEntireDisplay ? "1" : "0"
        ])
        done?(area)
    }

    private func cancel(keep current: CaptureArea) {
        let done = completion
        teardown()
        done?(current)
    }

    private func teardown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        completion = nil
    }
}

private final class CaptureAreaPickerWindow: NSWindow {
    var onConfirm: ((CaptureArea) -> Void)?
    var onCancel: (() -> Void)?
    private let pickerView: CaptureAreaPickerView

    init(screen: NSScreen, current: CaptureArea) {
        pickerView = CaptureAreaPickerView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            current: current,
            screen: screen
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
        pickerView.onConfirm = { [weak self] area in
            self?.onConfirm?(area)
        }
        pickerView.onCancel = { [weak self] in
            self?.onCancel?()
        }
        contentView = pickerView
    }

    override var canBecomeKey: Bool { true }

    func proposedArea() -> CaptureArea? {
        pickerView.proposedArea()
    }
}

private final class CaptureAreaPickerView: NSView {
    var onConfirm: ((CaptureArea) -> Void)?
    var onCancel: (() -> Void)?
    private var dragOrigin: NSPoint?
    private var dragCurrent: NSPoint?
    private let preset: NSRect?
    private let screen: NSScreen
    private let starting: CaptureArea

    init(frame: NSRect, current: CaptureArea, screen: NSScreen) {
        self.screen = screen
        self.starting = current
        self.preset = Self.rect(for: current, on: screen, in: frame)
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeKey()
        NSCursor.crosshair.push()
    }

    deinit {
        NSCursor.pop()
    }

    override func draw(_ dirtyRect: NSRect) {
        let hole = currentSelection() ?? preset
        let dim = NSBezierPath(rect: bounds)
        if let hole {
            dim.append(NSBezierPath(rect: hole))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        if let hole {
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: hole.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
            let label = "\(Int(hole.width.rounded()))×\(Int(hole.height.rounded()))"
            let text = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
            )
            text.draw(at: NSPoint(x: hole.minX + 8, y: hole.maxY + 6))
        }
        let instruction = NSAttributedString(
            string: "Drag to select the capture area. Space = entire display. Return confirms. Esc keeps the previous area.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
        let size = instruction.size()
        instruction.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 48))
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragCurrent = dragOrigin
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
        if let area = areaFromDrag() {
            onConfirm?(area)
            return
        }
        dragOrigin = nil
        dragCurrent = nil
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func proposedArea() -> CaptureArea? {
        if let dragged = areaFromDrag() {
            return dragged
        }
        if let preset, !starting.isEntireDisplay {
            return starting
        }
        return nil
    }

    private func areaFromDrag() -> CaptureArea? {
        guard let selection = currentSelection(),
              selection.width >= 160,
              selection.height >= 90 else {
            return nil
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
        let scale = screen.backingScaleFactor
        let localYTop = bounds.height - selection.minY - selection.height
        var width = floor(selection.width / 2) * 2
        var height = floor(selection.height / 2) * 2
        if width < 160 { width = 160 }
        if height < 90 { height = 90 }
        return CaptureArea(
            capturesFullDisplay: false,
            displayID: displayID,
            originX: Double(max(0, selection.minX)),
            originY: Double(max(0, localYTop)),
            widthPoints: Double(width),
            heightPoints: Double(height),
            backingScale: Double(scale)
        )
    }

    private func currentSelection() -> NSRect? {
        guard let origin = dragOrigin, let current = dragCurrent else { return nil }
        let rect = NSRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
        return rect.intersection(bounds)
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
