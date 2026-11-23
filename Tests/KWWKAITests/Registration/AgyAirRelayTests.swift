import Foundation
import Testing
@testable import KWWKAI

@Suite("Antigravity CLI (agy) AirRelay wiring & catalog")
struct AgyAirRelayTests {
    static let anthropicSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"model":"agy/gemini-4-neon-high","usage":{"input_tokens":10,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    private func decodeJSON(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("ProviderVariants.agyAirRelay sends Bearer auth, anthropic-version 2023-06-01, optional x-relay-secret, and agy/ wire model prefix")
    func agyAirRelayHeadersAndModelPrefix() async throws {
        let client = StubSSEClient(body: Self.anthropicSSE)
        let provider = ProviderVariants.agyAirRelay(
            baseURL: URL(string: "https://relay.airbuild.example/v1/")!,
            accessToken: "ya29.google-token",
            relaySecret: "relay-secret-42",
            client: client
        )

        let model = AgyModels.model(id: "gemini-4-neon-high")
        let result = await provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(cacheRetention: .long)
        ).result()

        #expect(result.stopReason == .stop)
        // Streamed AssistantMessage keeps the unprefixed model.id while wire body carries agy/<slug>.
        #expect(result.model == "gemini-4-neon-high")
        #expect(result.provider == "agy")

        let req = try #require(client.lastRequest)
        #expect(req.url.absoluteString == "https://relay.airbuild.example/v1/messages")
        #expect(req.headers["Authorization"] == "Bearer ya29.google-token")
        #expect(req.headers["x-relay-secret"] == "relay-secret-42")
        #expect(req.headers["anthropic-version"] == "2023-06-01")
        #expect(req.headers["x-api-key"] == nil)
        // Long cache retention beta is disabled for agy.
        let beta = req.headers["anthropic-beta"] ?? ""
        #expect(!beta.contains("extended-cache-ttl"))
        #expect(!beta.contains("inline-tools"))
        #expect(!beta.contains("compact-2026-01-12"))

        let body = try decodeJSON(req.body)
        #expect(body["model"] as? String == "agy/gemini-4-neon-high")
        #expect(body["stream"] as? Bool == true)
    }

    @Test("ProviderVariants.agyAirRelay omits x-relay-secret when nil or empty and avoids double-prefixing agy/")
    func agyAirRelayOptionalSecretAndNoDoublePrefix() async throws {
        let client = StubSSEClient(body: Self.anthropicSSE)
        let provider = ProviderVariants.agyAirRelay(
            baseURL: URL(string: "https://relay.airbuild.example")!,
            accessToken: "ya29.tok",
            relaySecret: nil,
            client: client
        )

        let prefixed = Model(
            id: "agy/claude-sonnet-5-5-high",
            name: "Claude Sonnet 5.5 (High)",
            api: "anthropic-messages",
            provider: "agy"
        )
        _ = await provider.stream(
            model: prefixed,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        ).result()

        let req = try #require(client.lastRequest)
        #expect(req.headers["x-relay-secret"] == nil)
        #expect(req.headers["Authorization"] == "Bearer ya29.tok")
        let body = try decodeJSON(req.body)
        #expect(body["model"] as? String == "agy/claude-sonnet-5-5-high")
    }

    @Test("ProviderVariants.agyAirRelay disables server compaction and mid-conversation tool changes even on bare models")
    func agyAirRelayDisablesUnsupportedFeatures() async throws {
        let client = StubSSEClient(body: Self.anthropicSSE)
        let provider = ProviderVariants.agyAirRelay(
            baseURL: URL(string: "https://relay.airbuild.example")!,
            accessToken: "ya29.tok",
            client: client
        )

        // Even a model that opts into server compaction and mid-convo tool changes
        // must have those capabilities stripped on the agy AirRelay route.
        var enabledCompat = ModelCompat()
        enabledCompat.supportsServerCompaction = true
        enabledCompat.supportsMidConvoSystemMessages = true
        enabledCompat.supportsMidConvoToolChanges = true
        enabledCompat.supportsAdditionalTools = true
        enabledCompat.supportsToolSearch = true
        enabledCompat.supportsLongCacheRetention = true

        let claudeModel = Model(
            id: "claude-sonnet-5-5-high",
            name: "Claude Sonnet 5.5 (High)",
            api: "anthropic-messages",
            provider: "agy",
            compat: enabledCompat
        )

        let compactResult = try await provider.compact(
            model: claudeModel,
            context: Context(messages: [.user(UserMessage(text: "compact me"))]),
            instructions: "summarize",
            options: nil
        )
        #expect(compactResult == nil)
        #expect(client.lastRequest == nil)

        let tool = Tool(name: "ping", description: "ping", parameters: ["type": "object"])
        _ = await provider.stream(
            model: claudeModel,
            context: Context(
                messages: [
                    .system(SystemMessage(toolsAdded: [tool])),
                    .user(UserMessage(text: "hi")),
                    .system(SystemMessage(toolsAdded: [
                        Tool(name: "pong", description: "pong", parameters: ["type": "object"]),
                    ])),
                ],
                tools: [tool]
            ),
            options: StreamOptions(cacheRetention: .long)
        ).result()

        let req = try #require(client.lastRequest)
        let beta = req.headers["anthropic-beta"] ?? ""
        #expect(!beta.contains("inline-tools"))
        #expect(!beta.contains("extended-cache-ttl"))
        let body = try decodeJSON(req.body)
        #expect(body["model"] as? String == "agy/claude-sonnet-5-5-high")
    }

    @Test("ModelsCatalog ships agy models with text-only input and disabled unsupported compat flags while antigravity stays absent")
    func catalogAndModelCompat() throws {
        #expect(ModelsCatalog.providers.contains("agy"))
        #expect(!ModelsCatalog.providers.contains("antigravity"))
        #expect(!ModelsCatalog.providers.contains("google-antigravity"))

        let models = ModelsCatalog.models(for: "agy")
        #expect(models.count >= 20)

        let neon = try #require(ModelsCatalog.model(provider: "agy", id: "gemini-4-neon-high"))
        #expect(neon.api == "anthropic-messages")
        #expect(neon.provider == "agy")
        #expect(neon.input == [.text])
        #expect(neon.compat?.supportsServerCompaction == false)
        #expect(neon.compat?.supportsMidConvoSystemMessages == false)
        #expect(neon.compat?.supportsMidConvoToolChanges == false)
        #expect(neon.compat?.supportsAdditionalTools == false)
        #expect(neon.compat?.supportsToolSearch == false)

        let sonnet = try #require(ModelsCatalog.model(provider: "agy", id: "claude-sonnet-5-5-high"))
        #expect(sonnet.input == [.text])
        #expect(sonnet.compat?.supportsServerCompaction == false)
        #expect(sonnet.compat?.supportsMidConvoToolChanges == false)
        #expect(sonnet.compat?.supportsAdditionalTools == false)
        #expect(sonnet.compat?.supportsToolSearch == false)

        // Fallback for future uncatalogued agy slugs preserves the same restrictions.
        let future = AgyModels.model(id: "gemini-5-alpha", baseURL: "https://relay.example.com/v1")
        #expect(future.id == "gemini-5-alpha")
        #expect(future.provider == "agy")
        #expect(future.baseURL == "https://relay.example.com")
        #expect(future.input == [.text])
        #expect(future.compat?.supportsServerCompaction == false)
        #expect(future.compat?.supportsMidConvoToolChanges == false)
        #expect(future.compat?.supportsAdditionalTools == false)
        #expect(future.compat?.supportsToolSearch == false)
    }

    @Test("registerStored wires agy when extras.baseUrl is configured and skips cleanly with a notice when absent")
    func registerStoredAgy() async throws {
        // Without baseUrl: skipped cleanly with notice.
        let storeWithoutURL = OAuthStore()
        try await storeWithoutURL.set(
            OAuthCredentials(access: "ya29.tok", refresh: "1//ref", expires: .max),
            for: "agy"
        )
        let notices = NoticeBox()
        let skipped = try await registerStored(
            storeId: "agy",
            store: storeWithoutURL,
            primeToken: false,
            notice: { notices.append($0) }
        )
        #expect(skipped == nil)
        #expect(notices.messages.contains { $0.contains("baseUrl") })

        // With baseUrl (and even if extras carries a stray relaySecret):
        // registers AirRelay AnthropicProvider scoped to "agy" and never
        // forwards a credential-stored relaySecret as x-relay-secret.
        let storeWithURL = OAuthStore()
        try await storeWithURL.set(
            OAuthCredentials(
                access: "ya29.live",
                refresh: "1//ref",
                expires: .max,
                extras: [
                    "baseUrl": .string("https://relay.airbuild.example/v1"),
                    "relaySecret": .string("must-not-be-forwarded"),
                ]
            ),
            for: "agy"
        )
        let resolved = try #require(try await registerStored(
            storeId: "agy",
            store: storeWithURL,
            modelOverride: "claude-sonnet-5-5-high",
            primeToken: false
        ))
        #expect(resolved.model.id == "claude-sonnet-5-5-high")
        #expect(resolved.model.provider == "agy")
        #expect(resolved.model.api == "anthropic-messages")
        #expect(resolved.model.baseURL == "https://relay.airbuild.example")
        #expect(resolved.model.input == [.text])
        #expect(resolved.model.compat?.supportsServerCompaction == false)
        #expect(resolved.model.compat?.supportsMidConvoToolChanges == false)
        #expect(resolved.model.compat?.supportsAdditionalTools == false)
        #expect(resolved.model.compat?.supportsToolSearch == false)

        let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
        #expect(auth.token == "ya29.live")
        #expect(auth.scheme == .bearer)
        #expect(auth.baseURL == "https://relay.airbuild.example")

        let registered = await APIRegistry.shared.provider(scope: "agy", api: "anthropic-messages") as? AnthropicProvider
        #expect(registered != nil)
        #expect(registered?.defaultBaseURL.absoluteString == "https://relay.airbuild.example")
        #expect(registered?.extraHeaders["x-relay-secret"] == nil)
        #expect(registered?.apiVersion == "2023-06-01")
    }
}

private final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String] = []
    func append(_ message: String) { lock.withLock { messages.append(message) } }
}
