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
    /// Present when the slice has a clip on disk. Adapters must not upload it unless `accepts_video`.
    var clipURL: URL?
    /// Session root used to refuse stills whose path walks a planted symlink.
    var sessionURL: URL
}

enum AIProviderError: LocalizedError {
    case missingAPIKey
    case invalidURL(String)
    case httpStatus(Int, String)
    case emptyResponse
    case decoding(String)
    /// Slice had nothing the adapter can send (no still, no wired MP4, no excerpt).
    case skippedNoSendableMedia
    /// Model returned only `drop` / empty `candidates[]` for a slice that still has media (D7).
    case noKeepableCandidate

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
        case .skippedNoSendableMedia:
            return "No still was available and clip video is not uploaded."
        case .noKeepableCandidate:
            return "Provider returned no keepable candidate for this slice."
        }
    }

    /// Gate 5: after 401/403, remaining slices must not upload stills or transcript.
    var isAuthFailure: Bool {
        switch self {
        case .missingAPIKey:
            return true
        case .httpStatus(let code, _):
            return code == 401 || code == 403
        case .invalidURL, .emptyResponse, .decoding, .skippedNoSendableMedia, .noKeepableCandidate:
            return false
        }
    }

    static func isAuthFailure(_ error: Error) -> Bool {
        (error as? AIProviderError)?.isAuthFailure == true
    }
}

enum ProviderWireMedia {
    /// Shipped adapters have no MP4 mapping. Stay false until a client returns a body URL.
    static let adaptersUploadVideo = false

    /// What actually leaves the Mac: capability flag **and** a wired adapter mapping.
    static func willUploadClip(configuration: AIProviderConfiguration) -> Bool {
        configuration.acceptsVideo && adaptersUploadVideo
    }

    /// Clip file bytes that may be placed on the HTTP body.
    /// Always nil unless `accepts_video` is true **and** the adapter has an MP4
    /// mapping. Shipped adapters have none — they send stills + transcript only.
    static func mp4BodyURL(configuration: AIProviderConfiguration, request: SliceEvaluationRequest) -> URL? {
        guard willUploadClip(configuration: configuration) else { return nil }
        guard request.clipURL != nil else { return nil }
        return nil
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
        if let data = trimmed.data(using: .utf8) {
            if let parsed = try? JSONDecoder().decode(CandidateEvaluationResponse.self, from: data) {
                return parsed
            }
            if let lossy = try? decodeLossy(from: data), !lossy.candidates.isEmpty {
                return lossy
            }
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
            if let lossy = try? decodeLossy(from: data), !lossy.candidates.isEmpty {
                return lossy
            }
            throw AIProviderError.decoding(error.localizedDescription)
        }
    }

    /// One malformed candidate must not fail the whole slice (C5: model JSON is untrusted).
    static func decodeLossy(from data: Data) throws -> CandidateEvaluationResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.decoding("No JSON object in model output.")
        }
        let list = obj["candidates"] as? [Any] ?? []
        let decoder = JSONDecoder()
        var candidates: [CandidateRecord] = []
        for item in list {
            guard JSONSerialization.isValidJSONObject(item),
                  let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let record = try? decoder.decode(CandidateRecord.self, from: itemData) else {
                continue
            }
            candidates.append(record)
        }
        return CandidateEvaluationResponse(candidates: candidates)
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
    #if os(macOS)
    static func jpegData(from image: NSImage, maxEdge: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
    #endif

    static func jpegPayload(url: URL, sessionRoot: URL, maxEdge: CGFloat = 1440) -> (mime: String, base64: String)? {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        if ExportRel.parentIsSymbolicLink(url) {
            return nil
        }
        guard let rel = ExportRel.unfollowedRelative(url, sessionRoot: sessionRoot),
              !ExportRel.containsSymlinkComponent(rel, sessionURL: sessionRoot) else {
            return nil
        }
        guard ExportRel.isReadableSessionFile(url, sessionRoot: sessionRoot) else { return nil }
        guard let data = ExportRel.readContainedData(url, sessionRoot: sessionRoot) else { return nil }
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        guard let jpeg = jpegData(from: image, maxEdge: maxEdge, quality: 0.82) else { return nil }
        return ("image/jpeg", jpeg.base64EncodedString())
        #else
        return ("image/jpeg", data.base64EncodedString())
        #endif
    }
}
