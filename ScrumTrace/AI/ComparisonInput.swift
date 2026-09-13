import CryptoKit
import Foundation

/// The semantic input is identical across adapters; their HTTP envelopes differ.
/// Only SHA-256 fingerprints leave this runtime through the session manifest.
struct ComparisonInput: Codable, Sendable, Equatable {
    struct Image: Codable, Sendable, Equatable {
        var mime: String
        var base64: String
    }
    var systemPrompt: String
    var userPrompt: String
    var images: [Image]

    init(request: SliceEvaluationRequest) {
        systemPrompt = request.systemPrompt
        userPrompt = request.userPrompt
        images = request.imagePayloads
    }

    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

actor ComparisonInputCache {
    private var inputs: [String: ComparisonInput] = [:]
    private var fingerprints: [String: String] = [:]
    private var failures: [String: String] = [:]
    private let expected: [String: Set<String>]

    init(slices: [SliceRecord]) {
        expected = Dictionary(uniqueKeysWithValues: slices.map {
            ($0.sliceId, Set($0.serviceEvaluations.compactMap(\.inputFingerprint)))
        })
    }

    func prepare(_ request: SliceEvaluationRequest) throws -> SliceEvaluationRequest {
        let input = ComparisonInput(request: request)
        let digest = try input.fingerprint()
        let sliceID = request.slice.sliceId
        let previous = expected[sliceID] ?? []
        guard previous.isEmpty || previous == [digest],
              fingerprints[sliceID] == nil || fingerprints[sliceID] == digest else {
            failures[sliceID] = "comparison_input_changed"
            throw ComparisonInputError.changed
        }
        inputs[sliceID] = inputs[sliceID] ?? input
        fingerprints[sliceID] = digest
        var frozen = request
        frozen.preparedInput = inputs[sliceID]
        frozen.clipURL = nil
        return frozen
    }

    func diagnostic(for sliceID: String) -> String? { failures[sliceID] }

    func fingerprint(for sliceID: String) -> String? { fingerprints[sliceID] }
}

enum ComparisonInputError: LocalizedError {
    case changed
    var errorDescription: String? {
        "Comparison input changed since an earlier attempt. Results were preserved and no changed input was uploaded. Start a new recording to compare the revised evidence."
    }
}

struct ComparisonProvider: AIProvider {
    var provider: any AIProvider
    var cache: ComparisonInputCache
    var kind: AIProviderKind { provider.kind }
    func evaluate(request: SliceEvaluationRequest) async throws -> CandidateEvaluationResponse {
        let frozen = try await cache.prepare(request)
        return try await provider.evaluate(request: frozen)
    }
}
