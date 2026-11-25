import CryptoKit
import Foundation

public enum DevlyMode: String, CaseIterable, Identifiable, Sendable {
    case base64 = "Base64"
    case json = "JSON"
    case sha256 = "SHA256"
    case jwt = "JWT"
    case url = "URL"
    case uuid = "UUID"

    public var id: String { rawValue }
}

/// Pure Swift developer Swiss Army knife inspired by Droppy's Devly droplet:
/// Base64, JSON pretty/minify, SHA-256 hashes, JWT payload decoding, URL encode/decode, and UUIDs.
public enum DevlyTools {
    public static func encode(_ input: String, mode: DevlyMode) -> String {
        switch mode {
        case .base64:
            return Data(input.utf8).base64EncodedString()
        case .json:
            return formatJSON(input, pretty: true)
        case .sha256:
            let digest = SHA256.hash(data: Data(input.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        case .jwt:
            return decodeJWT(input)
        case .url:
            return input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        case .uuid:
            return UUID().uuidString.lowercased()
        }
    }

    public static func decode(_ input: String, mode: DevlyMode) -> String {
        switch mode {
        case .base64:
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
                  let text = String(data: data, encoding: .utf8) else {
                return "Base64 inválido"
            }
            return text
        case .json:
            return formatJSON(input, pretty: false)
        case .sha256:
            return encode(input, mode: .sha256)
        case .jwt:
            return decodeJWT(input)
        case .url:
            return input.removingPercentEncoding ?? input
        case .uuid:
            return UUID().uuidString.lowercased()
        }
    }

    private static func formatJSON(_ raw: String, pretty: Bool) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return "JSON inválido"
        }
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: opts),
              let text = String(data: out, encoding: .utf8) else {
            return raw
        }
        return text
    }

    private static func decodeJWT(_ token: String) -> String {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count >= 2 else { return "Token JWT inválido" }

        func decodePart(_ segment: Substring) -> String? {
            var base64 = segment
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let rem = base64.count % 4
            if rem > 0 { base64.append(String(repeating: "=", count: 4 - rem)) }
            guard let data = Data(base64Encoded: base64) else { return nil }
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: pretty, encoding: .utf8) {
                return str
            }
            return String(data: data, encoding: .utf8)
        }

        let payload = decodePart(parts[1]) ?? "Payload ilegible"
        return payload
    }
}
