import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKMCP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Two real HTTP servers in one Python process, on two loopback ports: two
/// origins. `/same` on either redirects (307) within its origin, `/cross`
/// on the first to the second's `/final`, and `/final` answers a JSON-RPC
/// response to whatever was posted. `GET /seen` lists every other request
/// both servers got, with the `X-Api-Key` it carried.
private enum RedirectingServers {
    static let script = #"""
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
seen = []
ports = {}

def handler(name):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def answer(self, status, body=b"", headers=None):
            self.send_response(status)
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def serve(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            if self.path == "/seen":
                with lock:
                    data = json.dumps(seen).encode()
                return self.answer(200, data, {"Content-Type": "application/json"})
            with lock:
                seen.append({"server": name, "path": self.path, "apiKey": self.headers.get("X-Api-Key") or ""})
            if self.path == "/same":
                return self.answer(307, b"", {"Location": "/final"})
            if self.path == "/cross":
                return self.answer(307, b"", {"Location": "http://127.0.0.1:%d/final" % ports["b"]})
            request = json.loads(body or b"{}")
            reply = {"jsonrpc": "2.0", "id": request.get("id", 0), "result": {"server": name}}
            return self.answer(200, json.dumps(reply).encode(), {"Content-Type": "application/json"})

        do_GET = serve
        do_POST = serve
    return Handler

a = ThreadingHTTPServer(("127.0.0.1", 0), handler("a"))
b = ThreadingHTTPServer(("127.0.0.1", 0), handler("b"))
ports["a"] = a.server_address[1]
ports["b"] = b.server_address[1]
threading.Thread(target=b.serve_forever, daemon=True).start()
sys.stdout.write("%d %d\n" % (ports["a"], ports["b"]))
sys.stdout.flush()
a.serve_forever()
"""#

    struct Running {
        let process: Process
        let directory: URL
        let first: String
        let second: String
    }

    static func start() throws -> Running? {
        guard let python = FakeMCPServer.python else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-mcp-redirect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("server.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [scriptURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([0x0A]) {
            line.append(byte)
        }
        let ports = String(decoding: line, as: UTF8.self).split(separator: " ").compactMap { Int($0) }
        guard ports.count == 2 else {
            process.terminate()
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return Running(
            process: process,
            directory: directory,
            first: "http://127.0.0.1:\(ports[0])",
            second: "http://127.0.0.1:\(ports[1])"
        )
    }

    static func stop(_ running: Running) {
        running.process.terminate()
        try? FileManager.default.removeItem(at: running.directory)
    }

    /// What the servers were asked so far, as (server, path, X-Api-Key).
    static func seen(_ running: Running) async throws -> [[String: String]] {
        let (_, data) = try await URLSessionHTTPClient.shared.request(
            url: URL(string: "\(running.first)/seen")!,
            method: "GET",
            headers: [:],
            body: nil
        )
        return try JSONDecoder().decode([[String: String]].self, from: data)
    }
}

// The clients live as long as the process: releasing a `URLSession` while
// another test streams can abort a Linux test run (see
// `MCPHTTPSessionLifetimeTests`).
@Suite("MCP HTTP redirects", .serialized)
struct MCPHTTPRedirectTests {
    private let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

    @Test("the transports' client follows within the origin and hands back a redirect elsewhere")
    func sameOriginClient() async throws {
        guard let servers = try RedirectingServers.start() else { return }
        defer { RedirectingServers.stop(servers) }
        let client = MCPStreamableHTTPTransport.defaultHTTPClient
        let headers = ["X-Api-Key": "key-1", "Content-Type": "application/json"]

        let (followed, _) = try await client.request(
            url: URL(string: "\(servers.first)/same")!,
            method: "POST",
            headers: headers,
            body: body
        )
        #expect(followed.statusCode == 200)

        let (refused, _) = try await client.request(
            url: URL(string: "\(servers.first)/cross")!,
            method: "POST",
            headers: headers,
            body: body
        )
        #expect(refused.statusCode == 307)
        let seen = try await RedirectingServers.seen(servers)
        #expect(seen.map { $0["path"] ?? "" } == ["/same", "/final", "/cross"])
        #expect(seen.allSatisfy { $0["server"] == "a" })
    }

    @Test("the default client still follows every redirect")
    func defaultClient() async throws {
        guard let servers = try RedirectingServers.start() else { return }
        defer { RedirectingServers.stop(servers) }
        let (response, _) = try await URLSessionHTTPClient.shared.request(
            url: URL(string: "\(servers.first)/cross")!,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        #expect(response.statusCode == 200)
        let seen = try await RedirectingServers.seen(servers)
        #expect(seen.map { $0["server"] ?? "" } == ["a", "b"])
    }

    @Test("an MCP server cannot send a request, with its headers, on to another origin")
    func transport() async throws {
        guard let servers = try RedirectingServers.start() else { return }
        defer { RedirectingServers.stop(servers) }
        let message = JSONRPCMessage.request(id: .int(1), method: "ping", params: nil)

        let same = MCPStreamableHTTPTransport(
            url: URL(string: "\(servers.first)/same")!,
            headers: ["X-Api-Key": "key-1"]
        )
        _ = try await same.start()
        try await same.send(message)
        await same.close()

        let cross = MCPStreamableHTTPTransport(
            url: URL(string: "\(servers.first)/cross")!,
            headers: ["X-Api-Key": "key-1"]
        )
        _ = try await cross.start()
        await #expect(throws: MCPError.self) { try await cross.send(message) }
        await cross.close()

        let seen = try await RedirectingServers.seen(servers)
        #expect(seen.map { $0["path"] ?? "" } == ["/same", "/final", "/cross"])
        #expect(seen.allSatisfy { $0["server"] == "a" && $0["apiKey"] == "key-1" })
    }
}
