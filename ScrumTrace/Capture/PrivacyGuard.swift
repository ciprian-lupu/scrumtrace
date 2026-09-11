#if os(macOS)
import AppKit
import CoreGraphics
#endif
import Foundation

/// Auto-pauses when a credential manager is frontmost so secrets never hit disk.
final class PrivacyGuard: @unchecked Sendable {
    static let credentialBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-macos",
        "com.apple.Passwords",
        "com.apple.Passwords.MacPasswordManager",
        "com.apple.KeychainAccess",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonehalper",
        "com.dashlane.Dashlane",
        "com.apple.Safari.PasswordManager",
        "org.keepassxc.KeePassXC",
        "me.proton.Pass",
        "com.nordpass.macos",
        "com.enpass.macos.standalone",
        "com.strongbox"
    ]

    private var timer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let tickQueue = DispatchQueue(
        label: "com.str8minds.ScrumTrace.privacy",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private(set) var isTripped = false
    var onTrip: ((String) -> Void)?
    var onClear: (() -> Void)?
    /// Called on the privacy queue. Must pause capture without waiting for MainActor.
    var freezeCapture: (() -> Void)?

    var isCurrentlyTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isTripped
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: tickQueue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
        observeFrontmostApp()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }
        #endif
        workspaceObservers = []
        lock.lock()
        isTripped = false
        lock.unlock()
    }

    func tick() {
        let match = currentCredentialApp()
        lock.lock()
        let wasTripped = isTripped
        if let match {
            isTripped = true
            lock.unlock()
            // Pause writers and metadata on this queue. The MainActor hop for HUD
            // must not leave a window where Shot/Pin still see `.recording`.
            freezeCapture?()
            if !wasTripped {
                onTrip?(match)
            }
        } else {
            isTripped = false
            lock.unlock()
            if wasTripped {
                onClear?()
            }
        }
    }

    func currentCredentialApp() -> String? {
        #if os(macOS)
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.matchesCredential(front) {
            return front
        }
        return overlayCredentialOwner()
        #else
        return nil
        #endif
    }

    static func matchesCredential(_ bundle: String) -> Bool {
        if credentialBundleIDs.contains(bundle) {
            return true
        }
        let lowered = bundle.lowercased()
        return lowered.contains("1password") || lowered.contains("bitwarden") || lowered.contains("lastpass")
            || lowered.contains("keepass") || lowered.contains("nordpass") || lowered.contains("enpass")
            || lowered.contains("protonpass") || lowered.contains("proton.pass")
            || lowered.contains("strongbox") || lowered.contains("dashlane")
            || lowered.contains("passwords")
    }

    /// Overlays that never become frontmost (Quick Access, menu extras).
    private func overlayCredentialOwner() -> String? {
        #if os(macOS)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for row in info {
            let owner = (row[kCGWindowOwnerName as String] as? String) ?? ""
            let lowered = owner.lowercased()
            if lowered.contains("1password") || lowered.contains("bitwarden") || lowered.contains("lastpass")
                || lowered.contains("keepass") || lowered.contains("nordpass") || lowered.contains("enpass")
                || lowered.contains("proton pass") || lowered.contains("dashlane")
                || lowered == "passwords" {
                return owner
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Frontmost-app changes fire immediately; the 0.1s timer is only a backstop
    /// for overlays that never become the frontmost application.
    private func observeFrontmostApp() {
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.tickQueue.async { self.tick() }
            }
            workspaceObservers.append(token)
        }
        #endif
    }
}

/// Pauses the live recorder from a background privacy tick (C1). SessionController
/// `phase` updates later on MainActor; `SessionRecorder.isPaused` is the live gate.
final class CaptureFreeze: @unchecked Sendable {
    private let lock = NSLock()
    private weak var recorder: SessionRecorder?
    private let sampler: MetadataSampler
    private var startInFlight = false
    private var holdThroughStart = false

    init(sampler: MetadataSampler) {
        self.sampler = sampler
    }

    func attach(_ recorder: SessionRecorder?) {
        lock.lock()
        self.recorder = recorder
        lock.unlock()
    }

    func freeze() {
        lock.lock()
        let rec = recorder
        lock.unlock()
        let alreadyPaused = rec?.isPaused == true
        rec?.setPaused(true)
        sampler.isSuspended = true
        // Hold-to-Talk observers run on this queue (`queue: nil`) and abort
        // before the MainActor HUD hop (C1). Skip re-posting while already
        // frozen so an open Shot annotation is not aborted on every privacy tick.
        if alreadyPaused { return }
        NotificationCenter.default.post(
            name: .scrumTraceCaptureGate,
            object: CaptureSessionState.paused
        )
    }

    /// Carbon Pause hotkey: freeze writers on the event thread before the
    /// MainActor hop. Idle Opt+⌘P must not suspend metadata with no session.
    @discardableResult
    func freezeIfAttached() -> Bool {
        lock.lock()
        let rec = recorder
        lock.unlock()
        guard let rec else { return false }
        let alreadyPaused = rec.isPaused
        rec.setPaused(true)
        sampler.isSuspended = true
        if alreadyPaused { return false }
        NotificationCenter.default.post(
            name: .scrumTraceCaptureGate,
            object: CaptureSessionState.paused
        )
        return true
    }

    func markStartInFlight(_ live: Bool) {
        lock.lock()
        startInFlight = live
        if !live {
            holdThroughStart = false
        }
        lock.unlock()
    }

    var isHeldThroughStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return holdThroughStart
    }

    func holdPauseThroughStart() {
        lock.lock()
        holdThroughStart = true
        lock.unlock()
    }

    func consumeHoldThroughStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let held = holdThroughStart
        holdThroughStart = false
        return held
    }

    /// Carbon Pause: freeze writers and, during Start, remember the hold so
    /// `start()` cannot unpause after the permission sheet (C1).
    func freezeForPauseHotkey() -> Bool {
        lock.lock()
        if startInFlight {
            holdThroughStart = true
        }
        lock.unlock()
        return freezeIfAttached()
    }
}
