import CoreMedia
import Foundation

/// Maps wall-clock time to media presentation time.
///
/// `t_media = t_wall - Δt_paused(t)`
/// Pause intervals are wall-seconds since recording start. Media time never
/// advances while paused, and paused samples are not persisted.
enum TimelineMath {
    /// Completed pauses plus the active pause overlap at `wall`.
    static func pausedDelta(at wall: TimeInterval, pauses: [PauseInterval]) -> TimeInterval {
        var sum: TimeInterval = 0
        for pause in pauses {
            if let resume = pause.resumeWall {
                if resume <= wall {
                    sum += max(0, resume - pause.pauseWall)
                } else if pause.pauseWall < wall {
                    sum += max(0, wall - pause.pauseWall)
                }
            } else if pause.pauseWall < wall {
                sum += max(0, wall - pause.pauseWall)
            }
        }
        return sum
    }

    static func mediaTime(wall: TimeInterval, pauses: [PauseInterval]) -> TimeInterval {
        max(0, wall - pausedDelta(at: wall, pauses: pauses))
    }

    /// Inverse of `mediaTime`. Walks pauses in wall order.
    static func wallTime(media: TimeInterval, pauses: [PauseInterval]) -> TimeInterval {
        let completed = pauses.compactMap { pause -> (TimeInterval, TimeInterval)? in
            guard let resume = pause.resumeWall else { return nil }
            return (pause.pauseWall, resume)
        }
        .sorted { $0.0 < $1.0 }

        var wall = media
        for (pauseAt, resume) in completed where pauseAt <= wall {
            wall += max(0, resume - pauseAt)
        }
        return wall
    }

    static func clampMediaWindow(
        center: TimeInterval,
        duration: TimeInterval,
        mediaDuration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        let half = duration / 2
        var start = max(0, center - half)
        var end = min(mediaDuration, start + duration)
        start = max(0, end - duration)
        if end <= start {
            end = min(mediaDuration, start + 1)
        }
        return (start, end)
    }
}

/// Binds capture timestamps to `CMClockGetHostTimeClock()`.
final class ClockSynchronizer: @unchecked Sendable {
    private let hostClock: CMClock
    private let lock = NSLock()
    private var startHost: CMTime = .invalid
    private var pauses: [PauseInterval] = []
    private var recording = false

    init(hostClock: CMClock = CMClockGetHostTimeClock()) {
        self.hostClock = hostClock
    }

    var hostTimeClock: CMClock { hostClock }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        startHost = .invalid
        pauses = []
        recording = false
    }

    func markRecordingStarted() {
        lock.lock()
        defer { lock.unlock() }
        startHost = CMClockGetTime(hostClock)
        pauses = []
        recording = true
    }

    func currentWallSeconds() -> TimeInterval {
        lock.lock()
        let start = startHost
        lock.unlock()
        guard start.isValid else { return 0 }
        let now = CMClockGetTime(hostClock)
        return max(0, CMTimeGetSeconds(CMTimeSubtract(now, start)))
    }

    func currentMediaSeconds() -> TimeInterval {
        lock.lock()
        let localPauses = pauses
        lock.unlock()
        return TimelineMath.mediaTime(wall: currentWallSeconds(), pauses: localPauses)
    }

    func snapshotPauses() -> [PauseInterval] {
        lock.lock()
        defer { lock.unlock() }
        return pauses
    }

    func beginPause() {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        if let last = pauses.last, last.resumeWall == nil { return }
        let wall = wallSecondsLocked()
        pauses.append(PauseInterval(pauseWall: wall, resumeWall: nil))
    }

    func endPause() {
        lock.lock()
        defer { lock.unlock() }
        guard recording, var last = pauses.last, last.resumeWall == nil else { return }
        last.close(at: wallSecondsLocked())
        pauses[pauses.count - 1] = last
    }

    func mediaTime(forHostTime hostTime: CMTime) -> CMTime {
        lock.lock()
        let start = startHost
        let localPauses = pauses
        lock.unlock()
        guard start.isValid else { return .zero }
        let wall = max(0, CMTimeGetSeconds(CMTimeSubtract(hostTime, start)))
        let media = TimelineMath.mediaTime(wall: wall, pauses: localPauses)
        return CMTime(seconds: media, preferredTimescale: 600)
    }

    func mediaTime(forSampleBuffer buffer: CMSampleBuffer) -> CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if pts.isValid, startHostValid() {
            return mediaTime(forHostTime: pts)
        }
        return mediaTime(forHostTime: CMClockGetTime(hostClock))
    }

    private func startHostValid() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startHost.isValid
    }

    private func wallSecondsLocked() -> TimeInterval {
        guard startHost.isValid else { return 0 }
        let now = CMClockGetTime(hostClock)
        return max(0, CMTimeGetSeconds(CMTimeSubtract(now, startHost)))
    }
}

private extension CMTime {
    var isValid: Bool { flags.contains(.valid) }
}
