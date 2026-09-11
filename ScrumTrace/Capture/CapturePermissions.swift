import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
#endif

/// Screen Recording TCC is per code signature, not per bundle name. Ad-hoc
/// Debug rebuilds look like a new app, so Settings can show ScrumTrace on
/// while `CGPreflightScreenCaptureAccess()` is still false for *this* process.
/// ScreenCaptureKit also does not pick up a mid-process grant — calling
/// `SCShareableContent` in that state re-shows the system sheet.
enum CaptureReadiness: Equatable {
    case ready
    case screenDenied
    case screenGrantedNeedsRelaunch
    case microphoneDenied

    var allowsStart: Bool {
        switch self {
        case .ready:
            return true
        case .screenDenied, .screenGrantedNeedsRelaunch, .microphoneDenied:
            return false
        }
    }

    var menuLabel: String {
        switch self {
        case .ready:
            return "This process: Screen Recording and Microphone allowed"
        case .screenDenied:
            return "Screen Recording is not on for this process"
        case .screenGrantedNeedsRelaunch:
            return "Screen Recording is on — relaunch to apply"
        case .microphoneDenied:
            return "Microphone is off for this process"
        }
    }

    var userMessage: String {
        switch self {
        case .ready:
            return "Ready"
        case .screenDenied:
            return "This running process cannot capture. In System Settings → Privacy & Security → Screen Recording, click +, add ~/Applications/ScrumTrace.app, turn it on, then Relaunch. A ScrumTrace row that is already on is usually an older Debug copy — macOS treats each ad-hoc rebuild as a new app."
        case .screenGrantedNeedsRelaunch:
            return "Screen Recording is on, but this process started before the grant. macOS will not attach it until ScrumTrace quits. Use Relaunch, then press Record — do not press Record again in this process."
        case .microphoneDenied:
            return "Microphone is off for this process. Enable it for this ScrumTrace in System Settings → Privacy & Security → Microphone, then Relaunch."
        }
    }
}

enum CapturePermissions {
    private static var launchScreenGranted: Bool?

    /// Call from `applicationDidFinishLaunching` before any Record tap.
    static func snapshotLaunchState() {
        guard launchScreenGranted == nil else { return }
        #if os(macOS)
        launchScreenGranted = CGPreflightScreenCaptureAccess()
        #else
        launchScreenGranted = false
        #endif
    }

    /// True only if Screen Recording was already attached when this process started.
    static var screenGrantedAtLaunch: Bool {
        snapshotLaunchState()
        return launchScreenGranted ?? false
    }

    static func currentScreenGranted() -> Bool {
        #if os(macOS)
        return CGPreflightScreenCaptureAccess()
        #else
        return false
        #endif
    }

    static func microphoneStatus() -> String {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "allowed"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not asked for this process"
        @unknown default:
            return "unknown"
        }
        #else
        return "unavailable"
        #endif
    }

    static func readiness() -> CaptureReadiness {
        snapshotLaunchState()
        #if os(macOS)
        let now = CGPreflightScreenCaptureAccess()
        if now && launchScreenGranted == false {
            return .screenGrantedNeedsRelaunch
        }
        if !now {
            return .screenDenied
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return .microphoneDenied
        case .authorized, .notDetermined:
            return .ready
        @unknown default:
            return .ready
        }
        #else
        return .screenDenied
        #endif
    }

    static func runningAppPath() -> String {
        Bundle.main.bundlePath
    }

    static func scrubHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home || path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// CoreGraphics, macOS 10.15+. Sheet at most once per TCC client.
    /// Call from the menu or Settings — never from `startRecording()`.
    @discardableResult
    static func requestScreenAccess() -> Bool {
        #if os(macOS)
        return CGRequestScreenCaptureAccess()
        #else
        return false
        #endif
    }

    static func pendingCrashReportCount() -> Int {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("ScrumTrace-") && $0.hasSuffix(".ips") }.count
    }

    private static var signingCache: [String: String]?

    /// Technical fields only — never titles, URLs, notes, or keys.
    static func logFields() -> [String: String] {
        var fields = [
            "screen_at_launch": screenGrantedAtLaunch ? "1" : "0",
            "screen_now": currentScreenGranted() ? "1" : "0",
            "mic": microphoneStatus(),
            "readiness": readinessLabel(),
            "path": scrubHome(runningAppPath()),
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        #if os(macOS)
        fields["ax"] = AXIsProcessTrusted() ? "1" : "0"
        #endif
        for (key, value) in signingFields() {
            fields[key] = value
        }
        return fields
    }

    static func probeAndLog() {
        snapshotLaunchState()
        AgentLog.eventSync("permission_probe", [:])
    }

    static func signingFields() -> [String: String] {
        if let signingCache {
            return signingCache
        }
        let read = readCodesign()
        signingCache = read
        return read
    }

    private static func readCodesign() -> [String: String] {
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", "--verbose=4", Bundle.main.bundlePath]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return ["sign_error": "codesign_spawn_failed"]
        }
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let row = String(line)
            if row.hasPrefix("CDHash=") {
                out["cdhash"] = String(row.dropFirst(7))
            } else if row.hasPrefix("Identifier=") {
                out["sign_id"] = String(row.dropFirst(11))
            } else if row.hasPrefix("Format=") {
                out["sign_format"] = String(row.dropFirst(7))
            } else if row.hasPrefix("TeamIdentifier=") {
                out["team_id"] = String(row.dropFirst(15))
            } else if row.hasPrefix("Signature=") {
                out["sign_kind"] = String(row.dropFirst(10))
            }
        }
        if text.localizedCaseInsensitiveContains("adhoc") {
            out["adhoc"] = "1"
        }
        return out
        #else
        return [:]
        #endif
    }

    static func readinessLabel() -> String {
        switch readiness() {
        case .ready:
            return "ready"
        case .screenDenied:
            return "screenDenied"
        case .screenGrantedNeedsRelaunch:
            return "screenGrantedNeedsRelaunch"
        case .microphoneDenied:
            return "microphoneDenied"
        }
    }

    #if os(macOS)
    static func relaunchRunningApp() {
        AgentLog.event("relaunch_requested", [:])
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
    #endif
}
