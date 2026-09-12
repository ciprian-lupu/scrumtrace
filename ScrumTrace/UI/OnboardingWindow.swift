#if os(macOS)
import AppKit

/// First-run three-row permission window. Screen Recording is requested only
/// from the row button (`CapturePermissions.requestScreenAccess`), never from
/// `startRecording()`.
@MainActor
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
        if let retained {
            retained.focus()
            return
        }
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
    private var screenButton: NSButton?
    private var screenDetail: NSTextField?
    private var micLabel: NSTextField?
    private var axLabel: NSTextField?
    private var licenseLabel: NSTextField?
    private var timer: Timer?

    func show() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScrumTrace permissions"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 500))
        var y = 450.0
        let intro = makeText(
            "Review recording permissions for this app. After changing Screen Recording access, relaunch ScrumTrace. Microphone is needed when enabled in Settings → Capture.",
            frame: NSRect(x: 24, y: y, width: 512, height: 44)
        )
        root.addSubview(intro)
        y -= 84

        let (screenRow, screenStatus, screenNote, screenAction) = makeRow(
            title: "Screen Recording",
            detail: "Required for display capture. Use Ask now, then allow ScrumTrace in System Settings.",
            y: y,
            action: #selector(askScreen),
            buttonTitle: "Ask now"
        )
        screenLabel = screenStatus
        screenDetail = screenNote
        screenButton = screenAction
        root.addSubview(screenRow)
        y -= 100

        let (micRow, micStatus, _, _) = makeRow(
            title: "Microphone",
            detail: "Needed when Record microphone is enabled in Settings → Capture.",
            y: y,
            action: #selector(openMic),
            buttonTitle: "Open Settings"
        )
        micLabel = micStatus
        root.addSubview(micRow)
        y -= 100

        let (axRow, axStatus, _, _) = makeRow(
            title: "Accessibility",
            detail: "Optional. Adds window titles and scrubbed browser URLs. Not required to Record.",
            y: y,
            action: #selector(askAX),
            buttonTitle: "Ask now"
        )
        axLabel = axStatus
        root.addSubview(axRow)
        y -= 72

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
        focus()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window?.close()
        window = nil
    }

    private func refresh() {
        let readiness = CapturePermissions.readiness(requireMicrophone: AppSettings.shared.includeMicrophone)
        let screenGranted = CapturePermissions.currentScreenGranted()
        screenButton?.isEnabled = !screenGranted
        screenButton?.title = screenGranted ? "Allowed" : "Ask now"
        screenDetail?.stringValue = screenGranted
            ? (readiness == .screenGrantedNeedsRelaunch ? "Relaunch ScrumTrace from Settings → Permissions to apply the grant." : "Required for display capture. Access is already allowed for this copy.")
            : "Required for display capture. Use Ask now, then allow ScrumTrace in System Settings."
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
    ) -> (NSView, NSTextField, NSTextField, NSButton) {
        let box = NSView(frame: NSRect(x: 24, y: y, width: 512, height: 84))
        let heading = makeText(title, frame: NSRect(x: 0, y: 64, width: 360, height: 20))
        heading.font = NSFont.boldSystemFont(ofSize: 13)
        let status = makeText("…", frame: NSRect(x: 0, y: 46, width: 360, height: 18))
        let note = makeText(detail, frame: NSRect(x: 0, y: 2, width: 360, height: 44))
        note.textColor = .secondaryLabelColor
        let button = NSButton(frame: NSRect(x: 376, y: 35, width: 128, height: 28))
        button.title = buttonTitle
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        box.addSubview(heading)
        box.addSubview(status)
        box.addSubview(note)
        box.addSubview(button)
        return (box, status, note, button)
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
