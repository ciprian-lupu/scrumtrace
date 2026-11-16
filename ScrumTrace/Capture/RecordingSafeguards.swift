import Foundation

/// Keeps the Mac from idle-sleeping while ScrumTrace records or works on a recording.
///
/// A menu-bar app holds no power assertion of its own. In a meeting where nobody touches the recording Mac, the display
/// and then the system can go to sleep in the middle of the capture; after Stop, a long model load and transcription is
/// suspended the same way and provider calls in flight fail. This holds one activity per reason and ends it when the
/// reason goes away. It prevents idle sleep only: closing the lid or choosing Sleep still sleeps the Mac.
@MainActor
final class SleepGuard {
    enum Hold: String, CaseIterable {
        /// Screen and audio are being captured: the display has to stay on as well.
        case recording
        /// Stopping, transcribing, slicing, evaluating, packaging, transferring: the system has to stay awake.
        case working
    }

    typealias Begin = (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    typealias End = (NSObjectProtocol) -> Void

    private let begin: Begin
    private let end: End
    private var tokens: [Hold: NSObjectProtocol] = [:]

    init(
        begin: @escaping Begin = { ProcessInfo.processInfo.beginActivity(options: $0, reason: $1) },
        end: @escaping End = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    /// The holds currently in force.
    var held: Set<Hold> { Set(tokens.keys) }

    /// `.userInitiated` keeps the system awake and turns off sudden and automatic termination, so a logout still
    /// reaches `applicationWillTerminate` and the movie is closed. Recording also keeps the display on.
    static func options(for hold: Hold) -> ProcessInfo.ActivityOptions {
        switch hold {
        case .recording:
            return [.userInitiated, .idleDisplaySleepDisabled]
        case .working:
            return .userInitiated
        }
    }

    static func reason(for hold: Hold) -> String {
        switch hold {
        case .recording:
            return "ScrumTrace is recording"
        case .working:
            return "ScrumTrace is processing a recording"
        }
    }

    /// Call whenever the recording or busy state may have changed. Idempotent.
    func update(recording: Bool, working: Bool) {
        set(.recording, wanted: recording)
        set(.working, wanted: working)
    }

    private func set(_ hold: Hold, wanted: Bool) {
        if wanted {
            guard tokens[hold] == nil else { return }
            tokens[hold] = begin(Self.options(for: hold), Self.reason(for: hold))
        } else if let token = tokens.removeValue(forKey: hold) {
            end(token)
        }
    }
}

/// Free-disk rules for a recording.
///
/// The archive movie is written at a fixed average bitrate and nothing else bounds it, so a long recording on a nearly
/// full disk used to fail in the middle with a writer error, an unfinished movie and failed manifest writes. Start now
/// refuses when there is no room for a useful recording, and a running recording stops through the normal Stop while
/// there is still room to close the files and process what was captured.
enum RecordingDiskBudget {
    /// Bytes one second of recording can add: the archive movie at its configured average bitrate plus the room WAV
    /// (48 kHz 16-bit stereo at most).
    static let bytesPerSecond: Int64 = Int64(MediaBudget.archiveVideoBitrate / 8) + 192_000

    /// Start refuses below this. About a quarter of an hour at the full bitrate.
    static let minimumFreeBytesToStart: Int64 = 2_000_000_000
    /// A running recording warns below this.
    static let lowFreeBytes: Int64 = 2_000_000_000
    /// A running recording stops below this, leaving room to close the movie and process it.
    static let stopBelowFreeBytes: Int64 = 500_000_000

    enum Level: Equatable {
        case enough
        case low
        case stop
    }

    /// Whole minutes of recording that fit in `freeBytes` at the full bitrate. Screens that barely change compress far
    /// better, so this is a floor, not a forecast.
    static func minutesOfRecording(freeBytes: Int64) -> Int {
        guard freeBytes > 0 else { return 0 }
        return Int(freeBytes / bytesPerSecond / 60)
    }

    /// Nil when Start may go ahead; otherwise the sentence the Start failure shows. An unknown capacity (`nil`) never
    /// blocks a recording.
    static func startRefusal(freeBytes: Int64?) -> String? {
        guard let freeBytes, freeBytes < minimumFreeBytesToStart else { return nil }
        return "Not enough free disk space to record: \(describe(freeBytes)) free, and ScrumTrace needs at least "
            + "\(describe(minimumFreeBytesToStart)). Free up space or delete old recordings, then start again."
    }

    static func level(freeBytes: Int64?) -> Level {
        guard let freeBytes else { return .enough }
        if freeBytes < stopBelowFreeBytes { return .stop }
        if freeBytes < lowFreeBytes { return .low }
        return .enough
    }

    static func lowMessage(freeBytes: Int64) -> String {
        "Recording — disk space is low (\(describe(freeBytes)) free, about \(minutesOfRecording(freeBytes: freeBytes)) min)"
    }

    static func stopMessage(freeBytes: Int64) -> String {
        "Recording stopped because the disk is almost full (\(describe(freeBytes)) free). What was captured is being processed."
    }

    /// "1.4 GB" / "320 MB", decimal units like Finder, independent of the user's locale so logs and tests are stable.
    static func describe(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        if value >= 1_000_000_000 {
            let tenths = (value + 50_000_000) / 100_000_000
            return "\(tenths / 10).\(tenths % 10) GB"
        }
        return "\((value + 500_000) / 1_000_000) MB"
    }

    /// Free bytes on the volume that holds `url`, or nil when it cannot be read. `url` need not exist yet: the nearest
    /// existing ancestor answers, so the sessions folder can be asked before its first recording.
    static func freeBytes(at url: URL) -> Int64? {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
        let values = try? candidate.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        // The important-usage figure counts purgeable space and is what Finder shows; volumes that do not support it
        // report 0, and then the plain figure decides.
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let plain = values?.volumeAvailableCapacity {
            return Int64(plain)
        }
        return nil
    }
}
