import Foundation
import KWWKAI

/// Append-only JSONL session persistence. `SessionStore()` is disabled and
/// does not touch disk; the CLI opts into `~/.kwwk/sessions` via
/// `defaultDirectory()`.
///
/// Mirrors pi's `packages/agent/src/harness/session` storage in spirit but
/// keeps a flat append-oriented log instead of pi's branching entry tree: each
/// session file is a versioned header line followed by one JSON entry per
/// line. Entries are transcript messages (`user` / `assistant` /
/// `toolResult`), sparse metadata updates (model / thinking-level changes),
/// or compaction markers that describe the projected resumable context.
///
/// Ordinary persistence is append-only, so recording each message is cheap.
/// Explicit transcript maintenance such as `/shake` atomically rewrites the
/// existing entries so removed payloads do not remain buried in older JSONL
/// lines. Loading replays the log to reconstruct the projected context plus
/// the latest metadata.
///
/// File layout (one JSON object per line):
/// ```
/// {"type":"session","version":1,"id":"…","cwd":"…","createdAt":…,"model":"…","provider":"…"}
/// {"type":"message","timestamp":…,"message":{ …Message… }}
/// {"type":"meta","timestamp":…,"model":"…","provider":"…","thinkingLevel":"…"}
/// {"type":"compaction","timestamp":…,"replacementMessages":[{ …Message… }],"messagesCompacted":42}
/// ```
public actor SessionStore {

    /// On-disk JSONL schema version. Bump when the entry shapes change in a
    /// non-backward-compatible way; `load` rejects unknown versions.
    public static let version = 1

    /// Directory holding `<id>.jsonl` files when persistence is enabled.
    public let directory: URL
    public let isPersistent: Bool

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
            self.isPersistent = true
        } else {
            self.directory = URL(fileURLWithPath: "/dev/null")
            self.isPersistent = false
        }
    }

    /// CLI-compatible session directory: `~/.kwwk/sessions`.
    public static func defaultDirectory() -> URL {
        let home: URL = {
            #if targetEnvironment(macCatalyst) || os(iOS)
            return URL(fileURLWithPath: NSHomeDirectory())
            #else
            return FileManager.default.homeDirectoryForCurrentUser
            #endif
        }()
        return home
            .appendingPathComponent(".kwwk")
            .appendingPathComponent("sessions")
    }

    // MARK: - Paths

    public static func isValidSessionId(_ id: String) -> Bool {
        guard let first = id.first, let last = id.last,
              first.isLetter || first.isNumber,
              last.isLetter || last.isNumber else { return false }
        return id.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "."
        }
    }

    private func path(for id: String) throws -> URL {
        guard isPersistent else { throw SessionStoreError.storageDisabled }
        guard Self.isValidSessionId(id) else { throw SessionStoreError.invalidId(id) }
        return directory.appendingPathComponent("\(id).jsonl")
    }

    private func ensureDirectory() throws {
        guard isPersistent else { throw SessionStoreError.storageDisabled }
        // 0700: session transcripts carry the full conversation plus every tool
        // result (bash output, file contents). Lock the directory to the owner
        // at creation, mirroring BackgroundTaskManager's 0700 output dir — no
        // chmod-after-create race.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Stable key order keeps the JSONL human-diffable.
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    struct MessageRewrite: Sendable {
        let messages: [Message]
        let changedCount: Int
    }

    private struct MetaSnapshot: Sendable {
        var model: String?
        var provider: String?
        var thinkingLevel: String?
        var title: String?

        mutating func merge(
            model: String? = nil,
            provider: String? = nil,
            thinkingLevel: String? = nil,
            title: String? = nil
        ) {
            if let model { self.model = model }
            if let provider { self.provider = provider }
            if let thinkingLevel { self.thinkingLevel = thinkingLevel }
            if let title { self.title = title }
        }
    }

    /// Cached latest session metadata per session id, populated on create,
    /// meta appends, and loads so `appendCompaction` can snapshot it onto the
    /// compaction marker without re-reading the file.
    private var latestMetaBySession: [String: MetaSnapshot] = [:]

    // MARK: - Create / append

    /// Create a new session file with a versioned header. Overwrites any
    /// existing file for the same id — use `createIfMissing` to preserve a
    /// resumed transcript. Returns the written header.
    @discardableResult
    public func create(
        id: String,
        cwd: String,
        model: String? = nil,
        provider: String? = nil
    ) throws -> Header {
        try ensureDirectory()
        let header = Header(id: id, cwd: cwd, model: model, provider: provider)
        let line = try Self.encoder.encode(header)
        var data = line
        data.append(0x0A)  // newline
        let url = try path(for: id)
        // Create with 0600 at write time (no chmod-after-write window): the
        // transcript is the same class of sensitive data the 0600 task logs
        // protect. createFile truncates an existing file, matching this
        // method's overwrite contract.
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionStoreError.writeFailed(path: url.path)
        }
        latestMetaBySession[id] = MetaSnapshot(model: model, provider: provider)
        return header
    }

    /// Create the session file (header only) only when it does not already
    /// exist. Never truncates an existing transcript, so resuming a session
    /// and then calling this is a safe no-op. Backs `SessionRecorder.ensureCreated`.
    public func createIfMissing(
        id: String,
        cwd: String,
        model: String? = nil,
        provider: String? = nil
    ) throws {
        let url = try path(for: id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try create(id: id, cwd: cwd, model: model, provider: provider)
    }

    /// Append a single transcript message to a session, creating the file
    /// (with a header) on demand if it does not yet exist.
    public func append(
        id: String,
        cwd: String,
        message: Message,
        model: String? = nil,
        provider: String? = nil
    ) throws {
        let url = try path(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try create(id: id, cwd: cwd, model: model, provider: provider)
        }
        try appendEntry(
            id: id,
            .message(
                timestamp: Timestamp.now(),
                message: Self.removingInternalMessageSource(message)
            )
        )
    }

    /// Append all `messages` in order. Persists each as its own JSONL line.
    public func append(
        id: String,
        cwd: String,
        messages: [Message],
        model: String? = nil,
        provider: String? = nil
    ) throws {
        for message in messages {
            try append(id: id, cwd: cwd, message: message, model: model, provider: provider)
        }
    }

    /// Record a metadata change (model / provider / thinking level) without a
    /// transcript message.
    public func appendMeta(
        id: String,
        model: String? = nil,
        provider: String? = nil,
        thinkingLevel: String? = nil,
        title: String? = nil
    ) throws {
        try appendEntry(id: id, .meta(
            timestamp: Timestamp.now(),
            model: model,
            provider: provider,
            thinkingLevel: thinkingLevel,
            title: title
        ))
        var snapshot = latestMetaBySession[id] ?? MetaSnapshot()
        snapshot.merge(
            model: model,
            provider: provider,
            thinkingLevel: thinkingLevel,
            title: title
        )
        latestMetaBySession[id] = snapshot
    }

    /// Record a user-set session title as an append-only `meta` entry,
    /// creating the file (with a header) on demand. Backs `/rename`.
    public func setTitle(id: String, cwd: String, title: String) throws {
        let url = try path(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try create(id: id, cwd: cwd)
        }
        try appendMeta(id: id, title: title)
    }

    /// Record a context compaction without rewriting prior message entries.
    /// Loading the session will project `replacementMessages` first, followed
    /// by message entries appended after this marker.
    public func appendCompaction(
        id: String,
        cwd: String,
        replacementMessages: [Message],
        messagesCompacted: Int,
        firstKeptMessageIndex: Int? = nil,
        tokensBefore: Int? = nil,
        contextWindow: Int? = nil,
        reason: CompactionReason,
        usage: Usage? = nil,
        model: String? = nil,
        provider: String? = nil
    ) throws {
        let url = try path(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try create(id: id, cwd: cwd, model: model, provider: provider)
        }
        let trustedRecap = replacementMessages.first.flatMap {
            CompactionPlanner.summaryText(from: $0)
        } == nil ? nil : true
        let persistableMessages = replacementMessages.map(Self.removingInternalMessageSource)
        let meta = latestMetaBySession[id]
        try appendEntry(
            id: id,
            .compaction(
                timestamp: Timestamp.now(),
                compaction: Compaction(
                    replacementMessages: persistableMessages,
                    messagesCompacted: messagesCompacted,
                    firstKeptMessageIndex: firstKeptMessageIndex,
                    tokensBefore: tokensBefore,
                    contextWindow: contextWindow,
                    trustedRecap: trustedRecap,
                    reason: reason,
                    usage: usage,
                    model: meta?.model,
                    provider: meta?.provider,
                    thinkingLevel: meta?.thinkingLevel,
                    title: meta?.title
                )
            ))
    }

    private func appendEntry(id: String, _ entry: Entry) throws {
        let url = try path(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionStoreError.notFound(id)
        }
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        // If an earlier write was cut short mid-line (process killed or FUSE
        // flush interrupted), the file ends without a trailing newline. Insert
        // one first so the new entry lands on its own valid line instead of
        // fusing onto the truncated fragment and poisoning both.
        if fileSize > 0 {
            let lastByte = try Self.readExact(handle: handle, offset: fileSize - 1, count: 1)
            if lastByte.first != 0x0A {
                var separated = Data([0x0A])
                separated.append(line)
                line = separated
            }
            _ = try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    /// Atomically rewrite every persisted transcript-bearing entry with one
    /// canonical message transformation. Both ordinary message lines and the
    /// replacement context inside compaction markers are rewritten; headers,
    /// metadata, timestamps, and compaction bookkeeping remain unchanged.
    ///
    /// Returns the number of transformed payloads across the physical JSONL
    /// entries. A zero result leaves the file untouched.
    func rewriteMessages(
        id: String,
        using transform: @Sendable ([Message]) -> MessageRewrite
    ) throws -> Int {
        let url = try path(for: id)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw SessionStoreError.notFound(id)
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else {
            throw SessionStoreError.missingHeader(url.path)
        }
        _ = try parseHeader(String(first), path: url.path)

        var rewrittenEntries: [Entry] = []
        rewrittenEntries.reserveCapacity(max(0, lines.count - 1))
        var changedCount = 0

        for (offset, line) in lines.dropFirst().enumerated() {
            let lineNumber = offset + 2
            guard let data = String(line).data(using: .utf8) else {
                throw SessionStoreError.undecodableEntry(path: url.path, line: lineNumber)
            }
            let entry: Entry
            do {
                entry = try Self.decoder.decode(Entry.self, from: data)
            } catch {
                throw SessionStoreError.undecodableEntry(path: url.path, line: lineNumber)
            }

            switch entry {
            case .message(let timestamp, let message):
                let rewrite = transform([message])
                changedCount += rewrite.changedCount
                rewrittenEntries.append(.message(
                    timestamp: timestamp,
                    message: rewrite.messages[0]
                ))

            case .compaction(let timestamp, var compaction):
                let rewrite = transform(compaction.replacementMessages)
                changedCount += rewrite.changedCount
                compaction.replacementMessages = rewrite.messages
                rewrittenEntries.append(.compaction(
                    timestamp: timestamp,
                    compaction: compaction
                ))

            case .meta:
                rewrittenEntries.append(entry)
            }
        }

        guard changedCount > 0 else { return 0 }

        var data = Data()
        data.append(contentsOf: first.utf8)
        data.append(0x0A)
        for entry in rewrittenEntries {
            data.append(try Self.encoder.encode(entry))
            data.append(0x0A)
        }
        try replaceAtomically(url: url, data: data)
        return changedCount
    }

    private func replaceAtomically(url: URL, data: Data) throws {
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionStoreError.writeFailed(path: url.path)
        }
        // POSIX rename(2) atomically replaces the destination on macOS and
        // Linux alike. FileManager.replaceItemAt is not usable here: on
        // swift-corelibs-foundation it can leave the destination missing.
        guard rename(temporaryURL.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw SessionStoreError.writeFailed(path: url.path)
        }
    }

    // MARK: - Load

    /// How much of a session file `load` replays.
    public enum LoadScope: Sendable, Hashable {
        /// Every entry: the model-facing context plus the full visual
        /// history (`displayMessages`) a terminal recap shows.
        case full
        /// The model-facing context only. Reads the header at offset 0 and
        /// scans backwards from EOF in bounded chunks until the newest
        /// compaction marker is found, so entries before that marker are never
        /// read from disk or decoded. `displayMessages` then equals `messages`.
        /// A long-lived session's file keeps every message it ever recorded,
        /// embedded images included, so tail-only I/O keeps resuming one
        /// proportional to its live context rather than to its age — even over
        /// network-backed filesystems.
        case context
    }

    /// Default chunk size when scanning backwards from EOF in `loadContext`.
    /// 256 KiB captures a typical compaction marker + trailing turns in a
    /// single read while keeping memory bounded when a marker is farther back.
    static let defaultTailChunkSize = 256 * 1024

    /// Replay a session file into its header, projected resumable context, raw
    /// transcript message entries, and latest metadata. Throws on a
    /// missing/invalid header or unsupported version.
    public func load(id: String, scope: LoadScope = .full) throws -> LoadedSession {
        try load(at: try path(for: id), scope: scope)
    }

    public func load(at url: URL, scope: LoadScope = .full) throws -> LoadedSession {
        let loaded: LoadedSession
        switch scope {
        case .full: loaded = try loadFull(at: url)
        case .context: loaded = try loadContext(at: url, tailChunkSize: Self.defaultTailChunkSize)
        }
        latestMetaBySession[loaded.header.id] = MetaSnapshot(
            model: loaded.model,
            provider: loaded.provider,
            thinkingLevel: loaded.thinkingLevel,
            title: loaded.title
        )
        return loaded
    }

    private func loadFull(at url: URL) throws -> LoadedSession {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw SessionStoreError.notFound(url.lastPathComponent)
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else {
            throw SessionStoreError.missingHeader(url.path)
        }
        var replay = Replay(header: try parseHeader(String(first), path: url.path), tracksDisplay: true)

        // Line 1 is the header; entries start at line 2. An entry that fails
        // to decode (schema drift after an up/downgrade, mid-file corruption)
        // is an error — throwing with the exact line keeps a resumed context
        // from silently losing messages out of the middle of a conversation.
        for (offset, line) in lines.dropFirst().enumerated() {
            guard let data = String(line).data(using: .utf8) else {
                throw SessionStoreError.undecodableEntry(path: url.path, line: offset + 2)
            }
            replay.apply(try Self.decodeEntry(data, path: url.path, line: offset + 2))
        }
        return replay.loaded
    }

    func loadContext(at url: URL, tailChunkSize: Int = defaultTailChunkSize) throws -> LoadedSession {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SessionStoreError.notFound(url.lastPathComponent)
        }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            throw SessionStoreError.notFound(url.lastPathComponent)
        }
        guard fileSize > 0 else {
            throw SessionStoreError.missingHeader(url.path)
        }

        let (headerData, bodyStartOffset) = try Self.readHeaderLine(
            from: handle,
            fileSize: fileSize,
            path: url.path
        )
        guard let headerLine = String(data: headerData, encoding: .utf8) else {
            throw SessionStoreError.invalidHeader(url.path)
        }
        var replay = Replay(header: try parseHeader(headerLine, path: url.path), tracksDisplay: false)
        guard bodyStartOffset < fileSize else {
            return replay.loaded
        }

        // Scan backwards from EOF in bounded chunks until we hit the newest
        // compaction marker (or reach `bodyStartOffset` when no compaction
        // exists). Bytes before that marker are never read from disk.
        let chunkSize = max(1, tailChunkSize)
        var cursor = fileSize
        var fragmentChunks: [Data] = []
        var collectedReversed: [(data: Data, offset: UInt64)] = []
        var foundCompaction = false

        func isCompactionMarker(_ lineData: Data) -> Bool {
            guard Self.contains(lineData, Self.compactionDiscriminator) else { return false }
            if case .compaction? = try? Self.decoder.decode(Entry.self, from: lineData) {
                return true
            }
            return false
        }

        while cursor > bodyStartOffset && !foundCompaction {
            let step = UInt64(chunkSize)
            let readStart = cursor > step ? max(bodyStartOffset, cursor - step) : bodyStartOffset
            let length = Int(cursor - readStart)
            let chunk = try Self.readExact(handle: handle, offset: readStart, count: length)

            var segmentEnd = chunk.count
            chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var i = chunk.count - 1
                while i >= 0 {
                    if bytes[i] == 0x0A {
                        let lineStart = i + 1
                        let lineData = Self.assembleLine(
                            prefix: chunk,
                            range: lineStart..<segmentEnd,
                            trailingChunksReversed: fragmentChunks
                        )
                        fragmentChunks.removeAll(keepingCapacity: true)
                        segmentEnd = i
                        if !lineData.isEmpty {
                            let lineOffset = readStart + UInt64(lineStart)
                            collectedReversed.append((lineData, lineOffset))
                            if isCompactionMarker(lineData) {
                                foundCompaction = true
                                break
                            }
                        }
                    }
                    i -= 1
                }
            }

            if !foundCompaction {
                if segmentEnd > 0 {
                    fragmentChunks.append(Data(chunk[0..<segmentEnd]))
                }
                cursor = readStart
            }
        }

        if !foundCompaction && !fragmentChunks.isEmpty {
            let lineData = Self.assembleLine(
                prefix: nil,
                range: 0..<0,
                trailingChunksReversed: fragmentChunks
            )
            if !lineData.isEmpty {
                collectedReversed.append((lineData, bodyStartOffset))
            }
        }

        for item in collectedReversed.reversed() {
            do {
                let entry = try Self.decoder.decode(Entry.self, from: item.data)
                replay.apply(entry)
            } catch {
                // Only on the error path do we scan preceding bytes to report
                // the exact 1-based non-empty line number.
                let preceding = (try? Self.countNonEmptyLines(in: handle, upTo: item.offset)) ?? 0
                throw SessionStoreError.undecodableEntry(path: url.path, line: preceding + 1)
            }
        }
        return replay.loaded
    }

    struct RecoveredLoad: Sendable {
        let loaded: LoadedSession
        let recoveredCorruptLines: Int
    }

    private struct RawLineRecord {
        let data: Data
        /// Byte offset of the first byte of `data` in the session file.
        let offset: UInt64
        /// Byte length of this line in the file, including its terminating
        /// `\n` when one is present.
        let byteLength: Int
    }

    private struct ByteRangeReplacement {
        let offset: UInt64
        let length: Int
        let replacement: Data
    }

    /// Replay a session file, salvaging or skipping undecodable lines instead
    /// of throwing away the whole transcript. When any corrupt line is found,
    /// the file is stream-repaired atomically in place so subsequent strict
    /// loads and restarts succeed cleanly without losing context again.
    ///
    /// Missing/invalid headers and unsupported schema versions still throw —
    /// only entry-line corruption after the header is recovered.
    func loadRecoveringCorruptEntries(
        id: String,
        scope: LoadScope = .full
    ) throws -> RecoveredLoad {
        try loadRecoveringCorruptEntries(at: try path(for: id), scope: scope)
    }

    func loadRecoveringCorruptEntries(
        at url: URL,
        scope: LoadScope = .full,
        tailChunkSize: Int = defaultTailChunkSize
    ) throws -> RecoveredLoad {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SessionStoreError.notFound(url.lastPathComponent)
        }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw SessionStoreError.notFound(url.lastPathComponent)
        }
        guard fileSize > 0 else {
            try? handle.close()
            throw SessionStoreError.missingHeader(url.path)
        }

        let header: Header
        let bodyStartOffset: UInt64
        do {
            let (headerData, startOffset) = try Self.readHeaderLine(
                from: handle,
                fileSize: fileSize,
                path: url.path
            )
            guard let headerLine = String(data: headerData, encoding: .utf8) else {
                throw SessionStoreError.invalidHeader(url.path)
            }
            header = try parseHeader(headerLine, path: url.path)
            bodyStartOffset = startOffset
        } catch {
            try? handle.close()
            throw error
        }

        var replay = Replay(header: header, tracksDisplay: scope == .full)
        var replacements: [ByteRangeReplacement] = []
        var recoveredCount = 0

        if bodyStartOffset < fileSize {
            let records: [RawLineRecord]
            do {
                switch scope {
                case .context:
                    records = try Self.collectContextLines(
                        from: handle,
                        bodyStartOffset: bodyStartOffset,
                        fileSize: fileSize,
                        tailChunkSize: tailChunkSize
                    )
                case .full:
                    records = try Self.collectAllLines(
                        from: handle,
                        bodyStartOffset: bodyStartOffset,
                        fileSize: fileSize,
                        chunkSize: tailChunkSize
                    )
                }
            } catch {
                try? handle.close()
                throw error
            }

            for record in records {
                if let entry = try? Self.decoder.decode(Entry.self, from: record.data) {
                    replay.apply(entry)
                    continue
                }
                recoveredCount += 1
                if let salvaged = Self.salvageTrailingEntry(from: record.data) {
                    replay.apply(salvaged.entry)
                    var replacement = salvaged.rawBytes
                    replacement.append(0x0A)
                    replacements.append(ByteRangeReplacement(
                        offset: record.offset,
                        length: record.byteLength,
                        replacement: replacement
                    ))
                } else {
                    replacements.append(ByteRangeReplacement(
                        offset: record.offset,
                        length: record.byteLength,
                        replacement: Data()
                    ))
                }
            }
        }

        try? handle.close()

        if !replacements.isEmpty {
            try? Self.streamReplaceRanges(
                in: url,
                directory: directory,
                fileSize: fileSize,
                replacements: replacements
            )
        }

        let loaded = replay.loaded
        latestMetaBySession[loaded.header.id] = MetaSnapshot(
            model: loaded.model,
            provider: loaded.provider,
            thinkingLevel: loaded.thinkingLevel,
            title: loaded.title
        )
        return RecoveredLoad(loaded: loaded, recoveredCorruptLines: recoveredCount)
    }

    /// Every top-level key a valid `Entry` JSON object can begin with
    /// (`.message`, `.meta`, or `.compaction`, sorted or unsorted).
    private static let fusedEntryPrefixes: [[UInt8]] = [
        #"{"contextWindow":"#,
        #"{"firstKeptMessageIndex":"#,
        #"{"message":"#,
        #"{"messagesCompacted":"#,
        #"{"model":"#,
        #"{"provider":"#,
        #"{"reason":"#,
        #"{"replacementMessages":"#,
        #"{"thinkingLevel":"#,
        #"{"timestamp":"#,
        #"{"title":"#,
        #"{"tokensBefore":"#,
        #"{"trustedRecap":"#,
        #"{"type":"#,
        #"{"usage":"#,
    ].map { Array($0.utf8) }

    /// When a previous write was truncated mid-line without a trailing newline,
    /// the next appended JSON entry can land fused onto the end of the same
    /// line (`<truncated prefix>{"message":{...}}`). Scan for a valid entry
    /// suffix so that valid message is not lost when discarding the prefix.
    private static func salvageTrailingEntry(from lineData: Data) -> (entry: Entry, rawBytes: Data)? {
        guard lineData.count > 2 else { return nil }
        var candidateOffsets: [Int] = []
        lineData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let count = bytes.count
            var i = 1
            while i < count - 1 {
                if bytes[i] == 0x7B && bytes[i + 1] == 0x22 { // `{"`
                    for prefix in fusedEntryPrefixes {
                        if i + prefix.count <= count {
                            var matched = true
                            for j in 2..<prefix.count {
                                if bytes[i + j] != prefix[j] {
                                    matched = false
                                    break
                                }
                            }
                            if matched {
                                candidateOffsets.append(i)
                                break
                            }
                        }
                    }
                }
                i += 1
            }
        }
        for offset in candidateOffsets {
            let suffix = Data(lineData[offset...])
            if let entry = try? decoder.decode(Entry.self, from: suffix) {
                return (entry, suffix)
            }
        }
        return nil
    }

    /// Scans backwards from EOF in bounded chunks until the newest valid
    /// compaction marker (or `bodyStartOffset`), returning lines in file order
    /// with their exact file offsets and byte lengths.
    private static func collectContextLines(
        from handle: FileHandle,
        bodyStartOffset: UInt64,
        fileSize: UInt64,
        tailChunkSize: Int
    ) throws -> [RawLineRecord] {
        let chunkSize = max(1, tailChunkSize)
        var cursor = fileSize
        var fragmentChunks: [Data] = []
        var fragmentHasTrailingNewline = false
        var collectedReversed: [RawLineRecord] = []
        var foundCompaction = false

        func isCompactionMarker(_ lineData: Data) -> Bool {
            guard contains(lineData, compactionDiscriminator) else { return false }
            if case .compaction? = try? decoder.decode(Entry.self, from: lineData) {
                return true
            }
            return false
        }

        while cursor > bodyStartOffset && !foundCompaction {
            let step = UInt64(chunkSize)
            let readStart = cursor > step ? max(bodyStartOffset, cursor - step) : bodyStartOffset
            let length = Int(cursor - readStart)
            let chunk = try readExact(handle: handle, offset: readStart, count: length)

            var segmentEnd = chunk.count
            chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var i = chunk.count - 1
                while i >= 0 {
                    if bytes[i] == 0x0A {
                        let lineStart = i + 1
                        let lineData = assembleLine(
                            prefix: chunk,
                            range: lineStart..<segmentEnd,
                            trailingChunksReversed: fragmentChunks
                        )
                        let hasNewline = fragmentChunks.isEmpty
                            ? (segmentEnd < chunk.count || fragmentHasTrailingNewline)
                            : fragmentHasTrailingNewline
                        fragmentChunks.removeAll(keepingCapacity: true)
                        fragmentHasTrailingNewline = true
                        segmentEnd = i
                        if !lineData.isEmpty {
                            let lineOffset = readStart + UInt64(lineStart)
                            let byteLength = lineData.count + (hasNewline ? 1 : 0)
                            collectedReversed.append(RawLineRecord(
                                data: lineData,
                                offset: lineOffset,
                                byteLength: byteLength
                            ))
                            if isCompactionMarker(lineData) {
                                foundCompaction = true
                                break
                            }
                        }
                    }
                    i -= 1
                }
            }

            if !foundCompaction {
                if segmentEnd > 0 {
                    fragmentChunks.append(Data(chunk[0..<segmentEnd]))
                }
                cursor = readStart
            }
        }

        if !foundCompaction && !fragmentChunks.isEmpty {
            let lineData = assembleLine(
                prefix: nil,
                range: 0..<0,
                trailingChunksReversed: fragmentChunks
            )
            if !lineData.isEmpty {
                let byteLength = lineData.count + (fragmentHasTrailingNewline ? 1 : 0)
                collectedReversed.append(RawLineRecord(
                    data: lineData,
                    offset: bodyStartOffset,
                    byteLength: byteLength
                ))
            }
        }

        return collectedReversed.reversed()
    }

    /// Scans forward from `bodyStartOffset` to `fileSize` in chunks, returning
    /// every non-empty line with its exact file offset and byte length.
    private static func collectAllLines(
        from handle: FileHandle,
        bodyStartOffset: UInt64,
        fileSize: UInt64,
        chunkSize: Int
    ) throws -> [RawLineRecord] {
        let stepSize = max(1, chunkSize)
        var offset = bodyStartOffset
        var currentLine = Data()
        var currentLineStart = bodyStartOffset
        var records: [RawLineRecord] = []

        while offset < fileSize {
            let remaining = Int(min(UInt64(stepSize), fileSize - offset))
            let chunk = try readExact(handle: handle, offset: offset, count: remaining)
            guard !chunk.isEmpty else { break }

            var pos = 0
            while pos < chunk.count {
                if let nl = chunk[pos...].firstIndex(of: 0x0A) {
                    if currentLine.isEmpty {
                        currentLineStart = offset + UInt64(pos)
                    }
                    if nl > pos {
                        currentLine.append(chunk[pos..<nl])
                    }
                    if !currentLine.isEmpty {
                        records.append(RawLineRecord(
                            data: currentLine,
                            offset: currentLineStart,
                            byteLength: currentLine.count + 1
                        ))
                        currentLine.removeAll(keepingCapacity: true)
                    }
                    pos = nl + 1
                } else {
                    if currentLine.isEmpty {
                        currentLineStart = offset + UInt64(pos)
                    }
                    currentLine.append(chunk[pos..<chunk.count])
                    pos = chunk.count
                }
            }
            offset += UInt64(chunk.count)
        }

        if !currentLine.isEmpty {
            records.append(RawLineRecord(
                data: currentLine,
                offset: currentLineStart,
                byteLength: currentLine.count
            ))
        }
        return records
    }

    /// Stream-copies `url` into a temporary 0600 file while applying sorted
    /// non-overlapping byte-range replacements, then atomically renames it
    /// into place. Uses bounded memory regardless of file size.
    private static func streamReplaceRanges(
        in url: URL,
        directory: URL,
        fileSize: UInt64,
        replacements: [ByteRangeReplacement]
    ) throws {
        let sorted = replacements.sorted { $0.offset < $1.offset }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }

        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionStoreError.writeFailed(path: url.path)
        }

        do {
            let writer = try FileHandle(forWritingTo: temporaryURL)
            defer { try? writer.close() }

            var cursor: UInt64 = 0
            var lastWrittenByte: UInt8?

            func copyRange(_ start: UInt64, _ end: UInt64) throws {
                var pos = start
                while pos < end {
                    let count = Int(min(UInt64(defaultTailChunkSize), end - pos))
                    let chunk = try readExact(handle: reader, offset: pos, count: count)
                    guard !chunk.isEmpty else { break }
                    try writer.write(contentsOf: chunk)
                    lastWrittenByte = chunk.last
                    pos += UInt64(chunk.count)
                }
            }

            for item in sorted {
                let start = max(cursor, item.offset)
                if start > cursor {
                    try copyRange(cursor, start)
                }
                if !item.replacement.isEmpty {
                    try writer.write(contentsOf: item.replacement)
                    lastWrittenByte = item.replacement.last
                }
                cursor = min(fileSize, item.offset + UInt64(item.length))
            }
            if cursor < fileSize {
                try copyRange(cursor, fileSize)
            }
            if let last = lastWrittenByte, last != 0x0A {
                try writer.write(contentsOf: Data([0x0A]))
            }
            try writer.close()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        guard rename(temporaryURL.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw SessionStoreError.writeFailed(path: url.path)
        }
    }

    private static let compactionDiscriminator = Array(#""type":"compaction""#.utf8)

    private static func decodeEntry(_ data: Data, path: String, line: Int) throws -> Entry {
        do {
            return try decoder.decode(Entry.self, from: data)
        } catch {
            throw SessionStoreError.undecodableEntry(path: path, line: line)
        }
    }

    private static func readExact(handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count),
                  !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }
        return result
    }

    /// Reads the first non-empty line at the start of the file without pulling
    /// the rest of the file into memory. Returns the line bytes (without `\n`)
    /// and the byte offset immediately after its terminating `\n` (or
    /// `fileSize` if the file has only one line).
    private static func readHeaderLine(
        from handle: FileHandle,
        fileSize: UInt64,
        path: String
    ) throws -> (Data, UInt64) {
        var offset: UInt64 = 0
        var chunkSize = 4096
        var line = Data()

        while offset < fileSize {
            let remaining = Int(min(UInt64(chunkSize), fileSize - offset))
            let chunk = try readExact(handle: handle, offset: offset, count: remaining)
            guard !chunk.isEmpty else { break }

            var searchStart = 0
            if line.isEmpty {
                // Skip any leading empty lines to match `split(omittingEmptySubsequences: true)`.
                while searchStart < chunk.count && chunk[searchStart] == 0x0A {
                    searchStart += 1
                }
                if searchStart == chunk.count {
                    offset += UInt64(chunk.count)
                    continue
                }
            }

            if let newline = chunk[searchStart...].firstIndex(of: 0x0A) {
                line.append(chunk[searchStart..<newline])
                return (line, offset + UInt64(newline) + 1)
            }
            line.append(chunk[searchStart..<chunk.count])
            offset += UInt64(chunk.count)
            chunkSize = min(chunkSize * 2, defaultTailChunkSize)
        }

        guard !line.isEmpty else {
            throw SessionStoreError.missingHeader(path)
        }
        return (line, fileSize)
    }

    /// Assembles a line from its leftmost slice in the current chunk plus any
    /// trailing fragments collected from earlier (right-hand) chunks.
    private static func assembleLine(
        prefix: Data?,
        range: Range<Int>,
        trailingChunksReversed: [Data]
    ) -> Data {
        if trailingChunksReversed.isEmpty {
            guard let prefix, !range.isEmpty else { return Data() }
            return Data(prefix[range])
        }
        var total = range.count
        for chunk in trailingChunksReversed { total += chunk.count }
        var out = Data()
        out.reserveCapacity(total)
        if let prefix, !range.isEmpty {
            out.append(prefix[range])
        }
        for chunk in trailingChunksReversed.reversed() {
            out.append(chunk)
        }
        return out
    }

    /// Streams `0..<limit` in chunks to count non-empty lines, matching
    /// `split(separator: "\n", omittingEmptySubsequences: true)`. Called only
    /// when reporting an undecodable-entry error line number.
    private static func countNonEmptyLines(in handle: FileHandle, upTo limit: UInt64) throws -> Int {
        guard limit > 0 else { return 0 }
        var offset: UInt64 = 0
        var count = 0
        var inLine = false
        while offset < limit {
            let step = Int(min(UInt64(defaultTailChunkSize), limit - offset))
            let chunk = try readExact(handle: handle, offset: offset, count: step)
            guard !chunk.isEmpty else { break }
            chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for i in 0..<bytes.count {
                    if bytes[i] == 0x0A {
                        if inLine {
                            count += 1
                            inLine = false
                        }
                    } else {
                        inLine = true
                    }
                }
            }
            offset += UInt64(chunk.count)
        }
        if inLine { count += 1 }
        return count
    }

    /// Whether `needle` occurs inside `data`, without copying.
    private static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        guard let head = needle.first, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            let last = bytes.count - needle.count
            while offset <= last {
                if bytes[offset] == head {
                    var matched = 1
                    while matched < needle.count, bytes[offset + matched] == needle[matched] { matched += 1 }
                    if matched == needle.count { return true }
                }
                offset += 1
            }
            return false
        }
    }

    /// Replays entries in file order into a `LoadedSession`. The one place
    /// that says what each entry kind does to the projected context.
    private struct Replay {
        let header: Header
        let tracksDisplay: Bool
        var messages: [Message] = []
        var displayMessages: [Message] = []
        var model: String?
        var provider: String?
        var thinkingLevel: String?
        var title: String?

        init(header: Header, tracksDisplay: Bool) {
            self.header = header
            self.tracksDisplay = tracksDisplay
            self.model = header.model
            self.provider = header.provider
        }

        mutating func apply(_ entry: Entry) {
            switch entry {
            case .message(_, let message):
                messages.append(message)
                if tracksDisplay { displayMessages.append(message) }
            case .meta(_, let m, let p, let t, let ti):
                if let m { model = m }
                if let p { provider = p }
                if let t { thinkingLevel = t }
                if let ti { title = ti }
            case .compaction(_, let compaction):
                if let m = compaction.model { model = m }
                if let p = compaction.provider { provider = p }
                if let t = compaction.thinkingLevel { thinkingLevel = t }
                if let ti = compaction.title { title = ti }
                messages = SessionStore.upgradingLegacyRecapSource(
                    in: compaction.replacementMessages,
                    reason: compaction.reason,
                    trustedRecap: compaction.trustedRecap
                )
                guard tracksDisplay else { return }
                switch compaction.reason {
                case .compact:
                    // Context compaction shrinks the model-facing context
                    // only; the on-screen history is untouched.
                    break
                case .rewind:
                    // Rewind cut the conversation at a prompt: drop the same
                    // tail from the visual history that was cut from the
                    // model context. The kept prefix cannot simply replace
                    // the display — after a compaction it starts with a
                    // summary message the display never contained.
                    displayMessages = Array(
                        displayMessages.dropLast(compaction.messagesCompacted))
                case nil:
                    // Legacy entries predate the reason split and truncated
                    // both the model and the display context.
                    displayMessages = compaction.replacementMessages
                }
            }
        }

        var loaded: LoadedSession {
            LoadedSession(
                header: header,
                messages: messages,
                displayMessages: tracksDisplay ? displayMessages : messages,
                persistedContextCount: messages.count,
                model: model,
                provider: provider,
                thinkingLevel: thinkingLevel,
                title: title
            )
        }
    }

    private static func upgradingLegacyRecapSource(
        in replacementMessages: [Message],
        reason: CompactionReason?,
        trustedRecap: Bool?
    ) -> [Message] {
        // Fail closed for pre-reason markers: they may have represented a
        // rewind of a recap-shaped user prompt. A typed compact marker is
        // authoritative; a rewind must carry the explicit trust bit.
        let markerEstablishesTrust = reason == .compact || trustedRecap == true
        guard markerEstablishesTrust,
              let first = replacementMessages.first,
              case .user(var user) = first,
              user.source == nil,
              CompactionPlanner.isLegacyRecapEnvelope(first) else {
            return replacementMessages
        }

        user.source = .compaction
        var upgraded = replacementMessages
        upgraded[0] = .user(user)
        return upgraded
    }

    /// `.compaction` is an in-memory trust marker introduced after session
    /// schema v1 shipped. Persisting the enum case would make that otherwise
    /// compatible file undecodable by older binaries. The typed compaction
    /// entry restores the marker on load.
    private static func removingInternalMessageSource(_ message: Message) -> Message {
        guard case .user(var user) = message, user.source == .compaction else {
            return message
        }
        user.source = nil
        return .user(user)
    }

    private func parseHeader(_ line: String, path: String) throws -> Header {
        guard let data = line.data(using: .utf8),
              let header = try? Self.decoder.decode(Header.self, from: data) else {
            throw SessionStoreError.invalidHeader(path)
        }
        guard header.type == "session" else {
            throw SessionStoreError.invalidHeader(path)
        }
        guard header.version == Self.version else {
            throw SessionStoreError.unsupportedVersion(found: header.version, expected: Self.version)
        }
        return header
    }

    // MARK: - Listing

    /// All sessions on disk, newest activity first. Unreadable / malformed
    /// files are skipped rather than aborting the listing.
    public func list() -> [SessionInfo] {
        guard isPersistent else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var infos: [SessionInfo] = []
        for url in entries where url.pathExtension == "jsonl" {
            guard let info = try? info(at: url) else { continue }
            infos.append(info)
        }
        // Sort by updatedAt (mtime) descending. Filesystem mtime resolution
        // can tie two sessions written in the same tick, so break ties with
        // createdAt (millisecond, set at header creation) to keep ordering
        // deterministic — otherwise "most recent for cwd" is non-deterministic.
        infos.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.createdAt > $1.createdAt
        }
        return infos
    }

    private func info(at url: URL) throws -> SessionInfo {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw SessionStoreError.notFound(url.lastPathComponent)
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else {
            throw SessionStoreError.missingHeader(url.path)
        }
        let header = try parseHeader(String(first), path: url.path)

        var model = header.model
        var provider = header.provider
        var title: String?
        var messageCount = 0
        for line in lines.dropFirst() {
            // Listing only needs a message count plus the latest meta values, so
            // never JSON-decode the message bodies (full transcripts, embedded
            // base64 images) — that is what made `--continue` startup pay for
            // the entire on-disk history. The encoder writes `.sortedKeys`, so a
            // transcript-message entry is always `{"message":{…`; classify by
            // that prefix and skip the decode. Only the small/rare `meta` lines
            // are decoded (compaction markers are irrelevant to listing).
            if line.hasPrefix("{\"message\":") {
                messageCount += 1
                continue
            }
            guard line.contains("\"type\":\"meta\""),
                  let data = String(line).data(using: .utf8),
                  case .meta(_, let m, let p, _, let ti)? =
                    try? Self.decoder.decode(Entry.self, from: data) else { continue }
            if let m { model = m }
            if let p { provider = p }
            if let ti { title = ti }
        }

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let updatedAt = mtime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? header.createdAt

        return SessionInfo(
            id: header.id,
            cwd: header.cwd,
            createdAt: header.createdAt,
            model: model,
            provider: provider,
            updatedAt: updatedAt,
            messageCount: messageCount,
            title: title,
            path: url
        )
    }

    /// Most recently active session whose header `cwd` matches `cwd`, or nil
    /// if none exist. Backs the `--resume` / `--continue` CLI flags.
    public func latestForCwd(_ cwd: String) -> SessionInfo? {
        let target = Self.normalize(cwd)
        return list().first { Self.normalize($0.cwd) == target }
    }

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
