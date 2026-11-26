import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

extension MCPOAuth {
    // MARK: - Endpoint rules

    /// Whether the authorization flow may send a request, or the user
    /// agent, to `url`. It must be an `http` or `https` URL with a host and
    /// no credentials in it. With the MCP server's URL known, a loopback
    /// host is only for a server on loopback itself, and plain HTTP to any
    /// other host only for the server's own origin: what a server's metadata
    /// names cannot point the client at this machine or at a plain-HTTP
    /// service elsewhere.
    static func isAllowedEndpoint(_ url: URL, serverURL: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = normalizedHost(of: url), url.user == nil, url.password == nil
        else { return false }
        guard let serverURL else { return true }
        if isLoopbackHost(host) {
            return isStrictLoopbackHost(host) && isStrictLoopback(serverURL)
        }
        return scheme == "https" || MCPAuthHTTP.isSameOrigin(url, serverURL)
    }

    /// Whether `url`'s host can reach this machine (`isLoopbackHost`),
    /// including unspecified addresses (`0.0.0.0/8`, `::`) that resolvers
    /// may route locally. Used as the broad denylist check.
    static func isLoopback(_ url: URL) -> Bool {
        normalizedHost(of: url).map(isLoopbackHost) ?? false
    }

    /// Whether `url`'s host is strictly a loopback address
    /// (`isStrictLoopbackHost`), excluding unspecified addresses like
    /// `0.0.0.0` or `::`. Used for allowlist exemptions (plain HTTP token
    /// endpoints, local dev server endpoints, native redirect URIs).
    static func isStrictLoopback(_ url: URL) -> Bool {
        normalizedHost(of: url).map(isStrictLoopbackHost) ?? false
    }

    /// `url`'s host as the resolver reads it: lowercased, without IPv6
    /// brackets or trailing dots. Nil when there is none, or when it is
    /// written with `%` (percent-encoding, an IPv6 zone): no endpoint needs
    /// one, and the connection could read it differently than this check.
    static func normalizedHost(of url: URL) -> String? {
        guard let written = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false)?.percentEncodedHost,
              !written.contains("%")
        else { return nil }
        var host = written.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// Names the stock hosts files of macOS and Linux distributions give
    /// this machine, besides `localhost` subdomains (RFC 6761).
    private static let loopbackNames: Set<String> = [
        "localhost", "localhost.localdomain",
        "localhost4", "localhost4.localdomain4",
        "localhost6", "localhost6.localdomain6",
        "ip6-localhost", "ip6-loopback",
    ]

    /// Whether a host from `normalizedHost(of:)` is strictly a loopback
    /// target: a `localhost` name, `127.0.0.0/8`, `::1`, or IPv4-mapped /
    /// IPv4-compatible `127.0.0.0/8`. Unspecified addresses (`0.0.0.0/8`,
    /// `::`, `::2`, etc.) return false.
    static func isStrictLoopbackHost(_ host: String) -> Bool {
        if loopbackNames.contains(host) || host.hasSuffix(".localhost") { return true }
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            return withUnsafeBytes(of: &v4) { $0[0] == 127 }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        return withUnsafeBytes(of: &v6) { bytes in
            if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
            guard bytes[0..<10].allSatisfy({ $0 == 0 }),
                  (bytes[10] == 0 && bytes[11] == 0) || (bytes[10] == 0xFF && bytes[11] == 0xFF)
            else { return false }
            return bytes[12] == 127
        }
    }

    /// Whether a host from `normalizedHost(of:)` can reach this machine: a
    /// `localhost` name, or an address in 127.0.0.0/8 or 0.0.0.0/8, `::`,
    /// `::1`, or one of those in an IPv6 form (IPv4-mapped or -compatible).
    /// Addresses are read as the system resolver reads them, so `127.1`,
    /// `2130706433`, `0x7f.0.0.1` and `0:0:0:0:0:0:0:1` all count.
    static func isLoopbackHost(_ host: String) -> Bool {
        if loopbackNames.contains(host) || host.hasSuffix(".localhost") { return true }
        func isLoopbackIPv4(firstOctet: UInt8) -> Bool { firstOctet == 127 || firstOctet == 0 }
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            // `s_addr` is in network order: its first byte is the first octet.
            return withUnsafeBytes(of: &v4) { isLoopbackIPv4(firstOctet: $0[0]) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        return withUnsafeBytes(of: &v6) { bytes in
            // ::/96 holds `::`, `::1` and IPv4-compatible addresses;
            // ::ffff:0:0/96 the IPv4-mapped ones.
            guard bytes[0..<10].allSatisfy({ $0 == 0 }),
                  (bytes[10] == 0 && bytes[11] == 0) || (bytes[10] == 0xFF && bytes[11] == 0xFF)
            else { return false }
            return isLoopbackIPv4(firstOctet: bytes[12])
        }
    }
}
