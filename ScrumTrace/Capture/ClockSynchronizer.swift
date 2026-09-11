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

    static func isInsidePause(wall: TimeInterval, pauses: [PauseInterval]) -> Bool {
        pauses.contains { pause in
            pause.pauseWall <= wall && wall < (pause.resumeWall ?? .infinity)
        }
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
    private var stoppedWall: TimeInterval?

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
        stoppedWall = nil
    }

    func markRecordingStarted() {
        lock.lock()
        defer { lock.unlock() }
        startHost = CMClockGetTime(hostClock)
        pauses = []
        recording = true
        stoppedWall = nil
    }

    func currentWallSeconds() -> TimeInterval {
        lock.lock()
        let start = startHost
        let stopped = stoppedWall
        lock.unlock()
        guard start.isValid else { return 0 }
        if let stopped {
            return stopped
        }
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

    /// Freeze wall/media at Stop so writer teardown is not part of the session duration.
    func markRecordingStopped() {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        let wall = wallSecondsLocked()
        if var last = pauses.last, last.resumeWall == nil {
            last.close(at: wall)
            pauses[pauses.count - 1] = last
        }
        recording = false
        stoppedWall = wall
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

    func mediaTime(forSampleBuffer buffer: CMSampleBuffer, sampleClock: CMClock? = nil) -> CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid, startHostValid() else {
            return mediaTime(forHostTime: CMClockGetTime(hostClock))
        }
        // D2: convert SCStream PTS onto CMClockGetHostTimeClock() before t_media.
        // Host→host is a no-op; pass stream.synchronizationClock when the
        // sample clock is not already the host clock.
        let fromClock = sampleClock ?? CMClockGetHostTimeClock()
        let aligned = CMSyncConvertTime(pts, from: fromClock, to: hostClock)
        let source = aligned.isValid ? aligned : pts
        return mediaTime(forHostTime: source)
    }

    private func startHostValid() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startHost.isValid
    }

    func isInsidePause(hostTime: CMTime) -> Bool {
        lock.lock()
        let start = startHost
        let localPauses = pauses
        lock.unlock()
        guard start.isValid else { return false }
        let wall = CMTimeGetSeconds(CMTimeSubtract(hostTime, start))
        return TimelineMath.isInsidePause(wall: wall, pauses: localPauses)
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
