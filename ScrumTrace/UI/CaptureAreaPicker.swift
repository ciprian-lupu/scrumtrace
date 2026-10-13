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

    /// Which overlay starts as the key window, so Return confirms it: the one carrying a saved region, else
    /// the saved display, else the main display, else the first. Nil only when there are no screens.
    static func starterIndex(screenIDs: [UInt32], regionIndex: Int?, current: CaptureArea, mainID: UInt32) -> Int? {
        if let regionIndex, screenIDs.indices.contains(regionIndex) {
            return regionIndex
        }
        if !current.targetsMainDisplay, let saved = screenIDs.firstIndex(of: current.displayID) {
            return saved
        }
        if let main = screenIDs.firstIndex(of: mainID) {
            return main
        }
        return screenIDs.isEmpty ? nil : 0
    }

    /// Overlay heading for one screen: name, point size, an index when two screens share a name, "(main)".
    static func screenLabel(name: String, width: Int, height: Int, duplicateIndex: Int?, isMain: Bool) -> String {
        var text = name.isEmpty ? "Display" : name
        if let duplicateIndex {
            text += " \(duplicateIndex)"
        }
        text += " · \(width)×\(height) pt"
        if isMain {
            text += " (main)"
        }
        return text
    }

    /// Shown on every overlay when the saved display is not connected, so a Start never silently records
    /// another screen: the user confirms one of the connected screens explicitly.
    static func missingDisplayNotice(current: CaptureArea, connectedIDs: [UInt32]) -> String? {
        guard !current.targetsMainDisplay, !connectedIDs.contains(current.displayID) else { return nil }
        let name = current.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "The saved display"
        return "\(name) is not connected. Pick a display."
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
        let screens = NSScreen.screens
        let mainID = UInt32(CGMainDisplayID())
        let ids = screens.map { CaptureAreaPickerWindow.displayID(of: $0) }
        let notice = CaptureAreaPicker.missingDisplayNotice(current: current, connectedIDs: ids)
        windows = screens.enumerated().map { index, screen in
            let name = screen.localizedName
            let sameName = screens.indices.filter { screens[$0].localizedName == name }
            let label = CaptureAreaPicker.screenLabel(
                name: name,
                width: Int(screen.frame.width.rounded()),
                height: Int(screen.frame.height.rounded()),
                duplicateIndex: sameName.count > 1 ? (sameName.firstIndex(of: index) ?? 0) + 1 : nil,
                isMain: ids[index] == mainID
            )
            let window = CaptureAreaPickerWindow(
                screen: screen,
                current: current,
                mode: mode,
                label: label,
                notice: notice
            )
            window.onUseSelection = { [weak self, weak window] in
                self?.confirmSelection(from: window)
            }
            // The whole of the screen this overlay covers, never a display-less `.entireDisplay`.
            window.onUseEntire = { [weak self] area in
                self?.finish(area)
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
        let regionIndex = windows.firstIndex(where: {
            if let area = $0.proposedArea(), !area.isEntireDisplay { return true }
            return false
        })
        let starterIndex = CaptureAreaPicker.starterIndex(
            screenIDs: ids,
            regionIndex: regionIndex,
            current: current,
            mainID: mainID
        )
        let starter = starterIndex.map { windows[$0] }
        starter?.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:
                self.cancel()
                return nil
            case 49:
                // Space: this display, the one under the key overlay.
                self.confirmWholeDisplay(of: self.keyWindow())
                return nil
            case 36, 76:
                let key = self.keyWindow()
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
            "display": String(area.displayID),
            "mode": mode == .record ? "record" : "choose"
        ])
        switch mode {
        case .choose:
            done?(.selected(area))
        case .record:
            done?(.record(area))
        }
    }

    private func keyWindow() -> CaptureAreaPickerWindow? {
        windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    /// Entire Display button or Space: the screen of that overlay. Every path ends on a concrete display id.
    private func confirmWholeDisplay(of window: CaptureAreaPickerWindow?) {
        guard let window else {
            cancel()
            return
        }
        finish(window.fullDisplayArea())
    }

    private func confirmSelection(from preferred: CaptureAreaPickerWindow? = nil) {
        if let preferred {
            // Return on an overlay with no box: that overlay's whole display, not the main one.
            finish(preferred.proposedArea() ?? preferred.fullDisplayArea())
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
        confirmWholeDisplay(of: keyWindow())
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
    var onUseEntire: ((CaptureArea) -> Void)?
    var onCancel: (() -> Void)?
    var onEdited: (() -> Void)?
    private let pickerView: CaptureAreaPickerView

    static func displayID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? UInt32(CGMainDisplayID())
    }

    init(screen: NSScreen, current: CaptureArea, mode: CaptureAreaPicker.Mode, label: String, notice: String?) {
        pickerView = CaptureAreaPickerView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            current: current,
            screen: screen,
            mode: mode,
            label: label,
            notice: notice
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
        pickerView.onUseEntire = { [weak self] area in
            self?.onUseEntire?(area)
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

    override func becomeKey() {
        super.becomeKey()
        pickerView.needsDisplay = true
    }

    override func resignKey() {
        super.resignKey()
        pickerView.needsDisplay = true
    }

    func proposedArea() -> CaptureArea? {
        pickerView.proposedArea()
    }

    /// The whole of this overlay's screen.
    func fullDisplayArea() -> CaptureArea {
        pickerView.fullDisplayArea()
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
    var onUseEntire: ((CaptureArea) -> Void)?
    var onCancel: (() -> Void)?
    var onEdited: (() -> Void)?

    private let screen: NSScreen
    private let mode: CaptureAreaPicker.Mode
    /// Screen heading drawn on this overlay (name, size, main marker).
    private let label: String
    /// Missing-display message, the same on every overlay, or nil.
    private let notice: String?
    private var liveRect: NSRect?
    private var drag: CaptureDrag = .none
    private var dragStart: NSPoint = .zero
    private var dragOriginRect: NSRect = .zero

    private let toolbar = NSVisualEffectView()
    private let recordButton = NSButton()
    private let entireButton = NSButton()
    private let cancelButton = NSButton()

    init(
        frame: NSRect,
        current: CaptureArea,
        screen: NSScreen,
        mode: CaptureAreaPicker.Mode,
        label: String,
        notice: String?
    ) {
        self.screen = screen
        self.mode = mode
        self.label = label
        self.notice = notice
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
            hintText = "Drag to select the capture area. Drag the box or handles to adjust. Return records this display. Space = this display. Esc cancels."
        case .choose:
            hintText = "Drag to select the capture area. Drag the box or handles to adjust. Return uses this display. Space = this display. Esc cancels."
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
        // Which screen this overlay covers. The key overlay (the one Return confirms) is drawn solid, the
        // others dimmed, so two monitors are never confused.
        let isKey = window?.isKeyWindow ?? false
        let heading = NSAttributedString(
            string: isKey ? "▶ \(label)" : label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(isKey ? 1 : 0.55)
            ]
        )
        let headingSize = heading.size()
        heading.draw(at: NSPoint(x: bounds.midX - headingSize.width / 2, y: bounds.maxY - 80))
        if let notice {
            let warning = NSAttributedString(
                string: notice,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                    .foregroundColor: NSColor.systemYellow
                ]
            )
            let warningSize = warning.size()
            warning.draw(at: NSPoint(x: bounds.midX - warningSize.width / 2, y: bounds.maxY - 112))
        }
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

    /// The whole of this overlay's screen, carrying its display id and name.
    func fullDisplayArea() -> CaptureArea {
        CaptureArea.fullDisplay(id: CaptureAreaPickerWindow.displayID(of: screen), name: screen.localizedName)
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
        onUseEntire?(fullDisplayArea())
    }

    @objc private func cancelSelection() {
        onCancel?()
    }

    private func area(from rect: NSRect?) -> CaptureArea? {
        guard let selection = rect, selection.width >= 160, selection.height >= 90 else {
            return nil
        }
        if selection.width >= bounds.width - 2 && selection.height >= bounds.height - 2 {
            // A box covering the screen is that screen, with its display id, not a display-less default.
            return fullDisplayArea()
        }
        let displayID = CaptureAreaPickerWindow.displayID(of: screen)
        let localYTop = bounds.height - selection.minY - selection.height
        return CaptureArea(
            capturesFullDisplay: false,
            displayID: displayID,
            originX: Double(max(0, selection.minX)),
            originY: Double(max(0, localYTop)),
            widthPoints: Double(floor(selection.width / 2) * 2),
            heightPoints: Double(floor(selection.height / 2) * 2),
            backingScale: Double(screen.backingScaleFactor),
            displayName: screen.localizedName
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
        let displayID = CaptureAreaPickerWindow.displayID(of: screen)
        guard displayID == area.displayID else { return nil }
        let height = CGFloat(area.heightPoints)
        let width = CGFloat(area.widthPoints)
        let y = bounds.height - CGFloat(area.originY) - height
        return NSRect(x: area.originX, y: y, width: width, height: height).intersection(bounds)
    }
}
#endif
