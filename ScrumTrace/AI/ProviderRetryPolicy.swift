import Foundation

/// When one provider call is tried again inside a processing run.
///
/// A single 429, 5xx, dropped connection or local-agent hiccup used to mark the slice failed and the whole recording
/// "needs review" until someone clicked Retry Analysis. A call that fails for a reason that usually passes on a second
/// try is now repeated a bounded number of times. Sign-in failures, refused input and anything deterministic are never
/// repeated, and a run has a fixed budget of extra attempts so an outage cannot multiply its length.
struct ProviderRetryPolicy: Sendable, Equatable {
    /// Calls per request, the first one included.
    var maxAttempts: Int
    /// Seconds to wait before the second, third, … attempt. The last value repeats.
    var delays: [TimeInterval]
    /// Extra attempts one evaluation run may spend across all of its requests.
    var runBudget: Int

    /// Three attempts per call, 2 s then 6 s apart, at most four extra attempts in a run.
    static let standard = ProviderRetryPolicy(maxAttempts: 3, delays: [2, 6], runBudget: 4)
    /// One attempt per call.
    static let none = ProviderRetryPolicy(maxAttempts: 1, delays: [], runBudget: 0)

    /// Seconds to wait before `attempt`, where 2 is the first repeat.
    func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 2, let last = delays.last else { return 0 }
        let index = attempt - 2
        return max(0, index < delays.count ? delays[index] : last)
    }

    /// True for failures that usually pass on a second try: rate limits, server errors, HTTP timeouts, a dropped
    /// network and a local agent that exited without a result. A local agent that ran into its own three-minute
    /// timeout is not repeated: a second wait of that length rarely helps and would stretch an outage.
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        // 401 / 403 / sign-in: the remaining uploads of the run are stopped, never repeated (Gate 5).
        if AIProviderError.isAuthFailure(error) { return false }
        // The evidence changed between attempts: refused before upload, and repeating cannot change that.
        if error is ComparisonInputError { return false }
        if let local = error as? LocalAgentError {
            switch local {
            case .failed:
                return true
            case .timedOut, .notInstalled, .signInRequired, .outputTooLarge, .unsupported:
                return false
            }
        }
        if let provider = error as? AIProviderError {
            switch provider {
            case .httpStatus(let code, _):
                return code == 408 || code == 429 || (500...599).contains(code)
            case .missingAPIKey, .invalidURL, .emptyResponse, .decoding, .skippedNoSendableMedia, .noKeepableCandidate:
                return false
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}
