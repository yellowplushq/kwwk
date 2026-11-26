import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches and caches the latest Antigravity Hub version for the Code Assist
/// `User-Agent` header.
///
/// Google's Code Assist endpoints (`retrieveUserQuotaSummary` and
/// `fetchAvailableModels`) gate quota groups on the `antigravity/hub/<version>`
/// User-Agent: generic user agents receive 403, and 1.x CLI versions omit
/// newer Gemini model groups. The version is refreshed from the Hub updater
/// manifest at most once every six hours, falling back to a compiled-in release
/// if the manifest cannot be reached.
public actor AgyHubVersion {
    public static let shared = AgyHubVersion()
    public static let fallback = "2.35.1"
    public static let manifestURL = URL(
        string: "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml"
    )!
    public static let cacheLifetime: TimeInterval = 6 * 60 * 60
    public static let fetchTimeoutSeconds: TimeInterval = 10

    private let fixed: String?
    private let fetchTimeout: TimeInterval
    private var version = AgyHubVersion.fallback
    private var askedAt: Date?
    private var inFlight: Task<String, Never>?

    public init(
        fixed: String? = nil,
        fetchTimeoutSeconds: TimeInterval = AgyHubVersion.fetchTimeoutSeconds
    ) {
        self.fixed = fixed
        self.fetchTimeout = max(fetchTimeoutSeconds, 0)
    }

    /// Returns the cached Hub version (or the fixed/compiled-in fallback)
    /// without issuing a network request.
    public var cachedOrFallback: String {
        fixed ?? version
    }

    /// Returns the Hub version to present in the `User-Agent` header.
    public func current(client: HTTPClient = URLSessionHTTPClient()) async -> String {
        if let fixed { return fixed }
        if let askedAt, Date().timeIntervalSince(askedAt) < Self.cacheLifetime {
            return version
        }
        if let inFlight {
            return await inFlight.value
        }
        let currentFallback = version
        let timeout = fetchTimeout
        let task = Task<String, Never> {
            await Self.fetch(client: client, timeoutSeconds: timeout) ?? currentFallback
        }
        inFlight = task
        let fetched = await task.value
        version = fetched
        askedAt = Date()
        inFlight = nil
        return fetched
    }

    static func fetch(
        client: HTTPClient,
        timeoutSeconds: TimeInterval = fetchTimeoutSeconds
    ) async -> String? {
        let handle = CancellationHandle()
        let boundedTimeout = max(timeoutSeconds, 0)
        return await withTaskCancellationHandler {
            await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    guard let (response, body) = try? await client.request(
                        url: manifestURL,
                        method: "GET",
                        headers: ["User-Agent": "electron-builder"],
                        body: nil,
                        cancellation: handle,
                        timeoutSeconds: boundedTimeout
                    ), (200..<300).contains(response.statusCode) else {
                        return nil
                    }
                    return parse(manifest: String(decoding: body.prefix(64 << 10), as: UTF8.self))
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(boundedTimeout * 1_000_000_000))
                        handle.cancel(reason: "timeout")
                    } catch {
                        // Timer cancelled because the request finished or parent cancelled.
                    }
                    return nil
                }
                let first = await group.next() ?? nil
                handle.cancel(reason: "completed")
                group.cancelAll()
                return first
            }
        } onCancel: {
            handle.cancel(reason: "cancelled")
        }
    }

    /// Extracts the `version:` value when it contains only digits and dots.
    public static func parse(manifest: String) -> String? {
        for line in manifest.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("version:") else { continue }
            let value = line.dropFirst("version:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard !value.isEmpty, value.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
            return value
        }
        return nil
    }
}

/// Reads Antigravity (`agy`) subscription usage from Google's Code Assist
/// backend (`retrieveUserQuotaSummary`, with `fetchAvailableModels` as a
/// pooled fallback).
///
/// Read-only: authenticates using only the stored Google OAuth access token
/// and never touches the refresh chain. When `credentials.extras["projectId"]`
/// is absent (the current default for `AgyOAuth`), the reader resolves the
/// account's Code Assist companion project on the fly via
/// `POST <productionHost>/v1internal:loadCodeAssist`.
///
/// The normalized output puts account-level tightest summary windows
/// (`limitID == nil`, `.fiveHour` and `.sevenDay`) first so subscription cards
/// and list badges work out of the box, followed by each quota pool's own
/// windows (`agy:gemini`, `agy:claude-gpt`, …) whenever more than one pool is
/// present.
public struct AgyUsageReader: OAuthUsageReader {
    public let providerId = AgyOAuth.providerId
    public let productionHost: URL
    public let dailyHost: URL
    public let hubVersion: AgyHubVersion

    public static let defaultProductionHost = URL(string: "https://cloudcode-pa.googleapis.com")!
    public static let defaultDailyHost = URL(string: "https://daily-cloudcode-pa.googleapis.com")!
    public static let quotaRequestTimeoutSeconds: TimeInterval = 15

    public init(
        productionHost: URL = AgyUsageReader.defaultProductionHost,
        dailyHost: URL = AgyUsageReader.defaultDailyHost,
        hubVersion: AgyHubVersion = .shared
    ) {
        self.productionHost = productionHost
        self.dailyHost = dailyHost
        self.hubVersion = hubVersion
    }

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        let handle = CancellationHandle()
        return try await withTaskCancellationHandler {
            let version = await hubVersion.current(client: client)
            try Task.checkCancellation()
            let ua = Self.userAgent(version: version)

            let account = try await resolveAccount(
                credentials: credentials,
                userAgent: ua,
                cancellation: handle,
                client: client
            )

            // Primary source: `retrieveUserQuotaSummary` returns Google's canonical
            // pooled groups (e.g. Gemini Models, Claude and GPT models) with exact
            // 5-hour and weekly buckets.
            do {
                let summary = try await postJSON(
                    host: dailyHost,
                    method: "retrieveUserQuotaSummary",
                    body: ["project": account.projectId],
                    access: credentials.access,
                    userAgent: ua,
                    cancellation: handle,
                    timeoutSeconds: Self.quotaRequestTimeoutSeconds,
                    client: client
                )
                let windows = Self.windows(fromSummary: summary)
                if !windows.isEmpty {
                    return windows
                }
            } catch OAuthUsageError.unavailable(_, let status?, _) where status == 404 || status == 501 {
                // Endpoint absent/unsupported on this host: fall through to model-level quota aggregation.
            }

            // Fallback: aggregate per-model quotas from `fetchAvailableModels` into
            // family pools so callers still receive concise, deduplicated windows.
            let models = try await fetchAvailableModels(
                account: account,
                access: credentials.access,
                userAgent: ua,
                cancellation: handle,
                client: client
            )
            return Self.windows(fromModels: models)
        } onCancel: {
            handle.cancel(reason: "cancelled")
        }
    }

    // MARK: - Wire helpers

    struct AccountInfo {
        var projectId: String
        var tier: String?
        var paidTier: String?
    }

    private func resolveAccount(
        credentials: OAuthCredentials,
        userAgent: String,
        cancellation: CancellationHandle?,
        client: HTTPClient
    ) async throws -> AccountInfo {
        if let projectId = AgyOAuth.projectId(credentials) {
            return AccountInfo(
                projectId: projectId,
                tier: Self.extra(credentials, "tier"),
                paidTier: Self.extra(credentials, "paidTier")
            )
        }
        return try await Self.loadCodeAssist(
            access: credentials.access,
            productionHost: productionHost,
            userAgent: userAgent,
            cancellation: cancellation,
            timeoutSeconds: AgyOAuth.projectLookupTimeoutSeconds,
            client: client
        )
    }

    /// Calls `POST <productionHost>/v1internal:loadCodeAssist` to resolve the
    /// account's Code Assist companion project and tier metadata.
    static func loadCodeAssist(
        access: String,
        productionHost: URL = AgyUsageReader.defaultProductionHost,
        userAgent: String,
        cancellation: CancellationHandle? = nil,
        timeoutSeconds: TimeInterval? = AgyOAuth.projectLookupTimeoutSeconds,
        client: HTTPClient
    ) async throws -> AccountInfo {
        let reply = try await postJSON(
            host: productionHost,
            method: "loadCodeAssist",
            body: ["metadata": ["ideType": "ANTIGRAVITY"]],
            access: access,
            userAgent: userAgent,
            cancellation: cancellation,
            timeoutSeconds: timeoutSeconds,
            client: client
        )
        guard let projectId = companionProject(reply["cloudaicompanionProject"]) else {
            throw OAuthUsageError.unavailable(
                providerId: AgyOAuth.providerId,
                status: nil,
                detail: "Antigravity account has no Code Assist project"
            )
        }
        let currentTier = (reply["currentTier"] as? [String: Any])?["id"] as? String
        let paidTier = (reply["paidTier"] as? [String: Any])?["id"] as? String
        return AccountInfo(projectId: projectId, tier: currentTier, paidTier: paidTier)
    }

    /// Best-effort Code Assist project discovery bounded by `timeoutSeconds`.
    /// Uses the cached/fallback Hub 2.x User-Agent (no manifest network call)
    /// and passes both `timeoutSeconds` and a `CancellationHandle` to the
    /// underlying `HTTPClient` so a hung socket aborts immediately when the
    /// timeout fires or the enclosing Swift `Task` is cancelled.
    static func bestEffortProjectId(
        access: String,
        productionHost: URL = AgyUsageReader.defaultProductionHost,
        hubVersion: AgyHubVersion = .shared,
        timeoutSeconds: Double = AgyOAuth.projectLookupTimeoutSeconds,
        client: HTTPClient
    ) async -> String? {
        let version = await hubVersion.cachedOrFallback
        let userAgent = Self.userAgent(version: version)
        let boundedTimeout = max(timeoutSeconds, 0)
        let handle = CancellationHandle()
        return await withTaskCancellationHandler {
            await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    try? await Self.loadCodeAssist(
                        access: access,
                        productionHost: productionHost,
                        userAgent: userAgent,
                        cancellation: handle,
                        timeoutSeconds: boundedTimeout,
                        client: client
                    ).projectId
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(boundedTimeout * 1_000_000_000))
                        handle.cancel(reason: "timeout")
                    } catch {
                        // Sleep cancelled because loadCodeAssist finished or parent cancelled.
                    }
                    return nil
                }
                let first = await group.next() ?? nil
                handle.cancel(reason: "completed")
                group.cancelAll()
                return first
            }
        } onCancel: {
            handle.cancel(reason: "cancelled")
        }
    }

    private func fetchAvailableModels(
        account: AccountInfo,
        access: String,
        userAgent: String,
        cancellation: CancellationHandle?,
        client: HTTPClient
    ) async throws -> [String: Any] {
        let tiers = Self.tiersToAsk(tier: account.tier, paidTier: account.paidTier)
        var lastError: Error = OAuthUsageError.unavailable(
            providerId: providerId,
            status: nil,
            detail: "Antigravity returned no models"
        )
        for tier in tiers {
            var body: [String: Any] = ["project": account.projectId]
            if !tier.isEmpty {
                body["entitlement"] = ["userTier": tier]
            }
            do {
                return try await Self.postJSON(
                    host: dailyHost,
                    method: "fetchAvailableModels",
                    body: body,
                    access: access,
                    userAgent: userAgent,
                    cancellation: cancellation,
                    timeoutSeconds: Self.quotaRequestTimeoutSeconds,
                    client: client
                )
            } catch let error as OAuthUsageError {
                if case .unavailable(_, let status?, _) = error, !tier.isEmpty, status == 400 {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    private func postJSON(
        host: URL,
        method: String,
        body: [String: Any],
        access: String,
        userAgent: String,
        cancellation: CancellationHandle?,
        timeoutSeconds: TimeInterval?,
        client: HTTPClient
    ) async throws -> [String: Any] {
        try await Self.postJSON(
            host: host,
            method: method,
            body: body,
            access: access,
            userAgent: userAgent,
            cancellation: cancellation,
            timeoutSeconds: timeoutSeconds,
            client: client
        )
    }

    private static func postJSON(
        host: URL,
        method: String,
        body: [String: Any],
        access: String,
        userAgent: String,
        cancellation: CancellationHandle?,
        timeoutSeconds: TimeInterval?,
        client: HTTPClient
    ) async throws -> [String: Any] {
        var base = host.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/v1internal:\(method)") else {
            throw OAuthUsageError.unavailable(providerId: AgyOAuth.providerId, status: nil, detail: "invalid endpoint URL")
        }
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let (response, data) = try await OAuthUsage.get(
            url,
            headers: [
                "Authorization": "Bearer \(access)",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": userAgent,
            ],
            method: "POST",
            body: encoded,
            provider: AgyOAuth.providerId,
            cancellation: cancellation,
            timeoutSeconds: timeoutSeconds,
            client: client
        )
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OAuthUsageError.unavailable(
                providerId: AgyOAuth.providerId,
                status: response.statusCode,
                detail: "undecodable body"
            )
        }
        return object
    }

    static func userAgent(version: String) -> String {
        "antigravity/hub/\(version) \(platform)"
    }

    static var platform: String {
        #if os(Linux)
        let os = "linux"
        #elseif os(Windows)
        let os = "windows"
        #else
        let os = "darwin"
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "\(os)/\(arch)"
    }

    private static func extra(_ credentials: OAuthCredentials, _ key: String) -> String? {
        guard case .string(let value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }

    static func companionProject(_ value: Any?) -> String? {
        if let id = value as? String, !id.isEmpty { return id }
        if let object = value as? [String: Any], let id = object["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    static func tiersToAsk(tier: String?, paidTier: String?) -> [String] {
        var out: [String] = []
        for candidate in [paidTier, tier] {
            guard let candidate, !candidate.isEmpty,
                  candidate != "free-tier", candidate != "legacy-tier",
                  !out.contains(candidate)
            else { continue }
            out.append(candidate)
        }
        return out + [""]
    }

    // MARK: - Normalization (retrieveUserQuotaSummary)

    /// Normalizes a `retrieveUserQuotaSummary` JSON body for tests and callers.
    public static func windows(fromSummaryJSON body: Data) throws -> [OAuthUsageWindow] {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an object"))
        }
        return windows(fromSummary: object)
    }

    /// Normalizes a `retrieveUserQuotaSummary` payload into account-level
    /// summary windows (`limitID == nil`) followed by per-pool windows
    /// (`limitID == "agy:<slug>"`) when multiple pools exist.
    public static func windows(fromSummary payload: [String: Any]) -> [OAuthUsageWindow] {
        struct ParsedPool {
            let slug: String
            let name: String
            let windows: [OAuthUsageWindow]
        }

        var pools: [ParsedPool] = []
        var seenPoolSlugs: Set<String> = []

        for group in payload["groups"] as? [[String: Any]] ?? [] {
            let rawName = group["displayName"] as? String ?? ""
            let name = poolName(rawName)
            guard !name.isEmpty else { continue }
            let slug = poolSlug(name)
            guard !slug.isEmpty, seenPoolSlugs.insert(slug).inserted else { continue }

            var poolWindows: [OAuthUsageWindow] = []
            var seenKeys: Set<String> = []

            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard bucket["disabled"] as? Bool != true else { continue }
                let rawWindow = (bucket["window"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                let kind: OAuthUsageWindowKind
                let seconds: Int?
                let limitID: String
                let limitName: String

                switch rawWindow {
                case "5h":
                    kind = .fiveHour
                    seconds = 5 * 60 * 60
                    limitID = "agy:\(slug)"
                    limitName = name
                case "weekly":
                    kind = .sevenDay
                    seconds = 7 * 24 * 60 * 60
                    limitID = "agy:\(slug)"
                    limitName = name
                default:
                    let label = [bucket["displayName"], bucket["window"], bucket["bucketId"]]
                        .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }
                    guard let label else { continue }
                    let bucketSlug = poolSlug(
                        (bucket["bucketId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label
                    )
                    guard !bucketSlug.isEmpty else { continue }
                    kind = .secondary
                    seconds = nil
                    limitID = "agy:\(slug):\(bucketSlug)"
                    limitName = "\(name) · \(label)"
                }

                // Proto3 JSON omits numeric zero; an active bucket without
                // `remainingFraction` is exhausted (0 remaining -> 100% used).
                let usedPercent = usedPercent(fromRemainingFraction: bucket["remainingFraction"])
                let resetsAt = millis(fromRFC3339: bucket["resetTime"])

                let dedupeKey = "\(limitID)|\(kind.rawValue)"
                if let existingIndex = poolWindows.firstIndex(where: { "\($0.limitID ?? "")|\($0.window.rawValue)" == dedupeKey }) {
                    poolWindows[existingIndex] = tighter(poolWindows[existingIndex], OAuthUsageWindow(
                        window: kind,
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        windowSeconds: seconds,
                        limitID: limitID,
                        limitName: limitName
                    ))
                } else if seenKeys.insert(dedupeKey).inserted {
                    poolWindows.append(OAuthUsageWindow(
                        window: kind,
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        windowSeconds: seconds,
                        limitID: limitID,
                        limitName: limitName
                    ))
                }
            }

            guard !poolWindows.isEmpty else { continue }
            // Keep canonical 5h -> 7d -> custom ordering inside each pool.
            poolWindows.sort { windowRank($0.window) < windowRank($1.window) }
            pools.append(ParsedPool(slug: slug, name: name, windows: poolWindows))
        }

        guard !pools.isEmpty else { return [] }

        let allPoolWindows = pools.flatMap(\.windows)
        var out: [OAuthUsageWindow] = []

        if let fiveHour = tightest(allPoolWindows.filter { $0.window == .fiveHour }) {
            out.append(OAuthUsageWindow(
                window: .fiveHour,
                usedPercent: fiveHour.usedPercent,
                resetsAt: fiveHour.resetsAt,
                windowSeconds: 5 * 60 * 60
            ))
        }
        if let sevenDay = tightest(allPoolWindows.filter { $0.window == .sevenDay }) {
            out.append(OAuthUsageWindow(
                window: .sevenDay,
                usedPercent: sevenDay.usedPercent,
                resetsAt: sevenDay.resetsAt,
                windowSeconds: 7 * 24 * 60 * 60
            ))
        }
        if out.isEmpty, let fallback = tightest(allPoolWindows) {
            out.append(OAuthUsageWindow(
                window: .primary,
                usedPercent: fallback.usedPercent,
                resetsAt: fallback.resetsAt,
                windowSeconds: fallback.windowSeconds
            ))
        }

        // Emit per-pool rows whenever there are multiple pools (or custom
        // non-5h/non-weekly buckets) so detail views show each pool without
        // duplicating a single-pool account's main windows.
        let hasCustomBuckets = allPoolWindows.contains { $0.window != .fiveHour && $0.window != .sevenDay }
        if pools.count > 1 || hasCustomBuckets {
            out.append(contentsOf: allPoolWindows)
        }
        return out
    }

    // MARK: - Normalization (fetchAvailableModels fallback)

    /// Normalizes a `fetchAvailableModels` JSON body by aggregating chat
    /// models into family pools (`Gemini`, `Claude & GPT`).
    public static func windows(fromModelsJSON body: Data) throws -> [OAuthUsageWindow] {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an object"))
        }
        return windows(fromModels: object)
    }

    public static func windows(fromModels payload: [String: Any]) -> [OAuthUsageWindow] {
        guard let models = payload["models"] as? [String: Any] else { return [] }

        var byPool: [String: (name: String, window: OAuthUsageWindow)] = [:]
        for (id, value) in models {
            guard isChatModel(id),
                  let model = value as? [String: Any],
                  model["disabled"] as? Bool != true,
                  let quota = model["quotaInfo"] as? [String: Any]
            else { continue }

            let (slug, name) = modelFamily(id: id, displayName: model["displayName"] as? String)
            guard !slug.isEmpty else { continue }

            let candidate = OAuthUsageWindow(
                window: .primary,
                usedPercent: usedPercent(fromRemainingFraction: quota["remainingFraction"]),
                resetsAt: millis(fromRFC3339: quota["resetTime"]),
                windowSeconds: nil,
                limitID: "agy:\(slug)",
                limitName: name
            )
            if let existing = byPool[slug] {
                byPool[slug] = (existing.name, tighter(existing.window, candidate))
            } else {
                byPool[slug] = (name, candidate)
            }
        }

        guard !byPool.isEmpty else { return [] }

        // Stable order: Gemini first, then Claude & GPT, then alphabetical.
        let orderedSlugs = byPool.keys.sorted { lhs, rhs in
            let order: [String: Int] = ["gemini": 0, "claude-gpt": 1]
            let lo = order[lhs] ?? 2
            let ro = order[rhs] ?? 2
            if lo != ro { return lo < ro }
            return lhs < rhs
        }
        let poolWindows = orderedSlugs.compactMap { byPool[$0]?.window }

        var out: [OAuthUsageWindow] = []
        if let summary = tightest(poolWindows) {
            out.append(OAuthUsageWindow(
                window: .primary,
                usedPercent: summary.usedPercent,
                resetsAt: summary.resetsAt,
                windowSeconds: nil
            ))
        }
        if poolWindows.count > 1 {
            out.append(contentsOf: poolWindows)
        }
        return out
    }

    // MARK: - Helpers

    static func isChatModel(_ id: String) -> Bool {
        if id.hasPrefix("chat_") || id.hasPrefix("tab_") { return false }
        return !hiddenModels.contains(id)
    }

    private static let hiddenModels: Set<String> = ["gemini-2.5-flash-thinking", "gemini-2.5-pro"]

    private static func modelFamily(id: String, displayName: String?) -> (slug: String, name: String) {
        let lower = id.lowercased()
        if lower.hasPrefix("gemini") { return ("gemini", "Gemini") }
        if lower.hasPrefix("claude") || lower.hasPrefix("gpt-oss") { return ("claude-gpt", "Claude & GPT") }
        if let display = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            return (poolSlug(display), display)
        }
        let token = String(lower.split(separator: "-").first ?? "")
        return (poolSlug(token), token.capitalized)
    }

    static func poolName(_ displayName: String) -> String {
        var name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(" models") {
            name = String(name.dropLast(" models".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.replacingOccurrences(of: " and ", with: " & ")
    }

    static func poolSlug(_ pool: String) -> String {
        var out = ""
        var hyphen = false
        for scalar in pool.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                hyphen = false
            } else if !hyphen, !out.isEmpty {
                out.append("-")
                hyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Converts `remainingFraction` (0...1, or omitted when exhausted) into
    /// `usedPercent` (0...100).
    static func usedPercent(fromRemainingFraction value: Any?) -> Double {
        guard let raw = (value as? NSNumber)?.doubleValue, raw.isFinite else {
            return 100
        }
        let clamped = min(1, max(0, raw))
        return (1 - clamped) * 100
    }

    private static func windowRank(_ kind: OAuthUsageWindowKind) -> Int {
        switch kind {
        case .fiveHour: 0
        case .sevenDay: 1
        case .primary: 2
        case .secondary: 3
        }
    }

    private static func tightest(_ windows: [OAuthUsageWindow]) -> OAuthUsageWindow? {
        windows.reduce(nil) { acc, next in
            guard let acc else { return next }
            return tighter(acc, next)
        }
    }

    /// Picks the more constrained of two windows: higher `usedPercent` wins;
    /// on a tie, an earlier non-nil `resetsAt` wins.
    private static func tighter(_ lhs: OAuthUsageWindow, _ rhs: OAuthUsageWindow) -> OAuthUsageWindow {
        if rhs.usedPercent != lhs.usedPercent {
            return rhs.usedPercent > lhs.usedPercent ? rhs : lhs
        }
        switch (lhs.resetsAt, rhs.resetsAt) {
        case (nil, .some): return rhs
        case (.some, nil): return lhs
        case let (l?, r?): return r < l ? rhs : lhs
        case (nil, nil): return lhs
        }
    }

    /// Parses an RFC 3339 timestamp with arbitrary fractional-second precision
    /// into Unix milliseconds.
    static func millis(fromRFC3339 value: Any?) -> Int64? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        var whole = text
        var fraction = 0.0
        if let dot = whole.firstIndex(of: "."),
           let zone = whole[dot...].firstIndex(where: { "Zz+-".contains($0) }) {
            let digits = whole[whole.index(after: dot)..<zone]
            guard !digits.isEmpty,
                  digits.allSatisfy({ ("0"..."9").contains($0) }),
                  let parsed = Double("0.\(digits)")
            else {
                return nil
            }
            fraction = parsed
            whole.removeSubrange(dot..<zone)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: whole) else { return nil }
        return Int64(date.timeIntervalSince1970) * 1000 + Int64((fraction * 1000).rounded(.down))
    }
}
