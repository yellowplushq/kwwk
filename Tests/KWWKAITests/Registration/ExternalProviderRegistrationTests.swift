import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Dynamic host provider registration and Anthropic proxy hooks", .serialized)
struct ExternalProviderRegistrationTests {
    private struct CapturedRequest: Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data?
    }

    private actor CapturingSSEClient: HTTPClient {
        let sse: String
        private(set) var captured: [CapturedRequest] = []

        init(sse: String) {
            self.sse = sse
        }

        func stream(
            url: URL,
            method: String,
            headers: [String: String],
            body: Data?,
            cancellation: CancellationHandle?
        ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            captured.append(CapturedRequest(url: url, method: method, headers: headers, body: body))
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "text/event-stream"]
            )!
            let payload = Data(sse.utf8)
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(payload)
                continuation.finish()
            }
            return (response, stream)
        }
    }

    private static let minimalSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"model":"proxy/model-1","usage":{"input_tokens":10,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    private struct StubProxyOAuthProvider: OAuthProvider {
        let id: String
        let name: String
        let refreshedBaseURL: String?

        init(id: String, name: String, refreshedBaseURL: String? = nil) {
            self.id = id
            self.name = name
            self.refreshedBaseURL = refreshedBaseURL
        }

        func refresh(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            var extras = credentials.extras
            if let refreshedBaseURL {
                extras["baseUrl"] = .string(refreshedBaseURL)
            }
            return OAuthCredentials(
                access: "refreshed-\(credentials.access)",
                refresh: credentials.refresh,
                expires: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000,
                extras: extras
            )
        }

        func baseURL(from credentials: OAuthCredentials) -> String? {
            guard case .string(let raw) = credentials.extras["baseUrl"] ?? .null, !raw.isEmpty else {
                return nil
            }
            return raw
        }
    }

    private actor CountingCredentialSource: OAuthCredentialSource {
        let entries: [String: OAuthCredentials]
        private(set) var reads = 0

        init(_ entries: [String: OAuthCredentials]) {
            self.entries = entries
        }

        func providerIds() async -> [String] { Array(entries.keys) }

        func credentials(for providerId: String) async throws -> OAuthCredentials? {
            reads += 1
            return entries[providerId]
        }
    }

    @Test("AnthropicProvider modelIDTransform and compatTransform rewrite wire payloads while keeping model.id unprefixed")
    func anthropicProxyTransforms() async throws {
        let client = CapturingSSEClient(sse: Self.minimalSSE)
        let provider = AnthropicProvider(
            client: client,
            defaultBaseURL: URL(string: "https://proxy.example.invalid")!,
            defaultAPIKey: "tok-123",
            extraHeaders: ["x-proxy-secret": "sec-1"],
            authHeaderBuilder: { token in ["Authorization": "Bearer \(token)"] },
            modelIDTransform: { model in model.id.hasPrefix("proxy/") ? model.id : "proxy/\(model.id)" },
            compatTransform: { base in
                var compat = base ?? ModelCompat()
                compat.supportsServerCompaction = false
                compat.supportsLongCacheRetention = false
                return compat
            }
        )
        var initialCompat = ModelCompat()
        initialCompat.supportsServerCompaction = true
        initialCompat.supportsLongCacheRetention = true
        let model = Model(
            id: "model-1",
            name: "Model 1",
            api: "anthropic-messages",
            provider: "test-proxy",
            baseURL: "https://proxy.example.invalid",
            reasoning: false,
            input: [.text],
            contextWindow: 128_000,
            maxTokens: 8_192,
            compat: initialCompat
        )

        let stream = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(cacheRetention: .long)
        )
        for await _ in stream {}
        let result = await stream.result()

        #expect(result.model == "model-1")
        #expect(result.provider == "test-proxy")
        let req = try #require(await client.captured.first)
        #expect(req.url.absoluteString == "https://proxy.example.invalid/v1/messages")
        #expect(req.headers["Authorization"] == "Bearer tok-123")
        #expect(req.headers["x-proxy-secret"] == "sec-1")
        #expect(req.headers["x-api-key"] == nil)
        #expect(!(req.headers["anthropic-beta"] ?? "").contains("extended-cache-ttl"))
        let body = try #require(req.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == "proxy/model-1")
    }

    @Test("ModelsCatalog dynamically registers, updates, clears on empty list, and unregisters external provider catalogs")
    func modelsCatalogDynamicRegistration() throws {
        let providerId = "test-dynamic-catalog-\(UUID().uuidString.lowercased())"
        defer { ModelsCatalog.unregister(provider: providerId) }

        #expect(ModelsCatalog.model(provider: providerId, id: "m1") == nil)
        #expect(ModelsCatalog.models(for: providerId).isEmpty)

        let m1 = Model(
            id: "m1",
            name: "Model One",
            api: "anthropic-messages",
            provider: providerId,
            baseURL: "https://dynamic.example.invalid",
            reasoning: true,
            input: [.text],
            contextWindow: 200_000,
            maxTokens: 16_384
        )
        ModelsCatalog.register(provider: providerId, models: [m1])

        #expect(ModelsCatalog.providers.contains(providerId))
        #expect(ModelsCatalog.model(provider: providerId, id: "m1")?.name == "Model One")
        #expect(ModelsCatalog.models(for: providerId).map(\.id) == ["m1"])
        #expect(ModelsCatalog.byProvider[providerId]?["m1"]?.id == "m1")
        #expect(ModelsCatalog.all.contains { $0.provider == providerId && $0.id == "m1" })

        // Passing an empty array clears the dynamic overlay cleanly.
        ModelsCatalog.register(provider: providerId, models: [])
        #expect(!ModelsCatalog.providers.contains(providerId))
        #expect(ModelsCatalog.model(provider: providerId, id: "m1") == nil)
        #expect(ModelsCatalog.models(for: providerId).isEmpty)
    }

    @Test("StoredProviderRegistry wires directory, attribution, catalog, registerStored, and registerAllStored")
    func storedProviderDynamicRegistration() async throws {
        let suffix = UUID().uuidString.lowercased()
        let storeId = "test-dynamic-stored-\(suffix)"
        let scope = "test-dynamic-scope-\(suffix)"
        let catalogKey = "test-dynamic-cat-\(suffix)"
        defer {
            StoredProviderRegistry.unregister(storeId: storeId)
            OAuthSubscriptions.unregister(providerId: storeId)
        }

        let model = Model(
            id: "dyn-model-1",
            name: "Dynamic Model 1",
            api: "anthropic-messages",
            provider: scope,
            baseURL: "",
            reasoning: true,
            input: [.text],
            contextWindow: 100_000,
            maxTokens: 8_192
        )
        OAuthSubscriptions.register(OAuthSubscriptionRegistration(
            id: storeId,
            name: "Dynamic Provider",
            renewal: .refreshed { StubProxyOAuthProvider(id: storeId, name: "Dynamic Provider") },
            login: { _, _ in OAuthCredentials(access: "tok", refresh: "ref", expires: .max) }
        ))
        StoredProviderRegistry.register(StoredProviderRegistration(
            descriptor: ProviderDescriptor(
                storeId: storeId,
                scope: scope,
                catalogKey: catalogKey,
                displayName: "Dynamic Provider",
                formTitle: nil
            ),
            models: [model],
            register: { manager, creds, modelOverride, _, _, _ in
                guard case .string(let base) = creds.extras["baseUrl"] ?? .null,
                      let url = URL(string: base) else {
                    return nil
                }
                await APIRegistry.shared.register(
                    AnthropicProvider(defaultBaseURL: url, authHeaderBuilder: { ["Authorization": "Bearer \($0)"] }),
                    scope: scope
                )
                var active = ModelsCatalog.model(provider: catalogKey, id: modelOverride ?? model.id) ?? model
                active.baseURL = base
                return ResolvedAuth(
                    model: active,
                    modelLabel: "\(active.id) · Dynamic Provider",
                    authResolver: manager.resolver(for: storeId, scheme: .bearer, baseURL: base)
                )
            }
        ))

        do {
            #expect(providerDescriptor(forStoreId: storeId)?.displayName == "Dynamic Provider")
            #expect(ProviderAttribution.getProviderDisplayName(scope) == "Dynamic Provider")
            #expect(ProviderAttribution.getProviderDisplayName(catalogKey) == "Dynamic Provider")
            #expect(ModelsCatalog.model(provider: catalogKey, id: "dyn-model-1")?.name == "Dynamic Model 1")
            #expect(storedProviderOrder(ids: ["zz-unknown", storeId]).first == storeId)

            let store = OAuthStore()
            try await store.set(
                OAuthCredentials(
                    access: "dyn-access",
                    refresh: "dyn-refresh",
                    expires: .max,
                    extras: ["baseUrl": .string("https://dyn-relay.example.invalid")]
                ),
                for: storeId
            )
            let manager = OAuthManager(store: store)
            let allResolved = try await registerAllStored(
                manager: manager,
                modelOverride: "\(catalogKey)/dyn-model-1"
            )
            #expect(allResolved.model.provider == scope)
            #expect(allResolved.model.baseURL == "https://dyn-relay.example.invalid")
            #expect(allResolved.providerSlots.map(\.storeId) == [storeId])

            let auth = try #require(try await allResolved.authResolver?(allResolved.model, nil))
            #expect(auth.token == "dyn-access")
            #expect(auth.baseURL == "https://dyn-relay.example.invalid")

            StoredProviderRegistry.unregister(storeId: storeId)
            #expect(providerDescriptor(forStoreId: storeId) == nil)
            #expect(ProviderAttribution.displayNames[scope] == nil)
            #expect(ModelsCatalog.model(provider: catalogKey, id: "dyn-model-1") == nil)
            let skipped = try await registerStored(storeId: storeId, manager: manager, primeToken: false)
            #expect(skipped == nil)
        } catch {
            await APIRegistry.shared.unregisterScope(scope)
            throw error
        }
        await APIRegistry.shared.unregisterScope(scope)
    }

    @Test("Store-less OAuthManager returns refreshed baseURL from overlay with a single source read")
    func storelessManagerRefreshedBaseURL() async throws {
        let id = "test-refreshed-base-\(UUID().uuidString.lowercased())"
        let source = CountingCredentialSource([
            id: OAuthCredentials(
                access: "old-tok",
                refresh: "ref-tok",
                expires: 0,
                extras: ["baseUrl": .string("https://old.example.invalid")]
            ),
        ])
        let manager = OAuthManager(
            source: source,
            providers: [StubProxyOAuthProvider(id: id, name: "Relay", refreshedBaseURL: "https://fresh.example.invalid")]
        )
        let model = Model(
            id: "m",
            name: "M",
            api: "anthropic-messages",
            provider: id,
            baseURL: "",
            reasoning: false,
            input: [.text],
            contextWindow: 100_000,
            maxTokens: 4_096
        )
        let resolved = try #require(try await manager.resolver()(model, nil))
        #expect(resolved.token == "refreshed-old-tok")
        #expect(resolved.baseURL == "https://fresh.example.invalid")

        // Second call uses the held overlay and returns the refreshed baseURL with a single source read.
        let readsBeforeSecond = await source.reads
        let second = try #require(try await manager.resolver(for: id)(model, nil))
        #expect(second.token == "refreshed-old-tok")
        #expect(second.baseURL == "https://fresh.example.invalid")
        #expect(await source.reads == readsBeforeSecond + 1)
    }

    @Test("Shared catalogKey across dynamic StoredProviderRegistrations restores the earlier owner on unregister")
    func sharedCatalogKeyRestoration() {
        let suffix = UUID().uuidString.lowercased()
        let firstId = "test-shared-a-\(suffix)"
        let secondId = "test-shared-b-\(suffix)"
        let sharedKey = "test-shared-cat-\(suffix)"
        defer {
            StoredProviderRegistry.unregister(storeId: secondId)
            StoredProviderRegistry.unregister(storeId: firstId)
        }

        let m1 = Model(id: "m1", name: "First", api: "anthropic-messages", provider: sharedKey, baseURL: "", reasoning: false, input: [.text], contextWindow: 100_000, maxTokens: 4_096)
        let m2 = Model(id: "m2", name: "Second", api: "anthropic-messages", provider: sharedKey, baseURL: "", reasoning: false, input: [.text], contextWindow: 100_000, maxTokens: 4_096)
        let noop: StoredProviderRegistration.RegisterHandler = { _, _, _, _, _, _ in nil }

        StoredProviderRegistry.register(StoredProviderRegistration(
            descriptor: ProviderDescriptor(storeId: firstId, scope: firstId, catalogKey: sharedKey, displayName: "First", formTitle: nil),
            models: [m1],
            register: noop
        ))
        StoredProviderRegistry.register(StoredProviderRegistration(
            descriptor: ProviderDescriptor(storeId: secondId, scope: secondId, catalogKey: sharedKey, displayName: "Second", formTitle: nil),
            models: [m2],
            register: noop
        ))
        #expect(ModelsCatalog.models(for: sharedKey).map(\.id) == ["m2"])

        StoredProviderRegistry.unregister(storeId: secondId)
        #expect(ModelsCatalog.models(for: sharedKey).map(\.id) == ["m1"])

        StoredProviderRegistry.unregister(storeId: firstId)
        #expect(ModelsCatalog.models(for: sharedKey).isEmpty)
    }

    @Test("OAuthManager tolerates duplicate provider IDs by keeping the latest registration")
    func duplicateProviderIDsInOAuthManagerKeepLatest() async throws {
        let id = "test-dup-\(UUID().uuidString.lowercased())"
        let store = OAuthStore()
        try await store.set(
            OAuthCredentials(access: "tok", refresh: "ref", expires: 0),
            for: id
        )
        let manager = OAuthManager(
            store: store,
            providers: [
                StubProxyOAuthProvider(id: id, name: "First", refreshedBaseURL: "https://first.example.invalid"),
                StubProxyOAuthProvider(id: id, name: "Second", refreshedBaseURL: "https://second.example.invalid"),
            ]
        )
        let model = Model(id: "m", name: "M", api: "anthropic-messages", provider: id, baseURL: "", reasoning: false, input: [.text], contextWindow: 100_000, maxTokens: 4_096)
        let resolved = try #require(try await manager.resolver(for: id)(model, nil))
        #expect(resolved.baseURL == "https://second.example.invalid")
    }

    @Test("Empty-models StoredProviderRegistration preserves external ModelsCatalog entries while replacing non-empty models clears them")
    func emptyModelsRegistrationPreservesExternalCatalog() {
        let suffix = UUID().uuidString.lowercased()
        let storeId = "test-empty-models-\(suffix)"
        let catalogKey = "test-empty-cat-\(suffix)"
        defer {
            StoredProviderRegistry.unregister(storeId: storeId)
            ModelsCatalog.unregister(provider: catalogKey)
        }

        let externalModel = Model(id: "ext-1", name: "External", api: "anthropic-messages", provider: catalogKey, baseURL: "", reasoning: false, input: [.text], contextWindow: 100_000, maxTokens: 4_096)
        ModelsCatalog.register(provider: catalogKey, models: [externalModel])

        let noop: StoredProviderRegistration.RegisterHandler = { _, _, _, _, _, _ in nil }
        StoredProviderRegistry.register(StoredProviderRegistration(
            descriptor: ProviderDescriptor(storeId: storeId, scope: storeId, catalogKey: catalogKey, displayName: "Ext", formTitle: nil),
            models: [],
            register: noop
        ))
        // Registering with models: [] must not wipe externally registered catalog entries.
        #expect(ModelsCatalog.models(for: catalogKey).map(\.id) == ["ext-1"])

        // Registering non-empty models takes ownership, and replacing with models: [] clears them.
        let ownedModel = Model(id: "owned-1", name: "Owned", api: "anthropic-messages", provider: catalogKey, baseURL: "", reasoning: false, input: [.text], contextWindow: 100_000, maxTokens: 4_096)
        StoredProviderRegistry.register(StoredProviderRegistration(
            descriptor: ProviderDescriptor(storeId: storeId, scope: storeId, catalogKey: catalogKey, displayName: "Ext", formTitle: nil),
            models: [ownedModel],
            register: noop
        ))
        #expect(ModelsCatalog.models(for: catalogKey).map(\.id) == ["owned-1"])

        StoredProviderRegistry.register(StoredProviderRegistration(
            descriptor: ProviderDescriptor(storeId: storeId, scope: storeId, catalogKey: catalogKey, displayName: "Ext", formTitle: nil),
            models: [],
            register: noop
        ))
        #expect(ModelsCatalog.models(for: catalogKey).isEmpty)
    }

    @Test("Empty string from OAuthProvider.baseURL(from:) falls back to resolver fallbackBaseURL")
    func emptyBaseURLFallsBack() async throws {
        struct EmptyBaseProvider: OAuthProvider {
            let id: String
            let name = "EmptyBase"
            func refresh(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials { credentials }
            func baseURL(from credentials: OAuthCredentials) -> String? { "" }
        }
        let id = "test-empty-base-\(UUID().uuidString.lowercased())"
        let store = OAuthStore()
        try await store.set(OAuthCredentials(access: "tok", refresh: "", expires: .max), for: id)
        let manager = OAuthManager(store: store, providers: [EmptyBaseProvider(id: id)])
        let model = Model(id: "m", name: "M", api: "anthropic-messages", provider: id, baseURL: "", reasoning: false, input: [.text], contextWindow: 100_000, maxTokens: 4_096)
        let resolved = try #require(try await manager.resolver(for: id, baseURL: "https://fallback.example.invalid")(model, nil))
        #expect(resolved.baseURL == "https://fallback.example.invalid")
    }
}
