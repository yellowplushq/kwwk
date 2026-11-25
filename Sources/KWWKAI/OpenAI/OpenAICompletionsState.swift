import Foundation
import NIOConcurrencyHelpers

/// Mutable state for OpenAI Completions stream. Tracks content block order
/// and incremental tool-call JSON buffers.
final class OpenAICompletionsState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    let model: Model
    var signal: CancellationHandle?

    var responseId: String?
    var usage = Usage()
    var stopReason: StopReason = .stop
    var errorMessage: String?
    var failure: ProviderFailure?

    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, name: String, json: String, thoughtSignature: String?)
    }
    private struct State {
        var blocks: [Int: Block] = [:]
        var order: [Int] = []
        var textBlockIndex: Int?
        var thinkingBlockIndex: Int?
        /// Map from OpenAI `tool_calls[i].index` → our content index.
        var toolCallIndexMap: [Int: Int] = [:]
        /// The content index of the call opened last.
        var lastToolCallIndex: Int?
        /// Map from a settled tool-call `id` → our content index. Used to attach
        /// legacy encrypted reasoning details keyed by tool-call id.
        var toolCallContentIndexById: [String: Int] = [:]
        /// Legacy reasoning details that arrived before the matching tool-call id settled.
        var pendingReasoningById: [String: String] = [:]
        /// Structured OpenRouter `reasoning_details` accumulated across chunks
        /// (merged for `reasoning.text` / `reasoning.summary`, discrete for
        /// `reasoning.encrypted`). Serialized onto `thinkingBlockIndex` on read.
        var streamedReasoningDetails: [[String: JSONValue]] = []
        /// Active block index for LiteLLM `thinking_blocks` streaming deltas.
        var liteLLMThinkingIndex: Int?
        /// Accumulated raw Anthropic signatures for LiteLLM `thinking_blocks`
        /// keyed by content block index.
        var liteLLMSignatureByBlock: [Int: String] = [:]
        /// Pending message-level Gemini OpenAI-compat signature (`thinking_signature`
        /// / `thought_signature`) waiting for a tool call to attach to.
        var pendingMessageThoughtSignature: (field: String, signature: String)?
        var endedIndices: Set<Int> = []
    }
    private let state = NIOLockedValueBox(State())

    init(api: String, provider: String, modelId: String, model: Model) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
        self.model = model
    }

    // MARK: Block book-keeping

    func noteTextBlock() -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let idx = state.textBlockIndex { return (idx, false) }
            let idx = state.order.count
            state.textBlockIndex = idx
            state.order.append(idx)
            state.blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock() -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let idx = state.thinkingBlockIndex { return (idx, false) }
            let idx = state.order.count
            state.thinkingBlockIndex = idx
            state.order.append(idx)
            state.blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return (idx, true)
        }
    }

    /// The content block a tool-call fragment at `rawIndex` belongs to.
    ///
    /// A fragment that names the function starts the next call when it
    /// names an id other than the one the index's open call goes by (magpie
    /// #395, parallel calls all sent at index 0) or a different function;
    /// otherwise it continues the open call.
    ///
    /// A fragment that names no function never starts a call while one is
    /// open: it is more of the call at its index, or, at an index no call
    /// has used, more of the last call. Some relays put a fresh id or index
    /// on each piece of one call's arguments, and read as new calls those
    /// pieces ran as calls of their own, the first with only its first key.
    func noteToolCallBlock(
        at rawIndex: Int,
        id: String? = nil,
        name: String? = nil
    ) -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let idx = state.toolCallIndexMap[rawIndex] {
                guard let name, case .toolUse(let openID, let openName, _, _) = state.blocks[idx] else {
                    return (idx, false)
                }
                let otherID = id.map { !openID.isEmpty && openID != $0 } ?? false
                let otherName = !openName.isEmpty && openName != name
                if !otherID && !otherName { return (idx, false) }
            } else if name == nil, let last = state.lastToolCallIndex {
                state.toolCallIndexMap[rawIndex] = last
                return (last, false)
            }
            let idx = state.order.count
            state.toolCallIndexMap[rawIndex] = idx
            state.lastToolCallIndex = idx
            state.order.append(idx)
            state.blocks[idx] = .toolUse(id: "", name: "", json: "", thoughtSignature: nil)
            return (idx, true)
        }
    }

    func appendText(index: Int, text: String) {
        state.withLockedValue { state in
            if case .text(var t) = state.blocks[index] {
                t.text += text
                state.blocks[index] = .text(t)
            }
        }
    }

    func appendThinking(index: Int, text: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index] {
                th.thinking += text
                state.blocks[index] = .thinking(th)
            }
        }
    }

    func setThinkingSignature(index: Int, signature: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index], th.thinkingSignature == nil {
                th.thinkingSignature = signature
                state.blocks[index] = .thinking(th)
            }
        }
    }

    func updateToolCallID(rawIndex: Int, id: String) {
        state.withLockedValue { state in
            guard let contentIndex = state.toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let openID, let name, let json, let sig) = state.blocks[contentIndex] {
                // A piece of this call sent under another id keeps the first.
                guard openID.isEmpty || openID == id else { return }
                var newSig = sig
                if let pending = state.pendingReasoningById.removeValue(forKey: id) { newSig = pending }
                if let msgSig = state.pendingMessageThoughtSignature {
                    state.pendingMessageThoughtSignature = nil
                    newSig = Self.mergeGeminiThoughtSignature(existing: newSig, message: msgSig)
                }
                state.blocks[contentIndex] = .toolUse(id: id, name: name, json: json, thoughtSignature: newSig)
            }
            state.toolCallContentIndexById[id] = contentIndex
        }
    }

    func updateToolCallName(rawIndex: Int, name: String) {
        state.withLockedValue { state in
            guard let contentIndex = state.toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let id, let openName, let json, let sig) = state.blocks[contentIndex], openName.isEmpty {
                state.blocks[contentIndex] = .toolUse(id: id, name: name, json: json, thoughtSignature: sig)
            }
        }
    }

    func appendToolCallArgs(rawIndex: Int, chunk: String) {
        state.withLockedValue { state in
            guard let contentIndex = state.toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let id, let name, let json, let sig) = state.blocks[contentIndex] {
                state.blocks[contentIndex] = .toolUse(id: id, name: name, json: json + chunk, thoughtSignature: sig)
            }
        }
    }

    /// Attach a legacy encrypted reasoning detail (serialized JSON) to the tool call
    /// with the matching id, or stash it as pending if the id has not settled.
    func applyReasoningDetail(id: String, serialized: String) {
        state.withLockedValue { state in
            if let contentIndex = state.toolCallContentIndexById[id],
               case .toolUse(let cid, let name, let json, let existing) = state.blocks[contentIndex] {
                let merged = Self.mergeGeminiThoughtSignature(existing: existing, perCallRaw: serialized) ?? serialized
                state.blocks[contentIndex] = .toolUse(id: cid, name: name, json: json, thoughtSignature: merged)
            } else {
                state.pendingReasoningById[id] = serialized
            }
        }
    }

    /// Record a streamed OpenRouter `reasoning_details` entry (`reasoning.encrypted`,
    /// `reasoning.text`, or `reasoning.summary`), merging consecutive text/summary
    /// deltas and ensuring a thinking block exists to hold the replay array.
    func appendStreamedReasoningDetail(_ detail: [String: JSONValue]) -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            let firstSeen: Bool
            let idx: Int
            if let existing = state.thinkingBlockIndex {
                idx = existing
                firstSeen = false
            } else {
                idx = state.order.count
                state.thinkingBlockIndex = idx
                state.order.append(idx)
                state.blocks[idx] = .thinking(ThinkingContent(thinking: ""))
                firstSeen = true
            }
            if let last = state.streamedReasoningDetails.last,
               case .string(let type) = detail["type"],
               last["type"] == .string(type) {
                if type == "reasoning.text",
                   case .string(let incomingText) = detail["text"],
                   case .string(let existingText) = last["text"] {
                    var merged = last
                    merged["text"] = .string(existingText + incomingText)
                    if merged["signature"] == nil || merged["signature"] == .null || merged["signature"] == .string(""),
                       let sig = detail["signature"], sig != .null {
                        merged["signature"] = sig
                    }
                    Self.fillMissingCommonReasoningFields(&merged, from: detail)
                    state.streamedReasoningDetails[state.streamedReasoningDetails.count - 1] = merged
                    return (idx, firstSeen)
                }
                if type == "reasoning.summary",
                   case .string(let incomingSummary) = detail["summary"],
                   case .string(let existingSummary) = last["summary"] {
                    var merged = last
                    merged["summary"] = .string(existingSummary + incomingSummary)
                    Self.fillMissingCommonReasoningFields(&merged, from: detail)
                    state.streamedReasoningDetails[state.streamedReasoningDetails.count - 1] = merged
                    return (idx, firstSeen)
                }
            }
            state.streamedReasoningDetails.append(detail)
            return (idx, firstSeen)
        }
    }

    private static func fillMissingCommonReasoningFields(
        _ target: inout [String: JSONValue],
        from source: [String: JSONValue]
    ) {
        if target["id"] == nil || target["id"] == .null, let id = source["id"], id != .null {
            target["id"] = id
        }
        if target["format"] == nil || target["format"] == .string(""),
           case .string(let fmt) = source["format"], !fmt.isEmpty {
            target["format"] = .string(fmt)
        }
        if target["index"] == nil, let idx = source["index"] {
            target["index"] = idx
        }
    }

    /// Record a LiteLLM `thinking_blocks` delta entry (`thinking` or `redacted_thinking`).
    func appendLiteLLMThinkingBlock(_ entry: [String: JSONValue]) -> (index: Int, firstSeen: Bool, delta: String)? {
        state.withLockedValue { state in
            guard case .string(let type) = entry["type"] else { return nil }
            if type == "redacted_thinking" {
                guard case .string(let data) = entry["data"], !data.isEmpty else { return nil }
                state.liteLLMThinkingIndex = nil
                let idx = state.order.count
                state.order.append(idx)
                state.blocks[idx] = .thinking(ThinkingContent(
                    thinking: "[Reasoning redacted]",
                    thinkingSignature: data,
                    redacted: true
                ))
                return (idx, true, "")
            }
            guard type == "thinking" else { return nil }
            let thinking = { () -> String in
                if case .string(let s) = entry["thinking"] { return s }
                return ""
            }()
            let signature = { () -> String in
                if case .string(let s) = entry["signature"] { return s }
                return ""
            }()
            guard !thinking.isEmpty || !signature.isEmpty else { return nil }

            let idx: Int
            let firstSeen: Bool
            if let open = state.liteLLMThinkingIndex,
               !( !thinking.isEmpty && !(state.liteLLMSignatureByBlock[open] ?? "").isEmpty ) {
                idx = open
                firstSeen = false
            } else {
                idx = state.order.count
                state.order.append(idx)
                state.blocks[idx] = .thinking(ThinkingContent(thinking: ""))
                state.liteLLMThinkingIndex = idx
                firstSeen = true
            }
            if !thinking.isEmpty, case .thinking(var th) = state.blocks[idx] {
                th.thinking += thinking
                state.blocks[idx] = .thinking(th)
            }
            if !signature.isEmpty {
                state.liteLLMSignatureByBlock[idx] = (state.liteLLMSignatureByBlock[idx] ?? "") + signature
            }
            return (idx, firstSeen, thinking)
        }
    }

    /// Attach Gemini OpenAI-compat `extra_content.google|vertex.thought_signature`
    /// onto a tool call's `thoughtSignature`.
    func applyToolCallExtraContent(rawIndex: Int, extraContent: [String: JSONValue]) {
        guard let any = anyFromJSONValue(.object(extraContent)),
              let raw = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
              let serialized = String(data: raw, encoding: .utf8) else { return }
        state.withLockedValue { state in
            guard let contentIndex = state.toolCallIndexMap[rawIndex],
                  case .toolUse(let id, let name, let json, let existing) = state.blocks[contentIndex] else { return }
            let merged = Self.mergeGeminiThoughtSignature(existing: existing, perCallRaw: serialized) ?? serialized
            state.blocks[contentIndex] = .toolUse(id: id, name: name, json: json, thoughtSignature: merged)
        }
    }

    /// Attach a message-level Gemini OpenAI-compat signature (`thinking_signature`
    /// / `thought_signature`) to the first tool call (or stash until one arrives).
    func applyMessageThoughtSignature(field: String, signature: String) {
        state.withLockedValue { state in
            if let firstToolIndex = state.order.first(where: { idx in
                if case .toolUse = state.blocks[idx] { return true }; return false
            }), case .toolUse(let id, let name, let json, let existing) = state.blocks[firstToolIndex] {
                let merged = Self.mergeGeminiThoughtSignature(
                    existing: existing,
                    message: (field: field, signature: signature)
                )
                state.blocks[firstToolIndex] = .toolUse(id: id, name: name, json: json, thoughtSignature: merged)
            } else {
                state.pendingMessageThoughtSignature = (field: field, signature: signature)
            }
        }
    }

    private static func mergeGeminiThoughtSignature(
        existing: String?,
        perCallRaw: String? = nil,
        message: (field: String, signature: String)? = nil
    ) -> String? {
        var perCallObj: Any?
        var messageObj: [String: String] = [:]
        if let existing, let data = existing.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if parsed["perCall"] != nil || parsed["message"] != nil {
                perCallObj = parsed["perCall"]
                if let msg = parsed["message"] as? [String: String] { messageObj = msg }
            } else if let sig = parsed["thinking_signature"] as? String, !sig.isEmpty {
                messageObj["thinking_signature"] = sig
            } else if let sig = parsed["thought_signature"] as? String, !sig.isEmpty {
                messageObj["thought_signature"] = sig
            } else {
                perCallObj = parsed
            }
        }
        if let perCallRaw, let data = perCallRaw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            perCallObj = parsed
        }
        if let message {
            messageObj[message.field] = message.signature
        }
        let payload: Any
        if let perCallObj, messageObj.isEmpty {
            payload = perCallObj
        } else if perCallObj == nil, !messageObj.isEmpty {
            payload = messageObj
        } else if let perCallObj {
            payload = ["perCall": perCallObj, "message": messageObj] as [String: Any]
        } else {
            return existing
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return existing
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Stream events

    func applyUsage(_ obj: [String: JSONValue]) {
        func intOf(_ v: JSONValue?) -> Int? { if case .int(let n)? = v { return n }; return nil }
        let prompt = intOf(obj["prompt_tokens"]) ?? 0
        let promptDetails: [String: JSONValue] = {
            if case .object(let d)? = obj["prompt_tokens_details"] { return d }
            return [:]
        }()
        // DeepSeek exposes cache hits via `prompt_cache_hit_tokens` instead of
        // `prompt_tokens_details.cached_tokens`, Moonshot via a top-level
        // `cached_tokens`.
        let cacheRead = intOf(promptDetails["cached_tokens"]) ?? intOf(obj["prompt_cache_hit_tokens"])
            ?? intOf(obj["cached_tokens"]) ?? 0
        let cacheWrite = intOf(promptDetails["cache_write_tokens"]) ?? 0
        let output = intOf(obj["completion_tokens"]) ?? 0
        let completionDetails: [String: JSONValue] = {
            if case .object(let d)? = obj["completion_tokens_details"] { return d }
            return [:]
        }()
        let reasoning = intOf(completionDetails["reasoning_tokens"]) ?? 0
        let input = max(0, prompt - cacheRead - cacheWrite)
        usage.input = input
        usage.output = output
        usage.cacheRead = cacheRead
        usage.cacheWrite = cacheWrite
        usage.reasoning = reasoning
        usage.totalTokens = input + output + cacheRead + cacheWrite
        usage.cost = calculateCost(model: model, usage: usage)
        // OpenRouter bills whichever upstream it routed to, often above the
        // catalog's cheapest-provider price, and reports the charge in USD as
        // `usage.cost` on every response. Use it, split across the parts in
        // the catalog's proportions.
        // `compat.trustsReportedCost` says so for a relay under another name.
        let trustsReportedCost = model.compat?.trustsReportedCost
            ?? (model.behaviorProvider == "openrouter" || model.baseURL.lowercased().contains("openrouter.ai"))
        let billed: Double? = switch obj["cost"] {
        case .double(let d)?: d
        case .int(let n)?: Double(n)
        default: nil
        }
        if trustsReportedCost, let billed {
            let estimate = usage.cost
            let scale = estimate.total > 0 ? billed / estimate.total : 0
            usage.cost = Cost(
                input: estimate.input * scale,
                output: estimate.output * scale,
                cacheRead: estimate.cacheRead * scale,
                cacheWrite: estimate.cacheWrite * scale,
                total: billed,
                billed: true
            )
        }
    }

    /// Streaming snapshot. In-progress tool calls use an empty-object
    /// placeholder rather than re-parsing the growing JSON buffer on every
    /// delta (O(n^2)); full arguments are parsed once in
    /// `finalizeStreamingBlocks`/`finalize`.
    func snapshot() -> AssistantMessage { buildMessage(parseToolArgs: false) }

    /// Gives each tool call the stream never named an id for one of its
    /// own. llama.cpp, Ollama and some relays send none, and a call kept at
    /// `""` can't be told from another one, nor paired with its result, and
    /// Anthropic refuses it outright after a switch (magpie mints
    /// `call_<id>` the same way, gateway/chat.go). The id is minted once and
    /// kept, so the end event, the final message and the tool result agree.
    private func settleEmptyToolCallIds() {
        state.withLockedValue { state in
            for idx in state.order {
                guard case .toolUse(let id, let name, let json, let sig) = state.blocks[idx], id.isEmpty
                else { continue }
                let minted = "call_"
                    + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
                state.blocks[idx] = .toolUse(id: minted, name: name, json: json, thoughtSignature: sig)
            }
        }
    }

    private func buildMessage(parseToolArgs: Bool) -> AssistantMessage {
        if parseToolArgs { settleEmptyToolCallIds() }
        return state.withLockedValue { state in
            let serializedReasoningDetails: String? = {
                guard !state.streamedReasoningDetails.isEmpty,
                      let any = anyFromJSONValue(.array(state.streamedReasoningDetails.map(JSONValue.object))),
                      let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else {
                    return nil
                }
                return String(data: data, encoding: .utf8)
            }()
            return AssistantMessage(
                content: state.order.compactMap { idx -> AssistantBlock? in
                    switch state.blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(var th):
                        if idx == state.thinkingBlockIndex, let serializedReasoningDetails {
                            th.thinkingSignature = serializedReasoningDetails
                        } else if let liteLLMSig = state.liteLLMSignatureByBlock[idx], !liteLLMSig.isEmpty,
                                  let data = try? JSONSerialization.data(
                                      withJSONObject: ["litellm_thinking_signature": liteLLMSig],
                                      options: [.sortedKeys]
                                  ),
                                  let encoded = String(data: data, encoding: .utf8) {
                            th.thinkingSignature = encoded
                        }
                        return .thinking(th)
                    case .toolUse(let id, let name, let json, let sig):
                        let decoded: (arguments: JSONValue, unparsed: String?) = parseToolArgs
                            ? StreamedToolArguments.decode(json)
                            : (.object([:]), nil)
                        return .toolCall(ToolCall(
                            id: id,
                            name: name,
                            arguments: decoded.arguments,
                            thoughtSignature: sig,
                            unparsedArguments: decoded.unparsed
                        ))
                    case .none: return nil
                    }
                },
                api: api,
                provider: provider,
                model: modelId,
                responseId: responseId,
                usage: usage,
                stopReason: stopReason,
                timestamp: Timestamp.now()
            )
        }
    }

    /// Emit `text_end` / `thinking_end` / `toolcall_end` once per block when
    /// the stream reports a finish reason or runs out of events.
    func finalizeStreamingBlocks(emit: (AssistantMessageEvent) -> Void) {
        settleEmptyToolCallIds()
        let indices = state.withLockedValue { $0.order }
        for idx in indices {
            if state.withLockedValue({ $0.endedIndices.contains(idx) }) { continue }
            let partial = snapshot()
            guard let block = state.withLockedValue({ $0.blocks[idx] }) else { continue }
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse(let id, let name, let json, let sig):
                let decoded = StreamedToolArguments.decode(json)
                let call = ToolCall(
                    id: id,
                    name: name,
                    arguments: decoded.arguments,
                    thoughtSignature: sig,
                    unparsedArguments: decoded.unparsed
                )
                emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
            }
            _ = state.withLockedValue { $0.endedIndices.insert(idx) }
        }
    }

    func finalize() -> AssistantMessage {
        buildMessage(parseToolArgs: true)
    }

    func asAborted() -> AssistantMessage {
        stopReason = .aborted
        var m = buildMessage(parseToolArgs: true)
        m.errorMessage = "Request was aborted"
        return m
    }
}
