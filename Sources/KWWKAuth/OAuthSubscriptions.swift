import Foundation
import NIOConcurrencyHelpers
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Host-registered OAuth subscription injected at process startup. Keeps
/// host-specific or relay-backed providers outside kwwk while participating
/// uniformly in `OAuthSubscriptions.providers`, `login`, `refresher`, and
/// `OAuthManager.defaultProviders()`.
///
/// Hosts should register all custom subscriptions at process startup before
/// evaluating cached provider sets (such as `OAuthSubscriptions.refreshedIds`
/// or `OAuthManager.defaultProviders()`). For `.refreshed` entries, the
/// returned `OAuthProvider.id` must equal `registration.id`; `.session` and
/// `.permanent` entries do not join `OAuthManager.defaultProviders()` (hosts
/// using `OAuthManager` with them register an `OAuthProvider` explicitly).
public struct OAuthSubscriptionRegistration: Sendable {
    /// How credentials from this subscription stay valid. Coupling `.refreshed`
    /// with its refresher factory guarantees `OAuthSubscriptions.refreshedIds`
    /// and `refresher(providerId:)` can never disagree.
    public enum Renewal: Sendable {
        case refreshed(@Sendable () -> any OAuthProvider)
        case session
        case permanent
    }

    public typealias LoginHandler = @Sendable (
        _ callbacks: OAuthLogin.Callbacks,
        _ client: HTTPClient
    ) async throws -> OAuthCredentials

    public let id: String
    public let name: String
    public let renewal: Renewal
    public let login: LoginHandler

    public init(
        id: String,
        name: String,
        renewal: Renewal,
        login: @escaping LoginHandler
    ) {
        self.id = id
        self.name = name
        self.renewal = renewal
        self.login = login
    }

    public var upkeep: OAuthSubscriptions.Upkeep {
        switch renewal {
        case .refreshed: .refreshed
        case .session: .session
        case .permanent: .permanent
        }
    }

    public var provider: OAuthSubscriptions.Provider {
        OAuthSubscriptions.Provider(id: id, name: name, upkeep: upkeep)
    }

    func makeRefresher() -> (any OAuthProvider)? {
        switch renewal {
        case .refreshed(let factory): factory()
        case .session, .permanent: nil
        }
    }
}

/// Every subscription kwwk can sign in to, keep alive and read the usage of,
/// by the store id its login is kept under. A host — the kwwk CLI, an app
/// that runs the sign-in, a server that holds the refresh chain — asks here
/// and keeps no list of its own, so a provider kwwk gains reaches each of
/// them with the version that carries it. Hosts that carry private or
/// relay-backed providers register them at startup via `register(_:)`.
public enum OAuthSubscriptions {
    /// What a sign-in leaves behind, which decides who has to look after it.
    public enum Upkeep: Sendable, Equatable {
        /// A refresh token: someone has to trade it for a new access token
        /// before the old one lapses (`refresher`).
        case refreshed
        /// A session that lapses and cannot be renewed: sign in again.
        case session
        /// A key that does not expire.
        case permanent
    }

    public struct Provider: Sendable, Equatable {
        public let id: String
        public let name: String
        public let upkeep: Upkeep

        public init(id: String, name: String, upkeep: Upkeep) {
            self.id = id
            self.name = name
            self.upkeep = upkeep
        }
    }

    package static let builtInProviders: [Provider] = [
        Provider(id: "openai-codex", name: "ChatGPT Codex", upkeep: .refreshed),
        Provider(id: "anthropic", name: "Claude Pro or Max", upkeep: .refreshed),
        Provider(id: "github-copilot", name: "GitHub Copilot", upkeep: .refreshed),
        Provider(id: "cursor", name: "Cursor", upkeep: .refreshed),
        Provider(id: "devin", name: "Devin", upkeep: .session),
        Provider(id: "kiro", name: "Kiro", upkeep: .refreshed),
        Provider(id: QoderSite.global.id, name: QoderSite.global.name, upkeep: .refreshed),
        Provider(id: QoderSite.cn.id, name: QoderSite.cn.name, upkeep: .refreshed),
        Provider(id: WorkBuddySite.china.id, name: WorkBuddySite.china.name, upkeep: .refreshed),
        Provider(id: WorkBuddySite.international.id, name: WorkBuddySite.international.name, upkeep: .refreshed),
        Provider(id: TraeSite.china.id, name: TraeSite.china.name, upkeep: .refreshed),
        Provider(id: TraeSite.international.id, name: TraeSite.international.name, upkeep: .refreshed),
        Provider(id: RaccoonOAuth.providerId, name: RaccoonOAuth.name, upkeep: .refreshed),
        Provider(id: KimiSite.china.id, name: KimiSite.china.name, upkeep: .refreshed),
        Provider(id: KimiSite.global.id, name: KimiSite.global.name, upkeep: .refreshed),
        Provider(id: "xai", name: "Grok", upkeep: .refreshed),
        Provider(id: "zai", name: "Z.ai Coding Plan", upkeep: .permanent),
        Provider(id: ZaiSite.china.id, name: "BigModel Coding Plan", upkeep: .permanent),
        Provider(id: "openrouter", name: "OpenRouter", upkeep: .permanent),
    ]

    private static let dynamicRegistrations = NIOLockedValueBox<[OAuthSubscriptionRegistration]>([])

    /// Register (or replace in place by `id`) a host-provided OAuth
    /// subscription. Idempotent: calling twice with the same `id` updates the
    /// existing entry without creating duplicates.
    public static func register(_ registration: OAuthSubscriptionRegistration) {
        dynamicRegistrations.withLockedValue { entries in
            if let idx = entries.firstIndex(where: { $0.id == registration.id }) {
                entries[idx] = registration
            } else {
                entries.append(registration)
            }
        }
    }

    /// Remove a previously registered dynamic OAuth subscription.
    public static func unregister(providerId: String) {
        dynamicRegistrations.withLockedValue { entries in
            entries.removeAll { $0.id == providerId }
        }
    }

    private static func dynamicRegistration(for providerId: String) -> OAuthSubscriptionRegistration? {
        dynamicRegistrations.withLockedValue { entries in
            entries.first { $0.id == providerId }
        }
    }

    /// Every sign-in `login(providerId:)` runs, in the order kwwk lists them,
    /// followed by any host-registered subscriptions. A dynamic registration
    /// sharing a built-in id replaces it in place.
    public static var providers: [Provider] {
        let dynamic = dynamicRegistrations.withLockedValue { $0 }
        guard !dynamic.isEmpty else { return builtInProviders }
        var byID: [String: Provider] = Dictionary(uniqueKeysWithValues: dynamic.map { ($0.id, $0.provider) })
        var merged = builtInProviders.map { builtIn in
            byID.removeValue(forKey: builtIn.id) ?? builtIn
        }
        for entry in dynamic where byID[entry.id] != nil {
            merged.append(entry.provider)
        }
        return merged
    }

    public static func provider(id: String) -> Provider? {
        if let custom = dynamicRegistration(for: id) {
            return custom.provider
        }
        return builtInProviders.first { $0.id == id }
    }

    /// The store ids whose logins carry a refresh token, each with a
    /// `refresher`. A host that stores logins for others accepts a
    /// refresh-bearing one only under these.
    public static var refreshedIds: Set<String> {
        Set(providers.filter { $0.upkeep == .refreshed }.map(\.id))
    }

    /// The store ids whose usage kwwk can read (`OAuthUsage.readers`).
    public static var usageIds: Set<String> {
        Set(OAuthUsage.readers.keys)
    }

    /// Runs `providerId`'s sign-in. `kimiIdentity` is the device fingerprint
    /// Kimi binds a grant to; nil uses this machine's.
    public static func login(
        providerId: String,
        callbacks: OAuthLogin.Callbacks,
        kimiIdentity: KimiDeviceIdentity? = nil,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        if let custom = dynamicRegistration(for: providerId) {
            return try await custom.login(callbacks, client)
        }
        switch providerId {
        case "anthropic":
            return try await OAuthLogin.loginAnthropic(callbacks: callbacks, client: client)
        case "openai-codex":
            return try await OAuthLogin.loginOpenAICodex(callbacks: callbacks, client: client)
        case "github-copilot":
            return try await OAuthLogin.loginGitHubCopilot(callbacks: callbacks, client: client)
        case "cursor":
            return try await OAuthLogin.loginCursor(callbacks: callbacks, client: client)
        case "devin":
            return try await OAuthLogin.loginDevin(callbacks: callbacks, client: client)
        case "kiro":
            return try await OAuthLogin.loginKiro(callbacks: callbacks, client: client)
        case QoderSite.global.id:
            return try await OAuthLogin.loginQoder(site: .global, callbacks: callbacks, client: client)
        case QoderSite.cn.id:
            return try await OAuthLogin.loginQoder(site: .cn, callbacks: callbacks, client: client)
        case WorkBuddySite.china.id:
            return try await OAuthLogin.loginWorkBuddy(site: .china, callbacks: callbacks, client: client)
        case WorkBuddySite.international.id:
            return try await OAuthLogin.loginWorkBuddy(site: .international, callbacks: callbacks, client: client)
        case TraeSite.china.id, TraeSite.international.id:
            return try await OAuthLogin.loginTrae(
                site: TraeSite.site(id: providerId)!,
                callbacks: callbacks,
                client: client
            )
        case RaccoonOAuth.providerId:
            return try await OAuthLogin.loginRaccoon(callbacks: callbacks, client: client)
        case KimiSite.china.id, KimiSite.global.id:
            return try await OAuthLogin.loginKimiCoding(
                site: KimiSite.site(id: providerId)!,
                identity: kimiIdentity,
                callbacks: callbacks,
                client: client
            )
        case "xai":
            return try await OAuthLogin.loginXai(callbacks: callbacks, client: client)
        case ZaiSite.global.id:
            return try await OAuthLogin.loginZai(site: .global, callbacks: callbacks, client: client)
        case ZaiSite.china.id:
            return try await OAuthLogin.loginZai(site: .china, callbacks: callbacks, client: client)
        case "openrouter":
            return try await OAuthLogin.loginOpenRouter(callbacks: callbacks, client: client)
        default:
            throw OAuthError.unknownProvider(providerId)
        }
    }

    /// The provider that renews `providerId`'s login, nil for a store id
    /// with nothing to renew. `kimiIdentity` is sent for a Kimi login that
    /// recorded no device id of its own; nil uses this machine's.
    public static func refresher(
        providerId: String,
        kimiIdentity: KimiDeviceIdentity? = nil
    ) -> (any OAuthProvider)? {
        if let custom = dynamicRegistration(for: providerId) {
            return custom.makeRefresher()
        }
        return builtInRefresher(providerId: providerId, kimiIdentity: kimiIdentity)
    }

    package static func builtInRefresher(
        providerId: String,
        kimiIdentity: KimiDeviceIdentity? = nil
    ) -> (any OAuthProvider)? {
        switch providerId {
        case "anthropic": return AnthropicOAuthProvider()
        case "openai-codex": return OpenAICodexOAuthProvider()
        case "github-copilot": return GitHubCopilotOAuthProvider()
        case "cursor": return CursorOAuthProvider()
        case "kiro": return KiroOAuthProvider()
        case QoderSite.global.id: return QoderOAuthProvider(site: .global)
        case QoderSite.cn.id: return QoderOAuthProvider(site: .cn)
        case WorkBuddySite.china.id: return WorkBuddyOAuthProvider(site: .china)
        case WorkBuddySite.international.id: return WorkBuddyOAuthProvider(site: .international)
        case TraeSite.china.id, TraeSite.international.id:
            return TraeOAuthProvider(site: TraeSite.site(id: providerId)!)
        case RaccoonOAuth.providerId: return RaccoonOAuthProvider()
        case KimiSite.china.id, KimiSite.global.id:
            return KimiCodingOAuthProvider(site: KimiSite.site(id: providerId)!, identity: kimiIdentity)
        case "xai": return XaiOAuthProvider()
        default: return nil
        }
    }

    /// A refresher for every login that has one, in `providers` order.
    public static func refreshers(kimiIdentity: KimiDeviceIdentity? = nil) -> [any OAuthProvider] {
        let dynamic = dynamicRegistrations.withLockedValue { $0 }
        guard !dynamic.isEmpty else {
            return builtInProviders.compactMap { builtInRefresher(providerId: $0.id, kimiIdentity: kimiIdentity) }
        }
        var byID = Dictionary(uniqueKeysWithValues: dynamic.map { ($0.id, $0) })
        var result: [any OAuthProvider] = []
        for builtIn in builtInProviders {
            if let override = byID.removeValue(forKey: builtIn.id) {
                if let refresher = override.makeRefresher() { result.append(refresher) }
            } else if let refresher = builtInRefresher(providerId: builtIn.id, kimiIdentity: kimiIdentity) {
                result.append(refresher)
            }
        }
        for entry in dynamic where byID[entry.id] != nil {
            if let refresher = entry.makeRefresher() { result.append(refresher) }
        }
        return result
    }
}
