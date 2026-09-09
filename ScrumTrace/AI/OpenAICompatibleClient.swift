import Foundation

struct OpenAICompatibleClient: AIProvider {
    let configuration: AIProviderConfiguration
    var kind: AIProviderKind { .openaiCompatible }

    func evaluate(request: SliceEvaluationRequest) async throws -> CandidateEvaluationResponse {
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIProviderError.missingAPIKey }
        let root = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/v1/chat/completions") else {
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
                        "type": "image_url",
                        "image_url": ["url": "data:\(payload.mime);base64,\(payload.base64)"]
                    ])
                }
            }
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0.1,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": PromptTemplates.system],
                ["role": "user", "content": content]
            ]
        ]

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
}

private struct ChatEnvelope: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
    }
    var choices: [Choice]
}

enum HTTPStatus {
    static func throwIfNeeded(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.httpStatus(http.statusCode, String(body.prefix(400)))
        }
    }
}
