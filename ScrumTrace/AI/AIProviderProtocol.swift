#if os(macOS)
import AppKit
#endif
import Foundation

protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    func evaluate(request: SliceEvaluationRequest) async throws -> CandidateEvaluationResponse
}

struct SliceEvaluationRequest: Sendable {
    var product: ProductContext
    var slice: SliceRecord
    var transcriptExcerpt: String
    var shotNote: String
    var windowContext: String
    var imageURLs: [URL]
}

enum AIProviderError: LocalizedError {
    case missingAPIKey
    case invalidURL(String)
    case httpStatus(Int, String)
    case emptyResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is missing. Add it in Settings."
        case .invalidURL(let value):
            return "Invalid provider URL: \(value)"
        case .httpStatus(let code, let body):
            return "Provider HTTP \(code): \(body)"
        case .emptyResponse:
            return "Provider returned an empty response."
        case .decoding(let message):
            return "Could not decode provider JSON: \(message)"
        }
    }
}

enum AIEngine {
    static func make(configuration: AIProviderConfiguration) -> any AIProvider {
        switch configuration.kind {
        case .openaiCompatible:
            return OpenAICompatibleClient(configuration: configuration)
        case .anthropic:
            return AnthropicClient(configuration: configuration)
        case .google:
            return GoogleClient(configuration: configuration)
        }
    }
}

enum JSONExtractor {
    static func decodeCandidates(from text: String) throws -> CandidateEvaluationResponse {
        let trimmed = stripFences(text)
        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(CandidateEvaluationResponse.self, from: data) {
            return parsed
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else {
            throw AIProviderError.decoding("No JSON object in model output.")
        }
        let blob = String(trimmed[start...end])
        guard let data = blob.data(using: .utf8) else {
            throw AIProviderError.decoding("JSON blob was not UTF-8.")
        }
        do {
            return try JSONDecoder().decode(CandidateEvaluationResponse.self, from: data)
        } catch {
            throw AIProviderError.decoding(error.localizedDescription)
        }
    }

    static func stripFences(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = value.replacingOccurrences(of: "```json", with: "")
            value = value.replacingOccurrences(of: "```", with: "")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ImageBase64 {
    static func jpegPayload(url: URL, maxEdge: CGFloat = 1440) -> (mime: String, base64: String)? {
        #if os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let bitmap = NSImage(size: target)
        bitmap.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        bitmap.unlockFocus()
        guard let tiff = bitmap.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            return nil
        }
        return ("image/jpeg", jpeg.base64EncodedString())
        #else
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ("image/jpeg", data.base64EncodedString())
        #endif
    }
}
