//
//  AgentProvider.swift
//  AgentVisor
//
//  Per-agent integration seam. Each supported coding agent CLI (Anthropic
//  claude-code, Augment's auggie, OpenAI's codex) implements this protocol
//  to declare where its on-disk artifacts live, how to install hook
//  scripts into its config, and how to normalize per-agent identifiers
//  to agent-visor's canonical model. The rest of the app stays agent-
//  agnostic and routes through `AgentRegistry`.
//

import Foundation
import AgentVisorCore

/// One discovered session, agent-agnostic. The legacy 5-tuple promoted
/// to a named type so providers can return it directly. `pid == 0` is
/// the historical-session sentinel: bootstrap reads that as "no live
/// process" and synthesizes `.ended` phase + nil pid on SessionState.
struct DiscoveredSession: Equatable, Sendable {
    let sessionId: String
    let cwd: String
    let pid: Int
    let tty: String?
    let agentID: AgentID
}

/// What a provider's `fileSync` returned after the watcher debounce.
/// Two distinct shapes today:
/// - `.incremental` is claude-code's parseIncremental delta (only NEW
///   lines since the last call) plus its `clearDetected` and JSONL
///   permission-mode signals; SessionStore folds these into
///   `.fileUpdated` / `.clearDetected` reducer events.
/// - `.fullReplay` is the full-transcript path for providers without an
///   incremental parser; SessionStore folds it into `.historyLoaded`
///   (same shape as the chat-open path). Some providers gate this behind
///   cheaper metadata-only refreshes before calling `fileSync`.
enum FileSyncOutcome: Sendable {
    case incremental(IncrementalSyncResult)
    case fullReplay(ParsedHistory)
}

/// Result of an incremental file-extend parse — the delta-shape
/// outcome only claude-code produces today. Mirrors
/// `ConversationParser.IncrementalParseResult` field-for-field plus
/// `currentPermissionMode` so the call site can run claude-code's
/// JSONL permission-mode reconciliation without a separate parser
/// roundtrip.
struct IncrementalSyncResult: Sendable {
    let newMessages: [ChatMessage]
    let completedToolIds: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
    let clearDetected: Bool
    let currentPermissionMode: String?
}

/// Normalized output of a full transcript parse, agent-agnostic.
/// Folded into the `historyLoaded` reducer event by SessionStore.
/// Codex/cursor return `[:]` for `structuredResults` because their
/// parsers don't yet build tool-call structured payloads — that's
/// claude-code-only. The cache-warming side-effects of parsing live
/// inside each parser actor; this struct is just the bundle of values
/// that gets pushed back to SessionStore in one event.
struct ParsedHistory: Sendable {
    let messages: [ChatMessage]
    let completedToolIds: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
    let conversationInfo: ConversationInfo
    /// Latest permission-mode value seen in the JSONL after the parse.
    /// Only claude-code populates this — its `applyModeUpdate` /
    /// `lastAppliedJsonlMode` reconciliation logic doesn't apply to
    /// agents whose JSONL has no `permission-mode` lines.
    let currentPermissionMode: String?
}

protocol AgentProvider: Sendable {
    /// Stable wire identifier. The agent's hook script stamps this into
    /// the event payload so a single hook socket can multiplex across
    /// concurrent sessions of different agents.
    nonisolated var id: AgentID { get }

    /// User-facing name for chat headers and settings copy.
    nonisolated var displayName: String { get }

    /// Whether Agent Visor can spawn a brand-new, driveable session for
    /// this agent from the UI (the "New session" menu lists only agents
    /// that return true). Codex spawns via its app-server JSON-RPC;
    /// claude-code via a headless PTY fork. Observe-only agents
    /// (cursor, auggie) expose no spawn seam and stay false. Default
    /// false in the protocol extension.
    nonisolated var canSpawnSession: Bool { get }

    // MARK: - On-disk locations

    /// Per-agent config root (e.g. `~/.claude`, `~/.augment`).
    nonisolated var configDirectory: URL { get }

    /// JSON settings file the installer mutates to register hooks.
    nonisolated var settingsURL: URL { get }

    /// Where the hook script is copied on install.
    nonisolated var hooksDirectory: URL { get }

    /// Where the agent writes session metadata. Used for active-session
    /// discovery alongside hook events.
    nonisolated var sessionMetadataDirectory: URL { get }

    /// Where the agent writes session transcripts. Used to derive JSONL
    /// paths per session.
    nonisolated var projectsDirectory: URL { get }

    /// Substring that must appear in a session's process name during
    /// discovery to count it as an instance of this agent.
    nonisolated var processNameFilter: String { get }

    // MARK: - Encoders / lookups

    /// Convert a CWD to the on-disk project directory name this agent
    /// uses for its transcript files.
    nonisolated func projectDirName(forCwd cwd: String) -> String

    /// Full path to a session's JSONL transcript.
    nonisolated func transcriptURL(sessionId: String, cwd: String) -> URL

    // MARK: - Installation

    /// Install / refresh the agent's hook script and merge our entries
    /// into its settings.json. Safe to call repeatedly; never destroys
    /// existing entries that aren't ours.
    nonisolated func installHooks() throws

    /// Remove our hook entries and script. Leaves other entries alone.
    nonisolated func uninstallHooks()

    /// Whether our hooks are currently wired into this agent's settings.
    nonisolated func isInstalled() -> Bool

    // MARK: - Discovery

    /// Sessions whose CLI process is currently running. Bootstrap pairs
    /// these with a transcript file and surfaces them as `.idle` rows.
    /// Default `[]` lets a provider opt out of live discovery (e.g.
    /// observation-only providers that haven't been wired up yet).
    nonisolated func discoverLiveSessions() -> [DiscoveredSession]

    /// Sessions whose transcript exists on disk but whose CLI process
    /// is no longer running. Caller passes the live ids gathered from
    /// `discoverLiveSessions` across all providers so we don't double-
    /// count. `limit` is a global cap on historical rows surfaced by
    /// any single provider — providers may apply tighter internal
    /// recency filters before sorting + truncating to `limit`.
    /// Default `[]` for agents where session ids are pid-bound (e.g.
    /// claude-code) and a dead pid means a dead transcript.
    nonisolated func discoverHistoricalSessions(
        excluding liveIds: Set<String>,
        limit: Int
    ) -> [DiscoveredSession]

    // MARK: - History parsing

    /// Read a session's transcript from disk and return everything
    /// SessionStore needs to populate `historyLoaded`. Each provider
    /// owns the dance with its underlying parser actor (claude-code's
    /// ConversationParser + ConversationSummary, codex's
    /// CodexConversationParser, cursor's CursorConversationParser).
    /// Default impl returns an empty parse so a provider that hasn't
    /// wired transcript handling yet (auggie phase 3a) doesn't crash
    /// when a stray loadHistory is dispatched.
    nonisolated func loadFullHistory(sessionId: String, cwd: String) async -> ParsedHistory

    /// Parse just the bootstrap-time summary (firstUserMessage,
    /// lastMessage, model, context tokens, etc.). Used during initial
    /// discovery to populate the sidebar without parsing the entire
    /// transcript. Default delegates to `loadFullHistory` and returns
    /// only the `conversationInfo` field — providers with a cheaper
    /// summary path (claude-code's head+tail `ConversationSummary`)
    /// override this to avoid the full read.
    nonisolated func loadConversationInfo(sessionId: String, cwd: String) async -> ConversationInfo

    /// Run after the file watcher debounce when this session's
    /// transcript file has been extended. Returns either an
    /// incremental delta (claude-code) or a full replay (codex /
    /// cursor); SessionStore unwraps the tag and dispatches the
    /// appropriate reducer event. Default returns a no-op delta —
    /// providers without an incremental parser path (e.g. auggie
    /// pre-Phase-3b) simply do nothing on file extends.
    nonisolated func fileSync(sessionId: String, cwd: String) async -> FileSyncOutcome

    // MARK: - Lifecycle rules

    /// What `pruneDeadSessions` does when this session's CLI process
    /// is no longer alive. Default `.markEnded` keeps the row in the
    /// dictionary so chat history stays browsable. Providers whose
    /// dead sessions can't be revived from the sidebar (e.g. Zed —
    /// no deeplink or reveal path) override to `.remove`.
    nonisolated func deadProcessAction(for session: SessionState) -> DeadProcessAction

    /// Whether the file watcher should stop tailing this session's
    /// transcript when its CLI process exits. claude-code returns
    /// `true` because its session id is pid-bound (transcript can't
    /// grow once the pid dies). Codex / cursor return `false` because
    /// the transcript may extend if the user re-attaches the same
    /// session id from a new terminal.
    nonisolated func stopsWatchingOnDeath(for session: SessionState) -> Bool

    /// Sessions excluded from `pruneDeadSessions`'s duplicate-PID
    /// dedup pass. Cursor IDE Agents Window sessions all share
    /// Cursor.app's pid (one Electron app, many session transcripts),
    /// and Codex.app GUI threads share its app-server process, so
    /// identical pid is the design, not a duplicate. Default `false`.
    nonisolated func skipsPidDedup(for session: SessionState) -> Bool

    // MARK: - Metadata application

    /// Best-known user-set name for this session, looked up in
    /// whatever index the agent uses (claude-code's per-pid metadata
    /// file, codex's sqlite threads table, etc.). Returns nil when no
    /// user has renamed the session — the caller falls back to other
    /// signals (e.g. `customTitle` from the JSONL, first-user-message
    /// preview). Called from both the hook path (with a real `pid`)
    /// and bootstrap (`pid` may be nil for historical sessions).
    nonisolated func resolveSessionName(sessionId: String, pid: Int?) -> String?

    /// Origin classification for a session this provider just saw via
    /// the hook pipeline or process discovery. Drives downstream
    /// routing: `.cursorObserved` skips terminal-targeting code,
    /// `.observed` is read-only, `.visorSpawned` uses the pty bridge,
    /// `.terminal` uses the AX/AppleScript adapter. Default mirrors
    /// the historical claude-code heuristic (visor-spawn registry,
    /// then TTY presence).
    nonisolated func originForSession(sessionId: String, tty: String?) -> SessionOrigin

    /// Whether this agent's `lastModelName` from the JSONL parse
    /// should overwrite an already-set `session.modelName`. Codex
    /// returns true because its JSONL doesn't persist model across
    /// turns — every new turn is the source of truth. Other agents
    /// keep the first-set name (their model rarely changes mid-session
    /// and overwriting can clobber a manually-set value). Default
    /// `false`.
    nonisolated func overwritesModelName() -> Bool
}

/// What `pruneDeadSessions` does when a session's CLI process is no
/// longer alive. See `AgentProvider.deadProcessAction`.
enum DeadProcessAction: Sendable {
    /// Keep the row in the sessions dictionary but flip `phase` to
    /// `.ended`. Chat history stays browsable; the dimmed-row treatment
    /// in the sidebar surfaces the dead state.
    case markEnded
    /// Remove the row from the sessions dictionary entirely. Used for
    /// hosts whose dead sessions have no useful recovery path
    /// (e.g. Zed — no deeplink or reveal mechanism).
    case remove
}

extension AgentProvider {
    /// Most agents can't be spawned by the app (observe-only). The two
    /// that can — codex, claude-code — override this to true.
    nonisolated var canSpawnSession: Bool { false }

    nonisolated func discoverLiveSessions() -> [DiscoveredSession] { [] }

    nonisolated func discoverHistoricalSessions(
        excluding liveIds: Set<String>,
        limit: Int
    ) -> [DiscoveredSession] { [] }

    nonisolated func loadFullHistory(sessionId: String, cwd: String) async -> ParsedHistory {
        ParsedHistory(
            messages: [],
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:],
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil,
                lastCwd: nil,
                lastModelName: nil,
                lastContextTokens: nil,
                lastPermissionMode: nil
            ),
            currentPermissionMode: nil
        )
    }

    nonisolated func loadConversationInfo(sessionId: String, cwd: String) async -> ConversationInfo {
        await loadFullHistory(sessionId: sessionId, cwd: cwd).conversationInfo
    }

    nonisolated func fileSync(sessionId: String, cwd: String) async -> FileSyncOutcome {
        .incremental(IncrementalSyncResult(
            newMessages: [],
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:],
            clearDetected: false,
            currentPermissionMode: nil
        ))
    }

    nonisolated func deadProcessAction(for session: SessionState) -> DeadProcessAction {
        // Zed-hosted Claude sessions are special-cased here, not in
        // ClaudeCodeAgentProvider, because Zed identification keys on
        // `terminalHost`, not `agentID` (Zed runs claude-acp, so the
        // session's agentID is .claudeCode). The fact that this lives
        // in the default impl rather than per-provider is the right
        // shape: it's a *host*-driven rule, not an *agent*-driven one.
        if session.terminalHost == .zed { return .remove }
        if session.origin == .cursorObserved { return .remove }
        return .markEnded
    }

    nonisolated func stopsWatchingOnDeath(for session: SessionState) -> Bool {
        // Default: keep watching. Codex/cursor transcripts can grow
        // after the cli exits if the user re-attaches the same
        // session id; the file watcher needs to keep firing.
        false
    }

    nonisolated func skipsPidDedup(for session: SessionState) -> Bool { false }

    nonisolated func resolveSessionName(sessionId: String, pid: Int?) -> String? { nil }

    nonisolated func originForSession(sessionId: String, tty: String?) -> SessionOrigin {
        // claude-code-style heuristic: visor-spawned wins over
        // anything else; missing tty means a stdio child (Cursor's
        // claude-code extension is the canonical case); real tty
        // means a terminal-hosted CLI.
        if SpawnedSessionManager.isVisorSpawned(sessionId) {
            return .visorSpawned
        }
        return tty == nil ? .cursorObserved : .terminal
    }

    nonisolated func overwritesModelName() -> Bool { false }
}
