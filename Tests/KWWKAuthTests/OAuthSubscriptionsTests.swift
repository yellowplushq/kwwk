import Foundation
import Testing
@testable import KWWKAuth

@Suite("Subscriptions by store id", .serialized)
struct OAuthSubscriptionsTests {
    @Test("Every login that carries a refresh token has a refresher under its own id, and no other has one")
    func refreshersMatchUpkeep() {
        #expect(Set(OAuthSubscriptions.builtInProviders.map(\.id)).count == OAuthSubscriptions.builtInProviders.count)
        for provider in OAuthSubscriptions.builtInProviders {
            let refresher = OAuthSubscriptions.builtInRefresher(providerId: provider.id)
            if provider.upkeep == .refreshed {
                #expect(refresher?.id == provider.id, "\(provider.id)")
            } else {
                #expect(refresher == nil, "\(provider.id)")
            }
        }
        let expectedRefreshed = Set(OAuthSubscriptions.builtInProviders.filter { $0.upkeep == .refreshed }.map(\.id))
        #expect(expectedRefreshed.isSubset(of: OAuthSubscriptions.refreshedIds))
        #expect(OAuthSubscriptions.refresher(providerId: "some-new-vendor") == nil)
    }

    @Test("Each site of a two-site vendor is renewed and read at its own site")
    func sites() {
        #expect((OAuthSubscriptions.refresher(providerId: "qoder-cn") as? QoderOAuthProvider)?.site == .cn)
        #expect((OAuthSubscriptions.refresher(providerId: "qoder") as? QoderOAuthProvider)?.site == .global)
        #expect((OAuthSubscriptions.refresher(providerId: "workbuddy-ai") as? WorkBuddyOAuthProvider)?.site == .international)
        #expect((OAuthSubscriptions.refresher(providerId: "workbuddy") as? WorkBuddyOAuthProvider)?.site == .china)
        #expect((OAuthSubscriptions.refresher(providerId: "trae") as? TraeOAuthProvider)?.site == .china)
        #expect((OAuthSubscriptions.refresher(providerId: "trae-intl") as? TraeOAuthProvider)?.site == .international)
        #expect(OAuthSubscriptions.provider(id: "trae")?.name == "Trae CN")
        #expect(OAuthSubscriptions.provider(id: "trae-intl")?.name == "Trae")
        #expect(OAuthSubscriptions.refresher(providerId: "raccoon") is RaccoonOAuthProvider)
        #expect(OAuthSubscriptions.provider(id: "agy") == nil)
        #expect(OAuthSubscriptions.refresher(providerId: "agy") == nil)
        #expect((OAuthSubscriptions.refresher(providerId: "kimi-coding") as? KimiCodingOAuthProvider)?.site == .china)
        #expect((OAuthSubscriptions.refresher(providerId: "kimi-coding-ai") as? KimiCodingOAuthProvider)?.site == .global)
        #expect(OAuthSubscriptions.provider(id: "kimi-coding-ai")?.name == "Kimi For Coding Global")
    }

    @Test("Usage is read only for subscriptions that can be signed in to")
    func usageIds() {
        let known = Set(OAuthSubscriptions.builtInProviders.map(\.id))
        #expect(OAuthSubscriptions.usageIds.isSubset(of: known))
        #expect(OAuthSubscriptions.usageIds.contains("kiro"))
        #expect(!OAuthSubscriptions.usageIds.contains("agy"))
        #expect(OAuthSubscriptions.usageIds.contains("kimi-coding"))
        #expect(OAuthSubscriptions.usageIds.contains("kimi-coding-ai"))
        // A key or a session has no windows kwwk reads.
        #expect(!OAuthSubscriptions.usageIds.contains("zai"))
        #expect(!OAuthSubscriptions.usageIds.contains("github-copilot"))
    }

    @Test("A Kimi refresher carries the fingerprint a host hands it")
    func kimiIdentity() {
        let identity = KimiDeviceIdentity(
            deviceId: "abc",
            deviceName: "server",
            deviceModel: "Linux",
            osVersion: "Linux"
        )
        let kimi = OAuthSubscriptions.refresher(
            providerId: "kimi-coding",
            kimiIdentity: identity
        ) as? KimiCodingOAuthProvider
        #expect(kimi?.identity?.deviceId == "abc")
    }

    @Test("A store id with no sign-in is refused by name")
    func unknownLogin() async {
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthSubscriptions.login(providerId: "some-new-vendor", callbacks: OAuthLogin.Callbacks())
        }
        #expect(OAuthSubscriptions.provider(id: "some-new-vendor") == nil)
        #expect(OAuthSubscriptions.provider(id: "zai")?.upkeep == .permanent)
        #expect(OAuthSubscriptions.provider(id: "devin")?.upkeep == .session)
    }

    private struct StubCustomOAuthProvider: OAuthProvider {
        let id: String
        let name: String

        func refresh(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            OAuthCredentials(access: "refreshed-\(credentials.refresh)", refresh: credentials.refresh, expires: .max, extras: credentials.extras)
        }

        func baseURL(from credentials: OAuthCredentials) -> String? {
            guard case .string(let url) = credentials.extras["relayUrl"] ?? .null, !url.isEmpty else { return nil }
            return url
        }
    }

    @Test("Hosts can dynamically register, replace, and unregister custom OAuth subscriptions")
    func dynamicSubscriptionRegistration() async throws {
        let id = "custom-host-relay-\(UUID().uuidString.lowercased())"
        defer { OAuthSubscriptions.unregister(providerId: id) }

        let initial = OAuthSubscriptionRegistration(
            id: id,
            name: "Custom Relay",
            renewal: .refreshed { StubCustomOAuthProvider(id: id, name: "Custom Relay") },
            login: { _, _ in OAuthCredentials(access: "tok-1", refresh: "ref-1", expires: .max) }
        )
        OAuthSubscriptions.register(initial)
        // Re-registering with the same id replaces in place without duplicating.
        let updated = OAuthSubscriptionRegistration(
            id: id,
            name: "Custom Relay v2",
            renewal: .refreshed { StubCustomOAuthProvider(id: id, name: "Custom Relay v2") },
            login: { _, _ in OAuthCredentials(access: "tok-2", refresh: "ref-2", expires: .max) }
        )
        OAuthSubscriptions.register(updated)

        #expect(OAuthSubscriptions.providers.filter { $0.id == id }.count == 1)
        #expect(OAuthSubscriptions.provider(id: id)?.name == "Custom Relay v2")
        #expect(OAuthSubscriptions.refreshedIds.contains(id))
        #expect(OAuthSubscriptions.refreshers().contains { $0.id == id })
        let refresher = try #require(OAuthSubscriptions.refresher(providerId: id))
        #expect(refresher.id == id)
        #expect(refresher.baseURL(from: OAuthCredentials(access: "a", refresh: "r", expires: .max, extras: ["relayUrl": .string("https://relay.example.invalid")])) == "https://relay.example.invalid")
        let creds = try await OAuthSubscriptions.login(providerId: id, callbacks: OAuthLogin.Callbacks())
        #expect(creds.access == "tok-2")

        OAuthSubscriptions.unregister(providerId: id)
        #expect(OAuthSubscriptions.provider(id: id) == nil)
        #expect(OAuthSubscriptions.refresher(providerId: id) == nil)
        #expect(!OAuthSubscriptions.refreshedIds.contains(id))
    }

    @Test("Overriding a built-in subscription replaces it in place and restores it on unregister")
    func overridingBuiltInRestoresOnUnregister() async throws {
        let id = ZaiSite.china.id
        let originalIndex = try #require(OAuthSubscriptions.builtInProviders.firstIndex { $0.id == id })
        defer { OAuthSubscriptions.unregister(providerId: id) }

        OAuthSubscriptions.register(OAuthSubscriptionRegistration(
            id: id,
            name: "Custom BigModel",
            renewal: .refreshed { StubCustomOAuthProvider(id: id, name: "Custom BigModel") },
            login: { _, _ in OAuthCredentials(access: "override-tok", refresh: "override-ref", expires: .max) }
        ))
        #expect(OAuthSubscriptions.providers.filter { $0.id == id }.count == 1)
        #expect(OAuthSubscriptions.providers[originalIndex].name == "Custom BigModel")
        #expect(OAuthSubscriptions.provider(id: id)?.upkeep == .refreshed)
        #expect(OAuthSubscriptions.refresher(providerId: id)?.name == "Custom BigModel")
        let creds = try await OAuthSubscriptions.login(providerId: id, callbacks: OAuthLogin.Callbacks())
        #expect(creds.access == "override-tok")

        OAuthSubscriptions.unregister(providerId: id)
        #expect(OAuthSubscriptions.provider(id: id)?.name == "BigModel Coding Plan")
        #expect(OAuthSubscriptions.provider(id: id)?.upkeep == .permanent)
        #expect(OAuthSubscriptions.refresher(providerId: id) == nil)
    }

    @Test("GitHubCopilotOAuthProvider resolves its endpoint extra via OAuthProvider.baseURL(from:)")
    func copilotProviderBaseURL() {
        let provider = GitHubCopilotOAuthProvider()
        #expect(provider.baseURL(from: OAuthCredentials(access: "t", refresh: "r", expires: .max)) == nil)
        #expect(provider.baseURL(from: OAuthCredentials(access: "t", refresh: "r", expires: .max, extras: ["endpoint": .string("https://api.enterprise.githubcopilot.com")])) == "https://api.enterprise.githubcopilot.com")
    }
}
