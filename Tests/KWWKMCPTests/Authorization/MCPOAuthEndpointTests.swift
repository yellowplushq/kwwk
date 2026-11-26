import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKMCP

/// An MCP server and its authorization server answering from a table of
/// `"METHOD URL"` routes; anything else is a 404. Every request is recorded.
final class RoutedAuthServer: MCPAuthHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MCPAuthHTTPRequest] = []
    var requests: [MCPAuthHTTPRequest] { lock.withLock { recorded } }
    var routes: [String: (status: Int, body: JSONValue)] = [:]

    func send(_ request: MCPAuthHTTPRequest) async throws -> MCPAuthHTTPResponse {
        lock.withLock { recorded.append(request) }
        guard let route = routes["\(request.method) \(request.url.absoluteString)"] else {
            return MCPAuthHTTPResponse(status: 404, body: Data("not found".utf8), url: request.url)
        }
        return MCPAuthHTTPResponse(
            status: route.status,
            headers: ["Content-Type": "application/json"],
            body: (try? JSONEncoder().encode(route.body)) ?? Data(),
            url: request.url
        )
    }

    func contacted(host: String) -> Bool {
        requests.contains { $0.url.host == host }
    }

    /// Protected resource metadata for `server` at its path-aware well-known
    /// URL, naming `authorizationServer`.
    func publishResource(_ server: String, path: String = "/mcp", authorizationServer: String) {
        routes["GET \(server)/.well-known/oauth-protected-resource\(path)"] = (200, [
            "resource": .string(server + path),
            "authorization_servers": .array([.string(authorizationServer)]),
        ])
    }

    /// RFC 8414 metadata for `issuer`, its endpoints overridable.
    func publishAuthorizationServer(
        _ issuer: String,
        authorize: String? = nil,
        token: String? = nil,
        register: String? = nil
    ) {
        routes["GET \(issuer)/.well-known/oauth-authorization-server"] = (200, [
            "issuer": .string(issuer),
            "authorization_endpoint": .string(authorize ?? issuer + "/authorize"),
            "token_endpoint": .string(token ?? issuer + "/token"),
            "registration_endpoint": .string(register ?? issuer + "/register"),
            "response_types_supported": ["code"],
            "code_challenge_methods_supported": ["S256"],
        ])
        routes["POST \(register ?? issuer + "/register")"] = (201, ["client_id": "client-1"])
        routes["POST \(token ?? issuer + "/token")"] = (200, [
            "access_token": "access-1", "token_type": "Bearer", "refresh_token": "refresh-1",
        ])
    }
}

@Suite("MCP OAuth endpoints")
struct MCPOAuthEndpointTests {
    let remote = URL(string: "https://mcp.example.com/mcp")!
    let client = MCPOAuthClientInformation(clientID: "client-1")
    let redirect = URL(string: "http://127.0.0.1:4567/callback")!

    private func start(_ endpoint: String, serverURL: URL?) throws -> URL {
        try MCPOAuth.startAuthorization(
            authorizationServerURL: "https://auth.example.com",
            metadata: MCPAuthorizationServerMetadata(
                issuer: "https://auth.example.com",
                authorizationEndpoint: endpoint,
                tokenEndpoint: "https://auth.example.com/token"
            ),
            client: client,
            redirectURI: redirect,
            scope: nil,
            state: "state-1",
            resource: nil,
            serverURL: serverURL
        ).authorizationURL
    }

    @Test("an authorization endpoint the system would open in another app is refused")
    func authorizationEndpointScheme() throws {
        let refused = [
            "file:///System/Applications/Calculator.app",
            "smb://evil.example/share",
            "shortcuts://run-shortcut?name=x",
            "javascript:alert(1)",
            "vscode://evil.example/x",
            "https://user:password@auth.example.com/authorize",
            "/authorize",
        ]
        for endpoint in refused {
            for serverURL in [nil, remote] {
                #expect(throws: MCPAuthError.self, "\(endpoint)") { try start(endpoint, serverURL: serverURL) }
            }
        }
        // A caller that names no MCP server keeps every web page.
        #expect(try start("https://auth.example.com/authorize", serverURL: nil).host == "auth.example.com")
        #expect(try start("http://auth.example.com/authorize", serverURL: nil).host == "auth.example.com")
        #expect(try start("http://127.0.0.1:9/authorize", serverURL: nil).host == "127.0.0.1")
    }

    @Test("with the MCP server known, loopback is for a loopback server and plain HTTP for its own origin")
    func authorizationEndpointForServer() throws {
        #expect(try start("https://auth.example.com/authorize", serverURL: remote).host == "auth.example.com")
        #expect(throws: MCPAuthError.self) { try start("http://auth.example.com/authorize", serverURL: remote) }
        #expect(throws: MCPAuthError.self) { try start("http://127.0.0.1:9/authorize", serverURL: remote) }
        #expect(throws: MCPAuthError.self) { try start("https://localhost/authorize", serverURL: remote) }

        let local = URL(string: "http://localhost:3000/mcp")!
        #expect(try start("http://localhost:3000/authorize", serverURL: local).port == 3000)
        #expect(try start("http://127.0.0.1:4000/authorize", serverURL: local).port == 4000)
        #expect(try start("https://auth.example.com/authorize", serverURL: local).host == "auth.example.com")

        let lan = URL(string: "http://192.168.1.5:8000/mcp")!
        #expect(try start("http://192.168.1.5:8000/authorize", serverURL: lan).host == "192.168.1.5")
        #expect(throws: MCPAuthError.self) { try start("http://192.168.1.6/authorize", serverURL: lan) }
    }

    @Test("metadata naming another app's scheme never reaches the user agent")
    func maliciousAuthorizationEndpoint() async throws {
        let server = RoutedAuthServer()
        server.publishResource("https://mcp.example.com", authorizationServer: "https://auth.example.com")
        server.publishAuthorizationServer("https://auth.example.com", authorize: "smb://evil.example/share")
        let provider = MemoryOAuthProvider()
        let refusal = MCPAuthError.incompatibleServer("invalid authorization endpoint smb://evil.example/share")
        await #expect(throws: refusal) {
            _ = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: remote, httpClient: server))
        }
        #expect(provider.redirects.isEmpty)
        #expect(provider.verifier == nil)
    }

    @Test("a challenge's resource metadata URL elsewhere over plain HTTP is passed over for the well-known one")
    func resourceMetadataHint() async throws {
        let server = RoutedAuthServer()
        server.publishResource("https://mcp.example.com", authorizationServer: "https://auth.example.com")
        server.publishAuthorizationServer("https://auth.example.com")
        for hint in [
            "http://169.254.169.254/computeMetadata/v1/",
            "http://127.0.0.1:8080/.well-known/oauth-protected-resource",
            "file:///etc/passwd",
        ] {
            let info = try await MCPOAuth.discoverServerInfo(
                serverURL: remote,
                resourceMetadataURL: URL(string: hint),
                httpClient: server
            )
            #expect(info.authorizationServerURL == "https://auth.example.com", "\(hint)")
        }
        #expect(!server.contacted(host: "169.254.169.254"))
        #expect(!server.contacted(host: "127.0.0.1"))
        #expect(server.requests.allSatisfy { $0.url.scheme == "https" })

        // An HTTPS one on another host is still read.
        server.routes["GET https://resource.example.com/prm"] = (200, [
            "resource": "https://mcp.example.com/mcp",
            "authorization_servers": ["https://auth.example.com"],
        ])
        _ = try await MCPOAuth.discoverServerInfo(
            serverURL: remote,
            resourceMetadataURL: URL(string: "https://resource.example.com/prm"),
            httpClient: server
        )
        #expect(server.contacted(host: "resource.example.com"))
    }

    @Test("an authorization server that is not HTTPS, off the server's own origin, is not contacted")
    func authorizationServerURL() async throws {
        let refused = ["http://127.0.0.1:8080", "http://auth.internal", "https://localhost:9443", "file:///etc"]
        for authorizationServer in refused {
            let server = RoutedAuthServer()
            server.publishResource("https://mcp.example.com", authorizationServer: authorizationServer)
            let refusal = MCPAuthError.incompatibleServer("invalid authorization server URL \(authorizationServer)")
            await #expect(throws: refusal) {
                _ = try await MCPOAuth.discoverServerInfo(serverURL: remote, httpClient: server)
            }
            #expect(server.requests.allSatisfy { $0.url.host == "mcp.example.com" }, "\(authorizationServer)")
        }
    }

    @Test("a registration or token endpoint on this machine is refused for a remote server")
    func registrationAndTokenEndpoints() async throws {
        let register = RoutedAuthServer()
        register.publishResource("https://mcp.example.com", authorizationServer: "https://auth.example.com")
        register.publishAuthorizationServer("https://auth.example.com", register: "http://127.0.0.1:8080/register")
        let refusal = MCPAuthError.incompatibleServer("invalid registration endpoint http://127.0.0.1:8080/register")
        await #expect(throws: refusal) {
            _ = try await MCPOAuth.auth(
                MemoryOAuthProvider(),
                options: MCPOAuthOptions(serverURL: remote, httpClient: register)
            )
        }
        #expect(!register.contacted(host: "127.0.0.1"))

        let token = RoutedAuthServer()
        token.publishResource("https://mcp.example.com", authorizationServer: "https://auth.example.com")
        token.publishAuthorizationServer("https://auth.example.com", token: "http://localhost:8080/token")
        let provider = MemoryOAuthProvider()
        provider.client = MCPOAuthClientInformation(clientID: "client-1", issuer: "https://auth.example.com")
        provider.storedTokens = MCPOAuthTokens(
            accessToken: "old",
            refreshToken: "r",
            issuer: "https://auth.example.com"
        )
        await #expect(throws: MCPAuthError.insecureTokenEndpoint("http://localhost:8080/token")) {
            _ = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: remote, httpClient: token))
        }
        #expect(!token.contacted(host: "localhost"))
        #expect(provider.redirects.isEmpty)

        // A token endpoint must be a web URL, loopback or not.
        #expect(throws: MCPAuthError.insecureTokenEndpoint("file://localhost/token")) {
            try MCPOAuth.assertSecureTokenEndpoint(URL(string: "file://localhost/token")!)
        }
    }

    @Test("a refused registration reports the start of the answer only")
    func registrationRefusalIsBounded() async throws {
        let server = RoutedAuthServer()
        server.routes["POST https://auth.example.com/register"] = (400, .string(String(repeating: "x", count: 5_000)))
        do {
            _ = try await MCPOAuth.registerClient(
                authorizationServerURL: "https://auth.example.com",
                metadata: nil,
                clientMetadata: MCPOAuthClientMetadata(redirectURIs: [redirect.absoluteString]),
                scope: nil,
                httpClient: server
            )
            Issue.record("registration passed")
        } catch MCPAuthError.registrationRejected(let status, let body) {
            #expect(status == 400)
            #expect(body.count == 500)
        }
    }

    @Test("a local development server signs in end to end over plain HTTP on loopback")
    func loopbackServer() async throws {
        let local = URL(string: "http://localhost:3000/mcp")!
        let server = RoutedAuthServer()
        server.publishResource("http://localhost:3000", authorizationServer: "http://localhost:3000")
        server.publishAuthorizationServer("http://localhost:3000")
        let provider = MemoryOAuthProvider()
        let result = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: local, httpClient: server))
        #expect(result == .redirect)
        let page = try #require(provider.redirects.first)
        #expect(page.absoluteString.hasPrefix("http://localhost:3000/authorize?"))
        try await MCPOAuth.finishAuthorization(
            provider,
            serverURL: local,
            callbackParameters: ["code": "code-1", "state": "state-1"],
            httpClient: server
        )
        #expect(provider.storedTokens?.accessToken == "access-1")
    }

    @Test("a plain-HTTP server on the network still finds its HTTPS authorization server")
    func networkServer() async throws {
        let lan = URL(string: "http://192.168.1.5:8000/mcp")!
        let server = RoutedAuthServer()
        server.publishResource("http://192.168.1.5:8000", authorizationServer: "https://auth.example.com")
        server.publishAuthorizationServer("https://auth.example.com")
        let info = try await MCPOAuth.discoverServerInfo(
            serverURL: lan,
            resourceMetadataURL: URL(string: "http://192.168.1.5:8000/.well-known/oauth-protected-resource/mcp"),
            httpClient: server
        )
        #expect(info.authorizationServerURL == "https://auth.example.com")
        #expect(info.authorizationServerMetadata?.issuer == "https://auth.example.com")

        // Without resource metadata the server's own origin is the
        // authorization server, as before.
        let legacy = RoutedAuthServer()
        let fallback = try await MCPOAuth.discoverServerInfo(serverURL: lan, httpClient: legacy)
        #expect(fallback.authorizationServerURL == "http://192.168.1.5:8000/")
        #expect(legacy.requests.contains { $0.url.path == "/.well-known/oauth-authorization-server" })
    }
}
