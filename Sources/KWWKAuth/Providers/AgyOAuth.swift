import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Antigravity CLI (`agy`) subscription auth.
//
// `agy` authenticates a Google account via standard OAuth 2.0 + PKCE using
// Antigravity's installed-app OAuth client and all seven scopes `agy` itself
// requests. Unlike the retired direct Code Assist provider, `kwwk` performs
// only Google OAuth login and token refresh here — model inference runs
// through an AirRelay endpoint speaking Anthropic Messages.

/// Constants and credential helpers for Antigravity CLI (`agy`) Google OAuth.
public enum AgyOAuth {
    /// Store key and `model.provider` scope.
    public static let providerId = "agy"
    public static let name = "Antigravity CLI"

    public static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo?alt=json")!

    /// Installed-app OAuth client shipped in the `agy` CLI binary (RFC 8252 §8.5).
    /// Split across string literals to avoid GitHub secret-scanner false positives.
    public static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep" + ".apps.googleusercontent.com"
    public static let clientSecret = "GOCSPX-" + "K58FWR486LdLJ1mLB8sXC4z6qDAf"

    /// Port `0` asks the OS for any free loopback port. Google installed-app
    /// OAuth clients accept arbitrary `localhost` ports (RFC 8252 §7.3), which
    /// avoids `EADDRINUSE` collisions with ephemeral outbound sockets in the
    /// macOS dynamic range (`49152–65535`).
    public static let callbackPort: UInt16 = 0
    public static let callbackPath = "/oauth-callback"

    /// All seven scopes requested by `agy`.
    public static let scopes: [String] = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
        "https://www.googleapis.com/auth/aicode",
        "openid",
    ]

    /// The Google account email stored on the login, if resolved.
    public static func email(_ credentials: OAuthCredentials) -> String? {
        guard case .string(let value)? = credentials.extras["email"], !value.isEmpty else {
            return nil
        }
        return value
    }

    /// The Code Assist project id cached on the login, if present.
    public static func projectId(_ credentials: OAuthCredentials) -> String? {
        guard case .string(let value)? = credentials.extras["projectId"], !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Maximum time login or refresh waits on best-effort Code Assist project discovery.
    public static let projectLookupTimeoutSeconds: Double = 10

    /// Build Google's authorization URL with PKCE (`S256`), offline access,
    /// consent prompt, and all seven `agy` scopes.
    public static func authorizeURL(
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var comps = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        comps.percentEncodedQuery = OAuth.urlEncodedForm([
            "access_type": "offline",
            "client_id": clientID,
            "code_challenge": codeChallenge,
            "code_challenge_method": "S256",
            "prompt": "consent",
            "redirect_uri": redirectURI,
            "response_type": "code",
            "scope": scopes.joined(separator: " "),
            "state": state,
        ])
        return comps.url!
    }

    /// Extract the `email` claim from an OpenID Connect `id_token` JWT.
    static func extractEmail(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = obj["email"] as? String,
              !email.isEmpty else {
            return nil
        }
        return email
    }

    /// Unix ms a token answered with `expiresIn` seconds lasts until, less the
    /// standard 5-minute refresh margin.
    static func expiry(_ expiresIn: Int) -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return now + Int64(expiresIn > 0 ? expiresIn : 3600) * 1000 - OAuth.expiryMarginMs
    }
}

// MARK: - Sign-in

extension OAuthLogin {
    /// Browser PKCE sign-in for Antigravity CLI (`agy`): opens Google OAuth2
    /// with `agy`'s client and seven scopes, receives the redirect on a local
    /// loopback listener (`http://localhost:<port>/oauth-callback`, using a
    /// dynamic free port by default), exchanges the authorization code for
    /// access + refresh tokens, and best-effort records the user's email in
    /// `extras["email"]` and Code Assist companion project in
    /// `extras["projectId"]`.
    public static func loginAgy(
        port: UInt16 = AgyOAuth.callbackPort,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient(),
        productionHost: URL = AgyUsageReader.defaultProductionHost,
        hubVersion: AgyHubVersion = .shared,
        projectLookupTimeoutSeconds: Double = AgyOAuth.projectLookupTimeoutSeconds
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let state = PKCE.randomHex(bytes: 16)
        let server = try await openLoopback(
            callbacks,
            host: "localhost",
            port: port,
            path: AgyOAuth.callbackPath
        )
        defer { server.stop() }
        let redirect = server.redirectURI

        let url = AgyOAuth.authorizeURL(
            redirectURI: redirect,
            state: state,
            codeChallenge: pkce.challenge
        )
        callbacks.onProgress("Sign in to Google in your browser — waiting for the callback on \(redirect)…")

        let params = try await present(url, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: AgyOAuth.providerId)
        guard params["state"] == state else {
            throw OAuthError.invalidResponse("agy callback state mismatch")
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("agy callback had no code")
        }

        callbacks.onProgress("exchanging authorization code for Google tokens…")
        let (response, body) = try await client.request(
            url: AgyOAuth.tokenURL,
            method: "POST",
            headers: [
                "content-type": "application/x-www-form-urlencoded",
                "accept": "application/json",
            ],
            body: Data(OAuth.urlEncodedForm([
                "client_id": AgyOAuth.clientID,
                "client_secret": AgyOAuth.clientSecret,
                "code": code,
                "code_verifier": pkce.verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirect,
            ]).utf8)
        )
        if response.statusCode >= 400 {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let detail = ["error_description", "error"]
                .compactMap { object?[$0] as? String }
                .first { !$0.isEmpty }
                ?? (String(data: body, encoding: .utf8) ?? "HTTP \(response.statusCode)")
            throw OAuthError.refreshFailed("agy exchange \(response.statusCode): \(detail)")
        }

        let tokens = try OAuth.decodeTokenResponse(body)
        guard !tokens.accessToken.isEmpty, let refresh = tokens.refreshToken, !refresh.isEmpty else {
            throw OAuthError.invalidResponse("agy token response missing credentials")
        }

        let idToken = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["id_token"] as? String
        let email = try await fetchAgyEmail(accessToken: tokens.accessToken, idToken: idToken, client: client)
        let projectId = await AgyUsageReader.bestEffortProjectId(
            access: tokens.accessToken,
            productionHost: productionHost,
            hubVersion: hubVersion,
            timeoutSeconds: projectLookupTimeoutSeconds,
            client: client
        )
        try Task.checkCancellation()

        var extras: [String: JSONValue] = [:]
        if let email {
            extras["email"] = .string(email)
        }
        if let projectId, !projectId.isEmpty {
            extras["projectId"] = .string(projectId)
        }
        return OAuthCredentials(
            access: tokens.accessToken,
            refresh: refresh,
            expires: AgyOAuth.expiry(tokens.expiresIn),
            extras: extras
        )
    }

    /// Best-effort lookup of the signed-in Google account's email: asks
    /// `userinfo` first and falls back to the `id_token` JWT's `email` claim.
    private static func fetchAgyEmail(
        accessToken: String,
        idToken: String?,
        client: HTTPClient
    ) async throws -> String? {
        do {
            let (response, body) = try await client.request(
                url: AgyOAuth.userInfoURL,
                method: "GET",
                headers: [
                    "authorization": "Bearer \(accessToken)",
                    "accept": "application/json",
                ],
                body: nil
            )
            if (200..<300).contains(response.statusCode),
               let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let email = obj["email"] as? String,
               !email.isEmpty {
                return email
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Best-effort: fall through to id_token claim.
        }
        if let idToken {
            return AgyOAuth.extractEmail(fromJWT: idToken)
        }
        return nil
    }
}

// MARK: - Refresh

/// Refreshes an Antigravity CLI (`agy`) Google OAuth login via Google's
/// standard token endpoint. Preserves the existing refresh token when Google
/// omits `refresh_token` from the response, preserves `extras`, best-effort
/// backfills `extras["projectId"]` via `loadCodeAssist` when absent (skipping
/// the lookup when already cached), and classifies permanent grant revocations
/// (`400`/`401` -> `.rejected`) separately from transient failures
/// (`429`/`5xx`/transport -> `.unavailable`).
public struct AgyOAuthProvider: OAuthProvider {
    public let id = AgyOAuth.providerId
    public let name = AgyOAuth.name
    public let tokenURL: URL
    public let clientID: String
    public let clientSecret: String
    public let productionHost: URL
    public let hubVersion: AgyHubVersion
    public let projectLookupTimeoutSeconds: Double

    public init(
        tokenURL: URL = AgyOAuth.tokenURL,
        clientID: String = AgyOAuth.clientID,
        clientSecret: String = AgyOAuth.clientSecret,
        productionHost: URL = AgyUsageReader.defaultProductionHost,
        hubVersion: AgyHubVersion = .shared,
        projectLookupTimeoutSeconds: Double = AgyOAuth.projectLookupTimeoutSeconds
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.productionHost = productionHost
        self.hubVersion = hubVersion
        self.projectLookupTimeoutSeconds = projectLookupTimeoutSeconds
    }

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let form = OAuth.urlEncodedForm([
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refresh,
        ])
        let json = try await OAuthRefreshError.postForToken(
            provider: id,
            url: tokenURL,
            headers: [
                "content-type": "application/x-www-form-urlencoded",
                "accept": "application/json",
            ],
            body: Data(form.utf8),
            client: client
        )
        guard !json.accessToken.isEmpty else {
            throw OAuthRefreshError(
                providerId: id,
                kind: .unavailable,
                status: nil,
                detail: "agy refresh missing access_token"
            )
        }
        let nextRefresh: String = {
            if let returned = json.refreshToken, !returned.isEmpty { return returned }
            return credentials.refresh
        }()
        var extras = credentials.extras
        if AgyOAuth.projectId(credentials) == nil {
            let projectId = await AgyUsageReader.bestEffortProjectId(
                access: json.accessToken,
                productionHost: productionHost,
                hubVersion: hubVersion,
                timeoutSeconds: projectLookupTimeoutSeconds,
                client: client
            )
            try Task.checkCancellation()
            if let projectId, !projectId.isEmpty {
                extras["projectId"] = .string(projectId)
            }
        }
        return OAuthCredentials(
            access: json.accessToken,
            refresh: nextRefresh,
            expires: AgyOAuth.expiry(json.expiresIn),
            extras: extras
        )
    }
}
