import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// `load(scope: .context)` skips every entry before the newest compaction
/// marker. It must project exactly the context, count and metadata a full
/// replay projects; only the visual history differs.
@Suite("SessionStore context load")
struct SessionContextLoadTests {

    @Test("context load matches a full replay across compactions, rewinds and metadata")
    func matchesFullReplay() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "mixed"
        let cwd = "/w"

        try await store.append(id: id, cwd: cwd, messages: [user("a"), assistant("b")], model: "m0", provider: "p0")
        try await store.appendMeta(id: id, model: "m1", thinkingLevel: "high")
        try await store.setTitle(id: id, cwd: cwd, title: "before the marker")
        try await store.append(id: id, cwd: cwd, messages: [user("c"), assistant("d"), user("e")])
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [user("summary 1")],
            messagesCompacted: 5,
            reason: .compact
        )
        try await store.append(id: id, cwd: cwd, messages: [assistant("f"), user("g"), assistant("h")])
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [user("summary 1"), assistant("f")],
            messagesCompacted: 2,
            reason: .rewind
        )
        try await store.appendMeta(id: id, provider: "p2")
        try await store.append(id: id, cwd: cwd, messages: [user("i"), assistant("j")])

        let full = try await store.load(id: id)
        let context = try await store.load(id: id, scope: .context)
        #expect(context.messages == full.messages)
        #expect(context.persistedContextCount == full.persistedContextCount)
        #expect(context.model == "m1")
        #expect(context.provider == "p2")
        #expect(context.thinkingLevel == "high")
        #expect(context.title == "before the marker")
        #expect(context.header == full.header)
        #expect(context.displayMessages == context.messages)
        #expect(full.displayMessages != full.messages)
    }

    @Test("a session without a compaction marker replays every entry")
    func noMarker() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.append(id: "plain", cwd: "/w", messages: [user("a"), assistant("b"), user("c")])

        let full = try await store.load(id: "plain")
        let context = try await store.load(id: "plain", scope: .context)
        #expect(context.messages == full.messages)
        #expect(context.persistedContextCount == 3)
    }

    @Test("legacy markers without a reason still project their replacement")
    func legacyMarker() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "legacy"
        try await store.append(id: id, cwd: "/w", messages: [user("a"), assistant("b"), user("c")])
        try await store.appendCompaction(
            id: id,
            cwd: "/w",
            replacementMessages: [user("a")],
            messagesCompacted: 2,
            reason: .rewind
        )
        try await store.append(id: id, cwd: "/w", message: assistant("d"))
        let file = dir.appendingPathComponent("\(id).jsonl")
        let raw = try String(contentsOf: file, encoding: .utf8)
        try raw.replacingOccurrences(of: #""reason":"rewind","#, with: "")
            .write(to: file, atomically: true, encoding: .utf8)

        let full = try await store.load(id: id)
        let context = try await store.load(id: id, scope: .context)
        #expect(context.messages == full.messages)
        #expect(texts(context.messages) == ["a", "d"])
    }

    @Test("marker-shaped text inside a message is not taken for a marker")
    func markerTextInsideMessage() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "lookalike"
        try await store.append(id: id, cwd: "/w", message: user("a"))
        try await store.appendCompaction(
            id: id,
            cwd: "/w",
            replacementMessages: [user("summary")],
            messagesCompacted: 1,
            reason: .compact
        )
        try await store.append(id: id, cwd: "/w", messages: [
            user(#"{"type":"compaction"} and "type":"meta" as plain text"#),
            assistant("ok"),
        ])

        let full = try await store.load(id: id)
        let context = try await store.load(id: id, scope: .context)
        #expect(context.messages == full.messages)
        #expect(context.messages.count == 3)
    }

    @Test("an entry before the newest marker is never decoded")
    func skipsEntriesBeforeTheMarker() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "old-corruption"
        try await store.append(id: id, cwd: "/w", message: user("a"))
        try appendRaw(#"{"message":"not-an-object","timestamp":1,"type":"message"}"#, id: id, dir: dir)
        try await store.appendCompaction(
            id: id,
            cwd: "/w",
            replacementMessages: [user("summary")],
            messagesCompacted: 2,
            reason: .compact
        )
        try await store.append(id: id, cwd: "/w", message: assistant("b"))

        let context = try await store.load(id: id, scope: .context)
        #expect(texts(context.messages) == ["summary", "b"])
        await #expect(throws: SessionStore.SessionStoreError.self) {
            _ = try await store.load(id: id)
        }
    }

    @Test("an undecodable entry after the newest marker throws with its line")
    func throwsAfterTheMarker() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "new-corruption"
        try await store.append(id: id, cwd: "/w", message: user("a"))
        try await store.appendCompaction(
            id: id,
            cwd: "/w",
            replacementMessages: [user("summary")],
            messagesCompacted: 1,
            reason: .compact
        )
        try appendRaw(#"{"message":"not-an-object","timestamp":1,"type":"message"}"#, id: id, dir: dir)

        let url = dir.appendingPathComponent("\(id).jsonl")
        var caught: SessionStore.SessionStoreError?
        do {
            _ = try await store.load(id: id, scope: .context)
        } catch let error as SessionStore.SessionStoreError {
            caught = error
        }
        #expect(caught == .undecodableEntry(path: url.path, line: 4))
    }

    @Test("resolveResume passes the scope through")
    func resolveResumeScope() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "resume"
        try await store.append(id: id, cwd: "/w", messages: [user("a"), assistant("b")])
        try await store.appendCompaction(
            id: id,
            cwd: "/w",
            replacementMessages: [user("summary")],
            messagesCompacted: 2,
            reason: .compact
        )
        try await store.append(id: id, cwd: "/w", message: user("c"))

        let resolved = try await store.resolveResume(.id(id), cwd: "/w", scope: .context)
        #expect(resolved.resumed)
        #expect(texts(resolved.messages) == ["summary", "c"])
        #expect(resolved.displayMessages == resolved.messages)
        #expect(resolved.persistedCount == 2)
    }

    @Test("context load across fresh SessionStore preserves pre-compaction metadata from compaction snapshot")
    func freshStorePreservesSnapshotMetadata() async throws {
        let (writer, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "restarted"
        let cwd = "/w"

        try await writer.append(id: id, cwd: cwd, messages: [user("a"), assistant("b")], model: "m0", provider: "p0")
        try await writer.appendMeta(id: id, model: "m1", thinkingLevel: "high")
        try await writer.setTitle(id: id, cwd: cwd, title: "persisted title")
        try await writer.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [user("summary")],
            messagesCompacted: 2,
            reason: .compact
        )
        try await writer.appendMeta(id: id, provider: "p2")
        try await writer.append(id: id, cwd: cwd, message: user("after"))

        // A brand-new store (fresh process) with no in-memory cache still sees
        // pre-compaction metadata via the compaction snapshot + post-compaction meta.
        let reader = SessionStore(directory: dir)
        let context = try await reader.load(id: id, scope: .context)
        let full = try await reader.load(id: id, scope: .full)
        #expect(context.messages == full.messages)
        #expect(context.model == "m1")
        #expect(context.provider == "p2")
        #expect(context.thinkingLevel == "high")
        #expect(context.title == "persisted title")
    }

    @Test("tail chunk scan handles tiny chunks, multi-chunk lines, blank lines, and no trailing newline")
    func multiChunkTailBoundaries() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "chunked"
        let cwd = "/w"
        let bigPayload = String(repeating: "x", count: 512)

        try await store.append(id: id, cwd: cwd, messages: [user("old1"), assistant("old2")], model: "m0", provider: "p0")
        try await store.appendMeta(id: id, model: "m1", thinkingLevel: "medium")
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [user("summary-" + bigPayload)],
            messagesCompacted: 2,
            reason: .compact
        )
        try await store.append(id: id, cwd: cwd, messages: [
            user("after-1-" + bigPayload),
            assistant("after-2"),
        ])

        let url = dir.appendingPathComponent("\(id).jsonl")
        // Inject blank lines and strip the trailing newline to exercise edge cases.
        var raw = try String(contentsOf: url, encoding: .utf8)
        raw = "\n\n" + raw.replacingOccurrences(of: "\n", with: "\n\n")
        while raw.hasSuffix("\n") { raw.removeLast() }
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let full = try await store.load(at: url, scope: .full)
        // Exercise chunk sizes smaller than a single line (32, 64, 127 bytes).
        for chunkSize in [32, 64, 127, 4096] {
            let context = try await store.loadContext(at: url, tailChunkSize: chunkSize)
            #expect(context.messages == full.messages)
            #expect(context.model == "m1")
            #expect(context.provider == "p0")
            #expect(context.thinkingLevel == "medium")
            #expect(context.header == full.header)
        }
    }

    @Test("context load ignores unreadable corruption far before the marker and reports exact line after it")
    func largePrefixNeverReadOnHappyPath() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "large-prefix"
        let cwd = "/w"

        try await store.create(id: id, cwd: cwd, model: "m0", provider: "p0")
        let url = dir.appendingPathComponent("\(id).jsonl")

        // Write ~2 MiB of invalid non-UTF8 / corrupt JSON lines before the compaction marker.
        // A tail-only reader must never touch or decode them.
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var garbageLine = Data([0xFF, 0xFE, 0x7B])
            garbageLine.append(Data(repeating: 0x41, count: 64 * 1024))
            garbageLine.append(0x0A)
            for _ in 0..<32 {
                handle.write(garbageLine)
            }
        }

        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [user("compacted")],
            messagesCompacted: 32,
            reason: .compact
        )
        try await store.append(id: id, cwd: cwd, message: assistant("live"))

        let context = try await store.load(id: id, scope: .context)
        #expect(texts(context.messages) == ["compacted", "live"])
        #expect(context.persistedContextCount == 2)

        // Appending a corrupt line after the marker still reports its exact 1-based line number:
        // 1 (header) + 32 (garbage lines) + 1 (compaction) + 1 (assistant) + 1 (corrupt) = 36.
        try appendRaw(#"{"message":"bad","timestamp":1,"type":"message"}"#, id: id, dir: dir)
        var caught: SessionStore.SessionStoreError?
        do {
            _ = try await store.load(id: id, scope: .context)
        } catch let error as SessionStore.SessionStoreError {
            caught = error
        }
        #expect(caught == .undecodableEntry(path: url.path, line: 36))
    }

    @Test("header-only session loads empty context")
    func headerOnlySession() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.create(id: "empty", cwd: "/w", model: "m0", provider: "p0")

        let context = try await store.load(id: "empty", scope: .context)
        #expect(context.messages.isEmpty)
        #expect(context.model == "m0")
        #expect(context.provider == "p0")
    }

    private func tempStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwsess-context-\(UUID().uuidString)")
        return (SessionStore(directory: dir), dir)
    }

    private func appendRaw(_ line: String, id: String, dir: URL) throws {
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("\(id).jsonl"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(Data((line + "\n").utf8))
    }

    /// Message text only: each constructed message carries its own timestamp.
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
