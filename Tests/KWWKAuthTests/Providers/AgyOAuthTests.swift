import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

    @Test("loginAgy requests a dynamic loopback port (0), uses the bound redirect_uri, exchanges code with PKCE verifier and saves userinfo email and projectId")
    func loginSuccessWithUserInfoEmail() async throws {
        #expect(AgyOAuth.callbackPort == 0)
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.access","refresh_token":"1//refresh","expires_in":3600}"#),
            .response(status: 200, body: #"{"email":"dev@example.com","name":"Dev"}"#),
            .response(status: 200, body: #"{"cloudaicompanionProject":"proj-login-1","currentTier":{"id":"free-tier"}}"#),
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
            client: client,
            hubVersion: AgyHubVersion(fixed: "2.35.1")
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
        #expect(client.requestCount == 3)
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

        // Verify best-effort loadCodeAssist request
        let loadReq = client.requests[2]
        #expect(loadReq.url.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        #expect(loadReq.method == "POST")
        #expect(client.header("Authorization", request: 2) == "Bearer ya29.access")
        #expect(client.header("User-Agent", request: 2)?.hasPrefix("antigravity/hub/2.35.1 ") == true)

        #expect(credentials.access == "ya29.access")
        #expect(credentials.refresh == "1//refresh")
        #expect(AgyOAuth.email(credentials) == "dev@example.com")
        #expect(credentials.extras["email"] == .string("dev@example.com"))
        #expect(AgyOAuth.projectId(credentials) == "proj-login-1")
        #expect(credentials.extras["projectId"] == .string("proj-login-1"))
        #expect(credentials.expires >= before + (3600 - 300) * 1000)
        #expect(credentials.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3600 - 300) * 1000)
    }

    @Test("loginAgy falls back to id_token email claim when userinfo fails")
    func loginFallsBackToIDTokenEmail() async throws {
        let idToken = jwt(["email": "jwt-user@example.com", "sub": "12345"])
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.a","refresh_token":"1//r","expires_in":3600,"id_token":"\#(idToken)"}"#),
            .response(status: 500, body: "userinfo down"),
            .response(status: 200, body: #"{"cloudaicompanionProject":{"id":"proj-obj-1"}}"#),
        ])

        let credentials = try await OAuthLogin.loginAgy(
            callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "c"], made: LoopbackBox()),
            client: client,
            hubVersion: AgyHubVersion(fixed: "2.35.1")
        )
        #expect(credentials.access == "ya29.a")
        #expect(AgyOAuth.email(credentials) == "jwt-user@example.com")
        #expect(AgyOAuth.projectId(credentials) == "proj-obj-1")
    }

    @Test("loginAgy succeeds without email or projectId when userinfo and loadCodeAssist fail")
    func loginSucceedsWithoutEmail() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.a","refresh_token":"1//r","expires_in":3600}"#),
            .failure(URLError(.timedOut)),
            .response(status: 500, body: "loadCodeAssist unavailable"),
        ])

        let credentials = try await OAuthLogin.loginAgy(
            callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "c"], made: LoopbackBox()),
            client: client,
            hubVersion: AgyHubVersion(fixed: "2.35.1")
        )
        #expect(credentials.access == "ya29.a")
        #expect(AgyOAuth.email(credentials) == nil)
        #expect(credentials.extras["email"] == nil)
        #expect(AgyOAuth.projectId(credentials) == nil)
        #expect(credentials.extras["projectId"] == nil)
    }

    @Test("loginAgy cancels hung loadCodeAssist via CancellationHandle on timeout and succeeds without projectId")
    func loginIgnoresLoadCodeAssistTimeout() async throws {
        let client = HandleOnlyCancellingHTTPClient(initialResponses: [
            .response(status: 200, body: #"{"access_token":"ya29.slow","refresh_token":"1//r","expires_in":3600}"#),
            .response(status: 200, body: #"{"email":"slow@example.com"}"#),
        ])

        let credentials = try await OAuthLogin.loginAgy(
            callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "c"], made: LoopbackBox()),
            client: client,
            hubVersion: AgyHubVersion(fixed: "2.35.1"),
            projectLookupTimeoutSeconds: 0.05
        )

        #expect(credentials.access == "ya29.slow")
        #expect(AgyOAuth.email(credentials) == "slow@example.com")
        #expect(AgyOAuth.projectId(credentials) == nil)
        #expect(client.hungTimeoutSeconds == 0.05)
        #expect(client.hungHadCancellationHandle == true)
        #expect(client.cancelReasons == ["timeout"])
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

    @Test("AgyOAuthProvider.refresh preserves refresh token and already-cached projectId without calling loadCodeAssist")
    func refreshPreservesRefreshTokenAndCachedProjectId() async throws {
        let stale = OAuthCredentials(
            access: "old-access",
            refresh: "1//kept-refresh",
            expires: 0,
            extras: [
                "email": .string("dev@example.com"),
                "baseUrl": .string("https://relay.example.com"),
                "projectId": .string("proj-existing"),
            ]
        )
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.fresh","expires_in":3599}"#),
        ])
        let before = Int64(Date().timeIntervalSince1970 * 1000)

        let refreshed = try await AgyOAuthProvider(hubVersion: AgyHubVersion(fixed: "2.35.1")).refresh(stale, using: client)

        #expect(client.requestCount == 1)
        #expect(refreshed.access == "ya29.fresh")
        #expect(refreshed.refresh == "1//kept-refresh")
        #expect(refreshed.extras == stale.extras)
        #expect(AgyOAuth.projectId(refreshed) == "proj-existing")
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

    @Test("AgyOAuthProvider.refresh backfills missing or empty projectId via loadCodeAssist using the new access token")
    func refreshBackfillsMissingProjectId() async throws {
        for initialExtras in [[:], ["email": .string("legacy@example.com"), "projectId": .string("")]] as [[String: JSONValue]] {
            let stale = OAuthCredentials(access: "old", refresh: "1//r", expires: 0, extras: initialExtras)
            let client = QueuedHTTPClient([
                .response(status: 200, body: #"{"access_token":"ya29.refreshed","expires_in":3600}"#),
                .response(status: 200, body: #"{"cloudaicompanionProject":"proj-backfilled"}"#),
            ])

            let refreshed = try await AgyOAuthProvider(hubVersion: AgyHubVersion(fixed: "2.35.1")).refresh(stale, using: client)
            #expect(client.requestCount == 2)
            #expect(client.requests[1].url.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
            #expect(client.header("Authorization", request: 1) == "Bearer ya29.refreshed")
            #expect(client.header("User-Agent", request: 1)?.hasPrefix("antigravity/hub/2.35.1 ") == true)
            #expect(AgyOAuth.projectId(refreshed) == "proj-backfilled")
            #expect(refreshed.extras["projectId"] == .string("proj-backfilled"))
        }
    }

    @Test("AgyOAuthProvider.refresh still succeeds when best-effort loadCodeAssist fails or times out")
    func refreshIgnoresLoadCodeAssistFailureAndTimeout() async throws {
        let stale = OAuthCredentials(access: "old", refresh: "1//old", expires: 0, extras: ["email": .string("u@example.com")])
        let failClient = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ya29.new","refresh_token":"1//rotated","expires_in":3600}"#),
            .response(status: 500, body: "server error"),
        ])

        let refreshed = try await AgyOAuthProvider(hubVersion: AgyHubVersion(fixed: "2.35.1")).refresh(stale, using: failClient)
        #expect(failClient.requestCount == 2)
        #expect(refreshed.access == "ya29.new")
        #expect(refreshed.refresh == "1//rotated")
        #expect(AgyOAuth.projectId(refreshed) == nil)
        #expect(refreshed.extras["email"] == .string("u@example.com"))

        let slowClient = HandleOnlyCancellingHTTPClient(initialResponses: [
            .response(status: 200, body: #"{"access_token":"ya29.timeout","expires_in":3600}"#),
        ])
        let timedOut = try await AgyOAuthProvider(
            hubVersion: AgyHubVersion(fixed: "2.35.1"),
            projectLookupTimeoutSeconds: 0.05
        ).refresh(stale, using: slowClient)
        #expect(timedOut.access == "ya29.timeout")
        #expect(AgyOAuth.projectId(timedOut) == nil)
        #expect(slowClient.hungTimeoutSeconds == 0.05)
        #expect(slowClient.hungHadCancellationHandle == true)
        #expect(slowClient.cancelReasons == ["timeout"])
    }

    @Test("bestEffortProjectId passes default 10s timeoutSeconds and propagates parent Task cancellation to CancellationHandle")
    func bestEffortProjectIdDefaultTimeoutAndParentCancellation() async throws {
        let stale = OAuthCredentials(access: "old", refresh: "1//old", expires: 0)

        // 1. Default 10s timeoutSeconds is forwarded on the HTTP request.
        let timeoutRecorder = HandleOnlyCancellingHTTPClient(initialResponses: [
            .response(status: 200, body: #"{"access_token":"ya29.fresh","expires_in":3600}"#),
            .response(status: 200, body: #"{"cloudaicompanionProject":"proj-10s"}"#),
        ])
        let ok = try await AgyOAuthProvider(hubVersion: AgyHubVersion(fixed: "2.35.1")).refresh(stale, using: timeoutRecorder)
        #expect(AgyOAuth.projectId(ok) == "proj-10s")
        #expect(timeoutRecorder.recordedTimeouts.count == 2)
        #expect(timeoutRecorder.recordedTimeouts[1] == AgyOAuth.projectLookupTimeoutSeconds)
        #expect(timeoutRecorder.recordedTimeouts[1] == 10)

        // 2. Parent Task cancellation triggers CancellationHandle.cancel() immediately even with a 10s timeout.
        let hungClient = HandleOnlyCancellingHTTPClient(initialResponses: [
            .response(status: 200, body: #"{"access_token":"ya29.hung","expires_in":3600}"#),
        ])
        let task = Task {
            try await AgyOAuthProvider(hubVersion: AgyHubVersion(fixed: "2.35.1")).refresh(stale, using: hungClient)
        }
        await hungClient.waitUntilHung()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(hungClient.hungTimeoutSeconds == 10)
        #expect(hungClient.hungHadCancellationHandle == true)
        #expect(hungClient.cancelReasons == ["cancelled"])
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
            .response(status: 200, body: #"{"cloudaicompanionProject":"proj-sub"}"#),
        ])
        let creds = try await OAuthSubscriptions.login(
            providerId: "agy",
            callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "sub-code"], made: LoopbackBox()),
            client: client
        )
        #expect(creds.access == "ya29.sub")
        #expect(creds.refresh == "1//sub")
        #expect(AgyOAuth.email(creds) == "sub@example.com")
        #expect(AgyOAuth.projectId(creds) == "proj-sub")
    }
}

/// Serves queued initial responses, then hangs on subsequent requests while
/// explicitly ignoring Swift Task cancellation — unblocking ONLY when
/// `CancellationHandle.cancel()` fires (mirroring `URLSessionHTTPClient`'s
/// `awaitHeader` behavior).
final class HandleOnlyCancellingHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [QueuedHTTPClient.Answer]
    private(set) var recordedTimeouts: [TimeInterval?] = []
    private(set) var hungTimeoutSeconds: TimeInterval?
    private(set) var hungHadCancellationHandle = false
    private(set) var cancelReasons: [String?] = []
    private var hung = false
    private var hungWaiters: [CheckedContinuation<Void, Never>] = []

    init(initialResponses: [QueuedHTTPClient.Answer]) {
        self.responses = initialResponses
    }

    func waitUntilHung() async {
        await withCheckedContinuation { cont in
            let alreadyHung: Bool = lock.withLock {
                if hung { return true }
                hungWaiters.append(cont)
                return false
            }
            if alreadyHung { cont.resume() }
        }
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        try await run(url: url, cancellation: cancellation, timeoutSeconds: nil)
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?,
        timeoutSeconds: TimeInterval
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        try await run(url: url, cancellation: cancellation, timeoutSeconds: timeoutSeconds)
    }

    private func run(
        url: URL,
        cancellation: CancellationHandle?,
        timeoutSeconds: TimeInterval?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let next: QueuedHTTPClient.Answer? = lock.withLock {
            recordedTimeouts.append(timeoutSeconds)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        if let next {
            switch next {
            case .failure(let error):
                throw error
            case .response(let status, let body, let extra):
                var fields = ["content-type": "application/json"]
                for (k, v) in extra { fields[k] = v }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: fields
                )!
                let data = Data(body.utf8)
                return (response, AsyncThrowingStream { continuation in
                    continuation.yield(data)
                    continuation.finish()
                })
            }
        }

        // Hang until CancellationHandle fires — intentionally ignores Task cancellation.
        return try await withCheckedThrowingContinuation { cont in
            let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                hungTimeoutSeconds = timeoutSeconds
                hungHadCancellationHandle = cancellation != nil
                hung = true
                let w = hungWaiters
                hungWaiters.removeAll()
                return w
            }
            for waiter in waiters { waiter.resume() }

            guard let cancellation else {
                // If no CancellationHandle was supplied, fail fast so a regression
                // surfaces as a clear assertion failure instead of hanging CI forever.
                cont.resume(throwing: URLError(.cannotConnectToHost))
                return
            }
            _ = cancellation.onCancel { [weak self] reason in
                self?.lock.withLock { self?.cancelReasons.append(reason) }
                cont.resume(throwing: URLError(.cancelled))
            }
        }
    }
}
