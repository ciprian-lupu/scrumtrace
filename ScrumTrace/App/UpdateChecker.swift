import Foundation

/// v1 update check against GitHub Releases. Sparkle is not an SPM dependency
/// here — a Mac checkout cannot resolve a new package graph in this environment.
enum UpdateChecker {
    static let releasesURL = URL(string: "https://github.com/ciprian-lupu/scrumtrace/releases")!
    static let latestAPI = URL(string: "https://api.github.com/repos/ciprian-lupu/scrumtrace/releases/latest")!

    enum Result: Equatable {
        case upToDate(current: String)
        case noPublishedReleases(current: String)
        case newerAvailable(current: String, latest: String)
        case failed(String)

        var settingsLine: String {
            switch self {
            case .noPublishedReleases(let current):
                return "No GitHub release has been published yet (this build is \(current))."
            case .upToDate(let current):
                return "\(current) is the latest published tag."
            case .newerAvailable(let current, let latest):
                return "\(latest) is available (this build is \(current))."
            case .failed(let message):
                return message
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static func check() async -> Result {
        var request = URLRequest(url: latestAPI)
        request.setValue("ScrumTrace/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("GitHub returned an invalid response.")
            }
            return interpret(data: data, statusCode: http.statusCode, current: currentVersion)
        } catch {
            return .failed(AgentLog.sanitize(error.localizedDescription))
        }
    }

    static func interpret(data: Data, statusCode: Int, current: String) -> Result {
        if statusCode == 404 { return .noPublishedReleases(current: current) }
        guard (200..<300).contains(statusCode) else {
            return .failed("Could not check updates (GitHub HTTP \(statusCode)).")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("GitHub releases response was not JSON.")
        }
        let tag = (json["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) ?? ""
        guard !tag.isEmpty else { return .failed("Latest release has no tag.") }
        if compareVersions(current, tag) < 0 {
            return .newerAvailable(current: current, latest: tag)
        }
        return .upToDate(current: current)
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a < b { return -1 }
            if a > b { return 1 }
        }
        return 0
    }
}
