import Foundation
import NIOConcurrencyHelpers

/// Access to pi-mono's curated catalog of 900+ models, bundled as a JSON
/// resource at `Resources/models.json`. Regenerate with:
///
///   swift run kwwk-generate-models \
///       /path/to/pi-mono/packages/ai/src/models.generated.ts
///
/// Stays in-process cheap: the JSON is parsed once on first access and held
/// in a `Model` dictionary keyed by provider + id. Hosts may dynamically
/// register additional providers at runtime via `register(provider:models:)`;
/// register before evaluating any downstream cached snapshot of `byProvider`.
public enum ModelsCatalog {
    private static let bundledByProvider: [String: [String: Model]] = loadAll()
    package static let bundledAll: [Model] = bundledByProvider.values.flatMap { $0.values }

    private struct DynamicOverlay: Sendable {
        var registered: [String: [String: Model]] = [:]
        var generation: UInt64 = 0
        var cached: (byProvider: [String: [String: Model]], all: [Model])?
    }

    private static let dynamicOverlay = NIOLockedValueBox(DynamicOverlay())

    /// Dynamically register (or replace) the model list for `provider`.
    /// Passing an empty list removes any dynamic registration for `provider`.
    /// Performs no disk I/O; merged snapshots rebuild lazily on read.
    public static func register(provider: String, models: [Model]) {
        if models.isEmpty {
            unregister(provider: provider)
            return
        }
        dynamicOverlay.withLockedValue { state in
            state.registered[provider] = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            state.generation &+= 1
            state.cached = nil
        }
    }

    /// Remove any dynamically registered models for `provider`.
    public static func unregister(provider: String) {
        dynamicOverlay.withLockedValue { state in
            guard state.registered.removeValue(forKey: provider) != nil else { return }
            state.generation &+= 1
            state.cached = nil
        }
    }

    private static func snapshot() -> (byProvider: [String: [String: Model]], all: [Model]) {
        enum Resolution {
            case bundled
            case cached([String: [String: Model]], [Model])
            case rebuild(UInt64, [String: [String: Model]])
        }
        let step: Resolution = dynamicOverlay.withLockedValue { state in
            guard !state.registered.isEmpty else { return .bundled }
            if let cached = state.cached {
                return .cached(cached.byProvider, cached.all)
            }
            return .rebuild(state.generation, state.registered)
        }
        switch step {
        case .bundled:
            return (bundledByProvider, bundledAll)
        case .cached(let byProvider, let all):
            return (byProvider, all)
        case .rebuild(let gen, let registered):
            // Load bundled JSON outside the overlay lock so register/unregister
            // never block on disk I/O.
            var merged = bundledByProvider
            for (provider, models) in registered {
                merged[provider] = models
            }
            let flat = merged.values.flatMap { $0.values }
            dynamicOverlay.withLockedValue { state in
                guard state.generation == gen else { return }
                state.cached = (merged, flat)
            }
            return (merged, flat)
        }
    }

    /// Provider → model-id → Model.
    public static var byProvider: [String: [String: Model]] {
        snapshot().byProvider
    }

    /// Flat list of every model in the catalog.
    public static var all: [Model] {
        snapshot().all
    }

    /// Every provider key in the catalog (sorted alphabetically).
    public static var providers: [String] {
        Array(byProvider.keys).sorted()
    }

    /// Lookup a model by provider + id.
    public static func model(provider: String, id: String) -> Model? {
        let custom = dynamicOverlay.withLockedValue { $0.registered[provider] }
        if let custom { return custom[id] }
        return bundledByProvider[provider]?[id]
    }

    /// All models under a given provider, sorted by id.
    public static func models(for provider: String) -> [Model] {
        let custom = dynamicOverlay.withLockedValue { $0.registered[provider] }
        guard let inner = custom ?? bundledByProvider[provider] else { return [] }
        return inner.keys.sorted().compactMap { inner[$0] }
    }

    // MARK: - Loader

    private static func loadAll() -> [String: [String: Model]] {
        // The catalog is a bundled build resource; a missing or unparseable
        // models.json is a broken build, not a runtime condition to paper
        // over with an empty catalog (which would silently break every model
        // lookup). Fail loudly so it's caught at first use.
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json") else {
            fatalError("ModelsCatalog: bundled resource models.json is missing from the build")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            fatalError("ModelsCatalog: cannot read bundled models.json at \(url.path): \(error)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("ModelsCatalog: bundled models.json is not a JSON object")
        }
        var out: [String: [String: Model]] = [:]
        for (provider, value) in root {
            guard let inner = value as? [String: Any] else { continue }
            var models: [String: Model] = [:]
            for (modelId, modelJSON) in inner {
                guard let dict = modelJSON as? [String: Any],
                      let model = decode(dict) else { continue }
                models[modelId] = model
            }
            if !models.isEmpty { out[provider] = models }
        }
        // Cursor's model list isn't in pi's generated catalog; it ships as its
        // own bundled resource regenerated by `kwwk-generate-cursor-models`
        // (merged, not overwriting, so a future generated `cursor` block in
        // models.json would win). There is no runtime model sync for Cursor —
        // the bundled file is the authoritative catalog.
        if out["cursor"] == nil {
            let cursor = loadBundledArray("cursor-models")
            if !cursor.isEmpty { out["cursor"] = cursor }
        }
        // Devin's catalog is credential-scoped and likewise ships as its own
        // pre-generated resource (`kwwk-generate-devin-models`).
        if out["devin"] == nil {
            let devin = loadBundledArray("devin-models")
            if !devin.isEmpty { out["devin"] = devin }
        }
        // Kiro's list is each plan's own; the bundled one is a hand-kept seed
        // (`KiroModels.fetch` asks an account for its real one).
        if out["kiro"] == nil {
            let kiro = loadBundledArray("kiro-models")
            if !kiro.isEmpty { out["kiro"] = kiro }
        }
        // Qoder's roster is the account's own and every request is built
        // from the live listing; the bundled rows seed the model picker, the
        // same ones for both sites.
        for site in QoderSite.all where out[site.id] == nil {
            out[site.id] = loadBundledArray("qoder-models").mapValues { QoderModels.placed($0, on: site) }
        }
        // WorkBuddy's two plans ship magpie's written-in lists, one resource
        // for each build (`WorkBuddyModels`).
        for provider in ["workbuddy", "workbuddy-ai"] where out[provider] == nil {
            out[provider] = loadBundledArray("\(provider)-models")
        }
        // Trae's roster and Raccoon's catalogue are the account's own, read
        // live; a written-in seed stands in until they have answered, the
        // same one for both Trae builds.
        for site in TraeSite.all where out[site.id] == nil {
            out[site.id] = TraeModels.seed(on: site)
        }
        if out[RaccoonOAuth.providerId] == nil {
            out[RaccoonOAuth.providerId] = RaccoonModels.seed
        }
        // Kimi's two regions share model capabilities. Only the credential
        // scope and coding endpoint differ; keeping the China rows as the
        // source also lets subagents resolve overrides under the global site.
        if out[KimiSite.global.id] == nil, let china = out[KimiSite.china.id] {
            out[KimiSite.global.id] = china.mapValues { model in
                var global = model
                global.provider = KimiSite.global.id
                global.baseURL = KimiSite.global.apiBaseURL
                return global
            }
        }
        return out
    }

    /// Load a static per-provider catalog bundled as a plain `[Model]` array
    /// (`Resources/<name>.json`). Regenerate with:
    ///
    ///   swift run kwwk-generate-cursor-models
    ///   swift run kwwk-generate-devin-models
    private static func loadBundledArray(_ name: String) -> [String: Model] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            fatalError("ModelsCatalog: bundled resource \(name).json is missing from the build")
        }
        guard let data = try? Data(contentsOf: url),
              let models = try? JSONDecoder().decode([Model].self, from: data) else {
            fatalError("ModelsCatalog: bundled \(name).json is unreadable")
        }
        return Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
    }

    /// Hand-written decoder matching the fields pi emits, including the
    /// per-model `compat` block and `thinkingLevelMap` consumed by the provider
    /// encoders for reasoning/caching/request shaping.
    private static func decode(_ dict: [String: Any]) -> Model? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let api = dict["api"] as? String,
              let provider = dict["provider"] as? String else {
            return nil
        }
        let baseURL = dict["baseUrl"] as? String ?? ""
        let reasoning = dict["reasoning"] as? Bool ?? false
        let inputStrings = dict["input"] as? [String] ?? ["text"]
        let input: [InputModality] = inputStrings.compactMap { InputModality(rawValue: $0) }
        let contextWindow = dict["contextWindow"] as? Int ?? 0
        let maxTokens = dict["maxTokens"] as? Int ?? 0

        var cost = ModelCost()
        if let c = dict["cost"] as? [String: Any] {
            cost.input = doubleValue(c["input"]) ?? 0
            cost.output = doubleValue(c["output"]) ?? 0
            cost.cacheRead = doubleValue(c["cacheRead"]) ?? 0
            cost.cacheWrite = doubleValue(c["cacheWrite"]) ?? 0
            if let tierObjects = c["tiers"] as? [[String: Any]] {
                cost.tiers = tierObjects.compactMap { tier in
                    guard let inputTokensAbove = intValue(tier["inputTokensAbove"]),
                          let input = doubleValue(tier["input"]),
                          let output = doubleValue(tier["output"]),
                          let cacheRead = doubleValue(tier["cacheRead"]),
                          let cacheWrite = doubleValue(tier["cacheWrite"]) else {
                        return nil
                    }
                    return ModelCostTier(
                        inputTokensAbove: inputTokensAbove,
                        input: input,
                        output: output,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite
                    )
                }
            }
        }

        let headers = dict["headers"] as? [String: String]

        // compat: re-serialize the sub-object and run it through JSONDecoder so
        // the flattened ModelCompat picks up whichever per-API fields are present.
        var compat: ModelCompat?
        if let compatDict = dict["compat"] as? [String: Any],
           let compatData = try? JSONSerialization.data(withJSONObject: compatDict) {
            compat = try? JSONDecoder().decode(ModelCompat.self, from: compatData)
        }

        // thinkingLevelMap: preserve the present-with-null distinction (null =>
        // level explicitly unsupported) that JSONSerialization surfaces as NSNull.
        var thinkingLevelMap: [String: String?]?
        if let mapDict = dict["thinkingLevelMap"] as? [String: Any] {
            var parsed: [String: String?] = [:]
            for (level, value) in mapDict {
                if value is NSNull {
                    parsed[level] = .some(nil)
                } else if let s = value as? String {
                    parsed[level] = .some(s)
                }
            }
            if !parsed.isEmpty { thinkingLevelMap = parsed }
        }

        return Model(
            id: id,
            name: name,
            api: api,
            provider: provider,
            baseURL: baseURL,
            reasoning: reasoning,
            input: input,
            cost: cost,
            contextWindow: contextWindow,
            maxTokens: maxTokens,
            headers: headers,
            compat: compat,
            thinkingLevelMap: thinkingLevelMap
        )
    }

    private static func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}
