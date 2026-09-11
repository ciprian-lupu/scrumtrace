#if os(macOS)
import AppKit

/// First-run three-row permission window. Screen Recording is requested only
/// from the row button (`CapturePermissions.requestScreenAccess`), never from
/// `startRecording()`.
enum OnboardingWindow {
    private static let seenKey = "scrumtrace.onboarding.seen"
    private static var retained: OnboardingPanelController?

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: seenKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }

    static func presentIfNeeded() {
        if hasCompleted { return }
        present()
    }

    static func present() {
        if retained != nil { return }
        let controller = OnboardingPanelController()
        retained = controller
        controller.show()
    }

    static func dismiss() {
        retained?.close()
        released()
        markCompleted()
    }

    static func released() {
        retained = nil
    }
}

@MainActor
private final class OnboardingPanelController: NSObject {
    private var window: NSWindow?
    private var screenLabel: NSTextField?
    private var micLabel: NSTextField?
    private var axLabel: NSTextField?
    private var licenseLabel: NSTextField?
    private var timer: Timer?

    func show() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScrumTrace permissions"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        var y = 370.0
        let intro = makeText(
            "Grant these on this binary, then Relaunch. Record stays off until Screen Recording and Microphone are allowed for this process.",
            frame: NSRect(x: 24, y: y, width: 512, height: 44)
        )
        root.addSubview(intro)
        y -= 70

        let (screenRow, screenStatus) = makeRow(
            title: "Screen Recording",
            detail: "Required. System Settings → Privacy & Security → Screen Recording → + → this app.",
            y: y,
            action: #selector(askScreen),
            buttonTitle: "Ask now"
        )
        screenLabel = screenStatus
        root.addSubview(screenRow)
        y -= 78

        let (micRow, micStatus) = makeRow(
            title: "Microphone",
            detail: "Required for the room-mic WAV. The first Record can show the system sheet when status is not determined.",
            y: y,
            action: #selector(openMic),
            buttonTitle: "Open Settings"
        )
        micLabel = micStatus
        root.addSubview(micRow)
        y -= 78

        let (axRow, axStatus) = makeRow(
            title: "Accessibility",
            detail: "Optional. Adds window titles and scrubbed browser URLs. Not required to Record.",
            y: y,
            action: #selector(askAX),
            buttonTitle: "Ask now"
        )
        axLabel = axStatus
        root.addSubview(axRow)
        y -= 56

        let license = makeText(LicenseStore.status().settingsLine, frame: NSRect(x: 24, y: y, width: 512, height: 36))
        licenseLabel = license
        root.addSubview(license)
        y -= 48

        let done = NSButton(frame: NSRect(x: 400, y: 16, width: 136, height: 28))
        done.title = "Continue"
        done.bezelStyle = .rounded
        done.target = self
        done.action = #selector(finish)
        root.addSubview(done)

        window.contentView = root
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window?.close()
        window = nil
    }

    private func refresh() {
        let readiness = CapturePermissions.readiness()
        switch readiness {
        case .ready:
            screenLabel?.stringValue = "Allowed for this process"
        case .screenDenied:
            screenLabel?.stringValue = "Not this process — click Ask now, then Relaunch"
        case .screenGrantedNeedsRelaunch:
            screenLabel?.stringValue = "On — relaunch required"
        case .microphoneDenied:
            screenLabel?.stringValue = "Screen is OK; microphone is off"
        }
        micLabel?.stringValue = CapturePermissions.microphoneStatus()
        axLabel?.stringValue = MetadataSampler.requestTrust(prompt: false) ? "trusted" : "not trusted (optional)"
        licenseLabel?.stringValue = LicenseStore.status().settingsLine
    }

    private func makeRow(
        title: String,
        detail: String,
        y: CGFloat,
        action: Selector,
        buttonTitle: String
    ) -> (NSView, NSTextField) {
        let box = NSView(frame: NSRect(x: 24, y: y, width: 512, height: 70))
        let heading = makeText(title, frame: NSRect(x: 0, y: 44, width: 360, height: 20))
        heading.font = NSFont.boldSystemFont(ofSize: 13)
        let status = makeText("…", frame: NSRect(x: 0, y: 26, width: 360, height: 18))
        let note = makeText(detail, frame: NSRect(x: 0, y: 2, width: 360, height: 24))
        note.textColor = .secondaryLabelColor
        let button = NSButton(frame: NSRect(x: 376, y: 22, width: 128, height: 28))
        button.title = buttonTitle
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        box.addSubview(heading)
        box.addSubview(status)
        box.addSubview(note)
        box.addSubview(button)
        return (box, status)
    }

    private func makeText(_ string: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.stringValue = string
        field.isBezeled = false
        field.isEditable = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 12)
        field.cell?.wraps = true
        return field
    }

    @objc private func askScreen() {
        AgentLog.event("settings_action", ["action": "onboarding_screen"])
        Task.detached {
            _ = CapturePermissions.requestScreenAccess()
        }
    }

    @objc private func openMic() {
        AgentLog.event("settings_action", ["action": "onboarding_mic"])
        SystemPrivacySettings.openMicrophone()
    }

    @objc private func askAX() {
        AgentLog.event("settings_action", ["action": "onboarding_ax"])
        MetadataSampler.requestTrust(prompt: true)
        refresh()
    }

    @objc private func finish() {
        OnboardingWindow.dismiss()
    }
}

extension OnboardingPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        OnboardingWindow.markCompleted()
        OnboardingWindow.released()
    }
}
#endif
