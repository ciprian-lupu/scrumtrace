import Foundation

struct OpenAICompatibleClient: AIProvider {
    let configuration: AIProviderConfiguration
    var kind: AIProviderKind { .openaiCompatible }

    func evaluate(request: SliceEvaluationRequest) async throws -> CandidateEvaluationResponse {
        try configuration.validate()
        _ = ProviderWireMedia.mp4BodyURL(configuration: configuration, request: request)
        if ProviderWireMedia.willUploadClip(configuration: configuration) {
            throw AIProviderError.invalidURL("This adapter does not upload clip video.")
        }
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIProviderError.missingAPIKey }
        let url = try Self.chatCompletionsURL(baseURL: configuration.baseURL)

        var content: [[String: Any]] = [
            ["type": "text", "text": request.userPrompt]
        ]
        if configuration.acceptsImages {
            for payload in request.imagePayloads {
                content.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(payload.mime);base64,\(payload.base64)"]
                ])
            }
        }

        // DeepSeek Chat Completions accepts json_object, not OpenAI json_schema.
        // Thinking is on by default and can leave message.content empty.
        var body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": content]
            ]
        ]
        if Self.isDeepSeekEndpoint(configuration.baseURL) {
            body["response_format"] = ["type": "json_object"]
            body["thinking"] = ["type": "disabled"]
        } else {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "scrumtrace_candidates",
                    "strict": true,
                    "schema": EvaluationJSONSchema.openaiStructured
                ]
            ]
        }

        var requestHTTP = URLRequest(url: url)
        requestHTTP.httpMethod = "POST"
        requestHTTP.timeoutInterval = 90
        requestHTTP.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requestHTTP.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        requestHTTP.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: requestHTTP)
        try HTTPStatus.throwIfNeeded(response, data: data)
        let envelope = try JSONDecoder().decode(ChatEnvelope.self, from: data)
        guard let text = envelope.choices.first?.message.content, !text.isEmpty else {
            throw AIProviderError.emptyResponse
        }
        return try JSONExtractor.decodeCandidates(from: text)
    }

    static func isDeepSeekEndpoint(_ baseURL: String) -> Bool {
        let lowered = baseURL.lowercased()
        if let host = URL(string: baseURL)?.host?.lowercased() {
            return host == "api.deepseek.com" || host.hasSuffix(".deepseek.com")
        }
        return lowered.contains("api.deepseek.com")
    }

    /// Hive chat completions live at `/api/v3`, not `/v1`.
    static func isHiveEndpoint(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else {
            return false
        }
        return host == "api.thehive.ai" || (host.hasPrefix("api-") && host.hasSuffix(".thehive.ai"))
    }

    static func chatCompletionsURL(baseURL: String) throws -> URL {
        let root = try ProviderEndpoint.requireHTTPSOrLocal(baseURL)
            .absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versionedRoot: String
        if isHiveEndpoint(baseURL) || isHiveEndpoint(root) {
            if root.hasSuffix("/api/v3") || root.hasSuffix("/v3") {
                versionedRoot = root
            } else {
                versionedRoot = "\(root)/api/v3"
            }
        } else {
            versionedRoot = root.hasSuffix("/v1") ? root : "\(root)/v1"
        }
        guard let url = URL(string: "\(versionedRoot)/chat/completions") else {
            throw AIProviderError.invalidURL(baseURL)
        }
        return url
    }
}

private struct ChatEnvelope: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
    }
    var choices: [Choice]
}

enum HTTPStatus {
    static func throwIfNeeded(_ response: URLResponse, data _: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // Provider bodies are untrusted and can echo request content. Keep
            // them out of errors because those errors feed diagnostics and
            // offline-review copy.
            throw AIProviderError.httpStatus(http.statusCode, "Request rejected.")
        }
    }
}
