import CryptoKit
import Foundation

/// Display-only trial and optional offline Ed25519 license. Never called from
/// the Record path — a missing or expired trial must not block capture.
enum LicenseStore {
    static let trialDays = 14
    /// Offline verify key. The matching private key is not in this tree.
    static let publicKeyHex = "3b40698361154af35c5625750e53028671d681859a9aecd36a78b5c9dce75782"

    enum Status: Equatable {
        case trial(daysRemaining: Int)
        case trialEnded
        case licensed(label: String)
        case invalidKey

        var settingsLine: String {
            switch self {
            case .trial(let days):
                return "Local trial — \(days) day\(days == 1 ? "" : "s") remaining. Record is never gated."
            case .trialEnded:
                return "Local trial ended. Record still works. Paste a signed license when you have one."
            case .licensed(let label):
                return "Licensed\(label.isEmpty ? "" : " — \(label)"). Record is never gated."
            case .invalidKey:
                return "License key did not verify. Record still works."
            }
        }
    }

    private static let firstLaunchName = "first-launch.txt"
    private static let licenseName = "license.txt"

    static func status() -> Status {
        if let stored = readLicenseBlob(), !stored.isEmpty {
            if let label = verify(stored) {
                return .licensed(label: label)
            }
            return .invalidKey
        }
        let remaining = trialDaysRemaining()
        if remaining > 0 {
            return .trial(daysRemaining: remaining)
        }
        return .trialEnded
    }

    static func trialDaysRemaining() -> Int {
        let start = firstLaunchDate()
        let elapsed = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
        return max(0, trialDays - elapsed)
    }

    @discardableResult
    static func applyLicenseKey(_ raw: String) -> Status {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: supportURL.appendingPathComponent(licenseName))
            return status()
        }
        writeSupportFile(name: licenseName, text: trimmed)
        return status()
    }

    static func firstLaunchDate() -> Date {
        let url = supportURL.appendingPathComponent(firstLaunchName)
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let interval = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Date(timeIntervalSince1970: interval)
        }
        let now = Date()
        writeSupportFile(name: firstLaunchName, text: String(now.timeIntervalSince1970))
        return now
    }

    /// Payload is `label|unixExpires` (expires 0 = never) then `.` then
    /// base64url Ed25519 signature of the UTF-8 payload.
    static func verify(_ blob: String) -> String? {
        let parts = blob.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let payload = String(parts[0])
        guard let signature = decodeBase64URL(String(parts[1])) else { return nil }
        guard let key = publicKey() else { return nil }
        guard let message = payload.data(using: .utf8) else { return nil }
        guard key.isValidSignature(signature, for: message) else { return nil }
        let fields = payload.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count >= 2, let expires = TimeInterval(fields[1]) else { return nil }
        if expires > 0, Date(timeIntervalSince1970: expires) < Date() {
            return nil
        }
        return String(fields[0])
    }

    private static func publicKey() -> Curve25519.Signing.PublicKey? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var hex = publicKeyHex
        while hex.count >= 2 {
            let byte = hex.prefix(2)
            hex.removeFirst(2)
            guard let value = UInt8(byte, radix: 16) else { return nil }
            bytes.append(value)
        }
        guard bytes.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    }

    private static func decodeBase64URL(_ text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 {
            padded.append("=")
        }
        return Data(base64Encoded: padded)
    }

    private static func readLicenseBlob() -> String? {
        let url = supportURL.appendingPathComponent(licenseName)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScrumTrace", isDirectory: true)
    }

    private static func writeSupportFile(name: String, text: String) {
        let dir = supportURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
