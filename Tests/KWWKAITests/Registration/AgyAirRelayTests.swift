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

    @Test("ModelsCatalog ships vision-capable agy models with [.text, .image], gpt-oss as text-only, and disabled unsupported compat flags while antigravity stays absent")
    func catalogAndModelCompat() throws {
        #expect(ModelsCatalog.providers.contains("agy"))
        #expect(!ModelsCatalog.providers.contains("antigravity"))
        #expect(!ModelsCatalog.providers.contains("google-antigravity"))

        let models = ModelsCatalog.models(for: "agy")
        #expect(models.count == 27)

        // Every bundled Gemini (3.8/4/Orchestrator) and Claude 5.5 model advertises multimodal image input;
        // GPT-OSS remains text-only.
        let visionModels = models.filter { !$0.id.hasPrefix("gpt-oss") }
        let textOnlyModels = models.filter { $0.id.hasPrefix("gpt-oss") }
        #expect(visionModels.count == 26)
        #expect(textOnlyModels.map(\.id) == ["gpt-oss-120b-medium"])

        for model in visionModels {
            #expect(model.api == "anthropic-messages")
            #expect(model.provider == "agy")
            #expect(model.input == [.text, .image], "Expected vision model \(model.id) to advertise [.text, .image]")
            #expect(model.compat?.supportsServerCompaction == false)
            #expect(model.compat?.supportsMidConvoSystemMessages == false)
            #expect(model.compat?.supportsMidConvoToolChanges == false)
            #expect(model.compat?.supportsAdditionalTools == false)
            #expect(model.compat?.supportsToolSearch == false)
            #expect(model.compat?.supportsLongCacheRetention == false)
        }

        let gptOss = try #require(ModelsCatalog.model(provider: "agy", id: "gpt-oss-120b-medium"))
        #expect(gptOss.input == [.text])
        #expect(gptOss.compat?.supportsServerCompaction == false)
        #expect(gptOss.compat?.supportsMidConvoToolChanges == false)
        #expect(gptOss.compat?.supportsAdditionalTools == false)
        #expect(gptOss.compat?.supportsToolSearch == false)

        // Spot-check representative catalog lookups via AgyModels.model(id:baseURL:).
        let neon = AgyModels.model(id: "gemini-4-neon-high", baseURL: "https://relay.example.com/v1")
        #expect(neon.input == [.text, .image])
        #expect(neon.baseURL == "https://relay.example.com")

        let orchestrator = AgyModels.model(id: "gemini-pro-orchestrator-neon")
        #expect(orchestrator.input == [.text, .image])

        let flash = AgyModels.model(id: "gemini-3.8-flash-high")
        #expect(flash.input == [.text, .image])

        let opus = AgyModels.model(id: "claude-opus-5-5-high")
        #expect(opus.input == [.text, .image])

        let sonnet = AgyModels.model(id: "claude-sonnet-5-5-high")
        #expect(sonnet.input == [.text, .image])

        let gptOssBuilt = AgyModels.model(id: "gpt-oss-120b-medium", baseURL: "https://relay.example.com/v1")
        #expect(gptOssBuilt.input == [.text])
        #expect(gptOssBuilt.baseURL == "https://relay.example.com")

        // Fallback for future uncatalogued agy slugs classifies vision vs text-only and preserves compat restrictions.
        let futureGemini = AgyModels.model(id: "gemini-5-alpha", baseURL: "https://relay.example.com/v1")
        #expect(futureGemini.id == "gemini-5-alpha")
        #expect(futureGemini.provider == "agy")
        #expect(futureGemini.baseURL == "https://relay.example.com")
        #expect(futureGemini.input == [.text, .image])
        #expect(futureGemini.compat?.supportsServerCompaction == false)
        #expect(futureGemini.compat?.supportsMidConvoToolChanges == false)
        #expect(futureGemini.compat?.supportsAdditionalTools == false)
        #expect(futureGemini.compat?.supportsToolSearch == false)

        let futureClaude = AgyModels.model(id: "claude-sonnet-6-high")
        #expect(futureClaude.input == [.text, .image])

        let futureGptOss = AgyModels.model(id: "gpt-oss-120b-high")
        #expect(futureGptOss.input == [.text])

        let prefixedGptOss = AgyModels.model(id: "agy/gpt-oss-20b-low")
        #expect(prefixedGptOss.input == [.text])

        let unknownSlug = AgyModels.model(id: "unknown-text-model")
        #expect(unknownSlug.input == [.text])
    }

    @Test("ProviderVariants.agyAirRelay preserves base64 image blocks (PNG/JPEG/WebP/GIF) in user and tool_result turns for vision models and downgrades them for gpt-oss")
    func agyAirRelayPreservesBase64Images() async throws {
        let context = Context(
            messages: [
                .user(UserMessage(content: [
                    .text(TextContent(text: "Compare these images")),
                    .image(ImageContent(data: "cG5nLWRhdGE=", mimeType: "image/png")),
                    .image(ImageContent(data: "anBnLWRhdGE=", mimeType: "image/jpg")),
                    .image(ImageContent(data: "d2VicC1kYXRh", mimeType: "image/webp")),
                    .image(ImageContent(data: "Z2lmLWRhdGE=", mimeType: "image/gif")),
                ])),
                .assistant(AssistantMessage(
                    content: [.toolCall(ToolCall(id: "toolu_img_1", name: "read", arguments: ["path": .string("chart.png")]))],
                    api: "anthropic-messages",
                    provider: "agy",
                    model: "gemini-4-neon-high"
                )),
                .toolResult(ToolResultMessage(
                    toolCallId: "toolu_img_1",
                    toolName: "read",
                    content: [
                        .text(TextContent(text: "Loaded screenshot")),
                        .image(ImageContent(data: "dG9vbC1wbmc=", mimeType: "image/png")),
                        .image(ImageContent(data: "dG9vbC13ZWJw", mimeType: "image/webp")),
                    ]
                )),
            ]
        )

        // Vision-capable model preserves every base64 image block in both user and tool_result messages.
        let visionClient = StubSSEClient(body: Self.anthropicSSE)
        let visionProvider = ProviderVariants.agyAirRelay(
            baseURL: URL(string: "https://relay.airbuild.example")!,
            accessToken: "ya29.vision",
            client: visionClient
        )
        let visionModel = AgyModels.model(id: "gemini-4-neon-high")
        _ = await visionProvider.stream(model: visionModel, context: context, options: nil).result()

        let visionReq = try #require(visionClient.lastRequest)
        let visionBody = try decodeJSON(visionReq.body)
        #expect(visionBody["model"] as? String == "agy/gemini-4-neon-high")

        let messages = try #require(visionBody["messages"] as? [[String: Any]])
        #expect(messages.count == 3)

        let userBlocks = try #require(messages[0]["content"] as? [[String: Any]])
        let userImages = userBlocks.filter { ($0["type"] as? String) == "image" }
        #expect(userImages.count == 4)
        let expectedUserImages: [(String, String)] = [
            ("image/png", "cG5nLWRhdGE="),
            ("image/jpeg", "anBnLWRhdGE="),
            ("image/webp", "d2VicC1kYXRh"),
            ("image/gif", "Z2lmLWRhdGE="),
        ]
        for (block, expected) in zip(userImages, expectedUserImages) {
            let source = try #require(block["source"] as? [String: Any])
            #expect(source["type"] as? String == "base64")
            #expect(source["media_type"] as? String == expected.0)
            #expect(source["data"] as? String == expected.1)
        }

        let toolTurnBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        let toolResultBlock = try #require(toolTurnBlocks.first)
        #expect(toolResultBlock["type"] as? String == "tool_result")
        #expect(toolResultBlock["tool_use_id"] as? String == "toolu_img_1")
        let toolContent = try #require(toolResultBlock["content"] as? [[String: Any]])
        let toolImages = toolContent.filter { ($0["type"] as? String) == "image" }
        #expect(toolImages.count == 2)
        let expectedToolImages: [(String, String)] = [
            ("image/png", "dG9vbC1wbmc="),
            ("image/webp", "dG9vbC13ZWJw"),
        ]
        for (block, expected) in zip(toolImages, expectedToolImages) {
            let source = try #require(block["source"] as? [String: Any])
            #expect(source["type"] as? String == "base64")
            #expect(source["media_type"] as? String == expected.0)
            #expect(source["data"] as? String == expected.1)
        }

        // Non-vision gpt-oss-120b-medium downgrades both user and tool_result images to text placeholders.
        let textOnlyClient = StubSSEClient(body: Self.anthropicSSE)
        let textOnlyProvider = ProviderVariants.agyAirRelay(
            baseURL: URL(string: "https://relay.airbuild.example")!,
            accessToken: "ya29.textonly",
            client: textOnlyClient
        )
        let textOnlyModel = AgyModels.model(id: "gpt-oss-120b-medium")
        _ = await textOnlyProvider.stream(model: textOnlyModel, context: context, options: nil).result()

        let textOnlyReq = try #require(textOnlyClient.lastRequest)
        let textOnlyBody = try decodeJSON(textOnlyReq.body)
        #expect(textOnlyBody["model"] as? String == "agy/gpt-oss-120b-medium")

        let downgradedMessages = try #require(textOnlyBody["messages"] as? [[String: Any]])
        #expect(downgradedMessages.count == 3)
        let downgradedUserBlocks = try #require(downgradedMessages[0]["content"] as? [[String: Any]])
        #expect(!downgradedUserBlocks.contains { ($0["type"] as? String) == "image" })
        #expect(downgradedUserBlocks.contains { ($0["text"] as? String) == TransformMessages.nonVisionUserImagePlaceholder })

        let downgradedToolTurn = try #require(downgradedMessages[2]["content"] as? [[String: Any]])
        let downgradedToolResult = try #require(downgradedToolTurn.first)
        let downgradedToolContent = try #require(downgradedToolResult["content"] as? [[String: Any]])
        #expect(!downgradedToolContent.contains { ($0["type"] as? String) == "image" })
        #expect(downgradedToolContent.contains { ($0["text"] as? String) == TransformMessages.nonVisionToolImagePlaceholder })
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
        #expect(resolved.model.input == [.text, .image])
        #expect(resolved.model.compat?.supportsServerCompaction == false)
        #expect(resolved.model.compat?.supportsMidConvoToolChanges == false)
        #expect(resolved.model.compat?.supportsAdditionalTools == false)
        #expect(resolved.model.compat?.supportsToolSearch == false)

        let resolvedTextOnly = try #require(try await registerStored(
            storeId: "agy",
            store: storeWithURL,
            modelOverride: "gpt-oss-120b-medium",
            primeToken: false
        ))
        #expect(resolvedTextOnly.model.id == "gpt-oss-120b-medium")
        #expect(resolvedTextOnly.model.input == [.text])

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
