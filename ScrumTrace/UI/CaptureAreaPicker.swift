#if os(macOS)
import AppKit
import CoreGraphics

/// Full-screen drag overlay, same idea as the macOS region screenshot.
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
            let window = CaptureAreaPickerWindow(screen: screen)
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
            if event.keyCode == 53 {
                self?.cancel(keep: current)
                return nil
            }
            return event
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

    init(screen: NSScreen) {
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
        let view = CaptureAreaPickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onConfirm = { [weak self] area in
            self?.onConfirm?(area)
        }
        view.onCancel = { [weak self] in
            self?.onCancel?()
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
}

private final class CaptureAreaPickerView: NSView {
    var onConfirm: ((CaptureArea) -> Void)?
    var onCancel: (() -> Void)?
    private var dragOrigin: NSPoint?
    private var dragCurrent: NSPoint?

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
        NSColor.black.withAlphaComponent(0.42).setFill()
        dirtyRect.fill()
        let instruction = NSAttributedString(
            string: "Drag to select the capture area. Release to confirm. Esc keeps the previous area.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
        let size = instruction.size()
        let point = NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 48)
        instruction.draw(at: point)
        if let selection = currentSelection() {
            NSColor.black.withAlphaComponent(0.15).setFill()
            selection.fill()
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2
            path.stroke()
            let label = "\(Int(selection.width.rounded()))×\(Int(selection.height.rounded()))"
            let text = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
            )
            text.draw(at: NSPoint(x: selection.minX + 8, y: selection.maxY + 6))
        }
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
        guard let selection = currentSelection(),
              selection.width >= 160,
              selection.height >= 90,
              let screen = window?.screen else {
            onCancel?()
            return
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
        let scale = screen.backingScaleFactor
        let localX = selection.minX
        let localYTop = bounds.height - selection.minY - selection.height
        var width = floor(selection.width / 2) * 2
        var height = floor(selection.height / 2) * 2
        if width < 160 { width = 160 }
        if height < 90 { height = 90 }
        let area = CaptureArea(
            capturesFullDisplay: false,
            displayID: displayID,
            originX: Double(max(0, localX)),
            originY: Double(max(0, localYTop)),
            widthPoints: Double(width),
            heightPoints: Double(height),
            backingScale: Double(scale)
        )
        onConfirm?(area)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
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
}
#endif
