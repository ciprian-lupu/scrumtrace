import ApplicationServices
#if os(macOS)
import AppKit
#endif
import Foundation

/// Non-blocking frontmost window + browser URL sampler. Accessibility work
/// runs off the main thread and is abandoned after 200ms.
final class MetadataSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.str8minds.ScrumTrace.metadata", qos: .userInitiated)
    /// WA-8: the 200 ms deadline must not sit on the same serial queue as a
    /// blocking `AXUIElementCopyAttributeValue`.
    private let timeoutQueue = DispatchQueue(label: "com.str8minds.ScrumTrace.metadata.timeout", qos: .userInitiated)
    private let lock = NSLock()
    private var suspended = false
    private var onlyProcessID: pid_t?
    private var onlyDisplayID: UInt32?

    var isSuspended: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return suspended
        }
        set {
            lock.lock()
            suspended = newValue
            lock.unlock()
        }
    }

    /// Window mode: sample nothing unless this process is in front, so titles and URLs of apps that are not
    /// recorded never reach events.jsonl or a provider. Nil samples whatever is in front.
    var restrictedProcessID: pid_t? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return onlyProcessID
        }
        set {
            lock.lock()
            onlyProcessID = newValue
            lock.unlock()
        }
    }

    /// Display and region modes: titles and URLs come only from the focused window whose centre lies on this
    /// display, so a mail or chat window on an unrecorded monitor never reaches events.jsonl. Nil samples
    /// any display. This narrows what is logged, never what pauses: PrivacyGuard still watches every display.
    var restrictedDisplayID: UInt32? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return onlyDisplayID
        }
        set {
            lock.lock()
            onlyDisplayID = newValue
            lock.unlock()
        }
    }

    private func frontmostIsRecorded() -> Bool {
        guard let pid = restrictedProcessID else { return true }
        #if os(macOS)
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        #else
        return false
        #endif
    }

    /// Centre-point test in global top-left coordinates (what AX positions and `CGDisplayBounds` share).
    /// A window spanning two displays belongs to the one holding its centre; an empty frame is never on a
    /// display.
    static func windowIsOnDisplay(windowFrame: CGRect, displayBounds: CGRect) -> Bool {
        guard windowFrame.width > 0, windowFrame.height > 0, !displayBounds.isEmpty else { return false }
        return displayBounds.contains(CGPoint(x: windowFrame.midX, y: windowFrame.midY))
    }

    /// True when no display gate is set, or the focused window's frame is readable and on the gated display.
    /// An unreadable frame fails the gate: without a position the window cannot be shown to be recorded.
    static func displayGateAllows(windowFrame: CGRect?, restrictedDisplayID: UInt32?, bounds: (UInt32) -> CGRect) -> Bool {
        guard let restrictedDisplayID else { return true }
        guard let windowFrame else { return false }
        return windowIsOnDisplay(windowFrame: windowFrame, displayBounds: bounds(restrictedDisplayID))
    }

    private func focusedWindowIsOnRecordedDisplay(_ window: AXUIElement) -> Bool {
        #if os(macOS)
        return Self.displayGateAllows(
            windowFrame: Self.axFrame(of: window),
            restrictedDisplayID: restrictedDisplayID,
            bounds: { CGDisplayBounds(CGDirectDisplayID($0)) }
        )
        #else
        return restrictedDisplayID == nil
        #endif
    }

    /// AX position and size of a window, global top-left origin. Nil when either attribute is unavailable.
    private static func axFrame(of window: AXUIElement) -> CGRect? {
        var positionRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func requestTrust(prompt: Bool = false) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: prompt] as CFDictionary)
    }

    func sample(timeoutMs: UInt64 = MediaBudget.metadataSampleTimeoutMs) async -> WindowMetadata? {
        if isSuspended { return nil }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce<WindowMetadata?>()
            queue.async {
                if self.isSuspended {
                    once.resume(continuation, nil)
                    return
                }
                // Checked before and after the AX read: an app switch during the read must not leak a title.
                guard self.frontmostIsRecorded() else {
                    once.resume(continuation, nil)
                    return
                }
                let meta = self.readFrontmost()
                if self.isSuspended || !self.frontmostIsRecorded() {
                    once.resume(continuation, nil)
                    return
                }
                once.resume(continuation, meta)
            }
            timeoutQueue.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) {
                once.resume(continuation, nil)
            }
        }
    }

    private func readFrontmost() -> WindowMetadata? {
        if isSuspended { return nil }
        // Never prompt from the sampler. Untrusted AX still gets app name.
        guard Self.requestTrust(prompt: false) else {
            return isSuspended ? nil : NSWorkspaceFallback.frontmost()
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: AnyObject?
        let focusedStatus = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedApplicationAttribute as CFString,
            &focused
        )
        if isSuspended { return nil }
        guard focusedStatus == .success, let app = focused else {
            if isSuspended { return nil }
            let fallback = NSWorkspaceFallback.frontmost()
            return isSuspended ? nil : fallback
        }
        let appElement = unsafeBitCast(app, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        var titleRef: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXTitleAttribute as CFString, &titleRef)
        var windowRef: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        if isSuspended { return nil }
        var windowTitle: String = (titleRef as? String) ?? ""
        if let window = windowRef {
            let windowElement = unsafeBitCast(window, to: AXUIElement.self)
            // Display gate, checked before and after the title/URL read: a window dragged onto the
            // unrecorded monitor mid-read must not leak its title. Off-display keeps the app name only.
            guard focusedWindowIsOnRecordedDisplay(windowElement) else {
                return isSuspended ? nil : NSWorkspaceFallback.frontmost()
            }
            var winTitle: AnyObject?
            AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &winTitle)
            if let text = winTitle as? String, !text.isEmpty {
                windowTitle = text
            }
            let url = Self.documentURL(from: windowElement)
            guard focusedWindowIsOnRecordedDisplay(windowElement) else {
                return isSuspended ? nil : NSWorkspaceFallback.frontmost()
            }
            if let url {
                if isSuspended { return nil }
                let bundle = NSWorkspaceFallback.frontmost()?.bundleIdentifier ?? ""
                if isSuspended { return nil }
                return WindowMetadata(
                    appName: (titleRef as? String) ?? "App",
                    windowTitle: windowTitle,
                    bundleIdentifier: bundle,
                    url: url
                )
            }
        } else if restrictedDisplayID != nil {
            // No focused window to place on a display: app name only.
            return isSuspended ? nil : NSWorkspaceFallback.frontmost()
        }
        if isSuspended { return nil }
        let fallbackApp = NSWorkspaceFallback.frontmost()
        if isSuspended { return nil }
        return WindowMetadata(
            appName: (titleRef as? String) ?? "App",
            windowTitle: windowTitle,
            bundleIdentifier: fallbackApp?.bundleIdentifier ?? "",
            url: nil
        )
    }

    private static func documentURL(from window: AXUIElement) -> String? {
        var document: AnyObject?
        let status = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document)
        if status == .success, let value = document as? String, !value.isEmpty {
            return scrubbedURLString(value)
        }
        var extra: AnyObject?
        AXUIElementCopyAttributeValue(window, "AXURL" as CFString, &extra)
        if let url = extra as? URL {
            return scrubbedURLString(url.absoluteString)
        }
        if let text = extra as? String, !text.isEmpty {
            return scrubbedURLString(text)
        }
        return nil
    }

    static func scrubbedURLString(_ text: String) -> String {
        guard let parsed = URL(string: text), parsed.scheme != nil else {
            return text
        }
        var comps = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        return comps?.url?.absoluteString ?? parsed.absoluteString
    }
}

/// AX queries must not resume the HUD continuation twice (result vs 200 ms timeout).
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<T, Never>, _ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}

private enum NSWorkspaceFallback {
    static func frontmost() -> WindowMetadata? {
        #if os(macOS)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return WindowMetadata(
            appName: app.localizedName ?? "App",
            windowTitle: app.localizedName ?? "",
            bundleIdentifier: app.bundleIdentifier ?? "",
            url: nil
        )
        #else
        return nil
        #endif
    }
}
