import Foundation

struct ProviderPingResult: Sendable, Equatable {
    var replyPreview: String
    var elapsedMs: Int
}

/// One-word online probe for Settings. Does not send meeting stills or transcripts.
enum AIConnectionTest {
    static let prompt = "Reply with the single word pong."

    static func run(configuration: AIProviderConfiguration) async throws -> ProviderPingResult {
        try configuration.validate()
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIProviderError.missingAPIKey }
        let started = Date()
        let text: String
        switch configuration.kind {
        case .openaiCompatible:
            text = try await pingOpenAICompatible(configuration, key: key)
        case .anthropic:
            text = try await pingAnthropic(configuration, key: key)
        case .google:
            text = try await pingGoogle(configuration, key: key)
        }
        let preview = sanitizePreview(text)
        guard !preview.isEmpty else { throw AIProviderError.emptyResponse }
        return ProviderPingResult(
            replyPreview: preview,
            elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    static func userMessage(for error: Error) -> String {
        if let validation = error as? SettingsValidationError {
            return validation.localizedDescription
        }
        guard let providerError = error as? AIProviderError else {
            return "Could not reach the provider."
        }
        switch providerError {
        case .missingAPIKey:
            return "Save an API key first, or paste one above and test before saving."
        case .invalidURL:
            return "The endpoint is not a usable HTTPS API root."
        case .httpStatus(let code, _):
            switch code {
            case 401, 403:
                return "The key was rejected (HTTP \(code)). Check that it belongs to this endpoint."
            case 404:
                return "Endpoint or model was not found (HTTP 404). Check the model ID."
            case 429:
                return "The provider rate-limited this test (HTTP 429). Try again shortly."
            default:
                return "The provider rejected the test (HTTP \(code))."
            }
        case .emptyResponse:
            return "The key was accepted but the model returned no text."
        case .decoding:
            return "The provider replied, but the response was not readable text."
        case .skippedNoSendableMedia, .noKeepableCandidate:
            return "Could not run the connection test."
        }
    }

    static func successLine(result: ProviderPingResult, model: String) -> String {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = String(format: "%.1f", Double(result.elapsedMs) / 1000)
        return "Key accepted. \(name) replied “\(result.replyPreview)” in \(seconds)s."
    }

    static func sanitizePreview(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 48 {
            return collapsed
        }
        return String(collapsed.prefix(48)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func pingOpenAICompatible(
        _ configuration: AIProviderConfiguration,
        key: String
    ) async throws -> String {
        let root = try ProviderEndpoint.requireHTTPSOrLocal(configuration.baseURL)
            .absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versionedRoot = root.hasSuffix("/v1") ? root : "\(root)/v1"
        guard let url = URL(string: "\(versionedRoot)/chat/completions") else {
            throw AIProviderError.invalidURL(configuration.baseURL)
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "max_tokens": 16,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        if OpenAICompatibleClient.isDeepSeekEndpoint(configuration.baseURL) {
            body["thinking"] = ["type": "disabled"]
        }
        let data = try await postJSON(
            url: url,
            headers: [
                "Authorization": "Bearer \(key)"
            ],
            body: body
        )
        let envelope = try JSONDecoder().decode(OpenAIPingEnvelope.self, from: data)
        return envelope.choices.first?.message.content ?? ""
    }

    private static func pingAnthropic(
        _ configuration: AIProviderConfiguration,
        key: String
    ) async throws -> String {
        let root = try ProviderEndpoint.requireHTTPSOrLocal(configuration.baseURL)
            .absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versionedRoot = root.hasSuffix("/v1") ? root : "\(root)/v1"
        guard let url = URL(string: "\(versionedRoot)/messages") else {
            throw AIProviderError.invalidURL(configuration.baseURL)
        }
        let data = try await postJSON(
            url: url,
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01"
            ],
            body: [
                "model": configuration.model,
                "max_tokens": 16,
                "temperature": 0,
                "messages": [
                    ["role": "user", "content": prompt]
                ]
            ]
        )
        let envelope = try JSONDecoder().decode(AnthropicPingEnvelope.self, from: data)
        return envelope.content.compactMap(\.text).joined(separator: " ")
    }

    private static func pingGoogle(
        _ configuration: AIProviderConfiguration,
        key: String
    ) async throws -> String {
        let root = try ProviderEndpoint.requireHTTPSOrLocal(configuration.baseURL)
            .absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedModel = configuration.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? configuration.model
        guard let url = URL(string: "\(root)/v1beta/models/\(encodedModel):generateContent") else {
            throw AIProviderError.invalidURL(configuration.baseURL)
        }
        let data = try await postJSON(
            url: url,
            headers: [
                "x-goog-api-key": key
            ],
            body: [
                "contents": [
                    ["role": "user", "parts": [["text": prompt]]]
                ],
                "generationConfig": [
                    "temperature": 0,
                    "maxOutputTokens": 16
                ]
            ]
        )
        let envelope = try JSONDecoder().decode(GooglePingEnvelope.self, from: data)
        return (envelope.candidates ?? [])
            .compactMap(\.content)
            .flatMap { $0.parts ?? [] }
            .compactMap(\.text)
            .joined(separator: " ")
    }

    private static func postJSON(
        url: URL,
        headers: [String: String],
        body: [String: Any]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPStatus.throwIfNeeded(response, data: data)
        return data
    }
}

private struct OpenAIPingEnvelope: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
    }
    var choices: [Choice]
}

private struct AnthropicPingEnvelope: Decodable {
    struct Block: Decodable { var text: String? }
    var content: [Block]
}

private struct GooglePingEnvelope: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { var text: String? }
            var parts: [Part]?
        }
        var content: Content?
    }
    var candidates: [Candidate]?
}
