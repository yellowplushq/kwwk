import Foundation
import Testing
@testable import KWWKAuth

@Suite("URLSessionHTTPClient redirect policy")
struct RedirectPolicyTests {
    @Test("same origin, or plain HTTP to HTTPS on the same host and default ports")
    func sameOrigin() {
        func follows(_ from: String, _ to: String) -> Bool {
            URLSessionHTTPClient.RedirectPolicy.sameOrigin.follows(from: URL(string: from)!, to: URL(string: to)!)
        }
        #expect(follows("https://mcp.example.com/mcp", "https://mcp.example.com/mcp/"))
        #expect(follows("https://mcp.example.com/mcp", "https://MCP.example.com:443/v2"))
        #expect(follows("http://mcp.example.com/mcp", "https://mcp.example.com/mcp"))
        #expect(follows("http://127.0.0.1:8080/a", "http://127.0.0.1:8080/b"))
        #expect(!follows("https://mcp.example.com/mcp", "https://other.example.com/mcp"))
        #expect(!follows("https://mcp.example.com/mcp", "http://mcp.example.com/mcp"))
        #expect(!follows("https://mcp.example.com/mcp", "https://mcp.example.com:8443/mcp"))
        #expect(!follows("http://mcp.example.com:8080/mcp", "https://mcp.example.com/mcp"))
        #expect(!follows("https://mcp.example.com/mcp", "http://169.254.169.254/latest"))
        #expect(!follows("http://127.0.0.1:8080/a", "http://127.0.0.1:9090/b"))
        #expect(!follows("https://mcp.example.com/mcp", "https://user:pw@mcp.example.com/mcp"))
        #expect(!follows("https://mcp.example.com/mcp", "file:///etc/passwd"))
        #expect(!follows("https:///a", "https:///b"))
    }

    @Test("the default follows every redirect, as before")
    func follow() {
        #expect(URLSessionHTTPClient.RedirectPolicy.follow.follows(
            from: URL(string: "https://a.example/x")!,
            to: URL(string: "http://b.example/y")!
        ))
    }
}
