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
                let meta = self.readFrontmost()
                if self.isSuspended {
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
            var winTitle: AnyObject?
            AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &winTitle)
            if let text = winTitle as? String, !text.isEmpty {
                windowTitle = text
            }
            if let url = Self.documentURL(from: windowElement) {
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
            return value
        }
        var extra: AnyObject?
        AXUIElementCopyAttributeValue(window, "AXURL" as CFString, &extra)
        if let url = extra as? URL {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.query = nil
            comps?.fragment = nil
            return comps?.url?.absoluteString ?? url.absoluteString
        }
        if let text = extra as? String, !text.isEmpty {
            if let parsed = URL(string: text), parsed.scheme != nil {
                var comps = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
                comps?.query = nil
                comps?.fragment = nil
                return comps?.url?.absoluteString ?? parsed.absoluteString
            }
            return text
        }
        return nil
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
