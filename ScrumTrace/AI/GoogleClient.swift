import Foundation

struct GoogleClient: AIProvider {
    let configuration: AIProviderConfiguration
    var kind: AIProviderKind { .google }

    func evaluate(request: SliceEvaluationRequest) async throws -> CandidateEvaluationResponse {
        _ = ProviderWireMedia.mp4BodyURL(configuration: configuration, request: request)
        if ProviderWireMedia.willUploadClip(configuration: configuration) {
            throw AIProviderError.invalidURL("This adapter does not upload clip video.")
        }
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIProviderError.missingAPIKey }
        let root = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = "\(root)/v1beta/models/\(configuration.model):generateContent"
        guard let url = URL(string: path) else {
            throw AIProviderError.invalidURL(configuration.baseURL)
        }

        var parts: [[String: Any]] = [
            ["text": PromptTemplates.system + "\n\n" + PromptTemplates.evaluationUserPrompt(
                product: request.product,
                slice: request.slice,
                transcript: request.transcriptExcerpt,
                shotNote: request.shotNote,
                windowContext: request.windowContext
            )]
        ]
        if configuration.acceptsImages {
            for imageURL in request.imageURLs.prefix(4) {
                if let payload = ImageBase64.jpegPayload(url: imageURL, sessionRoot: request.sessionURL) {
                    parts.append([
                        "inline_data": [
                            "mime_type": payload.mime,
                            "data": payload.base64
                        ]
                    ])
                }
            }
        }

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "temperature": 0.1,
                "responseMimeType": "application/json"
            ]
        ]

        var requestHTTP = URLRequest(url: url)
        requestHTTP.httpMethod = "POST"
        requestHTTP.timeoutInterval = 90
        requestHTTP.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requestHTTP.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        requestHTTP.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: requestHTTP)
        try HTTPStatus.throwIfNeeded(response, data: data)
        let envelope = try JSONDecoder().decode(GoogleEnvelope.self, from: data)
        let text = (envelope.candidates ?? [])
            .compactMap(\.content)
            .flatMap { $0.parts ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n")
        guard !text.isEmpty else { throw AIProviderError.emptyResponse }
        return try JSONExtractor.decodeCandidates(from: text)
    }
}

private struct GoogleEnvelope: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { var text: String? }
            var parts: [Part]?
        }
        var content: Content?
    }
    var candidates: [Candidate]?
}
