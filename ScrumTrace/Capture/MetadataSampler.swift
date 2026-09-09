import ApplicationServices
#if os(macOS)
import AppKit
#endif
import Foundation

/// Non-blocking frontmost window + browser URL sampler. Accessibility work
/// runs off the main thread and is abandoned after 200ms.
final class MetadataSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.str8minds.ScrumTrace.metadata", qos: .userInitiated)
    var isSuspended = false

    func sample(timeoutMs: UInt64 = MediaBudget.metadataSampleTimeoutMs) async -> WindowMetadata? {
        if isSuspended { return nil }
        await withTaskGroup(of: WindowMetadata?.self) { group in
            group.addTask {
                await self.blockingSample()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func blockingSample() async -> WindowMetadata? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.readFrontmost())
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
