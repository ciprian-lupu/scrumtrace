import Foundation

/// Progress belongs to the named operation, never an estimated percentage of the whole pipeline.
struct ProcessingProgress: Equatable, Sendable {
    let id: UUID
    var message: String
    var fraction: Double?
    let startedAt: Date
    var elapsedSeconds: Int

    init(message: String, fraction: Double? = nil, startedAt: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.message = message
        self.fraction = Self.validFraction(fraction)
        self.startedAt = startedAt
        self.elapsedSeconds = 0
    }

    static func validFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }
    var elapsedLabel: String {
        elapsedSeconds < 60 ? "\(elapsedSeconds)s" : "\(elapsedSeconds / 60)m \(elapsedSeconds % 60)s"
    }
    var statusLine: String {
        [percent.map { "\($0)%" }, message, elapsedLabel].compactMap { $0 }.joined(separator: " · ")
    }
    var compactLabel: String { percent.map { "\($0)%" } ?? elapsedLabel }

    func refreshed(at now: Date) -> Self {
        var value = self
        value.elapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return value
    }
}

/// Worker callbacks publish only technical progress, without transcript text or model credentials.
final class ProcessingProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var activities: [ProcessingProgress] = []

    var snapshot: ProcessingProgress? {
        lock.lock()
        defer { lock.unlock() }
        return activities.last
    }

    @discardableResult
    func begin(_ message: String) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let progress = ProcessingProgress(message: message)
        activities.append(progress)
        return progress.id
    }

    func update(_ id: UUID, fraction: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = activities.indices.last, activities[index].id == id else { return }
        var current = activities[index]
        let fraction = ProcessingProgress.validFraction(fraction)
        // Model callbacks can arrive out of order. A completed operation never regresses.
        if let fraction {
            current.fraction = max(current.fraction ?? 0, fraction)
            activities[index] = current
        }
    }

    func end(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        activities.removeAll { $0.id == id }
    }
}
