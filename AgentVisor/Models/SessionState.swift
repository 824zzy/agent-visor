//
//  SessionState.swift
//  AgentVisor
//
//  Unified state model for a Claude session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation
import AgentVisorCore

/// Complete state for a single Claude session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: - Identity

    let sessionId: String
    let cwd: String
    let projectName: String
    /// Which coding-agent CLI is hosting this session. Threaded from the
    /// hook event's `agent` stamp; defaults to claude-code when discovered
    /// from disk (claude-code is the only agent that writes session
    /// metadata to ~/.claude/sessions/ today).
    let agentID: AgentID

    /// Provenance of this session — distinguishes who spawned the
    /// underlying `claude` process. Drives chat-input routing:
    /// `.terminal` uses the AppleScript/keystroke adapter; `.visorSpawned`
    /// writes silently to the pty owned by `SpawnedSessionManager`;
    /// `.cursorObserved` hides the composer (Cursor's extension owns the
    /// process and we can't inject into its stdin).
    var origin: SessionOrigin

    /// Runtime control is independent from ownership. A Codex Desktop
    /// session remains `.observed` in origin even when both apps attach to
    /// one shared app-server and Agent Visor can safely drive it.
    var codexControlCapability: CodexControlCapability

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool

    /// Session name set by the user via `/rename` in Claude Code.
    /// Read from ~/.claude/sessions/<pid>.json.
    var sessionName: String?

    /// Which terminal application is hosting the `claude` process —
    /// resolved by walking the parent PID chain via
    /// `TerminalHostDetector`. Drives the host glyph in the pill /
    /// row status badge so users with sessions in multiple hosts
    /// (Ghostty + Cursor + iTerm2) can tell them apart at a glance.
    /// `nil` until the discovery pass resolves it; `.unknown` once
    /// resolved against a bundle ID we don't recognize.
    var terminalHost: TerminalHost?

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Dynamic Project Name (from latest cwd in JSONL)

    /// The current working project, derived from the latest cwd in the JSONL.
    /// More accurate than projectName when sessions navigate between directories.
    var currentProject: String?

    // MARK: - Model & Usage Stats

    var modelName: String?
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0

    /// Latest Claude Code permission mode for this session, read from
    /// `permission-mode` JSONL entries. Stored as a raw string so unknown
    /// future modes render gracefully (UI maps known values via
    /// `PermissionMode.from(raw:)`).
    var permissionMode: String?

    /// Tokens in the most recent assistant message's context window
    /// (input + cache_read + cache_creation). Used to display current
    /// context usage as a percentage of the model's window.
    var lastContextTokens: Int = 0
    var contextWindowTokens: Int = 0
    var effortLevel: String?

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date
    var phaseChangedAt: Date
    var phaseObservedAt: Date?
    var phaseEvidenceSource: SessionPhaseEvidenceSource?

    // MARK: - Identifiable

    nonisolated var id: String { sessionId }

    /// Composite key for SwiftUI sidebar ForEach — sessionId + a
    /// phase case-tag. Including the phase tag in the row's identity
    /// forces ForEach to recreate the row when phase changes, which
    /// is what fixes the "stuck-orange dot in NEEDS ATTENTION"
    /// symptom: SwiftUI was reusing the cached row with the prior
    /// .processing phase even though the partition correctly placed
    /// the session in the .waitingForApproval bucket. Phase is the
    /// ONLY field worth keying off for row identity — others (tool
    /// name, last message) update via input flow without needing
    /// row recreation.
    nonisolated var sidebarRowKey: String {
        let tag: String
        switch phase {
        case .idle: tag = "idle"
        case .processing: tag = "processing"
        case .waitingForInput: tag = "waitingForInput"
        case .waitingForApproval: tag = "waitingForApproval"
        case .compacting: tag = "compacting"
        case .ended: tag = "ended"
        }
        return "\(sessionId)|\(tag)"
    }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        agentID: AgentID = .claudeCode,
        origin: SessionOrigin = .terminal,
        codexControlCapability: CodexControlCapability? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        terminalHost: TerminalHost? = nil,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil,
            lastCwd: nil, lastModelName: nil, lastContextTokens: nil,
            lastPermissionMode: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date(),
        phaseObservedAt: Date? = nil,
        phaseEvidenceSource: SessionPhaseEvidenceSource? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName.map(ProjectDisplayNamePolicy.displayName(forRawProjectName:))
            ?? ProjectDisplayNamePolicy.displayName(forCwd: cwd)
            ?? URL(fileURLWithPath: cwd).lastPathComponent
        self.agentID = agentID
        self.origin = origin
        self.codexControlCapability = codexControlCapability
            ?? (origin == .codexAppServer ? .managed : .observed)
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.terminalHost = terminalHost
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
        self.phaseChangedAt = createdAt
        self.phaseObservedAt = phaseObservedAt
        self.phaseEvidenceSource = phaseEvidenceSource
        self.sessionName = Self.readSessionName(pid: pid)
    }

    @discardableResult
    nonisolated mutating func setPhase(
        _ newPhase: SessionPhase,
        evidenceSource: SessionPhaseEvidenceSource,
        observedAt: Date = Date(),
        changedAt: Date = Date()
    ) -> Bool {
        var didChange = false
        if phase != newPhase {
            phase = newPhase
            phaseChangedAt = changedAt
            didChange = true
        }
        didChange = markPhaseEvidence(evidenceSource, observedAt: observedAt) || didChange
        return didChange
    }

    @discardableResult
    nonisolated mutating func markPhaseEvidence(
        _ source: SessionPhaseEvidenceSource,
        observedAt: Date = Date()
    ) -> Bool {
        let didChange = PhaseEvidenceMutationPolicy.didChange(
            currentSource: phaseEvidenceSource?.rawValue,
            currentObservedAt: phaseObservedAt?.timeIntervalSince1970,
            newSource: source.rawValue,
            newObservedAt: observedAt.timeIntervalSince1970
        )
        phaseObservedAt = observedAt
        phaseEvidenceSource = source
        return didChange
    }

    /// Read the session name from ~/.claude/sessions/<pid>.json.
    /// Claude Code writes this file for every interactive session;
    /// the `name` field is set when the user runs `/rename`.
    nonisolated static func readSessionName(pid: Int?) -> String? {
        guard let pid = pid else { return nil }
        let path = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        return name
    }

    /// Read the launch cwd from ~/.claude/sessions/<pid>.json.
    /// This is the directory where `claude` was originally started, which
    /// determines the JSONL storage path. Hook events can report a different
    /// cwd after Claude runs `cd`, but the JSONL always lives under the
    /// launch directory.
    nonisolated static func readLaunchCwd(pid: Int?) -> String? {
        guard let pid = pid else { return nil }
        let path = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = json["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        return cwd
    }

    /// Read the lifecycle status from ~/.claude/sessions/<pid>.json.
    /// Claude may mark a session ended/deactivated before the PID fully
    /// exits; pruning uses this to hide rows without waiting for process
    /// teardown.
    nonisolated static func readSessionStatus(pid: Int?) -> String? {
        guard let pid = pid else { return nil }
        let path = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String,
              !status.isEmpty else {
            return nil
        }
        return status
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    nonisolated var needsAttention: Bool {
        phase.needsAttention
    }

    /// The active permission context, if any
    nonisolated var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    nonisolated var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Best available project name: currentProject > projectName
    nonisolated var bestProjectName: String {
        currentProject ?? projectName
    }

    /// Display title: session name > currentProject > first user message > project name
    nonisolated var displayTitle: String {
        if let name = sessionName {
            return name
        }
        if let cp = currentProject, cp != projectName {
            return cp
        }
        return conversationInfo.firstUserMessage.map { String($0.prefix(50)) } ?? bestProjectName
    }

    /// Best hint for matching window title
    nonisolated var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    /// Pending tool name if waiting for approval
    nonisolated var pendingToolName: String? {
        activePermission?.toolName
    }

    /// Pending tool use ID
    nonisolated var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    nonisolated var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    nonisolated var lastMessage: String? {
        conversationInfo.lastMessage
    }

    /// Last message role
    nonisolated var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    nonisolated var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    nonisolated var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    nonisolated var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    nonisolated var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Timestamp of the last real conversational turn (any role). Drives the
    /// status-color staleness fade — `lastActivity` is unreliable for it
    /// because GUI-spawned sessions bump the JSONL mtime with non-message
    /// rows. See ConversationInfo.lastActivityDate.
    nonisolated var lastActivityDate: Date? {
        conversationInfo.lastActivityDate
    }

    /// Seconds of staleness for the status-color fade (green → gray over the
    /// idle window). Measured from the last real conversational turn, NOT
    /// `lastActivity`: GUI-spawned sessions (Claude Desktop, Zed) bump the
    /// JSONL mtime with non-message rows, and a registered-but-empty session
    /// has no transcript at all so its `lastActivity` defaults to "now". Both
    /// would otherwise fake a fresh green on a session with no real activity.
    /// A session with no turns yet has nothing to be fresh about → fully stale.
    nonisolated var statusIdleAge: TimeInterval {
        guard let date = lastActivityDate else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(date)
    }

    /// Whether the session can be interacted with
    nonisolated var canInteract: Bool {
        phase.needsAttention
    }

    /// Whether the notch's chat composer should accept text input for
    /// this session.
    ///
    /// `.cursorObserved` returns true thanks to `CursorAXSender` —
    /// AX write into the Message input + CGEventPostToPid Return
    /// delivers the message to Cursor's existing claude process
    /// without focus theft. `.visorSpawned` writes directly to its
    /// owned pty. `.terminal` needs a real TTY for the AppleScript /
    /// tmux send paths.
    nonisolated var supportsSilentSend: Bool {
        // Codex threads are drivable ONLY through the app-server origin
        // (CodexAppServerClient). A plain `.observed` codex thread —
        // actively running inside Codex.app or a live CLI — stays
        // read-only because resuming it into our engine would race the
        // owning engine's rollout writer.
        if agentID == .codex {
            return codexControlCapability != .observed
        }
        switch origin {
        case .terminal:        return tty != nil
        case .visorSpawned:    return true
        case .cursorObserved:  return true
        case .codexAppServer:  return true
        case .observed:        return false
        }
    }
}

/// Provenance of a Claude session — see `SessionState.origin`.
enum SessionOrigin: String, Codable, Equatable, Sendable {
    /// User launched `claude` in a real terminal (Ghostty, iTerm2,
    /// Terminal.app). agent-visor drives input via the host's
    /// AppleScript adapter.
    case terminal

    /// Cursor's claude-code extension spawned the process. No TTY,
    /// stdin owned by the extension host — agent-visor can mirror
    /// the transcript and surface tool approvals, but cannot inject
    /// user messages.
    case cursorObserved

    /// Non-Claude observed session. Phase-one Codex support is read-only:
    /// status and transcript history only, no prompt injection.
    case observed

    /// agent-visor itself spawned the process via
    /// `SpawnedSessionManager` under a pty it controls. Silent send
    /// works because the parent owns the primary fd.
    case visorSpawned

    /// Codex thread driven through agent-visor's own `codex app-server`
    /// (CodexAppServerClient): we `thread/resume` the rollout and
    /// `turn/start` from the composer, and answer the engine's approval
    /// requests in our UI. Only assigned to idle threads not currently
    /// owned by a live Codex.app/CLI engine — see
    /// CodexAgentProvider.originForSession.
    case codexAppServer
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}
