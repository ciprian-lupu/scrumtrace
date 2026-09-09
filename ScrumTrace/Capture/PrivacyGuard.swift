#if os(macOS)
import AppKit
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
    private let lock = NSLock()
    private(set) var isTripped = false
    var onTrip: ((String) -> Void)?
    var onClear: (() -> Void)?
    /// Called on the privacy timer queue. Must pause capture without waiting for MainActor.
    var freezeCapture: (() -> Void)?

    var isCurrentlyTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isTripped
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 0.4)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
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
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return nil
        }
        if Self.credentialBundleIDs.contains(bundle) {
            return bundle
        }
        let lowered = bundle.lowercased()
        if lowered.contains("1password") || lowered.contains("bitwarden") || lowered.contains("lastpass")
            || lowered.contains("keepass") || lowered.contains("nordpass") || lowered.contains("enpass")
            || lowered.contains("protonpass") || lowered.contains("proton.pass")
            || lowered.contains("strongbox") || lowered.contains("dashlane") {
            return bundle
        }
        return nil
        #else
        return nil
        #endif
    }
}

/// Pauses the live recorder from a background privacy tick (C1). SessionController
/// `phase` updates later on MainActor; `SessionRecorder.isPaused` is the live gate.
final class CaptureFreeze: @unchecked Sendable {
    private let lock = NSLock()
    private weak var recorder: SessionRecorder?
    private let sampler: MetadataSampler

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
        rec?.setPaused(true)
        sampler.isSuspended = true
        // Hold-to-Talk observers run on this queue (`queue: nil`) and abort
        // before the MainActor HUD hop (C1).
        NotificationCenter.default.post(
            name: .scrumTraceCaptureGate,
            object: CaptureSessionState.paused
        )
    }
}
