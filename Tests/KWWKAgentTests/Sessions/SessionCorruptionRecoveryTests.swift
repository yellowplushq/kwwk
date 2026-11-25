import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// Covers crash-truncated JSONL lines, fused trailing entries, and automatic
/// self-healing during `resolveResume`:
/// - `append` must separate a new entry from a truncated non-newline EOF.
/// - `resolveResume` must recover valid context around corrupted/truncated
///   lines (and salvage fused valid suffixes) instead of wiping context to
///   empty on every restart.
/// - The repaired session file must pass subsequent strict `load` calls.
@Suite("Session corruption recovery")
struct SessionCorruptionRecoveryTests {

    @Test("append separates from a truncated line missing a trailing newline")
    func appendInsertsNewlineAfterTruncatedEOF() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "truncated-eof"
        try await store.append(id: id, cwd: "/w", message: user("first"))
        let url = dir.appendingPathComponent("\(id).jsonl")
        try appendRawBytes(Data(#"{"message":{"api":"chatgpt-codex","content":[{"thinking":"cut"#.utf8), to: url)

        try await store.append(id: id, cwd: "/w", message: user("second"))

        // Strict load still surfaces the truncated line 3, but line 4 is valid
        // on its own line rather than fused onto line 3.
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 4)
        #expect(lines[3].hasPrefix(#"{"message":"#))

        // Resuming recovers both valid messages and repairs the file on disk.
        let resolved = try await store.resolveResume(.id(id), cwd: "/w", freshId: id, scope: .context)
        #expect(resolved.resumed)
        #expect(resolved.recoveredCorruptLines == 1)
        #expect(texts(resolved.messages) == ["first", "second"])

        // After recovery, strict load succeeds cleanly.
        let strict = try await store.load(id: id)
        #expect(texts(strict.messages) == ["first", "second"])
    }

    @Test("resolveResume salvages a valid entry fused onto a truncated prefix and heals the file")
    func salvagesFusedEntryAndRepairsDisk() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "fused-line"
        try await store.append(id: id, cwd: "/w", messages: [user("before-compact"), assistant("old")])
        try await store.appendCompaction(
            id: id,
            cwd: "/w",
            replacementMessages: [user("recap")],
            messagesCompacted: 2,
            reason: .compact
        )
        try await store.append(id: id, cwd: "/w", message: user("after-compact"))

        // Produce a valid encoded entry line, then fuse it onto a truncated
        // assistant prefix (exact shape of a crash-truncated write followed by
        // a legacy append without a separating newline).
        let scratchId = "scratch"
        try await store.append(id: scratchId, cwd: "/w", message: user("salvaged-turn"))
        let scratchURL = dir.appendingPathComponent("\(scratchId).jsonl")
        let validEntryLine = try String(contentsOf: scratchURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)[1]

        let url = dir.appendingPathComponent("\(id).jsonl")
        let truncatedPrefix = #"{"message":{"api":"chatgpt-codex","content":[{"thinking":"**waiting**","thinkingSignature":"{\"encrypted_content\":\"gAAAAABq_truncated"#
        try appendRawBytes(Data((truncatedPrefix + validEntryLine + "\n").utf8), to: url)
        try await store.append(id: id, cwd: "/w", message: assistant("reply-after-fused"))

        // Strict loads still reject the corrupted file before recovery.
        await #expect(throws: SessionStore.SessionStoreError.self) {
            _ = try await store.load(id: id, scope: .context)
        }

        let resolved = try await store.resolveResume(.id(id), cwd: "/w", freshId: id, scope: .context)
        #expect(resolved.resumed)
        #expect(resolved.sessionId == id)
        #expect(resolved.recoveredCorruptLines == 1)
        #expect(texts(resolved.messages) == ["recap", "after-compact", "salvaged-turn", "reply-after-fused"])
        #expect(resolved.persistedCount == 4)

        // The poison pill is gone on disk: subsequent strict loads (both
        // context and full) succeed and future restarts keep full context.
        let strictContext = try await store.load(id: id, scope: .context)
        #expect(texts(strictContext.messages) == ["recap", "after-compact", "salvaged-turn", "reply-after-fused"])
        let strictFull = try await store.load(id: id, scope: .full)
        #expect(texts(strictFull.messages) == ["recap", "after-compact", "salvaged-turn", "reply-after-fused"])
        #expect(texts(strictFull.displayMessages) == [
            "before-compact", "old", "after-compact", "salvaged-turn", "reply-after-fused",
        ])

        let secondResume = try await store.resolveResume(.id(id), cwd: "/w", freshId: id, scope: .context)
        #expect(secondResume.resumed)
        #expect(secondResume.recoveredCorruptLines == 0)
        #expect(texts(secondResume.messages) == ["recap", "after-compact", "salvaged-turn", "reply-after-fused"])
    }

    @Test("resolveResume drops a pure truncated trailing line without losing prior context")
    func dropsTruncatedTrailingLine() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "trailing-cut"
        try await store.append(id: id, cwd: "/w", messages: [user("one"), assistant("two")])
        let url = dir.appendingPathComponent("\(id).jsonl")
        try appendRawBytes(Data(#"{"message":{"role":"assistant","content":[{"text":"half"#.utf8), to: url)

        let resolved = try await store.resolveResume(.id(id), cwd: "/w", freshId: id, scope: .context)
        #expect(resolved.resumed)
        #expect(resolved.recoveredCorruptLines == 1)
        #expect(texts(resolved.messages) == ["one", "two"])

        // Next append lands cleanly and strict load succeeds.
        try await store.append(id: id, cwd: "/w", message: user("three"))
        let strict = try await store.load(id: id)
        #expect(texts(strict.messages) == ["one", "two", "three"])
    }

    @Test("latestForCwd and full scope recover corrupt mid-file lines")
    func latestForCwdFullScopeRecovery() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "full-mid-corrupt"
        try await store.append(id: id, cwd: "/project", message: user("a"))
        let url = dir.appendingPathComponent("\(id).jsonl")
        try appendRawBytes(Data("not valid json at all\n".utf8), to: url)
        try await store.append(id: id, cwd: "/project", message: assistant("b"))

        let resolved = try await store.resolveResume(.latestForCwd, cwd: "/project", scope: .full)
        #expect(resolved.resumed)
        #expect(resolved.sessionId == id)
        #expect(resolved.recoveredCorruptLines == 1)
        #expect(texts(resolved.messages) == ["a", "b"])
        #expect(texts(resolved.displayMessages) == ["a", "b"])

        let strict = try await store.load(id: id, scope: .full)
        #expect(texts(strict.messages) == ["a", "b"])
    }

    @Test("context recovery across tiny chunk boundaries preserves exact byte offsets")
    func tinyChunkBoundaryRecovery() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "chunk-boundaries"
        try await store.append(id: id, cwd: "/w", message: user("first message with enough text to span chunks"))
        try await store.appendCompaction(
            id: id,
            cwd: "/w",
            replacementMessages: [user("compaction summary spanning multiple tiny chunks")],
            messagesCompacted: 1,
            reason: .compact
        )
        let url = dir.appendingPathComponent("\(id).jsonl")
        try appendRawBytes(Data("{\"broken\": [1, 2, 3\n".utf8), to: url)
        try await store.append(id: id, cwd: "/w", message: assistant("valid reply after broken line"))
        try appendRawBytes(Data("{\"truncated_eof\": true".utf8), to: url)

        let recovered = try await store.loadRecoveringCorruptEntries(
            at: url,
            scope: .context,
            tailChunkSize: 29
        )
        #expect(recovered.recoveredCorruptLines == 2)
        #expect(texts(recovered.loaded.messages) == [
            "compaction summary spanning multiple tiny chunks",
            "valid reply after broken line",
        ])

        let strict = try await store.load(id: id, scope: .full)
        #expect(texts(strict.messages) == [
            "compaction summary spanning multiple tiny chunks",
            "valid reply after broken line",
        ])
    }

    @Test("salvages a compaction marker fused onto a truncated prefix")
    func salvagesFusedCompactionMarker() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "fused-compaction"
        try await store.append(id: id, cwd: "/w", message: user("before"))

        let scratchId = "scratch-compact"
        try await store.appendCompaction(
            id: scratchId,
            cwd: "/w",
            replacementMessages: [user("fresh-recap")],
            messagesCompacted: 1,
            reason: .compact
        )
        let scratchURL = dir.appendingPathComponent("\(scratchId).jsonl")
        let compactionLine = try String(contentsOf: scratchURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)[1]

        let url = dir.appendingPathComponent("\(id).jsonl")
        try appendRawBytes(Data(("{\"message\":{\"truncated\":" + compactionLine + "\n").utf8), to: url)
        try await store.append(id: id, cwd: "/w", message: assistant("after"))

        let resolved = try await store.resolveResume(.id(id), cwd: "/w", freshId: id, scope: .context)
        #expect(resolved.resumed)
        #expect(resolved.recoveredCorruptLines == 1)
        #expect(texts(resolved.messages) == ["fresh-recap", "after"])

        let strict = try await store.load(id: id, scope: .context)
        #expect(texts(strict.messages) == ["fresh-recap", "after"])
    }

    private func tempStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwsess-recovery-\(UUID().uuidString)")
        return (SessionStore(directory: dir), dir)
    }

    private func appendRawBytes(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func texts(_ messages: [Message]) -> [String] {
        messages.map { message in
            switch message {
            case .user(let user):
                return user.content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined()
            case .assistant(let assistant):
                return assistant.content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined()
            default:
                return ""
            }
        }
    }

    private func user(_ text: String) -> Message {
        .user(UserMessage(text: text))
    }

    private func assistant(_ text: String) -> Message {
        .assistant(AssistantMessage(
            content: [.text(TextContent(text: text))],
            api: "anthropic",
            provider: "anthropic",
            model: "claude-test"
        ))
    }
}
