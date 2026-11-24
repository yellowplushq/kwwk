import Crypto
import Foundation
import Testing
@testable import KWWKAuth

@Suite("Antigravity CLI (agy) OAuth")
struct AgyOAuthTests {
    private func callbacks(
        presenter: RecordingPresenter,
        params: [String: String],
        echoState: Bool = true,
        made: LoopbackBox,
        recordedPort: (@Sendable (UInt16) -> Void)? = nil
    ) -> OAuthLogin.Callbacks {
        var callbacks = quietCallbacksBase
        callbacks.browser = presenter
        callbacks.loopback = { host, port, path in
            recordedPort?(port)
            let boundPort: UInt16 = port == 0 ? 49_152 : port
            let loopback = ScriptedLoopback(host: host, port: boundPort, path: path, params: params, echoState: echoState)
            presenter.loopback = loopback
            made.set(loopback)
            return loopback
        }
        return callbacks
    }

    private func formParams(from body: Data?) -> [String: String] {
        guard let body else { return [:] }
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let val = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            out[key] = val
        }
        return out
    }

    // MARK: - Authorize URL & PKCE login

    @Test("Authorize URL carries Google's v2 endpoint, PKCE S256, offline consent, client_id and all 7 agy scopes")
    func authorizeURLContainsAllSevenScopes() throws {
        let url = AgyOAuth.authorizeURL(
            redirectURI: "http://localhost:51121/oauth-callback",
            state: "state-123",
            codeChallenge: "challenge-abc"
        )
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.scheme == "https")
        #expect(comps.host == "accounts.google.com")
        #expect(comps.path == "/o/oauth2/v2/auth")

        let query = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == AgyOAuth.clientID)
        #expect(query["client_id"] == "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com")
        #expect(query["redirect_uri"] == "http://localhost:51121/oauth-callback")
        #expect(query["response_type"] == "code")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        #expect(query["code_challenge"] == "challenge-abc")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "state-123")

        let scopes = (query["scope"] ?? "").split(separator: " ").map(String.init)
        #expect(scopes == [
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile",
            "https://www.googleapis.com/auth/cclog",
            "https://www.googleapis.com/auth/experimentsandconfigs",
            "https://www.googleapis.com/auth/aicode",
            "openid",
        ])
        #expect(scopes.count == 7)
    }

    @Test("loginAgy requests a dynamic loopback port (0), uses the bound redirect_uri, exchanges code with PKCE verifier and saves userinfo email")
    func loginSuccessWithUserInfoEmail() async throws {
        #expect(AgyOAuth.callbackPort == 0)
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.access","refresh_token":"1//refresh","expires_in":3600}"#),
            .response(status: 200, body: #"{"email":"dev@example.com","name":"Dev"}"#),
        ])
        let presenter = RecordingPresenter()
        let made = LoopbackBox()
        let askedPortLock = NSLock()
        nonisolated(unsafe) var askedPort: UInt16?
        let before = Int64(Date().timeIntervalSince1970 * 1000)

        let credentials = try await OAuthLogin.loginAgy(
            callbacks: callbacks(
                presenter: presenter,
                params: ["code": "auth-code-42"],
                made: made,
                recordedPort: { port in askedPortLock.withLock { askedPort = port } }
            ),
            client: client
        )

        #expect(askedPortLock.withLock { askedPort } == 0)
        let loopback = try #require(made.value)
        #expect(loopback.redirectURI == "http://localhost:49152/oauth-callback")
        #expect(loopback.listened && loopback.stopped)

        let shownURL = try #require(presenter.shown.first)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: shownURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["redirect_uri"] == "http://localhost:49152/oauth-callback")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        #expect(query["client_id"] == AgyOAuth.clientID)
        let scopes = Set((query["scope"] ?? "").split(separator: " ").map(String.init))
        #expect(scopes == Set(AgyOAuth.scopes))

        // Verify token exchange request
        #expect(client.requestCount == 2)
        let tokenReq = client.requests[0]
        #expect(tokenReq.url == AgyOAuth.tokenURL)
        #expect(tokenReq.method == "POST")
        #expect(client.header("content-type", request: 0) == "application/x-www-form-urlencoded")

        let form = formParams(from: tokenReq.body)
        let verifier = try #require(form["code_verifier"])
        #expect(!verifier.isEmpty)
        #expect(!shownURL.absoluteString.contains(verifier))
        #expect(query["code_challenge"] == PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "auth-code-42")
        #expect(form["redirect_uri"] == "http://localhost:49152/oauth-callback")
        #expect(form["client_id"] == AgyOAuth.clientID)
        #expect(form["client_secret"] == AgyOAuth.clientSecret)

        // Verify userinfo request
        let infoReq = client.requests[1]
        #expect(infoReq.url == AgyOAuth.userInfoURL)
        #expect(infoReq.method == "GET")
        #expect(client.header("authorization", request: 1) == "Bearer ya29.access")

        #expect(credentials.access == "ya29.access")
        #expect(credentials.refresh == "1//refresh")
        #expect(AgyOAuth.email(credentials) == "dev@example.com")
        #expect(credentials.extras["email"] == .string("dev@example.com"))
        #expect(credentials.expires >= before + (3600 - 300) * 1000)
        #expect(credentials.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3600 - 300) * 1000)
    }

    @Test("loginAgy falls back to id_token email claim when userinfo fails")
    func loginFallsBackToIDTokenEmail() async throws {
        let idToken = jwt(["email": "jwt-user@example.com", "sub": "12345"])
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.a","refresh_token":"1//r","expires_in":3600,"id_token":"\#(idToken)"}"#),
            .response(status: 500, body: "userinfo down"),
        ])

        let credentials = try await OAuthLogin.loginAgy(
            callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "c"], made: LoopbackBox()),
            client: client
        )
        #expect(credentials.access == "ya29.a")
        #expect(AgyOAuth.email(credentials) == "jwt-user@example.com")
    }

    @Test("loginAgy succeeds without email when both userinfo and id_token are unavailable")
    func loginSucceedsWithoutEmail() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.a","refresh_token":"1//r","expires_in":3600}"#),
            .failure(URLError(.timedOut)),
        ])

        let credentials = try await OAuthLogin.loginAgy(
            callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "c"], made: LoopbackBox()),
            client: client
        )
        #expect(credentials.access == "ya29.a")
        #expect(AgyOAuth.email(credentials) == nil)
        #expect(credentials.extras["email"] == nil)
    }

    @Test("loginAgy refuses missing/mismatched state and missing code before exchanging", arguments: [
        ["code": "c"],
        ["code": "c", "state": "wrong"],
        ["code": "", "state": "wrong"],
    ])
    func loginInvalidCallback(params: [String: String]) async throws {
        let client = QueuedHTTPClient([])
        let made = LoopbackBox()
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginAgy(
                callbacks: callbacks(presenter: RecordingPresenter(), params: params, echoState: false, made: made),
                client: client
            )
        }
        #expect(client.requestCount == 0)
        #expect(made.value?.stopped == true)
    }

    @Test("loginAgy maps access_denied callback error to OAuthLoginError.cancelled")
    func loginAccessDeniedCancels() async throws {
        let client = QueuedHTTPClient([])
        let made = LoopbackBox()
        await #expect(throws: OAuthLoginError.cancelled) {
            _ = try await OAuthLogin.loginAgy(
                callbacks: callbacks(presenter: RecordingPresenter(), params: ["error": "access_denied"], made: made),
                client: client
            )
        }
        #expect(client.requestCount == 0)
        #expect(made.value?.stopped == true)
    }

    @Test("loginAgy refuses token responses lacking refresh_token")
    func loginRequiresRefreshToken() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.a","expires_in":3600}"#),
        ])
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginAgy(
                callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "c"], made: LoopbackBox()),
                client: client
            )
        }
    }

    // MARK: - Refresh

    @Test("AgyOAuthProvider.refresh preserves refresh token and extras when Google omits refresh_token")
    func refreshPreservesRefreshTokenAndExtras() async throws {
        let stale = OAuthCredentials(
            access: "old-access",
            refresh: "1//kept-refresh",
            expires: 0,
            extras: ["email": .string("dev@example.com"), "baseUrl": .string("https://relay.example.com")]
        )
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.fresh","expires_in":3599}"#),
        ])
        let before = Int64(Date().timeIntervalSince1970 * 1000)

        let refreshed = try await AgyOAuthProvider().refresh(stale, using: client)

        #expect(refreshed.access == "ya29.fresh")
        #expect(refreshed.refresh == "1//kept-refresh")
        #expect(refreshed.extras == stale.extras)
        #expect(refreshed.expires >= before + (3599 - 300) * 1000)
        #expect(refreshed.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3599 - 300) * 1000)

        let req = try #require(client.requests.first)
        #expect(req.url == AgyOAuth.tokenURL)
        #expect(req.method == "POST")
        #expect(client.header("content-type", request: 0) == "application/x-www-form-urlencoded")
        let form = formParams(from: req.body)
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["refresh_token"] == "1//kept-refresh")
        #expect(form["client_id"] == AgyOAuth.clientID)
        #expect(form["client_secret"] == AgyOAuth.clientSecret)
    }

    @Test("AgyOAuthProvider.refresh adopts a rotated refresh token when returned")
    func refreshAdoptsNewRefreshToken() async throws {
        let stale = OAuthCredentials(access: "old", refresh: "1//old", expires: 0)
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.new","refresh_token":"1//rotated","expires_in":3600}"#),
        ])

        let refreshed = try await AgyOAuthProvider().refresh(stale, using: client)
        #expect(refreshed.access == "ya29.new")
        #expect(refreshed.refresh == "1//rotated")
    }

    @Test("AgyOAuthProvider.refresh classifies invalid_grant as rejected and 429/500/transport as unavailable")
    func refreshErrorClassification() async {
        let provider = AgyOAuthProvider()
        let stale = OAuthCredentials(access: "old", refresh: "1//r", expires: 0)

        func run(_ answer: QueuedHTTPClient.Answer) async -> OAuthRefreshError? {
            do {
                _ = try await provider.refresh(stale, using: QueuedHTTPClient([answer]))
                return nil
            } catch let err as OAuthRefreshError {
                return err
            } catch {
                Issue.record("unexpected error \(error)")
                return nil
            }
        }

        let invalidGrant = await run(.response(status: 400, body: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#))
        #expect(invalidGrant?.providerId == "agy")
        #expect(invalidGrant?.kind == .rejected)
        #expect(invalidGrant?.status == 400)

        let unauth = await run(.response(status: 401, body: #"{"error":"unauthorized"}"#))
        #expect(unauth?.kind == .rejected)
        #expect(unauth?.status == 401)

        let rateLimited = await run(.response(status: 429, body: #"{"error":"rate_limit"}"#))
        #expect(rateLimited?.kind == .unavailable)
        #expect(rateLimited?.status == 429)

        let serverError = await run(.response(status: 500, body: "internal error"))
        #expect(serverError?.kind == .unavailable)
        #expect(serverError?.status == 500)

        let transport = await run(.failure(URLError(.networkConnectionLost)))
        #expect(transport?.kind == .unavailable)
        #expect(transport?.status == nil)

        let emptyAccess = await run(.response(status: 200, body: #"{"access_token":"","expires_in":3600}"#))
        #expect(emptyAccess?.kind == .unavailable)
    }

    @Test("OAuthSubscriptions resolves agy login, metadata, and AgyOAuthProvider refresher")
    func subscriptionsDispatch() async throws {
        let entry = try #require(OAuthSubscriptions.provider(id: "agy"))
        #expect(entry.id == "agy")
        #expect(entry.name == "Antigravity CLI")
        #expect(entry.upkeep == .refreshed)
        #expect(OAuthSubscriptions.refresher(providerId: "agy") is AgyOAuthProvider)
        #expect(OAuthSubscriptions.refreshedIds.contains("agy"))

        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.sub","refresh_token":"1//sub","expires_in":3600}"#),
            .response(status: 200, body: #"{"email":"sub@example.com"}"#),
        ])
        let creds = try await OAuthSubscriptions.login(
            providerId: "agy",
            callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "sub-code"], made: LoopbackBox()),
            client: client
        )
        #expect(creds.access == "ya29.sub")
        #expect(creds.refresh == "1//sub")
        #expect(AgyOAuth.email(creds) == "sub@example.com")
    }
}
