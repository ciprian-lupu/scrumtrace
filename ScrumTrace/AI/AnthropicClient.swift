import Foundation

struct AnthropicClient: AIProvider {
    let configuration: AIProviderConfiguration
    var kind: AIProviderKind { .anthropic }

    func evaluate(request: SliceEvaluationRequest) async throws -> CandidateEvaluationResponse {
        _ = ProviderWireMedia.mp4BodyURL(configuration: configuration, request: request)
        if configuration.kind == .anthropic && AIProviderConfiguration.isRetiredAnthropic(configuration.model) {
            throw AIProviderError.invalidURL("Retired Anthropic model \(configuration.model)")
        }
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIProviderError.missingAPIKey }
        let root = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/v1/messages") else {
            throw AIProviderError.invalidURL(configuration.baseURL)
        }

        var content: [[String: Any]] = [
            ["type": "text", "text": PromptTemplates.evaluationUserPrompt(
                product: request.product,
                slice: request.slice,
                transcript: request.transcriptExcerpt,
                shotNote: request.shotNote,
                windowContext: request.windowContext
            )]
        ]
        if configuration.acceptsImages {
            for imageURL in request.imageURLs.prefix(4) {
                if let payload = ImageBase64.jpegPayload(url: imageURL) {
                    content.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": payload.mime,
                            "data": payload.base64
                        ]
                    ])
                }
            }
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 4096,
            "temperature": 0.1,
            "system": PromptTemplates.system,
            "messages": [["role": "user", "content": content]]
        ]

        var requestHTTP = URLRequest(url: url)
        requestHTTP.httpMethod = "POST"
        requestHTTP.timeoutInterval = 90
        requestHTTP.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requestHTTP.setValue(key, forHTTPHeaderField: "x-api-key")
        requestHTTP.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        requestHTTP.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: requestHTTP)
        try HTTPStatus.throwIfNeeded(response, data: data)
        let envelope = try JSONDecoder().decode(AnthropicEnvelope.self, from: data)
        let text = envelope.content.compactMap(\.text).joined(separator: "\n")
        guard !text.isEmpty else { throw AIProviderError.emptyResponse }
        return try JSONExtractor.decodeCandidates(from: text)
    }
}

private struct AnthropicEnvelope: Decodable {
    struct Block: Decodable { var text: String? }
    var content: [Block]
}
