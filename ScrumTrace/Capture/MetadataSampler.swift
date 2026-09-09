import ApplicationServices
#if os(macOS)
import AppKit
#endif
import Foundation

/// Non-blocking frontmost window + browser URL sampler. Accessibility work
/// runs off the main thread and is abandoned after 200ms.
final class MetadataSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.str8minds.ScrumTrace.metadata", qos: .userInitiated)
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

    static func requestTrust(prompt: Bool = false) {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: prompt] as CFDictionary)
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
                once.resume(continuation, self.readFrontmost())
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) {
                once.resume(continuation, nil)
            }
        }
    }

    private func readFrontmost() -> WindowMetadata? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let focusedStatus = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedApplicationAttribute as CFString,
            &focused
        )
        guard focusedStatus == .success, let app = focused else {
            return NSWorkspaceFallback.frontmost()
        }
        let appElement = unsafeBitCast(app, to: AXUIElement.self)
        var titleRef: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXTitleAttribute as CFString, &titleRef)
        var windowRef: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        var windowTitle: String = (titleRef as? String) ?? ""
        if let window = windowRef {
            let windowElement = unsafeBitCast(window, to: AXUIElement.self)
            var winTitle: AnyObject?
            AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &winTitle)
            if let text = winTitle as? String, !text.isEmpty {
                windowTitle = text
            }
            if let url = Self.documentURL(from: windowElement) {
                let bundle = NSWorkspaceFallback.frontmost()?.bundleIdentifier ?? ""
                return WindowMetadata(
                    appName: (titleRef as? String) ?? "App",
                    windowTitle: windowTitle,
                    bundleIdentifier: bundle,
                    url: url
                )
            }
        }
        return WindowMetadata(
            appName: (titleRef as? String) ?? "App",
            windowTitle: windowTitle,
            bundleIdentifier: NSWorkspaceFallback.frontmost()?.bundleIdentifier ?? "",
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
            return url.absoluteString
        }
        if let text = extra as? String, !text.isEmpty {
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
