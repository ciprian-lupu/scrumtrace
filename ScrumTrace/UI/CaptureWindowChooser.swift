#if os(macOS)
import AppKit
import ScreenCaptureKit

/// Start in single-window mode: lists the app windows on screen and returns the one to record.
enum CaptureWindowChooser {
    /// Longest chooser row. Browser tab titles can run to hundreds of characters.
    static let maxLabelLength = 90

    /// Nil when the user cancels, no window is on screen, or Screen Recording was not granted at launch.
    @MainActor
    static func present(completion: @escaping @MainActor (CaptureWindowTarget?) -> Void) {
        // Same rule as SessionRecorder.start: never ask ScreenCaptureKit for content without a launch grant,
        // or macOS shows the permission sheet again.
        guard CapturePermissions.screenGrantedAtLaunch else {
            AgentLog.event("window_chooser", ["result": "no_grant"])
            completion(nil)
            return
        }
        Task { @MainActor in
            let content = try? await Task.detached(priority: .userInitiated) {
                try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            }.value
            let targets = content.map { candidates(from: $0.windows) } ?? []
            let chosen = choose(from: targets)
            AgentLog.event("window_chooser", [
                "result": chosen == nil ? "cancelled" : "chosen",
                "windows": String(targets.count)
            ])
            completion(chosen)
        }
    }

    /// Normal app windows only: on screen, layer 0, big enough to be a real window, never ScrumTrace's own.
    static func candidates(from windows: [SCWindow]) -> [CaptureWindowTarget] {
        let own = Bundle.main.bundleIdentifier
        return windows.compactMap { window -> CaptureWindowTarget? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 120,
                  window.frame.height >= 80,
                  let app = window.owningApplication,
                  app.bundleIdentifier != own else { return nil }
            let name = app.applicationName.isEmpty ? app.bundleIdentifier : app.applicationName
            return CaptureWindowTarget(
                windowID: window.windowID,
                processID: app.processID,
                appName: name,
                windowTitle: window.title ?? ""
            )
        }
        .sorted { ($0.appName.lowercased(), $0.windowTitle) < ($1.appName.lowercased(), $1.windowTitle) }
    }

    static func rowTitle(_ target: CaptureWindowTarget) -> String {
        let label = target.label
        guard label.count > maxLabelLength else { return label }
        return String(label.prefix(maxLabelLength - 1)) + "…"
    }

    @MainActor
    private static func choose(from targets: [CaptureWindowTarget]) -> CaptureWindowTarget? {
        let alert = NSAlert()
        guard !targets.isEmpty else {
            alert.messageText = "No window to record"
            alert.informativeText = "Open the window you want to record, make sure it is not minimized, then start again."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return nil
        }
        alert.messageText = "Record one window"
        alert.informativeText = """
        Only this window is recorded, even when another window covers it. Shots show only this window. \
        Window titles and URLs are noted only while its app is in front. \
        The microphone is still recorded if it is on in Settings.
        """
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 26), pullsDown: false)
        // Menu items, not addItems(withTitles:): two windows with the same title must both stay listed.
        for target in targets {
            popup.menu?.addItem(NSMenuItem(title: rowTitle(target), action: nil, keyEquivalent: ""))
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard targets.indices.contains(index) else { return nil }
        return targets[index]
    }
}
#endif
