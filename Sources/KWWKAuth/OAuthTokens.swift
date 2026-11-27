import Foundation

// MARK: - Helpers

public enum OAuth {
    /// Safety margin subtracted from every token expiry so callers refresh
    /// slightly early.
    public static let expiryMarginMs: Int64 = 5 * 60 * 1000

    /// Decode a JWT's `exp` claim (Unix seconds) into an expiry in Unix
    /// milliseconds, subtracting a 5-minute safety margin so callers refresh
    /// slightly early. Returns nil for non-JWT / unparseable tokens.
    public static func jwtExpiryMillis(_ token: String) -> Int64? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let exp: Double?
        if let v = obj["exp"] as? Double { exp = v }
        else if let v = obj["exp"] as? Int { exp = Double(v) }
        else { exp = nil }
        guard let exp else { return nil }
        return Int64(exp * 1000) - expiryMarginMs
    }

    public struct TokenResponse: Decodable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: Int
        public let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }

        /// `expires_in` is optional per RFC 6749 §4.2.2 and xAI omits it when
        /// the lifetime is the default; fall back to one hour rather than
        /// failing the whole token decode.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try c.decode(String.self, forKey: .accessToken)
            refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
            expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 3600
            scope = try c.decodeIfPresent(String.self, forKey: .scope)
        }
    }

    public static func decodeTokenResponse(_ data: Data) throws -> TokenResponse {
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw OAuthError.invalidResponse("could not decode OAuth token response: \(body)")
        }
    }

    public static func urlEncodedForm(_ params: [String: String]) -> String {
        params.keys.sorted().map { key -> String in
            let v = params[key] ?? ""
            let encKey = key.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? key
            let encVal = v.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? v
            return "\(encKey)=\(encVal)"
        }.joined(separator: "&")
    }

    /// RFC 3986 unreserved characters. `application/x-www-form-urlencoded`
    /// wants everything outside this set percent-encoded, including colons
    /// (important for device-flow grants that carry a URN).
    private static let formAllowed: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s
    }()
}
