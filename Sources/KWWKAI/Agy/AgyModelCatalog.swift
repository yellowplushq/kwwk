import Foundation

/// Antigravity CLI (`agy`) model catalog seed and AirRelay normalization helpers.
///
/// Requests route through an AirRelay endpoint speaking Anthropic Messages
/// (`anthropic-messages`), with model IDs prefixed as `agy/<slug>`. Vision-capable
/// Gemini and Claude models advertise `[.text, .image]` (matching AirRelay's
/// `agy acp` + MCP `tool_result` base64 image forwarding), while non-vision
/// models such as `gpt-oss-*` remain text-only (`[.text]`). Thinking effort is
/// encoded in each slug (e.g. `gemini-4-neon-high`, `claude-sonnet-5-5-medium`),
/// so explicit thinking-level overrides and unsupported Anthropic beta features
/// are disabled.
public enum AgyModels {
    /// Default model slug matching `agy models`.
    public static let defaultModelId = "gemini-4-neon-high"

    /// Prefix applied to model IDs on the AirRelay wire.
    public static let modelPrefix = "agy/"

    /// Compatibility flags disabling features unsupported by the AirRelay `agy`
    /// bridge.
    public static var defaultCompat: ModelCompat {
        var c = ModelCompat()
        c.supportsServerCompaction = false
        c.supportsMidConvoSystemMessages = false
        c.supportsMidConvoToolChanges = false
        c.supportsAdditionalTools = false
        c.supportsToolSearch = false
        c.supportsLongCacheRetention = false
        return c
    }

    /// Merge `agy` AirRelay feature restrictions onto an existing `ModelCompat`.
    public static func applyCompat(_ base: ModelCompat?) -> ModelCompat {
        var c = base ?? ModelCompat()
        c.supportsServerCompaction = false
        c.supportsMidConvoSystemMessages = false
        c.supportsMidConvoToolChanges = false
        c.supportsAdditionalTools = false
        c.supportsToolSearch = false
        c.supportsLongCacheRetention = false
        return c
    }

    /// Format a model slug for the AirRelay wire (`agy/<slug>`), avoiding
    /// double-prefixing if the caller already supplied the prefix.
    public static func wireModelId(for id: String, prefix: String = modelPrefix) -> String {
        guard !prefix.isEmpty, !id.hasPrefix(prefix) else { return id }
        return prefix + id
    }

    /// Whether an `agy` model slug supports multimodal image inputs.
    ///
    /// AirRelay's `agy acp` backend forwards base64 PNG/JPEG/WebP/GIF image
    /// blocks for both user messages and MCP `tool_result` responses. All
    /// Gemini (3.8/4/Orchestrator) and Claude (5.5 Sonnet/Opus) models accept
    /// images, while `gpt-oss-*` (and unrecognized slugs) remain text-only.
    public static func supportsImageInput(for id: String) -> Bool {
        let lower = id.lowercased()
        let slug = lower.hasPrefix(modelPrefix) ? String(lower.dropFirst(modelPrefix.count)) : lower
        if slug.hasPrefix("gpt-oss") {
            return false
        }
        return slug.hasPrefix("gemini-") || slug.hasPrefix("claude-")
    }

    /// Input modalities supported by an `agy` model slug.
    public static func inputModalities(for id: String) -> [InputModality] {
        supportsImageInput(for: id) ? [.text, .image] : [.text]
    }

    /// Normalize an AirRelay base URL so `AnthropicProvider` always posts to
    /// `<base>/v1/messages` without duplicating `/v1` or `/v1/messages`.
    public static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1/messages") {
            s.removeLast("/v1/messages".count)
        } else if s.hasSuffix("/v1") {
            s.removeLast("/v1".count)
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Effort is baked into each `agy` model slug, so per-request thinking
    /// level overrides are disabled.
    static let noLevels: [String: String?] = Dictionary(
        uniqueKeysWithValues: ModelThinkingLevel.allCases.map { ($0.rawValue, String?.none) }
    )

    /// Bundled seed matching `agy models` (`agy v1.5.15`). Backends may also
    /// query AirRelay's live `/v1/agy/models` listing; `model(id:baseURL:)`
    /// builds a usable row for any slug not yet in this seed.
    static let seedRows: [Model] = [
        // Gemini 4 Neon
        row(id: "gemini-4-neon-high", name: "Gemini 4 Neon (High)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-neon-xhigh", name: "Gemini 4 Neon (XHigh)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-neon-medium", name: "Gemini 4 Neon (Medium)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-neon-low", name: "Gemini 4 Neon (Low)", contextWindow: 1_000_000, maxTokens: 64_000),
        // Gemini 4 Carbon
        row(id: "gemini-4-carbon-high", name: "Gemini 4 Carbon (High)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-carbon-medium", name: "Gemini 4 Carbon (Medium)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-carbon-low", name: "Gemini 4 Carbon (Low)", contextWindow: 1_000_000, maxTokens: 64_000),
        // Gemini 4 Argon
        row(id: "gemini-4-argon-high", name: "Gemini 4 Argon (High)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-argon-medium", name: "Gemini 4 Argon (Medium)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-argon-low", name: "Gemini 4 Argon (Low)", contextWindow: 1_000_000, maxTokens: 64_000),
        // Gemini 4 Hydrogen
        row(id: "gemini-4-hydrogen-high", name: "Gemini 4 Hydrogen (High)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-hydrogen-xhigh", name: "Gemini 4 Hydrogen (XHigh)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-hydrogen-medium", name: "Gemini 4 Hydrogen (Medium)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-4-hydrogen-low", name: "Gemini 4 Hydrogen (Low)", contextWindow: 1_000_000, maxTokens: 64_000),
        // Orchestrators
        row(id: "gemini-pro-orchestrator-neon", name: "Orchestrator (Neon)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-pro-orchestrator", name: "Orchestrator (Carbon)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-pro-orchestrator-argon", name: "Orchestrator (Argon)", contextWindow: 1_000_000, maxTokens: 64_000),
        // Gemini 3.8 Flash
        row(id: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash (High)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-3.8-flash-medium", name: "Gemini 3.8 Flash (Medium)", contextWindow: 1_000_000, maxTokens: 64_000),
        row(id: "gemini-3.8-flash-low", name: "Gemini 3.8 Flash (Low)", contextWindow: 1_000_000, maxTokens: 64_000),
        // Claude 5.5
        row(id: "claude-opus-5-5-low", name: "Claude Opus 5.5 (Low)", contextWindow: 200_000, maxTokens: 64_000),
        row(id: "claude-opus-5-5-medium", name: "Claude Opus 5.5 (Medium)", contextWindow: 200_000, maxTokens: 64_000),
        row(id: "claude-opus-5-5-high", name: "Claude Opus 5.5 (High)", contextWindow: 200_000, maxTokens: 64_000),
        row(id: "claude-sonnet-5-5-low", name: "Claude Sonnet 5.5 (Low)", contextWindow: 200_000, maxTokens: 64_000),
        row(id: "claude-sonnet-5-5-medium", name: "Claude Sonnet 5.5 (Medium)", contextWindow: 200_000, maxTokens: 64_000),
        row(id: "claude-sonnet-5-5-high", name: "Claude Sonnet 5.5 (High)", contextWindow: 200_000, maxTokens: 64_000),
        // GPT-OSS (text-only)
        row(id: "gpt-oss-120b-medium", name: "GPT-OSS 120B (Medium)", contextWindow: 128_000, maxTokens: 16_384, input: [.text]),
    ]

    /// The catalog dictionary loaded by `ModelsCatalog`.
    static var seed: [String: Model] {
        Dictionary(uniqueKeysWithValues: seedRows.map { ($0.id, $0) })
    }

    /// Look up a model row in `ModelsCatalog` (or build a fallback row for an
    /// uncatalogued `agy` slug) and optionally stamp a normalized AirRelay
    /// `baseURL`.
    public static func model(id: String, baseURL: String = "") -> Model {
        let normalizedBase = baseURL.isEmpty ? "" : normalizeBaseURL(baseURL)
        if var existing = ModelsCatalog.model(provider: AgyOAuth.providerId, id: id) {
            if !normalizedBase.isEmpty {
                existing.baseURL = normalizedBase
            }
            existing.compat = applyCompat(existing.compat)
            return existing
        }
        return row(
            id: id,
            name: id,
            baseURL: normalizedBase,
            contextWindow: 200_000,
            maxTokens: 64_000,
            input: inputModalities(for: id)
        )
    }

    private static func row(
        id: String,
        name: String,
        baseURL: String = "",
        contextWindow: Int,
        maxTokens: Int,
        input: [InputModality]? = nil
    ) -> Model {
        Model(
            id: id,
            name: name,
            api: "anthropic-messages",
            provider: AgyOAuth.providerId,
            baseURL: baseURL,
            reasoning: true,
            input: input ?? inputModalities(for: id),
            contextWindow: contextWindow,
            maxTokens: maxTokens,
            compat: defaultCompat,
            thinkingLevelMap: noLevels
        )
    }
}
