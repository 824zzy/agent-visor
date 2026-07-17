//
//  ConversationParser.swift
//  AgentVisor
//
//  Parses Claude JSONL conversation files to extract summary and last message
//  Optimized for incremental parsing - only reads new lines since last sync
//

import Foundation
import os.log
import AgentVisorCore

struct ConversationInfo: Equatable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String?  // "user", "assistant", or "tool"
    let lastToolName: String?  // Tool name if lastMessageRole is "tool"
    let firstUserMessage: String?  // Fallback title when no summary
    let lastUserMessageDate: Date?  // Timestamp of last user message (for stable sorting)
    /// Timestamp of the last real message of any role (user/assistant).
    /// Drives the idle/waitingForInput status-color fade. We can't use the
    /// JSONL file mtime for this: GUI-spawned sessions (Claude Desktop, Zed)
    /// keep the file alive with non-conversational rows (`permission-mode`,
    /// `mode`, summaries), so mtime reads "fresh" long after the last turn
    /// and the status stripe stays green on a conversationally-stale session.
    let lastActivityDate: Date?
    let lastCwd: String?  // Most recent working directory from JSONL messages
    /// User-set thread title from Zed's `{"type":"custom-title",...}`
    /// auxiliary rows. Nil for plain Claude CLI sessions; non-nil only
    /// when the agent ran inside Zed (`claude-acp`). See
    /// [[ClaudeCustomTitleExtractor]].
    let customTitle: String?

    // Lightweight metadata extracted from the tail — allows bootstrap to
    // populate session chips without a full incremental parse.
    let lastModelName: String?
    let lastContextTokens: Int?
    let lastContextWindowTokens: Int?
    let lastEffortLevel: String?
    let lastPermissionMode: String?
    let lastCodexApprovalPolicy: String?
    let lastCodexSandboxPolicyType: String?

    nonisolated init(
        summary: String?,
        lastMessage: String?,
        lastMessageRole: String?,
        lastToolName: String?,
        firstUserMessage: String?,
        lastUserMessageDate: Date?,
        lastActivityDate: Date? = nil,
        lastCwd: String?,
        customTitle: String? = nil,
        lastModelName: String?,
        lastContextTokens: Int?,
        lastContextWindowTokens: Int? = nil,
        lastEffortLevel: String? = nil,
        lastPermissionMode: String?,
        lastCodexApprovalPolicy: String? = nil,
        lastCodexSandboxPolicyType: String? = nil
    ) {
        self.summary = summary
        self.lastMessage = lastMessage
        self.lastMessageRole = lastMessageRole
        self.lastToolName = lastToolName
        self.firstUserMessage = firstUserMessage
        self.lastUserMessageDate = lastUserMessageDate
        self.lastActivityDate = lastActivityDate
        self.lastCwd = lastCwd
        self.customTitle = customTitle
        self.lastModelName = lastModelName
        self.lastContextTokens = lastContextTokens
        self.lastContextWindowTokens = lastContextWindowTokens
        self.lastEffortLevel = lastEffortLevel
        self.lastPermissionMode = lastPermissionMode
        self.lastCodexApprovalPolicy = lastCodexApprovalPolicy
        self.lastCodexSandboxPolicyType = lastCodexSandboxPolicyType
    }
}

actor ConversationParser {
    static let shared = ConversationParser()

    /// Logger for conversation parser (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "Parser")

    private var incrementalState: [String: IncrementalParseState] = [:]

    /// State for incremental JSONL parsing
    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var seenToolIds: Set<String> = []
        var toolIdToName: [String: String] = [:]  // Map tool_use_id to tool name
        var completedToolIds: Set<String> = []  // Tools that have received results
        var toolResults: [String: ToolResult] = [:]  // Tool results keyed by tool_use_id
        var structuredResults: [String: ToolResultData] = [:]  // Structured results keyed by tool_use_id
        var lastClearOffset: UInt64 = 0  // Offset of last /clear command (0 = none or at start)
        var clearPending: Bool = false  // True if a /clear was just detected
        var pendingCompact: PendingCompactBoundary?  // Buffered compact_boundary awaiting summary
        var currentMode: String?  // Latest permissionMode value seen in JSONL
        /// Flat (uuid, parentUuid, type) list of every parsed JSONL
        /// row. Populated for a future render-time filter that hides
        /// canceled user turns (see `CanceledUserTurnDetector` and
        /// the tests). Currently UNUSED at consumer side — see the
        /// large comment near the bottom of `parseNewLines` for the
        /// freeze that disabled the filter.
        var jsonlRows: [JSONLRow] = []
    }

    /// Compact boundary metadata held between the system entry and the
    /// adjacent isCompactSummary user entry that carries the summary text.
    private struct PendingCompactBoundary {
        let uuid: String
        let timestamp: Date
        let preTokens: Int?
        let trigger: String?
    }

    /// Parsed tool result data
    struct ToolResult: Codable {
        let content: String?
        let stdout: String?
        let stderr: String?
        let isError: Bool
        let isInterrupted: Bool

        init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
            self.content = content
            self.stdout = stdout
            self.stderr = stderr
            self.isError = isError
            // Detect if this was an interrupt or rejection (various formats)
            self.isInterrupted = isError && (
                content?.contains("Interrupted by user") == true ||
                content?.contains("interrupted by user") == true ||
                content?.contains("user doesn't want to proceed") == true
            )
        }
    }

    // MARK: - Full Conversation Parsing

    /// Parse full conversation history for chat view. Uses a disk cache so
    /// re-opening the same session in a later app launch skips the full
    /// JSONL parse: hits the cache for messages parsed before, then parses
    /// only the bytes appended since the cache was written. For huge
    /// sessions (100+ MB) this turns multi-second loads into ~50ms.

    /// Cache file size above which we don't even *try* to load the cache.
    /// Decoding a 43 MB ParsedHistoryCache through JSONDecoder takes
    /// seconds; treating it as missing forces the bypass path to rebuild
    /// from the last `compact_boundary` and overwrite the bloated cache
    /// with a small one. Once the codebase has shipped pruning, no new
    /// cache should ever exceed this — the threshold is a one-time
    /// migration safety net for legacy caches written before pruning.
    private static let legacyHugeCacheBytes: UInt64 = 10 * 1024 * 1024

    func parseFullConversation(sessionId: String, cwd: String) -> [ChatMessage] {
        let started = Date()
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return []
        }

        var state = IncrementalParseState()
        var cacheHit = false
        var deltaBytes: UInt64 = 0
        var totalBytes: UInt64 = 0
        var loadCacheMs = 0
        var parseDeltaMs = 0

        let cachePath = Self.cacheFile(sessionId: sessionId)
        let cacheFileSize: UInt64 = (try? FileManager.default.attributesOfItem(atPath: cachePath)[.size] as? UInt64) ?? 0
        let jsonlSize: UInt64 = (try? FileManager.default.attributesOfItem(atPath: sessionFile)[.size] as? UInt64) ?? 0

        // Load the cache up front so the bypass decision can compare the
        // cache's claimed jsonlBytesParsed against the live JSONL size.
        // For small caches this costs a few ms; for pathologically large
        // ones we skip the load entirely and treat the cache as missing,
        // which makes the bypass path rebuild it as a small cache.
        let cached: ParsedHistoryCache?
        if cacheFileSize > Self.legacyHugeCacheBytes {
            cached = nil
        } else {
            let loadCacheStart = Date()
            cached = loadCache(sessionId: sessionId)
            loadCacheMs = Int(Date().timeIntervalSince(loadCacheStart) * 1000)
        }

        // The bypass policy looks at jsonl size and the cache's
        // jsonlBytesParsed (nil if cache is missing/legacy/wrong-schema)
        // and decides whether to skip the cache and seek straight to the
        // last compact_boundary. The two cases it catches:
        //   - cold cache + huge JSONL (first open of a 458 MB session,
        //     or cache was deleted)
        //   - warm cache + huge offline delta (app was closed while the
        //     JSONL grew by 100+ MB)
        // Both have the same root cause — work to do is large — and
        // the same fix — parse only the post-boundary tail.
        let cachedJsonlBytes: UInt64? = {
            guard let c = cached, c.schemaVersion == Self.cacheSchemaVersion else { return nil }
            return c.jsonlBytesParsed
        }()
        if ConversationCacheBypassPolicy.shouldBypassCache(
            jsonlSize: jsonlSize,
            cachedJsonlBytes: cachedJsonlBytes,
            thresholdBytes: Self.pruneThresholdBytes
        ), let boundaryOffset = CompactBoundaryLocator.findLastBoundaryOffset(at: sessionFile, fileSize: jsonlSize) {
            totalBytes = jsonlSize
            deltaBytes = jsonlSize - boundaryOffset
            state.lastFileOffset = boundaryOffset
            let parseStart = Date()
            _ = parseNewLines(filePath: sessionFile, state: &state)
            parseDeltaMs = Int(Date().timeIntervalSince(parseStart) * 1000)

            let prePruneCount = state.messages.count
            let pruned = pruneToLastCompactBoundary(state: &state, totalBytes: totalBytes)
            if pruned {
                Self.logger.info("prune pre-compact \(sessionId.prefix(8), privacy: .public) before=\(prePruneCount) after=\(state.messages.count)")
            }
            incrementalState[sessionId] = state
            let saveCacheStart = Date()
            saveCache(sessionId: sessionId, sessionFile: sessionFile, state: state)
            let saveCacheMs = Int(Date().timeIntervalSince(saveCacheStart) * 1000)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            Self.logger.info("parseFullConversation \(sessionId.prefix(8), privacy: .public) cache=BYPASS jsonl=\(jsonlSize) boundary=\(boundaryOffset) loadCache=\(loadCacheMs)ms parseDelta=\(parseDeltaMs)ms saveCache=\(saveCacheMs)ms total=\(elapsedMs)ms")
            return state.messages
        }

        // Regular path: use the already-loaded cache when valid. Two
        // valid outcomes: cache covers entire file (skip parsing), or
        // cache covers a prefix (parse the rest). Any other state
        // (file shrank below cache, mtime moved backwards, schema
        // mismatch, decode failure) falls through to a full parse from
        // offset 0.
        if let cached = cached,
           cached.schemaVersion == Self.cacheSchemaVersion,
           let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFile),
           let fileSize = (attrs[.size] as? UInt64),
           fileSize >= cached.jsonlBytesParsed {
            cacheHit = true
            totalBytes = fileSize
            deltaBytes = fileSize - cached.jsonlBytesParsed
            state.lastFileOffset = cached.lastFileOffset
            state.lastClearOffset = cached.lastClearOffset
            // Strip synthetic-model assistant messages persisted by older
            // builds. parseMessageLine now drops these on the fresh path,
            // but caches written before that fix still carry them and
            // would resurface "No response requested." on relaunch. See
            // `synthetic_model_poisons_state`.
            state.messages = cached.messages.filter { msg in
                !SyntheticAssistantFilter.shouldDrop(role: msg.role.rawValue, model: msg.model)
            }
            state.seenToolIds = cached.seenToolIds
            state.toolIdToName = cached.toolIdToName
            state.completedToolIds = cached.completedToolIds
            state.toolResults = cached.toolResults
            state.structuredResults = cached.structuredResults
            state.currentMode = cached.currentMode
            // If file grew beyond the cached bytes, parse the delta.
            if fileSize > cached.jsonlBytesParsed {
                let parseStart = Date()
                _ = parseNewLines(filePath: sessionFile, state: &state)
                parseDeltaMs = Int(Date().timeIntervalSince(parseStart) * 1000)
            }
        } else {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFile),
               let fileSize = attrs[.size] as? UInt64 {
                totalBytes = fileSize
                deltaBytes = fileSize
            }
            let parseStart = Date()
            _ = parseNewLines(filePath: sessionFile, state: &state)
            parseDeltaMs = Int(Date().timeIntervalSince(parseStart) * 1000)
        }

        // Phase 2b: prune pre-compact-boundary content for large sessions.
        // The chat panel only renders the post-compact view (claude-code's
        // TUI does the same — pre-compact turns collapse into the single
        // boundary divider). Dropping them here shrinks state.messages,
        // which in turn shrinks the on-disk cache the next time it gets
        // saved, breaking the slow-cache cycle on huge sessions.
        let prePruneCount = state.messages.count
        let pruned = pruneToLastCompactBoundary(state: &state, totalBytes: totalBytes)
        if pruned {
            Self.logger.info("prune pre-compact \(sessionId.prefix(8), privacy: .public) before=\(prePruneCount) after=\(state.messages.count)")
        }

        incrementalState[sessionId] = state

        // Skip the encode+write entirely when the cache already covers the
        // current file AND we didn't prune anything. For a 333 MB session
        // with a 43 MB cache, the skip-when-unchanged condition alone saves
        // multi-second JSONEncoder cost on every panel open of a stable
        // session. When prune fires, we WANT the save so the next open
        // gets a small cache.
        var saveCacheMs = 0
        let shouldSkipSave = cacheHit && deltaBytes == 0 && !pruned
        if !shouldSkipSave {
            let saveCacheStart = Date()
            saveCache(sessionId: sessionId, sessionFile: sessionFile, state: state)
            saveCacheMs = Int(Date().timeIntervalSince(saveCacheStart) * 1000)
        }

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let saveStatus = shouldSkipSave ? "SKIP" : "\(saveCacheMs)ms"
        Self.logger.info("parseFullConversation \(sessionId.prefix(8), privacy: .public) cache=\(cacheHit ? "HIT" : "MISS", privacy: .public) total=\(totalBytes) delta=\(deltaBytes) loadCache=\(loadCacheMs)ms parseDelta=\(parseDeltaMs)ms saveCache=\(saveStatus, privacy: .public) pruned=\(pruned ? "yes" : "no", privacy: .public) total=\(elapsedMs)ms")

        return state.messages
    }

    /// Sessions smaller than this are not pruned. Pre-compact content in a
    /// small session is cheap to keep around. Matches claude-code-main's
    /// SKIP_PRECOMPACT_THRESHOLD constant.
    private static let pruneThresholdBytes: UInt64 = 5 * 1024 * 1024

    /// If the parsed state contains a compact_boundary message and the
    /// file is large enough to warrant it, drop everything before the
    /// LAST boundary from `state.messages` and prune the tool tracking
    /// maps to only IDs referenced by the kept messages. Returns true if
    /// anything was dropped.
    private func pruneToLastCompactBoundary(state: inout IncrementalParseState, totalBytes: UInt64) -> Bool {
        guard totalBytes > Self.pruneThresholdBytes else { return false }

        guard let lastBoundaryIdx = state.messages.lastIndex(where: { msg in
            msg.content.contains { block in
                if case .compactBoundary = block { return true }
                return false
            }
        }), lastBoundaryIdx > 0 else {
            return false
        }

        state.messages = Array(state.messages[lastBoundaryIdx...])

        // Tool maps may carry pre-boundary ids we no longer need.
        var keptToolIds = Set<String>()
        for msg in state.messages {
            for block in msg.content {
                if case .toolUse(let t) = block { keptToolIds.insert(t.id) }
            }
        }
        state.seenToolIds.formIntersection(keptToolIds)
        state.completedToolIds.formIntersection(keptToolIds)
        state.toolIdToName = state.toolIdToName.filter { keptToolIds.contains($0.key) }
        state.toolResults = state.toolResults.filter { keptToolIds.contains($0.key) }
        state.structuredResults = state.structuredResults.filter { keptToolIds.contains($0.key) }
        return true
    }

    // MARK: - Disk Cache

    /// Bumped when the cache's stored shape changes incompatibly. Reading
    /// a cache with a different version forces a full re-parse.
    private static let cacheSchemaVersion = 1

    /// Snapshot of an incremental parse, persisted to disk.
    private struct ParsedHistoryCache: Codable {
        let schemaVersion: Int
        let jsonlBytesParsed: UInt64
        let jsonlMtime: Date
        let lastFileOffset: UInt64
        let lastClearOffset: UInt64
        let messages: [ChatMessage]
        let seenToolIds: Set<String>
        let toolIdToName: [String: String]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let currentMode: String?
    }

    private static func cacheDirectory() -> String {
        AppPaths.appSupportDirectory().appendingPathComponent("cache").path
    }

    private static func cacheFile(sessionId: String) -> String {
        cacheDirectory() + "/" + sessionId + ".json"
    }

    private func loadCache(sessionId: String) -> ParsedHistoryCache? {
        let path = Self.cacheFile(sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ParsedHistoryCache.self, from: data)
    }

    /// Serial background queue for the encode+write step. Encoding a 43 MB
    /// ParsedHistoryCache through JSONEncoder takes seconds; keeping it on
    /// the actor blocked every other parser call. Writes are naturally
    /// serialized — only the latest snapshot for any given session matters,
    /// so we don't need per-session queues.
    nonisolated static let cacheWriteQueue = DispatchQueue(
        label: AppBranding.loggerSubsystem + ".cache-write",
        qos: .utility
    )

    private func saveCache(sessionId: String, sessionFile: String, state: IncrementalParseState) {
        // Build the snapshot synchronously inside the actor — value types
        // copied here are safe to ship to a background queue.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFile),
              let fileSize = (attrs[.size] as? UInt64),
              let mtime = attrs[.modificationDate] as? Date else {
            return
        }
        let cache = ParsedHistoryCache(
            schemaVersion: Self.cacheSchemaVersion,
            jsonlBytesParsed: fileSize,
            jsonlMtime: mtime,
            lastFileOffset: state.lastFileOffset,
            lastClearOffset: state.lastClearOffset,
            messages: state.messages,
            seenToolIds: state.seenToolIds,
            toolIdToName: state.toolIdToName,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            currentMode: state.currentMode
        )

        Self.cacheWriteQueue.async {
            Self.encodeAndWriteCache(sessionId: sessionId, cache: cache)
        }
    }

    /// nonisolated so it can run on the background queue. Pure function over
    /// its arguments — no actor state access. The cache value is a Sendable
    /// snapshot built on the actor before dispatch.
    nonisolated private static func encodeAndWriteCache(sessionId: String, cache: ParsedHistoryCache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        let dir = cacheDirectory()
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let finalPath = cacheFile(sessionId: sessionId)
        let tempPath = finalPath + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tempPath))
        _ = try? FileManager.default.replaceItemAt(
            URL(fileURLWithPath: finalPath),
            withItemAt: URL(fileURLWithPath: tempPath)
        )
        logger.debug("cache write complete \(sessionId.prefix(8), privacy: .public) bytes=\(data.count)")
    }

    /// Result of incremental parsing
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
    }

    /// Parse only NEW messages since last call (efficient incremental updates).
    ///
    /// When called for a session whose `incrementalState` hasn't been
    /// initialized (e.g. file watcher fires before the chat panel has
    /// ever been opened), returns an empty result instead of parsing
    /// from offset 0. Without this guard, the watcher's debounced sync
    /// would do a full multi-hundred-MB scan at launch — and queue
    /// ahead of `parseFullConversation` when the user does click the
    /// pill, which is exactly the contention we observed turning a
    /// 67ms parse into a 24s wait. The chat panel doesn't need
    /// pre-warmed state from a session that's never been opened, and
    /// when it does open, `parseFullConversation` lazily seeds the
    /// state via the cache-bypass path.
    func parseIncremental(sessionId: String, cwd: String) -> IncrementalParseResult {
        let started = Date()
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false
            )
        }

        // No prior state for this session: skip. The chat panel
        // populates state lazily; the watcher tick that next fires
        // after the chat panel opens will pick up new lines as a
        // proper incremental delta.
        guard var state = incrementalState[sessionId] else {
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false
            )
        }

        let prevOffset = state.lastFileOffset
        let newMessages = parseNewLines(filePath: sessionFile, state: &state)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        if elapsedMs > 100 {
            Self.logger.info("parseIncremental \(sessionId.prefix(8), privacy: .public) prevOffset=\(prevOffset) newOffset=\(state.lastFileOffset) deltaBytes=\(state.lastFileOffset - prevOffset) newMsgs=\(newMessages.count) elapsed=\(elapsedMs)ms")
        }
        let clearDetected = state.clearPending
        if clearDetected {
            state.clearPending = false
        }
        incrementalState[sessionId] = state

        return IncrementalParseResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: clearDetected
        )
    }

    /// Marker byte sequences for the line-level prefilter. Precomputed so
    /// the hot loop on multi-MB deltas doesn't reallocate them per line.
    private static let clearMarkerBytes = Data("<command-name>/clear</command-name>".utf8)
    private static let toolResultMarkerBytes = Data("\"tool_result\"".utf8)
    private static let permissionModeMarkerBytes = Data("\"type\":\"permission-mode\"".utf8)
    private static let systemTypeMarkerBytes = Data("\"type\":\"system\"".utf8)
    private static let userTypeMarkerBytes = Data("\"type\":\"user\"".utf8)
    private static let assistantTypeMarkerBytes = Data("\"type\":\"assistant\"".utf8)

    /// Parse only new lines since last read (incremental).
    ///
    /// Hot path on 100+ MB transcripts. Uses byte-level `JSONLLineIterator`
    /// over the raw `Data` instead of materializing the whole delta as a
    /// `String` and splitting on `\n` — the old path allocated 3x the
    /// delta size before any JSON work started.
    private func parseNewLines(filePath: String, state: inout IncrementalParseState) -> [ChatMessage] {
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        } catch {
            // Sequoia silent-deny on provenance-tagged JSONLs surfaces here as
            // NSCocoaErrorDomain / code 257. Route to the FDA checker so the user
            // gets a one-time prompt; otherwise the notch stays mysteriously empty.
            Task { @MainActor in
                FullDiskAccessChecker.reportOpenFailure(error: error, path: filePath)
            }
            return []
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return []
        }

        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            return state.messages
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return state.messages
        }

        guard let newData = try? fileHandle.readToEnd() else {
            return state.messages
        }

        // Trim a trailing partial line (no terminating LF) before
        // iterating. Without this, kqueue's `.extend` event can fire
        // mid-flush and the iterator hands the truncated tail to the
        // JSON parser. The truncated line silently fails to parse,
        // but `state.lastFileOffset` still advances to `fileSize`
        // below — so when the rest of the line lands, it's permanently
        // below the offset and never reread. The dropped row is
        // typically the most recent assistant message, which is why
        // chat sometimes goes silent until a downstream full-reparse
        // (e.g. session switch) recovers it.
        //
        // Compute the byte after the last LF in `newData`. Anything
        // past that is the partial tail; we leave those bytes for the
        // next tick by advancing lastFileOffset only that far.
        let lastLF = newData.lastIndex(of: 0x0A)
        let completeData: Data
        let consumedBytes: UInt64
        if let lastLF {
            // distance from start to (lastLF + 1) is the count of
            // bytes that end on a complete line (LF inclusive).
            let lineEnd = newData.index(after: lastLF)
            completeData = newData[..<lineEnd]
            consumedBytes = UInt64(newData.distance(from: newData.startIndex, to: lineEnd))
        } else {
            // No LF at all — entire delta is a partial line. Don't
            // consume anything; wait for the rest.
            completeData = Data()
            consumedBytes = 0
        }

        state.clearPending = false
        let isIncrementalRead = state.lastFileOffset > 0
        var newMessages: [ChatMessage] = []

        for lineBytes in JSONLLineIterator(data: completeData) {
            // Byte-level prefilter — every check is O(N) without UTF-8
            // decode. Only the lines that hit a marker are converted into
            // a parsed JSON object.
            if lineBytes.range(of: Self.clearMarkerBytes) != nil &&
               Self.isRealUserClearCommand(lineBytes: lineBytes) {
                state.messages = []
                state.seenToolIds = []
                state.toolIdToName = [:]
                state.completedToolIds = []
                state.toolResults = [:]
                state.structuredResults = [:]
                // The local `newMessages` accumulator is what gets returned
                // to the caller as `IncrementalParseResult.newMessages` and
                // dispatched into SessionStore as `FileUpdatePayload.messages`.
                // Until this reset was added, /clear cleared *state* (the
                // parser's internal bookkeeping including completedToolIds)
                // but left `newMessages` holding all pre-/clear content,
                // so payload.messages contained pre-/clear tool_use blocks
                // whose ids were no longer in payload.completedToolIds —
                // and `SessionStore.createChatItem` then marked them
                // `.running`. On a fresh post-restart parse from offset 0,
                // that produced phantom-pending tool items in the chat
                // for every AskUserQuestion answered before the last
                // /clear. Detection: `[DEBUG-bugA]` log line in
                // SessionStore's processFileUpdate (now removed).
                newMessages = []
                state.pendingCompact = nil

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = state.lastFileOffset
                    Self.logger.debug("/clear detected (new), will notify UI")
                }
                continue
            }

            if lineBytes.range(of: Self.toolResultMarkerBytes) != nil {
                if let json = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any],
                   let messageDict = json["message"] as? [String: Any],
                   let contentArray = messageDict["content"] as? [[String: Any]] {
                    // Record this row in the cancel-detection graph
                    // as a tool_result so its parent user turn (the
                    // tool-result message wraps tool-use blocks
                    // submitted to Claude) gets credit for being
                    // productive. The line's top-level type is
                    // "user" but the productive payload is the tool
                    // result — record under the productive type so
                    // the detector's productivity walk sees it.
                    if let uuid = json["uuid"] as? String {
                        state.jsonlRows.append(JSONLRow(
                            uuid: uuid,
                            parentUuid: json["parentUuid"] as? String,
                            type: "tool_result"
                        ))
                    }
                    let toolUseResult = json["toolUseResult"] as? [String: Any]
                    let topLevelToolName = json["toolName"] as? String
                    let stdout = toolUseResult?["stdout"] as? String
                    let stderr = toolUseResult?["stderr"] as? String

                    for block in contentArray {
                        if block["type"] as? String == "tool_result",
                           let toolUseId = block["tool_use_id"] as? String {
                            state.completedToolIds.insert(toolUseId)

                            let content = block["content"] as? String
                            let isError = block["is_error"] as? Bool ?? false
                            state.toolResults[toolUseId] = ToolResult(
                                content: content,
                                stdout: stdout,
                                stderr: stderr,
                                isError: isError
                            )

                            let toolName = topLevelToolName ?? state.toolIdToName[toolUseId]

                            if let toolUseResult = toolUseResult,
                               let name = toolName {
                                let structured = Self.parseStructuredResult(
                                    toolName: name,
                                    toolUseResult: toolUseResult,
                                    isError: isError
                                )
                                state.structuredResults[toolUseId] = structured
                            }
                        }
                    }
                }
            } else if lineBytes.range(of: Self.permissionModeMarkerBytes) != nil {
                // Side-channel mode marker. Not a renderable message — just
                // tracks the latest mode for the status bar / cycler UI.
                if let json = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any],
                   let mode = json["permissionMode"] as? String {
                    state.currentMode = mode
                }
            } else if lineBytes.range(of: Self.systemTypeMarkerBytes) != nil {
                if let json = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any],
                   let subtype = json["subtype"] as? String {
                    let uuid = json["uuid"] as? String ?? UUID().uuidString
                    let timestamp: Date
                    if let ts = json["timestamp"] as? String {
                        let fmt = ISO8601DateFormatter()
                        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        timestamp = fmt.date(from: ts) ?? Date()
                    } else {
                        timestamp = Date()
                    }

                    if subtype == "turn_duration", let durationMs = json["durationMs"] as? Int {
                        flushPendingCompact(state: &state, into: &newMessages)
                        let msg = ChatMessage(
                            id: uuid,
                            role: .system,
                            timestamp: timestamp,
                            content: [.turnDuration(durationMs: durationMs)]
                        )
                        newMessages.append(msg)
                        state.messages.append(msg)
                    } else if subtype == "away_summary", let content = json["content"] as? String {
                        flushPendingCompact(state: &state, into: &newMessages)
                        let msg = ChatMessage(
                            id: uuid,
                            role: .system,
                            timestamp: timestamp,
                            content: [.recap(content)]
                        )
                        newMessages.append(msg)
                        state.messages.append(msg)
                    } else if subtype == "compact_boundary" {
                        // Buffer the boundary; the next isCompactSummary user
                        // line carries the actual summary text.
                        flushPendingCompact(state: &state, into: &newMessages)
                        let metadata = json["compactMetadata"] as? [String: Any]
                        state.pendingCompact = PendingCompactBoundary(
                            uuid: uuid,
                            timestamp: timestamp,
                            preTokens: metadata?["preTokens"] as? Int,
                            trigger: metadata?["trigger"] as? String
                        )
                    } else if subtype == "local_command", let raw = json["content"] as? String {
                        // Output of a TUI built-in like /reload-plugins or
                        // /rename. claude-code wraps the body in
                        // <local-command-stdout>…</local-command-stdout> (or
                        // …-stderr). Strip the wrapper and skip empty bodies
                        // (`/clear` echoes an empty stdout that adds no signal).
                        let body = Self.unwrapLocalCommandContent(raw)
                        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        flushPendingCompact(state: &state, into: &newMessages)
                        let msg = ChatMessage(
                            id: uuid,
                            role: .system,
                            timestamp: timestamp,
                            content: [.localCommandOutput(trimmed)]
                        )
                        newMessages.append(msg)
                        state.messages.append(msg)
                    }
                }
            } else if lineBytes.range(of: Self.userTypeMarkerBytes) != nil ||
                      lineBytes.range(of: Self.assistantTypeMarkerBytes) != nil {
                if let json = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any] {
                    // Record in the cancel-detection graph BEFORE the
                    // compact-summary short-circuit below — the row
                    // is structurally relevant (it has a uuid and
                    // parentUuid) even when we hide it from the chat.
                    recordRowForCancelDetection(json: json, state: &state)

                    // Synthetic compact-summary user lines carry the post-/compact
                    // context refeed. Attach to the pending boundary instead of
                    // rendering as a user bubble.
                    if json["isCompactSummary"] as? Bool == true {
                        let summary = (json["message"] as? [String: Any])?["content"] as? String
                        emitPendingCompact(state: &state, into: &newMessages, summary: summary)
                        continue
                    }
                    flushPendingCompact(state: &state, into: &newMessages)
                    if let message = parseMessageLine(json, seenToolIds: &state.seenToolIds, toolIdToName: &state.toolIdToName) {
                        newMessages.append(message)
                        state.messages.append(message)
                    }
                }
            }
        }

        // If a boundary is still pending at end-of-stream, emit it without
        // a summary so the divider still appears.
        flushPendingCompact(state: &state, into: &newMessages)

        // Cancel-user-turn filtering is DISABLED for now. Earlier
        // iteration tried to filter canceled user bubbles by removing
        // them from `newMessages` / `state.messages`. That backfired
        // catastrophically: during streaming, a freshly-arrived user
        // line transiently has no productive descendant (assistant
        // hasn't streamed yet), so EVERY user turn was flagged as
        // "canceled" mid-stream and removed. The same removal fired
        // every parse pass at 5-10 Hz, mutating published chatItems
        // and triggering a SwiftUI graph thrash loop — RSS climbed
        // to ~830 MB, SelectionOverlay update path pinned at 99% CPU.
        //
        // Detector + tests are kept. Re-enabling needs a render-time
        // filter (not a destructive parse-time removal) AND a
        // freshness gate so an in-flight user turn isn't classified
        // as canceled until the next user turn lands or N seconds
        // pass with no productive descendant. Out of scope for this
        // session's focused freeze fix.
        _ = state.jsonlRows  // Kept populating for the future filter.

        // Advance only past complete lines. `consumedBytes` is the
        // count of bytes from `state.lastFileOffset` that ended on a
        // newline boundary; bytes past that are a mid-flush tail
        // we'll re-read on the next tick. See the comment at the
        // `lastLF` computation above for the failure mode this guards
        // against.
        state.lastFileOffset += consumedBytes
        return newMessages
    }

    /// Record a parsed JSONL line into the cancel-detection graph.
    /// Called from each branch in `parseNewLines` that has already
    /// JSON-decoded a line for its own reasons; piggybacks on that
    /// decode rather than re-parsing the raw bytes. Skips lines
    /// missing a `uuid` (synthetic markers like `last-prompt`).
    private func recordRowForCancelDetection(json: [String: Any], state: inout IncrementalParseState) {
        guard let uuid = json["uuid"] as? String else { return }
        // Prefer message.role for user/assistant rows, fall back to
        // the top-level `type` for everything else (system, tool_use,
        // attachment, output_style, compact_boundary, etc.). The
        // detector treats user as the "candidate to flag" and
        // assistant/tool_* as "productive" — bookkeeping rows count
        // as neither and are silently included so the parent-uuid
        // walk reaches them naturally.
        let rowType: String
        if let messageDict = json["message"] as? [String: Any],
           let role = messageDict["role"] as? String,
           role == "user" || role == "assistant" {
            rowType = role
        } else if let topType = json["type"] as? String {
            rowType = topType
        } else {
            return  // Nothing usable — skip.
        }
        state.jsonlRows.append(JSONLRow(
            uuid: uuid,
            parentUuid: json["parentUuid"] as? String,
            type: rowType
        ))
    }

    private func flushPendingCompact(state: inout IncrementalParseState, into newMessages: inout [ChatMessage]) {
        guard state.pendingCompact != nil else { return }
        emitPendingCompact(state: &state, into: &newMessages, summary: nil)
    }

    private func emitPendingCompact(state: inout IncrementalParseState, into newMessages: inout [ChatMessage], summary: String?) {
        guard let pending = state.pendingCompact else { return }
        state.pendingCompact = nil
        let msg = ChatMessage(
            id: pending.uuid,
            role: .system,
            timestamp: pending.timestamp,
            content: [.compactBoundary(summary: summary, preTokens: pending.preTokens, trigger: pending.trigger)]
        )
        newMessages.append(msg)
        state.messages.append(msg)
    }

    /// Get set of completed tool IDs for a session
    func completedToolIds(for sessionId: String) -> Set<String> {
        return incrementalState[sessionId]?.completedToolIds ?? []
    }

    /// Get tool results for a session
    func toolResults(for sessionId: String) -> [String: ToolResult] {
        return incrementalState[sessionId]?.toolResults ?? [:]
    }

    /// Get structured tool results for a session
    func structuredResults(for sessionId: String) -> [String: ToolResultData] {
        return incrementalState[sessionId]?.structuredResults ?? [:]
    }

    /// Get the latest Claude Code permission mode seen in JSONL.
    /// Returns nil for sessions where no `permission-mode` line has been
    /// observed yet.
    func currentPermissionMode(for sessionId: String) -> String? {
        return incrementalState[sessionId]?.currentMode
    }

    /// Reset incremental state for a session (call when reloading)
    func resetState(for sessionId: String) {
        incrementalState.removeValue(forKey: sessionId)
    }

    /// Check if a /clear command was detected during the last parse
    /// Returns true once and consumes the pending flag
    func checkAndConsumeClearDetected(for sessionId: String) -> Bool {
        guard var state = incrementalState[sessionId], state.clearPending else {
            return false
        }
        state.clearPending = false
        incrementalState[sessionId] = state
        return true
    }

    /// Convert a CWD to the project directory name that Claude Code uses
    /// under ~/.claude/projects/. Delegates to the Core helper so the
    /// rule lives in one tested place.
    static func projectDirName(from cwd: String) -> String {
        ClaudeProjectPathEncoder.projectDirName(forCwd: cwd)
    }

    /// True only when `line` is the real synthetic user `/clear`
    /// command — a user-role message whose `content` is the string
    /// `<command-name>/clear</command-name>` (or a string that starts
    /// with `<command-name>` and contains `/clear`). False when the
    /// substring merely appears inside a tool_use's input fields or a
    /// tool_result's content — common when the assistant edits parser
    /// code that itself looks for this marker, which would otherwise
    /// trigger phantom /clears and wipe the chat. Cheap when the
    /// substring isn't present; the caller pre-filters on `contains`.
    private static func isRealUserClearCommand(lineBytes: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any] else {
            return false
        }
        guard (json["type"] as? String) == "user",
              let messageDict = json["message"] as? [String: Any],
              let content = messageDict["content"] as? String else {
            // Real /clear commands carry the marker as a plain string
            // content. tool_use/tool_result lines have content as an
            // array, so we reject those even if the substring appears
            // somewhere in their serialized form.
            return false
        }
        return content.contains("<command-name>/clear</command-name>")
    }

    /// Strip the <local-command-stdout>…</local-command-stdout> (or -stderr)
    /// wrapper that claude-code adds around TUI-builtin output. Falls back
    /// to the raw string if the open tag isn't found, so any future shape
    /// shift still renders something instead of silently dropping the line.
    static func unwrapLocalCommandContent(_ raw: String) -> String {
        for tag in ["local-command-stdout", "local-command-stderr"] {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            if let openRange = raw.range(of: open) {
                let afterOpen = openRange.upperBound
                if let closeRange = raw.range(of: close, range: afterOpen..<raw.endIndex) {
                    return String(raw[afterOpen..<closeRange.lowerBound])
                }
                return String(raw[afterOpen...])
            }
        }
        return raw
    }

    /// Build session file path
    private static func sessionFilePath(sessionId: String, cwd: String) -> String {
        let projectDir = projectDirName(from: cwd)
        return NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
    }

    private func parseMessageLine(_ json: [String: Any], seenToolIds: inout Set<String>, toolIdToName: inout [String: String]) -> ChatMessage? {
        guard let type = json["type"] as? String else {
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        // Synthetic post-/compact context refeed. Boundary handling lives in
        // parseNewLines; never render as a user bubble.
        if json["isCompactSummary"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        guard let recordID = ClaudeTranscriptRecordIdentity.resolve(
            recordUUID: json["uuid"] as? String,
            providerMessageID: messageDict["id"] as? String
        ) else {
            return nil
        }

        if SyntheticAssistantFilter.shouldDrop(role: type, model: messageDict["model"] as? String) {
            return nil
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            if content.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    blocks.append(.text(trimmed))
                }
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            if text.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                // Trim surrounding whitespace/newlines. The
                                // streaming model often emits leading "\n\n"
                                // before its text continuation; rendering them
                                // as blank lines pushes content down and
                                // creates the perceived "empty line" gap
                                // between messages.
                                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                // Drop slash-command plumbing (the
                                // `<command-name>/foo</command-name>...` block
                                // claude-code injects when the user runs
                                // /config, /compact, etc.) and stdout-mirror
                                // blocks (`<local-command-stdout>...`). The
                                // string-content branch above already filters
                                // these — mirror the rule here for the
                                // content-array shape, otherwise raw XML
                                // renders as an ugly user bubble.
                                if trimmed.hasPrefix("<command-name>") ||
                                   trimmed.hasPrefix("<local-command") ||
                                   trimmed.hasPrefix("Caveat:") {
                                    continue
                                }
                                if !trimmed.isEmpty {
                                    blocks.append(.text(trimmed))
                                }
                            }
                        }
                    case "tool_use":
                        if let toolId = block["id"] as? String {
                            if seenToolIds.contains(toolId) {
                                continue
                            }
                            seenToolIds.insert(toolId)
                            if let toolName = block["name"] as? String {
                                toolIdToName[toolId] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String {
                            let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                blocks.append(.thinking(trimmed))
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        var msg = ChatMessage(
            id: recordID,
            role: role,
            timestamp: timestamp,
            content: blocks
        )

        if role == .assistant {
            msg.model = messageDict["model"] as? String
            if let usage = messageDict["usage"] as? [String: Any] {
                msg.inputTokens = usage["input_tokens"] as? Int
                msg.outputTokens = usage["output_tokens"] as? Int
                msg.cacheReadTokens = usage["cache_read_input_tokens"] as? Int
                msg.cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int
            }
        }

        return msg
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                } else if value is [Any] || value is [String: Any] {
                    // Preserve complex values (arrays, nested dicts) as JSON
                    // strings so renderers can reconstruct them on demand.
                    // Without this branch, AskUserQuestion's `questions`
                    // array and similar fields silently disappear from the
                    // chat-history representation of the tool call.
                    if let data = try? JSONSerialization.data(withJSONObject: value),
                       let str = String(data: data, encoding: .utf8) {
                        input[key] = str
                    }
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }

    // MARK: - Structured Result Parsing

    /// Parse tool result JSON into structured ToolResultData
    private static func parseStructuredResult(
        toolName: String,
        toolUseResult: [String: Any],
        isError: Bool
    ) -> ToolResultData {
        // Sessions are claude-code-only until Phase 2 threads the per-session
        // agent id through here. Phase 3 will let auggie/codex parsers reuse
        // the same canonical dispatch with their own result-schema branches.
        let canonical = ToolNameMapper.canonical(for: toolName, agent: .claudeCode)
        switch canonical {
        case .read:
            return parseReadResult(toolUseResult)
        case .edit:
            return parseEditResult(toolUseResult)
        case .write:
            return parseWriteResult(toolUseResult)
        case .bash:
            return parseBashResult(toolUseResult)
        case .grep:
            return parseGrepResult(toolUseResult)
        case .glob:
            return parseGlobResult(toolUseResult)
        case .todoWrite:
            return parseTodoWriteResult(toolUseResult)
        case .task:
            return parseTaskResult(toolUseResult)
        case .webFetch:
            return parseWebFetchResult(toolUseResult)
        case .webSearch:
            return parseWebSearchResult(toolUseResult)
        case .askUserQuestion:
            return parseAskUserQuestionResult(toolUseResult)
        case .bashOutput:
            return parseBashOutputResult(toolUseResult)
        case .killShell:
            return parseKillShellResult(toolUseResult)
        case .exitPlanMode:
            return parseExitPlanModeResult(toolUseResult)
        case .enterPlanMode, .generic:
            let content = toolUseResult["content"] as? String ??
                          toolUseResult["stdout"] as? String ??
                          toolUseResult["result"] as? String
            return .generic(GenericResult(rawContent: content, rawData: toolUseResult))
        case .mcp(let server, let tool):
            return .mcp(MCPResult(
                serverName: server,
                toolName: tool,
                rawResult: toolUseResult
            ))
        }
    }

    // MARK: - Individual Tool Result Parsers

    private static func parseReadResult(_ data: [String: Any]) -> ToolResultData {
        if let fileData = data["file"] as? [String: Any] {
            return .read(ReadResult(
                filePath: fileData["filePath"] as? String ?? "",
                content: fileData["content"] as? String ?? "",
                numLines: fileData["numLines"] as? Int ?? 0,
                startLine: fileData["startLine"] as? Int ?? 1,
                totalLines: fileData["totalLines"] as? Int ?? 0
            ))
        }
        return .read(ReadResult(
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            numLines: data["numLines"] as? Int ?? 0,
            startLine: data["startLine"] as? Int ?? 1,
            totalLines: data["totalLines"] as? Int ?? 0
        ))
    }

    private static func parseEditResult(_ data: [String: Any]) -> ToolResultData {
        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .edit(EditResult(
            filePath: data["filePath"] as? String ?? "",
            oldString: data["oldString"] as? String ?? "",
            newString: data["newString"] as? String ?? "",
            replaceAll: data["replaceAll"] as? Bool ?? false,
            userModified: data["userModified"] as? Bool ?? false,
            structuredPatch: patches
        ))
    }

    private static func parseWriteResult(_ data: [String: Any]) -> ToolResultData {
        let typeStr = data["type"] as? String ?? "create"
        let writeType: WriteResult.WriteType = typeStr == "overwrite" ? .overwrite : .create

        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .write(WriteResult(
            type: writeType,
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            structuredPatch: patches
        ))
    }

    private static func parseBashResult(_ data: [String: Any]) -> ToolResultData {
        return .bash(BashResult(
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            interrupted: data["interrupted"] as? Bool ?? false,
            isImage: data["isImage"] as? Bool ?? false,
            returnCodeInterpretation: data["returnCodeInterpretation"] as? String,
            backgroundTaskId: data["backgroundTaskId"] as? String
        ))
    }

    private static func parseGrepResult(_ data: [String: Any]) -> ToolResultData {
        let modeStr = data["mode"] as? String ?? "files_with_matches"
        let mode: GrepResult.Mode
        switch modeStr {
        case "content": mode = .content
        case "count": mode = .count
        default: mode = .filesWithMatches
        }

        return .grep(GrepResult(
            mode: mode,
            filenames: data["filenames"] as? [String] ?? [],
            numFiles: data["numFiles"] as? Int ?? 0,
            content: data["content"] as? String,
            numLines: data["numLines"] as? Int,
            appliedLimit: data["appliedLimit"] as? Int
        ))
    }

    private static func parseGlobResult(_ data: [String: Any]) -> ToolResultData {
        return .glob(GlobResult(
            filenames: data["filenames"] as? [String] ?? [],
            durationMs: data["durationMs"] as? Int ?? 0,
            numFiles: data["numFiles"] as? Int ?? 0,
            truncated: data["truncated"] as? Bool ?? false
        ))
    }

    private static func parseTodoWriteResult(_ data: [String: Any]) -> ToolResultData {
        func parseTodos(_ array: [[String: Any]]?) -> [TodoItem] {
            guard let array = array else { return [] }
            return array.compactMap { item -> TodoItem? in
                guard let content = item["content"] as? String,
                      let status = item["status"] as? String else {
                    return nil
                }
                return TodoItem(
                    content: content,
                    status: status,
                    activeForm: item["activeForm"] as? String
                )
            }
        }

        return .todoWrite(TodoWriteResult(
            oldTodos: parseTodos(data["oldTodos"] as? [[String: Any]]),
            newTodos: parseTodos(data["newTodos"] as? [[String: Any]])
        ))
    }

    private static func parseTaskResult(_ data: [String: Any]) -> ToolResultData {
        return .task(TaskResult(
            agentId: data["agentId"] as? String ?? "",
            status: data["status"] as? String ?? "unknown",
            content: data["content"] as? String ?? "",
            prompt: data["prompt"] as? String,
            totalDurationMs: data["totalDurationMs"] as? Int,
            totalTokens: data["totalTokens"] as? Int,
            totalToolUseCount: data["totalToolUseCount"] as? Int
        ))
    }

    private static func parseWebFetchResult(_ data: [String: Any]) -> ToolResultData {
        return .webFetch(WebFetchResult(
            url: data["url"] as? String ?? "",
            code: data["code"] as? Int ?? 0,
            codeText: data["codeText"] as? String ?? "",
            bytes: data["bytes"] as? Int ?? 0,
            durationMs: data["durationMs"] as? Int ?? 0,
            result: data["result"] as? String ?? ""
        ))
    }

    private static func parseWebSearchResult(_ data: [String: Any]) -> ToolResultData {
        var results: [SearchResultItem] = []
        if let resultsArray = data["results"] as? [[String: Any]] {
            results = resultsArray.compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else {
                    return nil
                }
                return SearchResultItem(
                    title: title,
                    url: url,
                    snippet: item["snippet"] as? String ?? ""
                )
            }
        }

        return .webSearch(WebSearchResult(
            query: data["query"] as? String ?? "",
            durationSeconds: data["durationSeconds"] as? Double ?? 0,
            results: results
        ))
    }

    private static func parseAskUserQuestionResult(_ data: [String: Any]) -> ToolResultData {
        var questions: [QuestionItem] = []
        if let questionsArray = data["questions"] as? [[String: Any]] {
            questions = questionsArray.compactMap { q -> QuestionItem? in
                guard let question = q["question"] as? String else { return nil }
                var options: [QuestionOption] = []
                if let optionsArray = q["options"] as? [[String: Any]] {
                    options = optionsArray.compactMap { opt -> QuestionOption? in
                        guard let label = opt["label"] as? String else { return nil }
                        return QuestionOption(
                            label: label,
                            description: opt["description"] as? String
                        )
                    }
                }
                return QuestionItem(
                    question: question,
                    header: q["header"] as? String,
                    options: options
                )
            }
        }

        var answers: [String: String] = [:]
        if let answersDict = data["answers"] as? [String: String] {
            answers = answersDict
        }

        return .askUserQuestion(AskUserQuestionResult(
            questions: questions,
            answers: answers
        ))
    }

    private static func parseBashOutputResult(_ data: [String: Any]) -> ToolResultData {
        return .bashOutput(BashOutputResult(
            shellId: data["shellId"] as? String ?? "",
            status: data["status"] as? String ?? "",
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            stdoutLines: data["stdoutLines"] as? Int ?? 0,
            stderrLines: data["stderrLines"] as? Int ?? 0,
            exitCode: data["exitCode"] as? Int,
            command: data["command"] as? String,
            timestamp: data["timestamp"] as? String
        ))
    }

    private static func parseKillShellResult(_ data: [String: Any]) -> ToolResultData {
        return .killShell(KillShellResult(
            shellId: data["shell_id"] as? String ?? data["shellId"] as? String ?? "",
            message: data["message"] as? String ?? ""
        ))
    }

    private static func parseExitPlanModeResult(_ data: [String: Any]) -> ToolResultData {
        return .exitPlanMode(ExitPlanModeResult(
            filePath: data["filePath"] as? String,
            plan: data["plan"] as? String,
            isAgent: data["isAgent"] as? Bool ?? false
        ))
    }

    // MARK: - Subagent Tools Parsing

    /// Parse subagent tools from an agent JSONL file
    func parseSubagentTools(agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = Self.projectDirName(from: cwd)
        let agentFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentId + ".jsonl"

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}

/// Info about a subagent tool call parsed from JSONL
struct SubagentToolInfo: Sendable {
    let id: String
    let name: String
    let input: [String: String]
    let isCompleted: Bool
    let timestamp: String?
}

// MARK: - Static Subagent Tools Parsing

extension ConversationParser {
    /// Parse subagent tools from an agent JSONL file (static, synchronous version)
    nonisolated static func parseSubagentToolsSync(agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = projectDirName(from: cwd)
        let agentFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentId + ".jsonl"

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}
