//
//  SessionStore.swift
//  AgentVisor
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import AppKit
import AgentVisorCore
import Combine
import Foundation
import Mixpanel
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "Session")

    // MARK: - Chat-order diagnostic
    //
    // Dump the tail of `session.chatItems` at key points in `processFileUpdate`
    // to investigate ordering bugs (e.g., a chronologically-newest text block
    // appearing earlier in the displayed history than older items).
    //
    // Enable with:
    //     defaults write com.824zzy.AgentVisor chatOrderDebug -bool true
    // Disable with:
    //     defaults write com.824zzy.AgentVisor chatOrderDebug -bool false
    // Read once at launch; relaunch Agent Visor to toggle.
    // Output goes to Console.app (subsystem com.824zzy.agentvisor, category Session).

    nonisolated static let chatOrderDebugEnabled: Bool =
        UserDefaults.standard.bool(forKey: "chatOrderDebug")

    private static let chatOrderTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Log the trailing slice of `items` for a given checkpoint. Up to 20
    /// items so a long history doesn't drown the log. No-op unless the
    /// `chatOrderDebug` default is set.
    nonisolated static func logChatOrder(_ label: String, _ items: [ChatHistoryItem]) {
        guard chatOrderDebugEnabled else { return }
        let tailCount = min(items.count, 20)
        let tail = items.suffix(tailCount).enumerated().map { (offset, item) -> String in
            let trueIdx = items.count - tailCount + offset
            let ts = chatOrderTimeFormatter.string(from: item.timestamp)
            let idShort = String(item.id.prefix(14))
            let (kind, preview) = describe(item.type)
            let previewShort = String(preview.prefix(50))
                .replacingOccurrences(of: "\n", with: " ")
            return "    [\(trueIdx)] \(ts) \(kind) id=\(idShort) :: \(previewShort)"
        }.joined(separator: "\n")
        Self.logger.info("chatOrder[\(label, privacy: .public)] count=\(items.count, privacy: .public) tail:\n\(tail, privacy: .public)")
    }

    private static func describe(_ type: ChatHistoryItemType) -> (kind: String, preview: String) {
        switch type {
        case .user(let t):              return ("user   ", t)
        case .image(let image):         return ("image  ", image.displayName)
        case .assistant(let t):         return ("ast    ", t)
        case .toolCall(let tool):       return ("tool   ", tool.name)
        case .thinking(let t):          return ("think  ", t)
        case .interrupted:              return ("interr ", "")
        case .turnDuration(let s):      return ("dur    ", "\(s)s")
        case .recap(let t):             return ("recap  ", t)
        case .compactBoundary:          return ("compact", "")
        case .localCommandOutput(let t):return ("locmd  ", t)
        }
    }

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Sessions the user has hidden. Kept in `sessions` (so an unhide is
    /// instant) but filtered out at the publish boundary, so the sidebar AND
    /// pills both stop showing them. Hydrated from persistence on first read
    /// and kept in sync by `hideSession`/`unhideSession`.
    private lazy var hiddenSessionIds: Set<String> = MainWindowSettings.hiddenSessionIds()

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    private var lastCodexMetadataRediscoveryAt: Date?
    private var pendingCodexMetadataRediscoveryTask: Task<Void, Never>?
    private var lastCodexDiscoverySnapshot: CodexThreadDiscoverySnapshot?

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    /// Snapshot of current sessions (for synchronous reads after awaited operations)
    func currentSessions() -> [SessionState] {
        Array(sessions.values)
    }

    func setCodexControlCapability(
        sessionId: String,
        capability: CodexControlCapability
    ) {
        guard sessions[sessionId]?.agentID == .codex else { return }
        sessions[sessionId]?.codexControlCapability = capability
        publishStateWithoutPrune()
    }

    func resetConnectedCodexControlCapabilities() {
        var changed = false
        for sessionId in Array(sessions.keys)
        where sessions[sessionId]?.codexControlCapability == .connected {
            sessions[sessionId]?.codexControlCapability = .observed
            changed = true
        }
        if changed {
            publishStateWithoutPrune()
        }
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .fileExtended(let sessionId, let cwd):
            // File was appended to. Schedule a debounced incremental parse
            // unless we already lost track of this session.
            guard sessions[sessionId] != nil else { return }
            scheduleFileSync(sessionId: sessionId, cwd: cwd)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .codexAppServerThreadStarted(let sessionId, let cwd):
            processCodexAppServerThreadStarted(sessionId: sessionId, cwd: cwd)

        case .visorSpawnedSessionStarted(let sessionId, let cwd):
            processVisorSpawnedSessionStarted(sessionId: sessionId, cwd: cwd)

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break

        case .injectScrapedAssistantText(let sessionId, let boundToolUseId, let text):
            processScrapedAssistantText(sessionId: sessionId, boundToolUseId: boundToolUseId, text: text)

        case .codexAssistantDelta(let sessionId, let itemId, let delta):
            processCodexAssistantDelta(sessionId: sessionId, itemId: itemId, delta: delta)

        case .codexUserMessage(let sessionId, let itemId, let text, let images):
            processCodexUserMessage(sessionId: sessionId, itemId: itemId, text: text, images: images)
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        guard let event = codexBackedHookEvent(event) else { return }

        let sessionId = event.sessionId
        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createSession(from: event)
        let eventProvider = AgentRegistry.provider(for: event.agentID)
        let sharesProcessAcrossSessions = eventProvider?.skipsPidDedup(for: session) ?? false

        // Deduplicate: if this PID is already tracked under a different session ID,
        // remove the old session. This handles /resume which creates a new session ID
        // but reuses the same process. GUI agents intentionally share a host process,
        // so their hook-emitter PID is not a one-session ownership signal.
        if let pid = event.pid {
            let staleIds = sessions.keys.filter { existingId in
                guard existingId != sessionId,
                      let existing = sessions[existingId],
                      existing.pid == pid else { return false }
                let existingSharesProcess = AgentRegistry.provider(for: existing.agentID)?
                    .skipsPidDedup(for: existing) ?? false
                return HookProcessMetadataPolicy.shouldRemoveCollidingSession(
                    incomingSharesProcessAcrossSessions: sharesProcessAcrossSessions,
                    existingSharesProcessAcrossSessions: existingSharesProcess
                )
            }
            for staleId in staleIds {
                Self.logger.debug("Dedup: removing stale session \(staleId.prefix(8), privacy: .public) (PID \(pid) now belongs to \(sessionId.prefix(8), privacy: .public))")
                sessions.removeValue(forKey: staleId)
                cancelPendingSync(sessionId: staleId)
                Task { @MainActor in
                    SessionFileWatcherManager.shared.stopWatching(sessionId: staleId)
                }
            }
        }

        // Track new session in Mixpanel
        if isNewSession {
            Mixpanel.mainInstance().track(event: "Session Started")
        }

        let normalizedTTY = event.tty?.replacingOccurrences(of: "/dev/", with: "")
        let processMetadata = HookProcessMetadataPolicy.merge(
            existing: HookProcessMetadata(pid: session.pid, tty: session.tty),
            reported: HookProcessMetadata(pid: event.pid, tty: normalizedTTY),
            sharesProcessAcrossSessions: sharesProcessAcrossSessions
        )
        session.pid = processMetadata.pid
        session.tty = processMetadata.tty
        // Refresh terminalHost on every hook event. The host can change
        // mid-session: a JSONL first written from iTerm2 gets resumed
        // via `claude --resume <id>` inside Zed, and we want the host
        // badge to reflect Zed (the live driver), not the stale iTerm2
        // detection from session creation. The detector is idempotent
        // and parent-walk-bounded; running it per-event is cheap.
        if event.agentID == .codex, processMetadata.tty == nil {
            session.terminalHost = .codexApp
        } else if !sharesProcessAcrossSessions, let pid = processMetadata.pid {
            let host = TerminalHostDetector.detect(pid: pid_t(pid), reader: LiveProcessInfoReader.shared)
            // Don't overwrite a real host with `.unknown` — process
            // walk can transiently miss when the parent chain is being
            // re-parented mid-event (rare but happens during shell
            // reparent / launchd handoff).
            if host != .unknown {
                session.terminalHost = host
            }
        }
        // Refresh session name on every hook event. Each provider
        // looks up the user-set name in its own index — claude-code
        // by pid, codex by sessionId, etc. Nil means "no rename
        // recorded"; don't clobber a customTitle the bootstrap parser
        // may have surfaced from JSONL rows.
        if let eventProvider,
           let name = eventProvider.resolveSessionName(sessionId: event.sessionId, pid: processMetadata.pid),
           !name.isEmpty {
            session.sessionName = name
        }
        if !sharesProcessAcrossSessions, let pid = processMetadata.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        // Notifications (idle_prompt, etc.) are signals from Claude Code,
        // not activity from Claude or the user. Updating lastActivity here
        // would reset the color fade on every idle_prompt and make stale
        // sessions look fresh forever.
        if event.event != "Notification" {
            session.lastActivity = Date()
        }

        if event.isTerminalLifecycleStatus {
            // Keep the ended state in the store for recovery/history
            // paths, but publish immediately so active sidebars can hide
            // it without waiting for an unrelated later event.
            session.setPhase(.ended, evidenceSource: .hook)
            sessions[sessionId] = session
            cancelPendingSync(sessionId: sessionId)
            publishState()
            return
        }

        // Apply chat-item side-effects BEFORE the phase transition so the
        // "is any tool still waiting for approval?" check below sees the
        // accurate post-event state. Specifically, PostToolUse for the
        // tool that was waiting needs to flip its chatItem from
        // .waitingForApproval to .success *before* the phase decision,
        // otherwise we would incorrectly hold the session in
        // .waitingForApproval forever.
        let shouldCreateApprovalPlaceholder = event.event == "PermissionRequest"
            && (event.agentID != .codex || event.tool == "AskUserQuestion")
        if shouldCreateApprovalPlaceholder, let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)

            // Subagent tools skip placeholder creation in processToolTracking
            // (they go into the subagent's tool list instead of chatItems). If
            // the tool is missing from chatItems, the pending-approval phase
            // guard below won't see it and the session will drop out of
            // .waitingForApproval as soon as the next sibling event arrives.
            // Create a minimal placeholder so the guard works for subagent
            // tools too.
            if !session.chatItems.contains(where: { $0.id == toolUseId }),
               let toolName = event.tool {
                // Pipe the hook event's toolInput through the same
                // conversion the PreToolUse path uses (arrays/nested
                // dicts get JSON-encoded as strings). Without this,
                // AskUserQuestion's `questions` array would be dropped
                // and the chat view would render an empty body.
                let input = ToolEventProcessor.extractToolInput(from: event.toolInput)
                session.chatItems.append(ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(ToolCallItem(
                        name: toolName,
                        input: input,
                        status: .waitingForApproval,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: Date()
                ))
                Self.logger.debug("Created approval placeholder for \(toolName, privacy: .public) tool \(toolUseId.prefix(12), privacy: .public) inputKeys=\(input.keys.sorted().joined(separator: ","), privacy: .public)")
            }
        }

        if event.agentID != .codex {
            processToolTracking(event: event, session: &session)
            processSubagentTracking(event: event, session: &session)
        }

        let newPhase = event.determinePhase()
        if !ObservedHookPhasePolicy.shouldApplyHookPhase(
            usesTranscriptPhaseInference: usesTranscriptPhaseInference(session),
            reportedPhase: Self.reportedHookPhase(for: newPhase),
            isCurrentlyWaitingForApproval: session.phase.isWaitingForApproval
        ) {
            sessions[sessionId] = session
            _ = await applyInferredObservedPhase(sessionId: sessionId)
            publishState()

            if event.shouldSyncFile {
                scheduleFileSync(sessionId: sessionId, cwd: session.cwd)
            }
            return
        }

        // Guard against parallel tool events clobbering a pending permission.
        //
        // When a tool is waiting for approval, Claude may fire sibling
        // PreToolUse/PostToolUse events (auto-approved parallel tools,
        // subagent tools, etc.) whose determinePhase() returns .processing.
        // Without a guard, the session flips from .waitingForApproval to
        // .processing and the right pill goes orange instead of yellow.
        //
        // Once in .waitingForApproval, block transitions except:
        //   - .waitingForApproval  (another tool needs approval)
        //   - .waitingForInput     (turn ended, approval handled via native UI)
        //   - .ended               (session terminated)
        //   - a source-specific definitive continuation signal. Claude Code
        //     requires a matching completion so parallel siblings cannot
        //     clear the approval. Observed Codex may omit tool identity, so
        //     its first PreToolUse/UserPromptSubmit after the user answers is
        //     the strongest available signal that the turn resumed.
        //
        // Explicit approval/denial from the notch goes through
        // processPermissionApproved/Denied which set the phase directly,
        // bypassing this path entirely.
        let preserveWaitingForApproval: Bool
        if session.phase.isWaitingForApproval
            && !newPhase.isWaitingForApproval
            && newPhase != .ended
            && newPhase != .waitingForInput {
            if case .waitingForApproval(let ctx) = session.phase,
               PendingApprovalCompletionPolicy.shouldReleaseWaitingState(
                    agentID: session.agentID,
                    event: event.event,
                    incomingToolUseId: event.toolUseId,
                    incomingToolName: event.tool,
                    pendingToolUseId: ctx.toolUseId,
                    pendingToolName: ctx.toolName
               ) {
                preserveWaitingForApproval = false
                debugLog("[Approval] \(event.event) on waiting \(sessionId.prefix(8)) doneTool=\(event.tool ?? "nil") doneId=\((event.toolUseId ?? "").prefix(8)) waitTool=\(ctx.toolName) waitId=\(ctx.toolUseId.prefix(8)) -> preserve=\(preserveWaitingForApproval)")
            } else {
                preserveWaitingForApproval = true
                debugLog("[Approval] \(event.event) on waiting \(sessionId.prefix(8)) -> preserve (newPhase=\(String(describing: newPhase)))")
            }
        } else {
            preserveWaitingForApproval = false
        }

        if preserveWaitingForApproval {
            Self.logger.info("Preserving waitingForApproval across \(event.event, privacy: .public) (tool=\(event.tool ?? "nil", privacy: .public))")
        } else if event.event == "Notification" {
            // Notifications are informational only and never change phase.
            // Specifically, Claude Code fires Notification(idle_prompt) every
            // ~60s while a session is in .waitingForInput; if we let that
            // flow through, setPhase() updates phaseChangedAt and the
            // SessionStatusDot pulse stops far before its configured 7-min
            // window. Skip the transition entirely for notifications.
        } else if session.phase == .ended && newPhase != .ended {
            // Resurrection. A hook event can only originate from a LIVE
            // claude process, but the same PID can still emit delayed hook
            // events while winding down after SessionEnd. Only a different
            // PID proves the user re-attached (`claude --resume`) or started
            // a fresh turn in a new shell.
            if SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook(
                currentPid: session.pid,
                eventPid: event.pid
            ) {
                Self.logger.info("Resurrecting ended session \(sessionId.prefix(8), privacy: .public) on live \(event.event, privacy: .public) (pid \(session.pid ?? -1, privacy: .public) -> \(event.pid ?? -1, privacy: .public))")
                session.setPhase(newPhase, evidenceSource: .hook)
                let cwdCopy = session.cwd
                let agentCopy = session.agentID
                Task { @MainActor in
                    SessionFileWatcherManager.shared.startWatching(
                        sessionId: sessionId,
                        cwd: cwdCopy,
                        agentID: agentCopy
                    )
                }
            } else {
                Self.logger.info("Ignoring late hook \(event.event, privacy: .public) for ended session \(sessionId.prefix(8), privacy: .public) pid=\(event.pid ?? -1, privacy: .public)")
            }
        } else if session.phase.canTransition(to: newPhase) {
            session.setPhase(newPhase, evidenceSource: .hook)
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        sessions[sessionId] = session
        publishState()

        if event.shouldSyncFile {
            // Use session.cwd (the launch directory, immutable) not event.cwd
            // (the current working directory, which drifts when Claude runs cd).
            // Claude Code stores JSONL files under the launch directory's project
            // path, so using event.cwd after a cd results in a wrong lookup path.
            scheduleFileSync(sessionId: sessionId, cwd: session.cwd)
        }
    }

    private func codexBackedHookEvent(_ event: HookEvent) -> HookEvent? {
        guard event.agentID == .codex else { return event }
        guard sessions[event.sessionId] == nil else { return event }
        guard CodexThreadStore.thread(id: event.sessionId) == nil,
              CodexAgentProvider.rolloutFileURL(sessionId: event.sessionId) == nil else {
            return event
        }

        Self.logger.debug("Ignoring Codex hook for unknown thread id \(event.sessionId.prefix(8), privacy: .public)")
        return nil
    }

    private static func reportedHookPhase(for phase: SessionPhase) -> ObservedHookPhasePolicy.ReportedPhase {
        switch phase {
        case .idle:
            return .idle
        case .processing:
            return .processing
        case .waitingForInput:
            return .waitingForInput
        case .waitingForApproval:
            return .waitingForApproval
        case .compacting:
            return .compacting
        case .ended:
            return .ended
        }
    }

    static func originForHostedSession(
        sessionId: String,
        tty: String?,
        agentID: AgentID = .claudeCode,
        terminalHost: TerminalHost? = nil
    ) -> SessionOrigin {
        let provider = AgentRegistry.provider(for: agentID) ?? AgentRegistry.defaultProvider
        let providerOrigin = provider.originForSession(sessionId: sessionId, tty: tty)
        guard agentID == .claudeCode, providerOrigin != .visorSpawned else {
            return providerOrigin
        }
        switch ClaudeHostedSessionOriginPolicy.origin(
            hasTTY: tty != nil,
            terminalHost: terminalHost
        ) {
        case .terminal: return .terminal
        case .cursorObserved: return .cursorObserved
        case .observed: return .observed
        }
    }

    private func createSession(from event: HookEvent) -> SessionState {
        // Prefer the launch cwd from Claude Code's session metadata file.
        // Hook events report the process's CURRENT working directory, which
        // drifts after `cd` commands. The JSONL storage path is based on the
        // LAUNCH directory, so using a drifted cwd makes all file lookups
        // (chat history, interrupt detection) fail silently.
        let launchCwd = event.agentID == .claudeCode
            ? (SessionState.readLaunchCwd(pid: event.pid) ?? event.cwd)
            : event.cwd
        let normalizedTTY = event.tty?.replacingOccurrences(of: "/dev/", with: "")
        let host: TerminalHost?
        if event.agentID == .codex, normalizedTTY == nil {
            host = .codexApp
        } else {
            host = event.pid.map {
                TerminalHostDetector.detect(pid: pid_t($0), reader: LiveProcessInfoReader.shared)
            }
        }
        var session = SessionState(
            sessionId: event.sessionId,
            cwd: launchCwd,
            projectName: ProjectDisplayNamePolicy.displayName(forCwd: launchCwd)
                ?? URL(fileURLWithPath: launchCwd).lastPathComponent,
            agentID: event.agentID,
            origin: SessionStore.originForHostedSession(
                sessionId: event.sessionId,
                tty: normalizedTTY,
                agentID: event.agentID,
                terminalHost: host
            ),
            pid: event.pid,
            tty: normalizedTTY,
            isInTmux: false,  // Will be updated
            terminalHost: host,
            phase: .idle
        )
        if event.agentID == .codex,
           let title = CodexThreadStore.thread(id: event.sessionId)?.title,
           !title.isEmpty {
            session.sessionName = title
        }
        return session
    }

    private func processCodexAppServerThreadStarted(sessionId: String, cwd: String) {
        if sessions[sessionId] != nil {
            setSessionPhase(sessionId, .idle, evidenceSource: .localAction)
            sessions[sessionId]?.lastActivity = Date()
            sessions[sessionId]?.terminalHost = .codexApp
            return
        }

        var session = SessionState(
            sessionId: sessionId,
            cwd: cwd,
            projectName: ProjectDisplayNamePolicy.displayName(forCwd: cwd)
                ?? URL(fileURLWithPath: cwd).lastPathComponent,
            agentID: .codex,
            origin: .codexAppServer,
            pid: nil,
            tty: nil,
            terminalHost: .codexApp,
            phase: .idle
        )
        session.lastActivity = Date()
        sessions[sessionId] = session

        Task { @MainActor in
            SessionFileWatcherManager.shared.startWatching(
                sessionId: sessionId,
                cwd: cwd,
                agentID: .codex
            )
        }
    }

    /// Pre-seed a claude-code session the app just forked under a headless
    /// PTY (SpawnedSessionManager). Mirrors the Codex app-server seed above
    /// so the caller can select the row immediately and land on its
    /// (initially empty) chat instead of a "session not found" flash. The
    /// spawned claude's first SessionStart hook arrives within ms and
    /// reconciles in place via processHookEvent (keyed on sessionId;
    /// pid stays nil here so it doesn't trip the pid-dedup pass).
    private func processVisorSpawnedSessionStarted(sessionId: String, cwd: String) {
        if sessions[sessionId] != nil {
            setSessionPhase(sessionId, .idle, evidenceSource: .localAction)
            sessions[sessionId]?.lastActivity = Date()
            return
        }

        var session = SessionState(
            sessionId: sessionId,
            cwd: cwd,
            projectName: ProjectDisplayNamePolicy.displayName(forCwd: cwd)
                ?? URL(fileURLWithPath: cwd).lastPathComponent,
            agentID: .claudeCode,
            origin: .visorSpawned,
            pid: nil,
            tty: nil,
            phase: .idle
        )
        session.lastActivity = Date()
        sessions[sessionId] = session

        Task { @MainActor in
            SessionFileWatcherManager.shared.startWatching(
                sessionId: sessionId,
                cwd: cwd,
                agentID: .claudeCode
            )
        }
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && toolName != "Task"
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            } else if value.value is [Any] || value.value is [String: Any] {
                                // Preserve arrays/nested dicts (e.g.
                                // AskUserQuestion's `questions`) as JSON
                                // strings so renderers can decode on demand.
                                if let data = try? JSONSerialization.data(withJSONObject: value.value),
                                   let str = String(data: data, encoding: .utf8) {
                                    input[key] = str
                                }
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }

                // AskUserQuestion is the one tool that pends indefinitely
                // on user input, so its surrounding assistant text gets
                // held in claude-code memory for the whole wait. Kick off
                // an AX scrape on a background queue to backfill that
                // text from the terminal's scrollback. See
                // `feedback_chat_parity_with_ghostty.md` for the rule and
                // GhosttyModeProbe.readScrollback for the read path.
                if toolName == "AskUserQuestion" {
                    let sid = session.sessionId
                    let sessionSnapshot = session
                    Task.detached(priority: .userInitiated) {
                        await Self.scrapeAndInjectAssistantText(
                            session: sessionSnapshot,
                            boundToolUseId: toolUseId,
                            sessionId: sid
                        )
                    }
                }
            }

        case "PostToolUse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                var matched = false
                var matchedButSkipped: ToolStatus? = nil
                for i in 0..<session.chatItems.count {
                    guard session.chatItems[i].id == toolUseId,
                          case .toolCall(var tool) = session.chatItems[i].type else { continue }
                    if tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        matched = true
                    } else {
                        matchedButSkipped = tool.status
                    }
                    break
                }
                if matched {
                    Self.logger.debug("PostToolUse flipped \(toolUseId.prefix(12), privacy: .public) → .success")
                } else if let skip = matchedButSkipped {
                    Self.logger.debug("PostToolUse \(toolUseId.prefix(12), privacy: .public) matched but status was \(String(describing: skip), privacy: .public), not flipped")
                } else {
                    let toolIdsPreview = session.chatItems.compactMap { item -> String? in
                        guard case .toolCall = item.type else { return nil }
                        return String(item.id.prefix(12))
                    }.suffix(8).joined(separator: ",")
                    Self.logger.warning("PostToolUse \(toolUseId.prefix(12), privacy: .public) had NO matching chatItem (last 8 tool ids: \(toolIdsPreview, privacy: .public))")
                }
            } else {
                Self.logger.warning("PostToolUse arrived without tool_use_id (tool=\(event.tool ?? "nil", privacy: .public))")
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if event.tool == "Task", let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            }

        case "PostToolUse":
            if event.tool == "Task" {
                Self.logger.debug("PostToolUse for Task received (subagent still running)")
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.setPhase(newPhase, evidenceSource: .localAction)
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.setPhase(.processing, evidenceSource: .localAction)
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.setPhase(.processing, evidenceSource: .localAction)
                }
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.setPhase(newPhase, evidenceSource: .transcriptHeuristic)
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.setPhase(.processing, evidenceSource: .transcriptHeuristic)
                }
            }
        }

        sessions[sessionId] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.setPhase(newPhase, evidenceSource: .localAction)
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.setPhase(.processing, evidenceSource: .localAction)
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.setPhase(.processing, evidenceSource: .localAction)
                }
            }
        }

        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.setPhase(newPhase, evidenceSource: .localAction)
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.setPhase(.idle, evidenceSource: .localAction)
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.setPhase(.idle, evidenceSource: .localAction)
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }

        // Update conversationInfo from JSONL (summary, lastMessage, etc.)
        let conversationInfo = await ConversationSummary.shared.parse(
            sessionId: payload.sessionId,
            cwd: session.cwd
        )
        session.conversationInfo = Self.preserveCodexSyntheticUserInfo(
            conversationInfo,
            previous: session.conversationInfo,
            chatItems: session.chatItems
        )
        session.lastActivity = Self.mergedLastActivity(
            current: session.lastActivity,
            info: session.conversationInfo
        )

        // Aggregate model and token usage from new messages. Walk in order so
        // a compact_boundary that appears before later assistant turns resets
        // the context counter without clobbering subsequent token updates.
        for message in payload.messages {
            if message.content.contains(where: { if case .compactBoundary = $0 { return true } else { return false } }) {
                // /compact wiped the context window. The next assistant turn
                // will overwrite this with the real post-compact size; until
                // then the status bar must drop to ~0% to match the TUI.
                session.lastContextTokens = 0
                continue
            }
            guard message.role == .assistant else { continue }
            if let model = message.model, !model.hasPrefix("<") {
                session.modelName = model
            }
            let context = (message.inputTokens ?? 0)
                + (message.cacheReadTokens ?? 0)
                + (message.cacheCreationTokens ?? 0)
            session.totalInputTokens += context
            session.totalOutputTokens += (message.outputTokens ?? 0)
            if context > 0 {
                session.lastContextTokens = context
            }
        }
        applyConversationMetadata(session.conversationInfo, to: &session)

        // Update currentProject from the latest cwd in the JSONL
        if let lastCwd = conversationInfo.lastCwd {
            let lastComponent = ProjectDisplayNamePolicy.displayName(forCwd: lastCwd)
                ?? URL(fileURLWithPath: lastCwd).lastPathComponent
            if lastComponent != session.projectName && !lastComponent.isEmpty {
                session.currentProject = lastComponent
            }
        }

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .image, .thinking, .interrupted, .turnDuration, .recap, .compactBoundary, .localCommandOutput:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        Self.logChatOrder("pre-process[isIncremental=\(payload.isIncremental),msgs=\(payload.messages.count)]", session.chatItems)

        if payload.isIncremental {
            // Mutable so the set stays current as we append within this loop.
            // Snapshotting once and never updating let two blocks that
            // synthesize the same `<message.id>-<kind>-<blockIndex>` key both
            // pass the guard, producing duplicate ChatHistoryItem ids that
            // SwiftUI's flipped LazyVStack tolerates silently but eager
            // VStack hard-fails on (the "phantom-space gap" symptom).
            var existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                // Merge results from JSONL when hook set status before sync
                                let mergedResult = existingTool.result ?? extractResultText(toolId: tool.id, from: payload)
                                let mergedStructured = existingTool.structuredResult ?? payload.structuredResults[tool.id]
                                let mergedStatus = mergeToolStatus(
                                    existing: existingTool.status,
                                    toolId: tool.id,
                                    input: tool.input,
                                    payload: payload
                                )

                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: mergedStatus,
                                        result: mergedResult,
                                        structuredResult: mergedStructured,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                        existingIds.insert(item.id)
                    }
                }
            }

            // Drop AX-scrape synthetics whose bound tool just arrived in
            // the JSONL. The real text block from the same message is
            // also being appended in this batch, so leaving the
            // synthetic would visibly duplicate it. See
            // `feedback_chat_parity_with_ghostty.md` for why we have
            // the synthetic in the first place.
            removeAxSyntheticsForArrivingTools(payload: payload, chatItems: &session.chatItems)
            removeCodexStreamSyntheticsForArrivingMessages(payload.messages, chatItems: &session.chatItems)

            // Sort by timestamp to recover chronological order. PreToolUse
            // hooks append tool items at the END of `chatItems` at the
            // moment they fire, but the corresponding tool_use block in the
            // JSONL has a chronologically-earlier timestamp. Without this
            // sort, the merge-in-place path keeps the tool item at its
            // hook-insertion position, sitting AFTER text/duration items
            // that arrived in JSONL after the hook but came from an
            // earlier chronological moment. See
            // `feedback_chat_items_sort_overhead.md` memory for the perf
            // tradeoff and a faster suffix-sort alternative if this ever
            // becomes a hot spot on long sessions.
            session.chatItems.sort { $0.timestamp < $1.timestamp }

            Self.logChatOrder("after-incremental-process", session.chatItems)
        } else {
            var existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                // Merge results from JSONL when hook set status before sync
                                let mergedResult = existingTool.result ?? extractResultText(toolId: tool.id, from: payload)
                                let mergedStructured = existingTool.structuredResult ?? payload.structuredResults[tool.id]
                                let mergedStatus = mergeToolStatus(
                                    existing: existingTool.status,
                                    toolId: tool.id,
                                    input: tool.input,
                                    payload: payload
                                )

                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: mergedStatus,
                                        result: mergedResult,
                                        structuredResult: mergedStructured,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                        existingIds.insert(item.id)
                    }
                }
            }

            Self.logChatOrder("after-non-incremental-process(pre-sort)", session.chatItems)

            removeAxSyntheticsForArrivingTools(payload: payload, chatItems: &session.chatItems)
            removeCodexStreamSyntheticsForArrivingMessages(payload.messages, chatItems: &session.chatItems)

            session.chatItems.sort { $0.timestamp < $1.timestamp }

            Self.logChatOrder("after-non-incremental-sort", session.chatItems)
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        // Re-read live state before writing back. processFileUpdate has
        // multiple await points (ConversationParser.parse, populateSubagentTools)
        // during which the actor yields and processHookEvent can run, modifying
        // the session's phase or chatItems. Our local `session` copy was taken
        // before the await and still has the old values. Writing it back would
        // silently overwrite the hook-driven changes.
        // Write back ONLY the fields processFileUpdate owns. The local
        // `session` copy was taken before the awaits above, so its phase
        // (and any other hook-driven state) is stale. Writing it back
        // would overwrite concurrent changes from processHookEvent (e.g.,
        // a .waitingForApproval transition). Reading the live session and
        // surgically updating file-sync fields avoids this entirely.
        if var live = sessions[payload.sessionId] {
            // Merge hook-derived chatItems added during the await window.
            let localIds = Set(session.chatItems.map { $0.id })
            let hookItems = live.chatItems.filter { !localIds.contains($0.id) }
            if !hookItems.isEmpty {
                Self.logChatOrder("merge-pre[hookItems=\(hookItems.count)]", session.chatItems)
                session.chatItems.append(contentsOf: hookItems)
                session.chatItems.sort { $0.timestamp < $1.timestamp }
                Self.logChatOrder("merge-post-sort", session.chatItems)
            }

            // Defensive: ensure no duplicate ids survive past this boundary.
            // The merge-in-place + toolTracker.markSeen + existingIds-set
            // dedup paths *should* prevent any duplicate from being created,
            // but a tool block placeholder added by a hook during an await
            // window can race with createChatItem when the local snapshot is
            // stale, and the dedup costs almost nothing. This is the single
            // choke point where chatItems get written back to the actor's
            // published state, so dedup'ing here covers every entry path.
            // SwiftUI's flipped LazyVStack tolerates duplicate ids by
            // reserving phantom space for each occurrence (the chronic
            // "gap" symptom) — keeping ids unique here is what kills the
            // gap permanently.
            session.chatItems = Self.dedupedById(session.chatItems)

            Self.logChatOrder("post-dedup(write-back)", session.chatItems)

            live.conversationInfo = session.conversationInfo
            live.lastActivity = Self.mergedLastActivity(
                current: live.lastActivity,
                info: session.conversationInfo
            )
            live.currentProject = session.currentProject
            live.chatItems = session.chatItems
            live.toolTracker = session.toolTracker
            live.needsClearReconciliation = session.needsClearReconciliation
            live.modelName = session.modelName
            live.totalInputTokens = session.totalInputTokens
            live.totalOutputTokens = session.totalOutputTokens
            live.lastContextTokens = session.lastContextTokens
            applyCodexTranscriptApprovalPhaseIfNeeded(to: &live)
            sessions[payload.sessionId] = live
        } else {
            session.chatItems = Self.dedupedById(session.chatItems)
            applyCodexTranscriptApprovalPhaseIfNeeded(to: &session)
            sessions[payload.sessionId] = session
        }

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )

        // Sidecar lifecycle is tied to JSONL state, not to in-memory
        // chatItems. If the JSONL has a tool_result for a tool we have a
        // pending-permission sidecar for, delete the sidecar — whether
        // or not the chatItem lookup in emitToolCompletionEvents
        // succeeded. This catches the case where a tool was resolved
        // out-of-band (user interrupted via TUI, no socket response,
        // no PostToolUse hook fired) and the chatItem either doesn't
        // exist or was filtered out. Idempotent — delete() no-ops if
        // the file is already gone. Cheap — at most one filesystem
        // remove per completed tool, and only on JSONL update ticks.
        for toolUseId in payload.completedToolIds {
            PendingPermissionStore.delete(
                sessionId: payload.sessionId,
                toolUseId: toolUseId
            )
        }

        publishState()
    }

    /// Populate subagent tools for Task tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .image(let image):
            let itemId = "\(message.id)-image-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .image(image), timestamp: message.timestamp)

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status = initialToolStatus(isCompleted: isCompleted, input: tool.input)

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)

        case .turnDuration(let durationMs):
            let itemId = "\(message.id)-duration-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .turnDuration(seconds: max(1, durationMs / 1000)), timestamp: message.timestamp)

        case .recap(let text):
            let itemId = "\(message.id)-recap-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .recap(text), timestamp: message.timestamp)

        case .compactBoundary(let summary, let preTokens, let trigger):
            let itemId = "\(message.id)-compact-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(
                id: itemId,
                type: .compactBoundary(summary: summary, preTokens: preTokens, trigger: trigger),
                timestamp: message.timestamp
            )

        case .localCommandOutput(let text):
            let itemId = "\(message.id)-local-cmd-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .localCommandOutput(text), timestamp: message.timestamp)
        }
    }

    /// Extract result text from JSONL payload for a tool
    private func extractResultText(toolId: String, from payload: FileUpdatePayload) -> String? {
        guard let parserResult = payload.toolResults[toolId] else { return nil }
        if let stdout = parserResult.stdout, !stdout.isEmpty { return stdout }
        if let stderr = parserResult.stderr, !stderr.isEmpty { return stderr }
        if let content = parserResult.content, !content.isEmpty { return content }
        return nil
    }

    /// Merge tool status: if hook already set .success but JSONL has error/interrupt info, use that
    private func mergeToolStatus(
        existing: ToolStatus,
        toolId: String,
        input: [String: String],
        payload: FileUpdatePayload
    ) -> ToolStatus {
        // If JSONL says completed, ensure status reflects that
        if payload.completedToolIds.contains(toolId) {
            if let parserResult = payload.toolResults[toolId] {
                if parserResult.isInterrupted { return .interrupted }
                if parserResult.isError { return .error }
            }
            return .success
        }
        if isCodexTranscriptApprovalRequest(input: input) {
            return .waitingForApproval
        }
        return existing
    }

    private func initialToolStatus(isCompleted: Bool, input: [String: String]) -> ToolStatus {
        if isCompleted { return .success }
        if isCodexTranscriptApprovalRequest(input: input) { return .waitingForApproval }
        return .running
    }

    private func isCodexTranscriptApprovalRequest(input: [String: String]) -> Bool {
        input["sandbox_permissions"] == "require_escalated"
    }

    private func applyCodexTranscriptApprovalPhaseIfNeeded(to session: inout SessionState) {
        guard session.agentID == .codex,
              session.origin != .codexAppServer,
              !session.phase.isWaitingForApproval,
              let pending = firstPendingTranscriptApproval(in: session.chatItems),
              session.phase.canTransition(to: .waitingForApproval(PermissionContext(
                toolUseId: pending.id,
                toolName: pending.tool.name,
                toolInput: codexToolInput(pending.tool.input),
                receivedAt: pending.timestamp
              ))) else {
            return
        }

        session.setPhase(.waitingForApproval(PermissionContext(
            toolUseId: pending.id,
            toolName: pending.tool.name,
            toolInput: codexToolInput(pending.tool.input),
            receivedAt: pending.timestamp
        )), evidenceSource: .transcriptHeuristic, observedAt: pending.timestamp)
    }

    private func firstPendingTranscriptApproval(
        in items: [ChatHistoryItem]
    ) -> (id: String, tool: ToolCallItem, timestamp: Date)? {
        for item in items {
            guard case .toolCall(let tool) = item.type,
                  tool.status == .waitingForApproval,
                  isCodexTranscriptApprovalRequest(input: tool.input) else {
                continue
            }
            return (item.id, tool, item.timestamp)
        }
        return nil
    }

    private func codexToolInput(_ input: [String: String]) -> [String: AnyCodable] {
        input.mapValues { AnyCodable($0) }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.setPhase(.idle, evidenceSource: .localAction)
        }

        sessions[sessionId] = session
    }

    // MARK: - AX Scrollback Backfill

    /// Synthetic chat item id format for AX-scraped assistant text
    /// injected during the AskUserQuestion JSONL buffering window. The
    /// id is keyed by the bound tool's id so the dedup pass in
    /// `processFileUpdate` can find and remove the synthetic when the
    /// real text + tool_use blocks arrive in the JSONL.
    static func axScrapeItemId(forToolUseId toolUseId: String) -> String {
        "ax-stream-\(toolUseId)"
    }

    /// Read the terminal's full AX scrollback for `session`, extract the
    /// assistant text block immediately preceding the active question
    /// form, and dispatch an `injectScrapedAssistantText` event back
    /// into the actor. Runs off-actor (Task.detached) because the AX
    /// read can take ~1s on a long buffer.
    nonisolated static func scrapeAndInjectAssistantText(session: SessionState, boundToolUseId: String, sessionId: String) async {
        // Editor hosts (Cursor's claude-code extension, etc.) have no
        // terminal pane to AX-scrape. The assistant prelude is in JSONL —
        // the next file-update surfaces it directly into chatItems within
        // a debounce window, no synthetic backfill needed. Skipping the
        // futile AX read also avoids ~100ms of cross-app accessibility
        // calls per AskUserQuestion on Cursor sessions.
        if session.tty == nil {
            return
        }
        let scrollback: String? = TerminalAdapterRegistry.adapter(for: session) is ITermAdapter
            ? ITermModeProbe.readScrollback(for: session)
            : GhosttyModeProbe.readScrollback(for: session)
        guard let scrollback else {
            return
        }
        guard let block = TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: scrollback) else {
            return
        }
        await SessionStore.shared.process(.injectScrapedAssistantText(
            sessionId: sessionId,
            boundToolUseId: boundToolUseId,
            text: block
        ))
    }

    /// Remove AX-scrape synthetic items for any tool_use blocks present
    /// in the incoming payload. Called from both branches of
    /// processFileUpdate so the synthetic disappears the moment the
    /// real JSONL content for its bound tool lands. The real text block
    /// from the same assistant message is appended in the same batch,
    /// so without this dedup the chat history briefly shows both.
    private func removeAxSyntheticsForArrivingTools(payload: FileUpdatePayload, chatItems: inout [ChatHistoryItem]) {
        var arrivingToolIds: Set<String> = []
        for message in payload.messages {
            for block in message.content {
                if case .toolUse(let tool) = block {
                    arrivingToolIds.insert(tool.id)
                }
            }
        }
        guard !arrivingToolIds.isEmpty else { return }
        let removedIds = arrivingToolIds.map { Self.axScrapeItemId(forToolUseId: $0) }
        let before = chatItems.count
        chatItems.removeAll { item in removedIds.contains(item.id) }
        let removed = before - chatItems.count
        if removed > 0 {
            Self.logger.info("ax-scrape: removed \(removed, privacy: .public) synthetic(s) after JSONL flush")
        }
    }

    private func processScrapedAssistantText(sessionId: String, boundToolUseId: String, text: String) {
        guard var session = sessions[sessionId] else { return }

        let syntheticId = Self.axScrapeItemId(forToolUseId: boundToolUseId)

        // If we already injected a synthetic for this tool, skip — the
        // scrape may fire twice if PreToolUse arrives on two paths.
        guard !session.chatItems.contains(where: { $0.id == syntheticId }) else {
            return
        }

        // If JSONL has already caught up and the real text item is in
        // chatItems, skip to avoid duplication. We detect this loosely:
        // any .assistant item whose body shares the first 80 chars with
        // our scraped text counts as the same content.
        let prefix = String(text.prefix(80))
        let alreadyPresent = session.chatItems.contains { item in
            if case .assistant(let body) = item.type {
                return body.hasPrefix(prefix)
            }
            return false
        }
        if alreadyPresent {
            Self.logger.debug("ax-scrape: JSONL already has matching text for \(boundToolUseId.prefix(12), privacy: .public), skipping inject")
            return
        }

        // Anchor the synthetic to render just before the bound tool.
        // The tool's placeholder timestamp is Date() at hook fire; use
        // 1ms earlier so the timestamp sort places this above it.
        let toolTimestamp = session.chatItems.first(where: { $0.id == boundToolUseId })?.timestamp ?? Date()
        let syntheticTimestamp = toolTimestamp.addingTimeInterval(-0.001)

        let synthetic = ChatHistoryItem(
            id: syntheticId,
            type: .assistant(text),
            timestamp: syntheticTimestamp
        )
        session.chatItems.append(synthetic)
        session.chatItems.sort { $0.timestamp < $1.timestamp }
        sessions[sessionId] = session

        Self.logger.info("ax-scrape: injected \(text.count, privacy: .public) chars for \(boundToolUseId.prefix(12), privacy: .public)")
    }

    private func processCodexAssistantDelta(sessionId: String, itemId: String, delta: String) {
        guard !delta.isEmpty,
              var session = sessions[sessionId] else {
            return
        }

        let syntheticId = CodexAssistantDeltaNotification.syntheticItemId(for: itemId)
        let now = Date()
        let text: String

        if let idx = session.chatItems.firstIndex(where: { $0.id == syntheticId }),
           case .assistant(let existing) = session.chatItems[idx].type {
            text = existing + delta
            session.chatItems[idx] = ChatHistoryItem(
                id: syntheticId,
                type: .assistant(text),
                timestamp: session.chatItems[idx].timestamp
            )
        } else {
            text = delta
            session.chatItems.append(ChatHistoryItem(
                id: syntheticId,
                type: .assistant(text),
                timestamp: now
            ))
            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.lastActivity = now
        session.conversationInfo = Self.conversationInfo(
            session.conversationInfo,
            applyingAssistantText: text,
            at: now
        )
        sessions[sessionId] = session
    }

    private func processCodexUserMessage(
        sessionId: String,
        itemId: String,
        text: String,
        images: [ChatImageAttachment]
    ) {
        guard var session = sessions[sessionId] else {
            return
        }

        let syntheticId = CodexTurnUserMessageNotification.syntheticItemId(for: itemId)
        let now = Date()
        let visibleText = CodexUserMessageText.visibleText(
            raw: text,
            imageCount: images.count,
            includeImagePlaceholder: false
        ) ?? ""
        guard !visibleText.isEmpty || !images.isEmpty else { return }

        if !visibleText.isEmpty,
           !session.chatItems.contains(where: { $0.id == syntheticId }) {
            session.chatItems.append(ChatHistoryItem(
                id: syntheticId,
                type: .user(visibleText),
                timestamp: now
            ))
        }
        for (index, image) in images.enumerated() {
            let imageId = "\(syntheticId)-image-\(index)"
            guard !session.chatItems.contains(where: { $0.id == imageId }) else { continue }
            session.chatItems.append(ChatHistoryItem(
                id: imageId,
                type: .image(image),
                timestamp: now
            ))
        }
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        session.lastActivity = now
        let preview = visibleText.isEmpty ? "[Image]" : visibleText
        session.conversationInfo = Self.conversationInfo(
            session.conversationInfo,
            applyingUserText: preview,
            at: now
        )
        sessions[sessionId] = session
    }

    private static func conversationInfo(
        _ info: ConversationInfo,
        applyingAssistantText text: String,
        at date: Date
    ) -> ConversationInfo {
        ConversationInfo(
            summary: info.summary,
            lastMessage: text,
            lastMessageRole: "assistant",
            lastToolName: nil,
            firstUserMessage: info.firstUserMessage,
            lastUserMessageDate: info.lastUserMessageDate,
            lastActivityDate: date,
            lastCwd: info.lastCwd,
            customTitle: info.customTitle,
            lastModelName: info.lastModelName,
            lastContextTokens: info.lastContextTokens,
            lastContextWindowTokens: info.lastContextWindowTokens,
            lastEffortLevel: info.lastEffortLevel,
            lastPermissionMode: info.lastPermissionMode,
            lastCodexApprovalPolicy: info.lastCodexApprovalPolicy,
            lastCodexSandboxPolicyType: info.lastCodexSandboxPolicyType
        )
    }

    private static func conversationInfo(
        _ info: ConversationInfo,
        applyingUserText text: String,
        at date: Date
    ) -> ConversationInfo {
        ConversationInfo(
            summary: info.summary,
            lastMessage: text,
            lastMessageRole: "user",
            lastToolName: nil,
            firstUserMessage: (info.firstUserMessage?.isEmpty == false) ? info.firstUserMessage : text,
            lastUserMessageDate: date,
            lastActivityDate: date,
            lastCwd: info.lastCwd,
            customTitle: info.customTitle,
            lastModelName: info.lastModelName,
            lastContextTokens: info.lastContextTokens,
            lastContextWindowTokens: info.lastContextWindowTokens,
            lastEffortLevel: info.lastEffortLevel,
            lastPermissionMode: info.lastPermissionMode,
            lastCodexApprovalPolicy: info.lastCodexApprovalPolicy,
            lastCodexSandboxPolicyType: info.lastCodexSandboxPolicyType
        )
    }

    private static func preserveCodexSyntheticUserInfo(
        _ incoming: ConversationInfo,
        previous: ConversationInfo,
        chatItems: [ChatHistoryItem]
    ) -> ConversationInfo {
        let syntheticUserCandidates = chatItems.reversed().compactMap { item -> String? in
            guard item.id.hasPrefix("codex-stream-user-") else { return nil }
            switch item.type {
            case .user(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .image:
                return "[Image]"
            case .assistant, .toolCall, .thinking, .interrupted, .turnDuration, .recap,
                 .compactBoundary, .localCommandOutput:
                return nil
            }
        }
        let syntheticUserText = syntheticUserCandidates.first { $0 != "[Image]" }
            ?? syntheticUserCandidates.first
        guard let syntheticUserText else {
            return incoming
        }

        let firstUserMessage = (incoming.firstUserMessage?.isEmpty == false)
            ? incoming.firstUserMessage
            : previous.firstUserMessage ?? syntheticUserText
        let lastMessage = incoming.lastMessage
            ?? previous.lastMessage
            ?? syntheticUserText

        return ConversationInfo(
            summary: incoming.summary,
            lastMessage: lastMessage,
            lastMessageRole: incoming.lastMessageRole ?? previous.lastMessageRole,
            lastToolName: incoming.lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: incoming.lastUserMessageDate ?? previous.lastUserMessageDate,
            lastActivityDate: incoming.lastActivityDate ?? previous.lastActivityDate,
            lastCwd: incoming.lastCwd ?? previous.lastCwd,
            customTitle: incoming.customTitle ?? previous.customTitle,
            lastModelName: incoming.lastModelName ?? previous.lastModelName,
            lastContextTokens: incoming.lastContextTokens ?? previous.lastContextTokens,
            lastContextWindowTokens: incoming.lastContextWindowTokens ?? previous.lastContextWindowTokens,
            lastEffortLevel: incoming.lastEffortLevel ?? previous.lastEffortLevel,
            lastPermissionMode: incoming.lastPermissionMode ?? previous.lastPermissionMode,
            lastCodexApprovalPolicy: incoming.lastCodexApprovalPolicy ?? previous.lastCodexApprovalPolicy,
            lastCodexSandboxPolicyType: incoming.lastCodexSandboxPolicyType ?? previous.lastCodexSandboxPolicyType
        )
    }

    private func removeCodexStreamSyntheticsForArrivingMessages(
        _ messages: [ChatMessage],
        chatItems: inout [ChatHistoryItem]
    ) {
        var arrivingSyntheticIds = Set<String>()
        var arrivingAssistantTexts: [String] = []
        var arrivingUserTexts: [String] = []
        var arrivingUserImages: [String] = []

        for message in messages {
            switch message.role {
            case .assistant:
                arrivingSyntheticIds.insert(
                    CodexAssistantDeltaNotification.syntheticItemId(for: message.id)
                )
                for block in message.content {
                    if case .text(let text) = block, !text.isEmpty {
                        arrivingAssistantTexts.append(text)
                    }
                }
            case .user:
                arrivingSyntheticIds.insert(
                    CodexTurnUserMessageNotification.syntheticItemId(for: message.id)
                )
                let text = message.textContent
                if !text.isEmpty {
                    arrivingUserTexts.append(text)
                }
                for block in message.content {
                    if case .image(let image) = block {
                        arrivingUserImages.append(image.value)
                    }
                }
            case .system:
                break
            }
        }

        guard !arrivingSyntheticIds.isEmpty || !arrivingAssistantTexts.isEmpty
            || !arrivingUserTexts.isEmpty || !arrivingUserImages.isEmpty else {
            return
        }

        let before = chatItems.count
        chatItems.removeAll { item in
            guard item.id.hasPrefix("codex-stream-") else { return false }
            if arrivingSyntheticIds.contains(item.id) { return true }
            switch item.type {
            case .assistant(let syntheticText):
                return Self.textsContainSharedPrefix(syntheticText, arrivingAssistantTexts)
            case .user(let syntheticText):
                let visibleSynthetic = CodexUserMessageText.visibleText(raw: syntheticText, imageCount: 0)
                    ?? syntheticText
                return Self.textsContainSharedPrefix(visibleSynthetic, arrivingUserTexts)
            case .image(let syntheticImage):
                return arrivingUserImages.contains(syntheticImage.value)
            case .toolCall, .thinking, .interrupted, .turnDuration, .recap, .compactBoundary, .localCommandOutput:
                return false
            }
        }

        let removed = before - chatItems.count
        if removed > 0 {
            Self.logger.info("codex-stream: removed \(removed, privacy: .public) synthetic assistant item(s) after JSONL replay")
        }
    }

    private static func textsContainSharedPrefix(_ syntheticText: String, _ realTexts: [String]) -> Bool {
        let syntheticPrefix = String(syntheticText.prefix(80))
        guard !syntheticPrefix.isEmpty else { return false }
        return realTexts.contains { realText in
            let realPrefix = String(realText.prefix(80))
            guard !realPrefix.isEmpty else { return false }
            return realText.hasPrefix(syntheticPrefix) || syntheticText.hasPrefix(realPrefix)
        }
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        // Mark ended but DO NOT remove. The user can still browse the
        // chat history, send a message (which fails fast if the TTY is
        // gone), or — for codex/cursor whose session ids persist across
        // restarts of the cli — re-attach later.
        setSessionPhase(sessionId, .ended, evidenceSource: .hook)
        cancelPendingSync(sessionId: sessionId)
        publishState()
        // Capture the agent id off the actor so the MainActor closure
        // doesn't have to reach back across actor boundaries.
        let agent = sessions[sessionId]?.agentID
        // Drop transient drafts: composed-but-unsent text and unsubmitted
        // AskUserQuestion answers should not survive a session end. The
        // chat-history transcript persists on disk regardless.
        await MainActor.run {
            DraftStore.shared.clear(sessionId: sessionId)
            AskUserQuestionDraftStore.shared.clear(sessionId: sessionId)
            // For claude-code, the JSONL is final — stop the watcher to
            // free the file descriptor. Codex/cursor transcripts can
            // grow if the user re-runs the same session id, so keep the
            // watcher live for them.
            if agent == .claudeCode {
                SessionFileWatcherManager.shared.stopWatching(sessionId: sessionId)
            }
        }
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        let startedAt = Date()
        let agentID = sessions[sessionId]?.agentID ?? .claudeCode
        guard let provider = AgentRegistry.provider(for: agentID) else { return }

        let parsed = await provider.loadFullHistory(sessionId: sessionId, cwd: cwd)

        // claude-code threads JSONL `permission-mode` lines through
        // `applyModeUpdate` to reconcile against optimistic cycles.
        // Other agents have no permission-mode lines; skip entirely
        // (their providers return `currentPermissionMode = nil` and we
        // mustn't clobber any stored mode for them).
        if agentID == .claudeCode {
            let cycledDuringLoad = userCycleTimestamps[sessionId].map { $0 > startedAt } ?? false
            if !cycledDuringLoad {
                if let mode = parsed.currentPermissionMode {
                    lastAppliedJsonlMode[sessionId] = mode
                }
                applyModeUpdate(sessionId: sessionId, mode: parsed.currentPermissionMode, source: "history")
            } else {
                Self.logger.info("history mode skipped: user cycled during load for \(sessionId.prefix(8), privacy: .public)")
            }
        }

        await process(.historyLoaded(
            sessionId: sessionId,
            messages: parsed.messages,
            completedTools: parsed.completedToolIds,
            toolResults: parsed.toolResults,
            structuredResults: parsed.structuredResults,
            conversationInfo: parsed.conversationInfo
        ))
        debugLog("[LoadHistory] agent=\(agentID) sid=\(sessionId.prefix(8)) parsed=\(parsed.messages.count) chatItems=\(sessions[sessionId]?.chatItems.count ?? -1)")
    }

    /// Optimistically set a session's permissionMode in advance of the
    /// JSONL signal. Called by the cycler immediately after triggering a
    /// Shift+Tab so the chip updates without waiting for Claude Code's
    /// snapshot. The next JSONL `permission-mode` line will reconcile.
    /// Stamps a "user just cycled" timestamp so the AX probe can avoid
    /// overriding the prediction with stale labels from Ghostty's
    /// scrollback (Claude Code prints no label when transitioning to
    /// default, so the probe can mistake an old "auto mode on" line for
    /// the current mode).
    func applyOptimisticMode(sessionId: String, mode: String) {
        userCycleTimestamps[sessionId] = Date()
        applyModeUpdate(sessionId: sessionId, mode: mode, source: "optimistic")
    }

    /// Re-anchor the cycle timestamp to "now". Called by the cycler
    /// right after the keystroke is posted to Ghostty. The AX dance
    /// before the keystroke can take 1+ seconds; without this, probe
    /// ticks that start *during* the AX dance would only have to beat
    /// the original applyOptimisticMode timestamp to be accepted, even
    /// though Ghostty's TUI hasn't seen the keystroke yet.
    func markCycleTimestamp(sessionId: String) {
        userCycleTimestamps[sessionId] = Date()
    }

    /// Apply a mode discovered by the AX probe. Suppressed for a few
    /// seconds after a user-initiated cycle, because the probe's tail
    /// can still contain the prior mode's label and would otherwise
    /// flip the chip back.
    func applyProbedMode(sessionId: String, mode: String, startedAt: Date) {
        // Reject if a cycle happened *after* the probe started reading.
        // The probe was holding a snapshot from before the cycle, so its
        // value is stale even though it's only just being applied now.
        if let cycleAt = userCycleTimestamps[sessionId], cycleAt > startedAt {
            Self.logger.info("probe rejected: cycle newer than probe start for \(sessionId.prefix(8), privacy: .public)")
            return
        }
        // Backstop: a probe that started after the cycle can still read
        // stale text if Ghostty's TUI hasn't redrawn the new mode label
        // yet. Suppress for a short window after every cycle.
        if let cycleAt = userCycleTimestamps[sessionId],
           Date().timeIntervalSince(cycleAt) < probeSuppressionWindow {
            return
        }
        applyModeUpdate(sessionId: sessionId, mode: mode, source: "probe")
    }

    /// Window during which a user-initiated cycle is authoritative and
    /// non-cycle sources (probe, JSONL) are ignored. Long enough to
    /// cover the keystroke-to-redraw latency we observed (~700 ms from
    /// press to the AX cycle log line). A probe that *starts reading*
    /// during this window is still suppressed; a probe that started
    /// before the cycle is rejected by the start-time check instead.
    private let probeSuppressionWindow: TimeInterval = 0.8
    private var userCycleTimestamps: [String: Date] = [:]

    /// Last `permission-mode` value applied from JSONL per session.
    /// Used by the file-sync path to skip redundant re-applications:
    /// JSONL only writes mode lines on prompt submission, but file-sync
    /// fires on every JSONL extend (Claude Code streaming output). Each
    /// fire would otherwise re-apply the same stale mode value and
    /// flip the chip back from an in-flight optimistic update.
    private var lastAppliedJsonlMode: [String: String] = [:]

    /// File-sync path: apply a JSONL-derived mode only when it differs
    /// from the last value we applied from JSONL for this session. The
    /// optimistic/probe paths can have set the chip to a newer value
    /// that JSONL hasn't caught up to yet (Claude Code only writes
    /// permission-mode lines on prompt submission); re-applying the
    /// same old JSONL value on every file extend would clobber that.
    private func applyJsonlModeIfNew(sessionId: String, mode: String?) {
        guard let mode = mode else { return }
        guard lastAppliedJsonlMode[sessionId] != mode else { return }
        // Don't clobber an in-flight optimistic update with a JSONL
        // value that may not have caught up yet.
        if let cycleAt = userCycleTimestamps[sessionId],
           Date().timeIntervalSince(cycleAt) < probeSuppressionWindow {
            return
        }
        lastAppliedJsonlMode[sessionId] = mode
        applyModeUpdate(sessionId: sessionId, mode: mode, source: "jsonl")
    }

    /// Surgically update a session's permissionMode without touching other
    /// fields. Called from the cycler (optimistic), the AX probe, the
    /// file-sync path, and the history-load path.
    private func applyModeUpdate(sessionId: String, mode: String?, source: String = "?") {
        guard var session = sessions[sessionId] else { return }
        let oldMode = session.permissionMode
        guard oldMode != mode else { return }
        Self.logger.info("apply mode \(oldMode ?? "nil", privacy: .public) → \(mode ?? "nil", privacy: .public) src=\(source, privacy: .public) for \(sessionId.prefix(8), privacy: .public)")

        session.permissionMode = mode
        sessions[sessionId] = session
        publishState()
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = Self.preserveCodexSyntheticUserInfo(
            conversationInfo,
            previous: session.conversationInfo,
            chatItems: session.chatItems
        )
        session.lastActivity = Self.mergedLastActivity(
            current: session.lastActivity,
            info: session.conversationInfo
        )

        // Aggregate model and token usage from all messages. Walk in order so
        // a compact_boundary resets lastContextTokens; later assistant turns
        // then overwrite it with the post-compact size. If /compact is the
        // last thing in the transcript, the bar shows 0% — matching the TUI.
        session.totalInputTokens = 0
        session.totalOutputTokens = 0
        session.lastContextTokens = 0
        for message in messages {
            if message.content.contains(where: { if case .compactBoundary = $0 { return true } else { return false } }) {
                session.lastContextTokens = 0
                continue
            }
            guard message.role == .assistant else { continue }
            if let model = message.model, !model.hasPrefix("<") {
                session.modelName = model
            }
            let context = (message.inputTokens ?? 0)
                + (message.cacheReadTokens ?? 0)
                + (message.cacheCreationTokens ?? 0)
            session.totalInputTokens += context
            session.totalOutputTokens += (message.outputTokens ?? 0)
            if context > 0 {
                session.lastContextTokens = context
            }
        }
        applyConversationMetadata(session.conversationInfo, to: &session)

        // Update currentProject from the latest cwd in the JSONL
        if let lastCwd = conversationInfo.lastCwd {
            let lastComponent = ProjectDisplayNamePolicy.displayName(forCwd: lastCwd)
                ?? URL(fileURLWithPath: lastCwd).lastPathComponent
            if lastComponent != session.projectName && !lastComponent.isEmpty {
                session.currentProject = lastComponent
            }
        }

        // Convert messages to chat items. existingIds is mutable so duplicate
        // ids generated within the same JSONL replay don't both pass the
        // createChatItem guard (see fileUpdated for the failure mode).
        var existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                    existingIds.insert(item.id)
                }
            }
        }

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }
        removeCodexStreamSyntheticsForArrivingMessages(messages, chatItems: &session.chatItems)

        // Final dedup at the loadHistory write boundary — same rationale
        // as the processFileUpdate merge dedup above.
        session.chatItems = Self.dedupedById(session.chatItems)

        // NOTE: a prior attempt at "recover pending AskUserQuestion on
        // history-load by scanning chatItems for a .running tool" lived
        // here and was reverted. It was structurally wrong:
        //   1. claude-code buffers an entire pending assistant turn (text +
        //      tool_use) in process memory until the tool resolves. While a
        //      question is pending the tool_use is NOT in JSONL, so the
        //      scan finds nothing for the actual repro case.
        //   2. Pre-existing cache staleness can leave already-completed
        //      tools with status .running in chatItems on first reload (a
        //      tail-parse delta that arrives after the cache offset can
        //      lose a tool_result for an id whose tool_use was already
        //      cached). A scan that trusts chatItems status would then
        //      fire on stale, already-answered tools and synthesise a
        //      phantom .waitingForApproval phase.
        // The correct fix is a sidecar file persisted by HookSocketServer
        // when PermissionRequest arrives, replayed as a synthetic hook
        // event on startup. Tracked separately.

        sessions[sessionId] = session

        // Observed (hookless) agents derive phase from the transcript we
        // just parsed: codex GUI from its task marker, cursor from
        // last-role + quiescence. No-op for hooked agents (claude-code,
        // codex CLI, zed-claude), whose phase comes from hook events.
        _ = await applyInferredObservedPhase(sessionId: sessionId)
    }

    // MARK: - Transcript-driven phase (observed/hookless agents)

    /// Observed agents have no hook seam, so their phase is inferred from
    /// transcript shape instead of reported. Codex.app GUI threads
    /// (`tty == nil`) and all cursor sessions qualify; everything else
    /// (claude-code, codex CLI, zed-claude) reports phase via hooks.
    private func usesTranscriptPhaseInference(_ s: SessionState) -> Bool {
        switch s.agentID {
        case .codex:
            // Split by surface:
            //   - CLI (tty != nil) reliably fires ~/.codex/hooks.json for
            //     every turn boundary, so hooks stay authoritative there and
            //     the transcript marker (which can't distinguish "processing"
            //     from "awaiting approval") doesn't fight them.
            //   - Codex.app GUI threads (tty == nil) do NOT re-fire turn hooks
            //     for every internal turn-state change, so a thread still
            //     working would sit on a stale .waitingForInput from an earlier
            //     Stop hook (the reported "Codex working / Agent Visor finished"
            //     desync). The rollout's task_started/task_complete marker is
            //     the authoritative live signal for those, and
            //     `applyInferredObservedPhase` guards against clobbering a
            //     hook-set .waitingForApproval — so inference and the approval
            //     hook coexist instead of oscillating.
            return s.tty == nil
        case .cursor:
            // Cursor IDE has no hook seam — transcript shape is the only signal.
            return true
        default:
            return false
        }
    }

    private func observedLastEntryRole(_ s: SessionState) -> LastEntryRole {
        switch s.lastMessageRole {
        case "user":      return .user
        case "assistant": return .assistant
        case "tool":      return .tool
        default:          return .none
        }
    }

    /// Infer and apply a phase for one observed session. Codex uses the
    /// cached task marker (authoritative, set on every rollout parse);
    /// cursor falls back to last-role + file quiescence. Only ever moves
    /// between processing / waitingForInput (never forces idle or ended,
    /// and respects the phase state machine).
    private func applyInferredObservedPhase(sessionId: String) async -> Bool {
        guard var session = sessions[sessionId],
              usesTranscriptPhaseInference(session),
              session.phase != .ended else { return false }

        guard let provider = AgentRegistry.provider(for: session.agentID) else { return false }
        let transcriptPath = provider.transcriptURL(
            sessionId: sessionId,
            cwd: session.cwd
        ).path
        guard let transcriptModifiedAt =
            (try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.modificationDate]
                as? Date
        else {
            return false
        }

        // Codex marker: prefer the full-parse cache (populated when the chat
        // is open), but fall back to a fresh head+tail summary parse for
        // BACKGROUND threads that were never opened this run. Without this
        // refresh the marker stays `.none` after launch — the reconcile timer
        // would then never see a running thread's `task_started` and a live
        // GUI thread would sit on a stale `waitingForInput`. The summary parse
        // is signature-cached (mtime+size), so it's a no-op when the rollout
        // hasn't grown since the last read.
        var marker: TurnMarker = .none
        if session.agentID == .codex {
            marker = await CodexConversationParser.shared.lastTurnMarker(for: sessionId)
            if marker == .none {
                _ = await CodexConversationSummary.shared.parse(
                    sessionId: sessionId,
                    rolloutPath: transcriptPath
                )
                marker = await CodexConversationSummary.shared.lastTurnMarker(for: sessionId)
            }
        }

        // Quiescence (seconds since the transcript was last written) gates
        // staleness on BOTH paths now: the heuristic (no-marker) one AND
        // codex's marker path, so a long-dormant completed thread infers
        // .idle instead of "your turn". Computed from transcript mtime.
        let quiescent = max(0, Date().timeIntervalSince(transcriptModifiedAt))

        let inferred = TranscriptPhaseInferrer.infer(
            turnMarker: marker,
            lastEntryRole: observedLastEntryRole(session),
            quiescentSeconds: quiescent
        )
        let evidenceSource: SessionPhaseEvidenceSource = marker == .none
            ? .transcriptHeuristic
            : .transcriptMarker

        guard ObservedApprovalRecoveryPolicy.shouldApply(
            currentPhaseIsWaitingForApproval: session.phase.isWaitingForApproval,
            inferredPhase: inferred
        ) else {
            return false
        }

        let newPhase: SessionPhase
        switch inferred {
        case .processing:      newPhase = .processing
        case .waitingForInput: newPhase = .waitingForInput
        case .idle:
            // Inference says dormant (e.g. a completed Codex thread quiet
            // past the stale ceiling, or one whose rollout was archived).
            // For observed agents this is the ONLY signal that clears an
            // active phase — there's no hook and no process-death event —
            // so it must be able to pull a stuck `.processing` /
            // `.waitingForInput` down to `.idle`. (Previously this was a
            // no-op, which pinned a thread on a transiently-seeded
            // "processing" forever: the green "running" pill the user saw
            // on long-finished threads.) Only clear genuinely-active
            // phases; leave everything else alone.
            let active = session.phase == .processing || session.phase == .waitingForInput
            guard ObservedIdleClearPolicy.shouldClear(currentPhaseIsActive: active) else {
                let evidenceChanged = session.markPhaseEvidence(
                    evidenceSource,
                    observedAt: transcriptModifiedAt
                )
                sessions[sessionId] = session
                return evidenceChanged
            }
            newPhase = .idle
        }

        guard session.phase != newPhase else {
            let evidenceChanged = session.markPhaseEvidence(
                evidenceSource,
                observedAt: transcriptModifiedAt
            )
            sessions[sessionId] = session
            return evidenceChanged
        }
        guard session.phase.canTransition(to: newPhase) else { return false }
        AgentDiscoveryUtilities.writeLog(
            "[Phase] \(session.agentID.rawValue) \(sessionId.prefix(8)) -> \(inferred) (marker=\(marker) quiescent=\(Int(quiescent))s)"
        )
        session.setPhase(
            newPhase,
            evidenceSource: evidenceSource,
            observedAt: transcriptModifiedAt
        )
        sessions[sessionId] = session
        return true
    }

    /// Periodic re-evaluation of observed sessions. Catches the cursor
    /// quiescence flip (processing → waitingForInput once the transcript
    /// goes quiet) that no file event can trigger — there's no event for
    /// "the file stopped changing." Cheap: a dict scan plus one stat per
    /// cursor session; codex re-reads only its cached marker.
    func reconcileObservedPhases() async {
        let observedIds = sessions.compactMap { id, session in
            usesTranscriptPhaseInference(session) && session.phase != .ended ? id : nil
        }
        var didChange = false
        for sessionId in observedIds {
            if await applyInferredObservedPhase(sessionId: sessionId) {
                didChange = true
            }
        }
        if didChange {
            publishState()
        }
    }

    private func reconcileHookReadyFreshness(now: Date = Date()) {
        var didChange = false
        for sessionId in Array(sessions.keys) {
            guard var session = sessions[sessionId] else { continue }
            let observedAt = session.phaseObservedAt ?? session.phaseChangedAt
            guard HookReadyExpirationPolicy.shouldExpire(
                isWaitingForInput: session.phase == .waitingForInput,
                hasHookEvidence: session.phaseEvidenceSource == .hook,
                observedAt: observedAt.timeIntervalSince1970,
                now: now.timeIntervalSince1970
            ), session.phase.canTransition(to: .idle) else { continue }

            session.setPhase(.idle, evidenceSource: .rediscovery, observedAt: now)
            sessions[sessionId] = session
            didChange = true
            AgentDiscoveryUtilities.writeLog(
                "[Phase] \(session.agentID.rawValue) \(sessionId.prefix(8)) -> idle (stale hook ready)"
            )
        }
        if didChange {
            publishState()
        }
    }

    /// Stable-order dedup by `ChatHistoryItem.id`. Keeps the first occurrence
    /// of each id and drops subsequent duplicates. Called from every choke
    /// point that writes `session.chatItems` back to the actor's published
    /// state, so SwiftUI's flipped LazyVStack never sees duplicate ids
    /// (which would otherwise reserve phantom layout space for each
    /// repeated id and produce visible row gaps).
    private static func dedupedById(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String) {
        cancelPendingSync(sessionId: sessionId)
        let agentID = sessions[sessionId]?.agentID ?? .claudeCode
        guard let provider = AgentRegistry.provider(for: agentID) else { return }

        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            if agentID == .codex {
                let mode = await self?.codexFileSyncMode(sessionId: sessionId)
                await self?.refreshCodexMetadataBeforeFullReplay(sessionId: sessionId, cwd: cwd, provider: provider)
                if mode == .metadataOnly {
                    return
                }
            }

            switch await provider.fileSync(sessionId: sessionId, cwd: cwd) {
            case .fullReplay(let parsed):
                // Codex / cursor: no incremental parser, full reparse
                // every tick. Same shape as bootstrap → historyLoaded.
                await self?.process(.historyLoaded(
                    sessionId: sessionId,
                    messages: parsed.messages,
                    completedTools: parsed.completedToolIds,
                    toolResults: parsed.toolResults,
                    structuredResults: parsed.structuredResults,
                    conversationInfo: parsed.conversationInfo
                ))

            case .incremental(let result):
                // claude-code's delta path. Mode may change without
                // producing a ChatMessage (a `permission-mode` line on
                // its own); propagate before the early-return below
                // so the chip updates. File extends fire constantly
                // during streaming, and re-applying a stale JSONL mode
                // would flip the chip from any in-flight optimistic /
                // probe value — `applyJsonlModeIfNew` guards on the
                // *new value* check.
                await self?.applyJsonlModeIfNew(sessionId: sessionId, mode: result.currentPermissionMode)

                if result.clearDetected {
                    await self?.process(.clearDetected(sessionId: sessionId))
                }

                guard !result.newMessages.isEmpty || result.clearDetected else {
                    return
                }

                let payload = FileUpdatePayload(
                    sessionId: sessionId,
                    cwd: cwd,
                    messages: result.newMessages,
                    isIncremental: !result.clearDetected,
                    completedToolIds: result.completedToolIds,
                    toolResults: result.toolResults,
                    structuredResults: result.structuredResults
                )

                await self?.process(.fileUpdated(payload))
            }
        }
    }

    private func refreshCodexMetadataBeforeFullReplay(
        sessionId: String,
        cwd: String,
        provider: any AgentProvider
    ) async {
        let info = await provider.loadConversationInfo(sessionId: sessionId, cwd: cwd)
        await applyMetadataOnlyConversationInfo(sessionId: sessionId, info: info)
    }

    private func codexFileSyncMode(sessionId: String) -> CodexFileSyncMode? {
        guard let session = sessions[sessionId],
              session.agentID == .codex else { return nil }
        return CodexFileSyncPolicy.mode(
            isAgentVisorOwned: session.origin == .codexAppServer,
            hasRenderedChatItems: !session.chatItems.isEmpty
        )
    }

    private func applyMetadataOnlyConversationInfo(sessionId: String, info: ConversationInfo) async {
        guard var session = sessions[sessionId] else { return }
        let merged = Self.preserveCodexSyntheticUserInfo(
            info,
            previous: session.conversationInfo,
            chatItems: session.chatItems
        )
        session.conversationInfo = merged
        session.lastActivity = Self.mergedLastActivity(
            current: session.lastActivity,
            info: merged
        )
        if let lastCwd = merged.lastCwd {
            let lastComponent = ProjectDisplayNamePolicy.displayName(forCwd: lastCwd)
                ?? URL(fileURLWithPath: lastCwd).lastPathComponent
            if lastComponent != session.projectName && !lastComponent.isEmpty {
                session.currentProject = lastComponent
            }
        }
        applyConversationMetadata(merged, to: &session)
        sessions[sessionId] = session

        if session.agentID == .codex {
            let marker = await CodexConversationSummary.shared.lastTurnMarker(for: sessionId)
            await CodexConversationParser.shared.updateLastTurnMarker(
                sessionId: sessionId,
                marker: marker
            )
        }
        _ = await applyInferredObservedPhase(sessionId: sessionId)
        publishState()
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    /// Read-only access to a session by ID.
    func getSession(id: String) -> SessionState? {
        sessions[id]
    }

    func refreshSessionNames(agentID: AgentID) {
        guard let provider = AgentRegistry.provider(for: agentID) else { return }
        let matchingSessions = sessions.values.filter { $0.agentID == agentID }
        guard !matchingSessions.isEmpty else { return }

        var resolvedNames: [String: String] = [:]
        let candidates = matchingSessions.map { session in
            if let name = provider.resolveSessionName(sessionId: session.sessionId, pid: session.pid) {
                resolvedNames[session.sessionId] = name
            }
            return SessionNameRefreshCandidate(
                sessionId: session.sessionId,
                currentName: session.sessionName
            )
        }

        let changes = SessionNameRefreshPlanner.changes(
            candidates: candidates,
            resolvedNames: resolvedNames
        )
        guard !changes.isEmpty else { return }

        for change in changes {
            sessions[change.sessionId]?.sessionName = change.name
        }
        publishState()
    }

    func refreshCodexMetadata() {
        refreshSessionNames(agentID: .codex)
        pruneDeadSessions()
    }

    func refreshCodexMetadataAfterExternalChange() async {
        let now = Date()
        let snapshot = currentCodexDiscoverySnapshot(now: now)
        let requiresRediscovery = snapshot.requiresRediscovery(
            comparedTo: lastCodexDiscoverySnapshot
        )
        lastCodexDiscoverySnapshot = snapshot

        let actions = CodexMetadataRefreshPlanner.actionsForMetadataChange(
            now: now,
            lastRediscoveryAt: lastCodexMetadataRediscoveryAt,
            hasScheduledRediscovery: pendingCodexMetadataRediscoveryTask != nil,
            requiresRediscovery: requiresRediscovery
        )
        for action in actions {
            switch action {
            case .refreshKnownSessions:
                refreshCodexMetadata()
            case .rediscoverSessions:
                markCodexMetadataRediscoveryStarted(cancelScheduledTask: true)
                await completeCodexMetadataRediscovery()
            case .scheduleRediscovery(let delay):
                scheduleCodexMetadataRediscovery(after: delay)
            }
        }
    }

    private func scheduleCodexMetadataRediscovery(after delay: TimeInterval) {
        guard pendingCodexMetadataRediscoveryTask == nil else { return }
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        pendingCodexMetadataRediscoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.runScheduledCodexMetadataRediscovery()
        }
    }

    private func runScheduledCodexMetadataRediscovery() async {
        markCodexMetadataRediscoveryStarted(cancelScheduledTask: false)
        await completeCodexMetadataRediscovery()
    }

    private func markCodexMetadataRediscoveryStarted(cancelScheduledTask: Bool) {
        if cancelScheduledTask {
            pendingCodexMetadataRediscoveryTask?.cancel()
        }
        pendingCodexMetadataRediscoveryTask = nil
        lastCodexMetadataRediscoveryAt = Date()
    }

    private func completeCodexMetadataRediscovery() async {
        let rediscovered = await Self.discoverCodexInBackground()
        bootstrapSessions(rediscovered)
        lastCodexDiscoverySnapshot = currentCodexDiscoverySnapshot()
    }

    private func currentCodexDiscoverySnapshot(now: Date = Date()) -> CodexThreadDiscoverySnapshot {
        CodexThreadDiscoverySnapshot.make(
            candidates: CodexThreadStore.liveThreadCandidates(),
            now: Int(now.timeIntervalSince1970),
            windowSeconds: Int(AppSettings.observedWindowSeconds)
        )
    }

    // MARK: - State Publishing

    private func publishState() {
        send(Array(sessions.values))
    }

    /// Single publish boundary. Drops hidden sessions before sending so BOTH
    /// subscribers — the window sidebar (`MainWindowViewModel`) and the
    /// menu-bar pills (`ClaudeSessionMonitor`) — honor the hidden set without
    /// each re-implementing the filter. Sort matches the prior behavior.
    private func send(_ sessionsToPublish: [SessionState]) {
        let visible = hiddenSessionIds.isEmpty
            ? sessionsToPublish
            : sessionsToPublish.filter { !hiddenSessionIds.contains($0.sessionId) }
        sessionsSubject.send(visible.sorted { $0.projectName < $1.projectName })
    }

    // MARK: - User-initiated hide / delete

    enum SessionDeletionError: Error {
        case sessionNotFound
        case notDeletable
        case sessionIsLive
    }

    /// Hide a session from the sidebar + pills (reversible). The row stays in
    /// `sessions` so an unhide is instant; it's just filtered at `send`. The
    /// id is persisted so the ~30s rediscovery can't resurface it and it stays
    /// hidden across relaunch. `title`/`agentRaw` ride along so the settings
    /// "Hidden sessions" list can show a real label.
    func hideSession(id: String, title: String, agentRaw: String) {
        guard sessions[id] != nil else { return }
        MainWindowSettings.hide(id: id, title: title, agentRaw: agentRaw)
        hiddenSessionIds.insert(id)
        publishStateWithoutPrune()
    }

    func unhideSession(id: String) {
        MainWindowSettings.unhide(id: id)
        hiddenSessionIds.remove(id)
        publishStateWithoutPrune()
    }

    /// Permanently delete a session's transcript file. Gated to Claude Code
    /// sessions that are NOT live — deleting a live transcript would leave
    /// `claude` writing to an unlinked fd (corruption) and break `--resume`.
    /// Reuses the prune teardown (watcher stop + pending-sync cancel) and, for
    /// visor-spawned sessions, kills the owned process first. No persistence
    /// needed: the JSONL is gone, so discovery can't re-find it.
    func deleteSessionData(sessionId: String) async throws {
        guard let session = sessions[sessionId] else {
            throw SessionDeletionError.sessionNotFound
        }
        guard session.agentID == .claudeCode else {
            throw SessionDeletionError.notDeletable
        }

        // Liveness gate (mirrors `isLive` in the view model).
        if session.origin == .visorSpawned {
            if await SpawnedSessionManager.shared.isManaged(sessionId) {
                throw SessionDeletionError.sessionIsLive
            }
        } else if let pid = session.pid, pid != 0, kill(Int32(pid), 0) == 0 {
            throw SessionDeletionError.sessionIsLive
        }

        let cwd = session.cwd
        let agentID = session.agentID

        // Teardown — same as the prune path.
        sessions.removeValue(forKey: sessionId)
        cancelPendingSync(sessionId: sessionId)
        hiddenSessionIds.remove(sessionId)
        await MainActor.run {
            SessionFileWatcherManager.shared.stopWatching(sessionId: sessionId)
        }

        // Delete the transcript file.
        if let provider = AgentRegistry.provider(for: agentID) {
            let url = provider.transcriptURL(sessionId: sessionId, cwd: cwd)
            do {
                try FileManager.default.removeItem(at: url)
                Self.logger.info("Deleted transcript \(sessionId.prefix(8), privacy: .public) at \(url.path, privacy: .public)")
            } catch {
                Self.logger.error("Failed to delete transcript \(sessionId.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
                // Already removed from the store + torn down; re-throw so the
                // UI can surface the file-system failure.
                publishStateWithoutPrune()
                throw error
            }
        }

        publishStateWithoutPrune()
    }

    private func setSessionPhase(
        _ sessionId: String,
        _ phase: SessionPhase,
        evidenceSource: SessionPhaseEvidenceSource,
        observedAt: Date = Date()
    ) {
        guard var session = sessions[sessionId] else { return }
        session.setPhase(phase, evidenceSource: evidenceSource, observedAt: observedAt)
        sessions[sessionId] = session
    }

    private func applyClaudeReattachment(
        _ attachment: ClaudeSessionReattachment,
        sessionId: String
    ) {
        guard var session = sessions[sessionId] else { return }

        session.pid = attachment.pid
        session.tty = attachment.tty
        session.terminalHost = attachment.terminalHost
        session.isInTmux = attachment.isInTmux
        switch attachment.origin {
        case .terminal: session.origin = .terminal
        case .cursorObserved: session.origin = .cursorObserved
        case .observed: session.origin = .observed
        }
        if let name = attachment.sessionName, !name.isEmpty {
            session.sessionName = name
        }
        session.lastActivity = Date()
        session.setPhase(.idle, evidenceSource: .rediscovery)
        sessions[sessionId] = session

        let cwd = session.cwd
        let agentID = session.agentID
        Task { @MainActor in
            SessionFileWatcherManager.shared.startWatching(
                sessionId: sessionId,
                cwd: cwd,
                agentID: agentID
            )
        }
    }

    private static func hasTerminalBootstrapMetadataStatus(agentID: AgentID, pid: Int) -> Bool {
        guard agentID == .claudeCode,
              let status = SessionState.readSessionStatus(pid: pid) else {
            return false
        }
        return ClaudeCodeSessionMetadataPolicy.isTerminalStatus(status)
    }

    private static func bootstrapPhase(
        agentID: AgentID,
        pid: Int,
        isHistorical: Bool
    ) -> SessionPhase {
        if hasTerminalBootstrapMetadataStatus(agentID: agentID, pid: pid) {
            return .ended
        }
        return isHistorical ? .ended : .idle
    }

    private static func bootstrapLastActivity(fileDate: Date?, pid: Int, tty: String?) -> Date {
        if let fileDate {
            return fileDate
        }
        if pid != 0, tty != nil {
            return Date()
        }
        return .distantPast
    }

    // MARK: - Stale Session Cleanup

    private var pruneTask: Task<Void, Never>?

    /// Start periodic pruning of dead sessions (every 10 seconds)
    /// Bootstrap discovered sessions (called with results from ClaudeSessionMonitor.discoverExistingSessions)
    func bootstrapSessions(_ discovered: [DiscoveredSession]) {
        guard !discovered.isEmpty else { return }
        debugLog("[Scan] Bootstrapping \(discovered.count) discovered sessions")

        let tree = ProcessTreeBuilder.shared.buildTree()

        // Pre-warm the codex thread list once instead of running a
        // per-id sqlite3 fork in the loop below. `liveThreadCandidates`
        // is a single bounded query (limit 200) cached by `(sql, mtime)`,
        // so subsequent codex bootstraps within the same mtime window
        // pay zero subprocesses.
        let codexThreadsById: [String: CodexThreadCandidate]
        if discovered.contains(where: { $0.agentID == .codex }) {
            let liveCandidates = CodexThreadStore.liveThreadCandidates()
            codexThreadsById = Dictionary(
                uniqueKeysWithValues: liveCandidates.map { ($0.id, $0) }
            )
        } else {
            codexThreadsById = [:]
        }

        for info in discovered {
            // Skip sessions the user hid. Without this, the ~30s rediscovery
            // would re-add a hidden row (its backing files still exist on
            // disk), undoing the hide. Deleted sessions don't need this —
            // their transcript is gone, so discovery can't re-find them.
            if hiddenSessionIds.contains(info.sessionId) {
                continue
            }

            // Discovery uses pid=0 as a sentinel for rows surfaced from
            // disk without a per-session process. For Codex GUI threads
            // that sentinel is still an active observed-app row within
            // the configured window, not historical transcript state.
            let isCodexObservedAppSentinel = info.agentID == .codex && info.tty == nil && info.pid == 0
            let isHistorical = info.pid == 0 && !isCodexObservedAppSentinel
            let bootstrapPhase = Self.bootstrapPhase(
                agentID: info.agentID,
                pid: info.pid,
                isHistorical: isHistorical
            )

            // If the session already exists, normally we skip the
            // bootstrap to preserve in-memory state. Exceptions are
            // app-backed observed sessions whose pid sentinel may flip
            // as the host app starts/stops.
            if let existing = sessions[info.sessionId] {
                if Self.hasTerminalBootstrapMetadataStatus(agentID: info.agentID, pid: info.pid),
                   existing.phase != .ended {
                    setSessionPhase(info.sessionId, .ended, evidenceSource: .rediscovery)
                    if let provider = AgentRegistry.provider(for: existing.agentID),
                       provider.stopsWatchingOnDeath(for: existing) {
                        cancelPendingSync(sessionId: info.sessionId)
                        Task { @MainActor in
                            SessionFileWatcherManager.shared.stopWatching(sessionId: info.sessionId)
                        }
                    }
                }
                if let provider = AgentRegistry.provider(for: info.agentID),
                   let resolvedName = provider.resolveSessionName(
                    sessionId: info.sessionId,
                    pid: info.pid == 0 ? nil : info.pid
                   ),
                   let change = SessionNameRefreshPlanner.changes(
                    candidates: [
                        .init(sessionId: info.sessionId, currentName: existing.sessionName)
                    ],
                    resolvedNames: [
                        info.sessionId: resolvedName
                    ]
                   ).first {
                    sessions[change.sessionId]?.sessionName = change.name
                }
                if info.agentID == .cursor, info.pid != 0,
                   existing.phase == .ended, existing.pid == nil {
                    setSessionPhase(info.sessionId, .idle, evidenceSource: .rediscovery)
                    sessions[info.sessionId]?.pid = info.pid
                }
                if info.agentID == .codex, info.tty == nil {
                    if existing.phase == .ended {
                        setSessionPhase(info.sessionId, .idle, evidenceSource: .rediscovery)
                    }
                    sessions[info.sessionId]?.pid = info.pid == 0 ? nil : info.pid
                    if let rolloutPath = codexThreadsById[info.sessionId]?.rolloutPath,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: rolloutPath),
                       let modDate = attrs[.modificationDate] as? Date,
                       modDate > existing.lastActivity {
                        sessions[info.sessionId]?.lastActivity = modDate
                    }
                    let sessionId = info.sessionId
                    let sessionCwd = info.cwd
                    Task { @MainActor in
                        SessionFileWatcherManager.shared.startWatching(
                            sessionId: sessionId,
                            cwd: sessionCwd,
                            agentID: .codex
                        )
                    }
                }
                // Hook-created sessions can already have a resolved process
                // name while their conversation summary is still empty.
                let needsBootstrapSummary = SessionConversationBackfillPolicy.shouldLoad(
                    sessionName: existing.sessionName,
                    firstUserMessage: existing.conversationInfo.firstUserMessage,
                    lastMessage: existing.conversationInfo.lastMessage
                )
                if needsBootstrapSummary,
                   let provider = AgentRegistry.provider(for: info.agentID) {
                    let sessionId = info.sessionId
                    let sessionCwd = info.cwd
                    Task { [weak self] in
                        let conversationInfo = await provider.loadConversationInfo(
                            sessionId: sessionId, cwd: sessionCwd
                        )
                        await self?.applyBootstrapConversationInfo(
                            sessionId: sessionId,
                            info: conversationInfo
                        )
                    }
                }
                continue
            }

            let cwd = info.cwd
            let codexThread = info.agentID == .codex ? codexThreadsById[info.sessionId] : nil
            let projectName = ProjectDisplayNamePolicy.displayName(forCwd: cwd)
                ?? URL(fileURLWithPath: cwd).lastPathComponent
            debugLog("[Scan] Session: \(info.sessionId.prefix(8)) pid=\(info.pid) tty=\(info.tty ?? "none") cwd=\(cwd)")

            // Codex stores its rollout path in sqlite; everyone else
            // derives the path from sessionId+cwd via the provider.
            let provider = AgentRegistry.provider(for: info.agentID)
            let jsonlPath: String
            if info.agentID == .codex, let path = codexThread?.rolloutPath {
                jsonlPath = path
            } else if let provider {
                jsonlPath = provider.transcriptURL(sessionId: info.sessionId, cwd: cwd).path
            } else {
                jsonlPath = ""
            }
            let fileDate: Date?
            if !jsonlPath.isEmpty,
               let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
               let modDate = attrs[.modificationDate] as? Date {
                fileDate = modDate
            } else {
                fileDate = nil
            }

            let hasProcessBackedPid = info.pid != 0
            let host: TerminalHost
            if info.agentID == .codex, info.tty == nil {
                host = .codexApp
            } else if !hasProcessBackedPid {
                host = .unknown
            } else {
                host = TerminalHostDetector.detect(
                    pid: pid_t(info.pid),
                    reader: LiveProcessInfoReader.shared
                )
            }
            var session = SessionState(
                sessionId: info.sessionId,
                cwd: cwd,
                projectName: projectName,
                agentID: info.agentID,
                origin: SessionStore.originForHostedSession(
                    sessionId: info.sessionId,
                    tty: info.tty,
                    agentID: info.agentID,
                    terminalHost: host
                ),
                pid: hasProcessBackedPid ? info.pid : nil,
                tty: info.tty,
                isInTmux: hasProcessBackedPid ? ProcessTreeBuilder.shared.isInTmux(pid: info.pid, tree: tree) : false,
                terminalHost: host,
                phase: bootstrapPhase
            )
            session.lastActivity = Self.bootstrapLastActivity(
                fileDate: fileDate,
                pid: info.pid,
                tty: info.tty
            )
            // Per-agent session-name resolution. Codex pulls from the
            // sqlite threads index; claude-code from `<pid>.json`
            // (no pid for historical → nil → no name set here, the
            // bootstrap parser will surface customTitle later).
            if let provider,
               let name = provider.resolveSessionName(sessionId: info.sessionId, pid: hasProcessBackedPid ? info.pid : nil),
               !name.isEmpty {
                session.sessionName = name
            }
            sessions[info.sessionId] = session
            if info.agentID == .codex, info.tty == nil {
                let sessionId = info.sessionId
                let sessionCwd = cwd
                Task { @MainActor in
                    SessionFileWatcherManager.shared.startWatching(
                        sessionId: sessionId,
                        cwd: sessionCwd,
                        agentID: .codex
                    )
                }
            }
            // Defer heavy parsing until either the user opens the
            // chat view (`loadHistory`) or `SessionFileWatcher`
            // reports the file extending. Bootstrap fetches just the
            // light `ConversationInfo` summary so the sidebar can
            // render previews without parsing 100+ MB files upfront.
            // Each provider owns its summary path. claude-code and codex
            // read bounded head+tail summaries; cursor currently warms its
            // parser cache and reads the cached info.
            let sessionId = info.sessionId
            let sessionCwd = cwd
            if let provider {
                Task { [weak self] in
                    let conversationInfo = await provider.loadConversationInfo(
                        sessionId: sessionId, cwd: sessionCwd
                    )
                    await self?.applyBootstrapConversationInfo(
                        sessionId: sessionId,
                        info: conversationInfo
                    )
                }
            }
        }

        debugLog("[Scan] Complete. Total sessions: \(sessions.count)")
        publishState()
    }

    /// Light follow-up to `bootstrapSessions`: fold a freshly-parsed
    /// `ConversationInfo` into the session and re-publish so the session
    /// list updates with last-message previews AND the model/mode/context
    /// chips show immediately without needing a full incremental parse.
    private func applyBootstrapConversationInfo(sessionId: String, info: ConversationInfo) async {
        guard var session = sessions[sessionId] else { return }
        session.conversationInfo = info
        session.lastActivity = Self.mergedLastActivity(
            current: session.lastActivity,
            info: info
        )
        if let lastCwd = info.lastCwd {
            let lastComponent = ProjectDisplayNamePolicy.displayName(forCwd: lastCwd)
                ?? URL(fileURLWithPath: lastCwd).lastPathComponent
            if lastComponent != session.projectName && !lastComponent.isEmpty {
                session.currentProject = lastComponent
            }
        }
        applyConversationMetadata(info, to: &session)
        sessions[sessionId] = session
        _ = await applyInferredObservedPhase(sessionId: sessionId)
        publishState()
    }

    private static func mergedLastActivity(current: Date, info: ConversationInfo) -> Date {
        SessionActivityDatePolicy.merged(
            current: current,
            candidates: [info.lastActivityDate, info.lastUserMessageDate]
        )
    }

    private func applyConversationMetadata(_ info: ConversationInfo, to session: inout SessionState) {
        // Zed's claude-acp adapter writes user-set thread titles directly
        // into the JSONL as `{"type":"custom-title",...}` rows. When
        // present, that's the most authoritative title — it's what Zed
        // shows in its own sidebar. Don't clobber a non-empty
        // sessionName already on the session (the hook-side
        // `readSessionName(pid:)` may have run first), but DO overwrite
        // when the existing name is the bare UUID prefix or empty.
        session.sessionName = SessionTranscriptTitlePolicy.preferredName(
            sessionId: session.sessionId,
            currentName: session.sessionName,
            transcriptTitle: info.customTitle
        )
        // Most agents keep the first-set model name; codex overwrites
        // on every parse because its JSONL doesn't persist model
        // across turns (every new turn is the source of truth). The
        // per-provider `overwritesModelName` flag encodes that.
        if let model = info.lastModelName, !model.isEmpty {
            let shouldWrite = session.modelName == nil
                || (AgentRegistry.provider(for: session.agentID)?.overwritesModelName() ?? false)
            if shouldWrite {
                session.modelName = model
            }
        }
        if let tokens = info.lastContextTokens, tokens > 0 {
            session.lastContextTokens = tokens
        }
        if let window = info.lastContextWindowTokens, window > 0 {
            session.contextWindowTokens = window
        }
        if let effort = info.lastEffortLevel, !effort.isEmpty {
            session.effortLevel = effort
        }
        if let mode = info.lastPermissionMode, session.permissionMode == nil {
            session.permissionMode = mode
        }
    }

    private func debugLog(_ message: String) {
        let line = "\(Date()): \(message)\n"
        let path = AppPaths.navLogPath
        if let data = line.data(using: .utf8),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }


    func startPeriodicPruning() {
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                // 3s instead of 10s. The 10s lag was visible to users
                // closing a Zed thread (claude-acp child PID dies, but
                // agent-visor's sidebar kept the row for up to 10s).
                // `kill(pid, 0)` on N tracked sessions is microseconds —
                // the cost of polling every 3s is negligible.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.pruneDeadSessions()
                // Re-evaluate observed (hookless) sessions so cursor flips
                // to "your turn" once its transcript goes quiet — there's
                // no file event for "stopped writing."
                await self?.reconcileObservedPhases()
                await self?.reconcileHookReadyFreshness()

                // Periodic re-discovery (~30s). Discovery otherwise runs
                // only once at launch; new sessions arrive via hooks after
                // that. But observed agents (codex GUI, cursor IDE) are
                // active-only, and the prune can drop them on a transient
                // miss — most notably right after the Mac wakes, when
                // NSWorkspace briefly reports Codex.app as not running so
                // `activeGUIThreadIDs()` is momentarily empty and every
                // codex row is removed. With no re-discovery they'd stay
                // gone until relaunch. `bootstrapSessions` merges (skips
                // sessions already present), so re-running it is a safe
                // self-heal that re-adds anything wrongly pruned.
                tick += 1
                if tick % 10 == 0 {
                    let rediscovered = await Self.discoverInBackground()
                    await MainActor.run {
                        CodexMetadataWatcher.shared.start()
                    }
                    await self?.bootstrapSessions(rediscovered)
                }
            }
        }
    }

    /// Run the (blocking, `ps`-based) discovery scan off the actor and
    /// off the main thread, then hand the result back for a merge. Process
    /// needs a run loop, so it can't run inline on the actor.
    private static func discoverInBackground() async -> [DiscoveredSession] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: ClaudeSessionMonitor.discoverExistingSessions())
            }
        }
    }

    private static func discoverCodexInBackground() async -> [DiscoveredSession] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let provider = CodexAgentProvider()
                let live = provider.discoverLiveSessions()
                let liveIds = Set(live.map(\.sessionId))
                let historical = provider.discoverHistoricalSessions(excluding: liveIds, limit: 30)
                continuation.resume(returning: live + historical)
            }
        }
    }

    /// Mark sessions whose CLI process has died as ended, but keep them
    /// in the dictionary so chat history remains browsable. Sessions are
    /// only fully removed by `processSessionEnd` (explicit user action /
    /// hook event with status=ended) — see G4 in the rebrand goal.
    /// Earlier behavior was to remove dead-PID sessions outright; that
    /// made codex / cursor sessions vanish from the sidebar the moment
    /// the user closed the terminal pane, even though their transcript
    /// JSONL still existed on disk and could be re-loaded.
    /// True when a session has nothing worth keeping in the "Recent"
    /// list: no user-set / extension title, no first user message, and
    /// no rendered chat items. These are SDK/MCP-spawned children and
    /// aborted launches — keeping them past death just floods the
    /// sidebar with dead "New session" rows that open to an empty chat.
    private static func isEmptyNoiseSession(_ session: SessionState) -> Bool {
        let hasName = !(session.sessionName ?? "").isEmpty
        let hasFirstUser = !(session.conversationInfo.firstUserMessage ?? "").isEmpty
        let hasItems = !session.chatItems.isEmpty
        return !hasName && !hasFirstUser && !hasItems
    }

    private func pruneDeadSessions() {
        var didMark = false

        // 1. Sessions with dead PIDs: per-provider rule decides
        //    whether to mark `.ended` (keep transcript browsable) or
        //    remove outright (no recovery path). File-watcher cleanup
        //    is also per-provider — claude-code stops watching since
        //    its session ids are pid-bound; codex/cursor keep watching
        //    in case the same session id reattaches.
        //
        // Zed-hosted sessions get special-cased: Zed pools its
        // claude-acp child process across threads, so closing a thread
        // does NOT reliably kill the PID. PID-alive ⇒ live-row was wrong
        // for Zed (rows lingered indefinitely after thread close), so we
        // key Zed liveness on transcript idleness instead. The window is
        // the observed-agent window (default 42h): an idle-but-open Zed
        // thread must stay visible. The old 30s window pruned a thread the
        // moment you stopped typing for half a minute — exactly the bug
        // where an open Zed session vanished. Genuine thread close is
        // caught promptly by the claude SessionEnd hook; this is only the
        // fallback cleanup for a thread that went away without one.
        let now = Date()
        let zedIdleSeconds: TimeInterval = AppSettings.observedWindowSeconds

        // Codex.app runs all GUI threads in one process, so PID-alive
        // can't decide per-thread liveness. Re-derive the active set the
        // SAME way discovery does, but keep recent GUI rows as a fallback
        // when the sqlite active-set query has a transient miss.
        let hasCodex = sessions.values.contains { $0.agentID == .codex }
        let codexActiveIDs: Set<String> = hasCodex
            ? CodexAgentProvider.activeGUIThreadIDs()
            : []
        let codexAppPid = hasCodex ? CodexAgentProvider.runningCodexAppPid() : nil

        // Zed pools its claude-acp child across threads, so PID-alive
        // can't decide per-thread liveness — but Zed.app NOT running is a
        // definitive signal that every Zed thread is dead. Without this,
        // closing Zed left rows lingering for the full 42h idle window
        // (the JSONL just stops growing; nothing else fires). Computed
        // once per sweep, only when we actually track a Zed session.
        let hasZed = sessions.values.contains { $0.terminalHost == .zed }
        let zedRunning = hasZed
            ? NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "dev.zed.Zed" }
            : false

        // Cursor IDE Agents Window threads share Cursor.app's PID, so
        // PID-alive can't decide liveness either (it's true for every
        // thread whenever Cursor.app runs). Re-derive the active set by
        // transcript recency — same window discovery uses — over only the
        // tracked IDE sessions (a handful of stats, not a tree walk).
        let cursorIDESessions = sessions.values.filter { $0.agentID == .cursor && $0.tty == nil }
        let cursorActiveIDs: Set<String> = {
            guard !cursorIDESessions.isEmpty,
                  CursorAgentProvider.isAppRunning(),
                  let provider = AgentRegistry.provider(for: .cursor) else { return [] }
            let cutoff = now.addingTimeInterval(-CursorAgentProvider.activeWindowSeconds)
            let fm = FileManager.default
            return Set(cursorIDESessions.compactMap { s -> String? in
                let path = provider.transcriptURL(sessionId: s.sessionId, cwd: s.cwd).path
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime >= cutoff else { return nil }
                return s.sessionId
            })
        }()

        let deadPidIds = sessions.filter { _, session in
            if session.phase == .ended { return false }
            if session.agentID == .claudeCode,
               let status = SessionState.readSessionStatus(pid: session.pid),
               ClaudeCodeSessionMetadataPolicy.isTerminalStatus(status) {
                return true
            }
            if session.agentID == .claudeCode,
               session.origin == .cursorObserved {
                return shouldPruneCursorObservedClaudeSession(session, now: now)
            }
            if session.agentID == .codex {
                let isKnownArchived: Bool
                let isExplicitlyArchived: Bool
                if let thread = CodexThreadStore.thread(id: session.sessionId) {
                    isKnownArchived = thread.archived
                    isExplicitlyArchived = thread.isExplicitlyArchived
                    if session.tty == nil,
                       !CodexActiveThreadSelector.isInteractiveGUISource(thread.source) {
                        return true
                    }
                    if session.tty != nil,
                       thread.source != "cli" {
                        return true
                    }
                } else {
                    isKnownArchived = false
                    isExplicitlyArchived = false
                }
                let nonAppPidAlive: Bool
                if let pid = session.pid, pid != 0, pid != codexAppPid {
                    nonAppPidAlive = kill(Int32(pid), 0) == 0
                } else {
                    nonAppPidAlive = false
                }
                return !CodexSessionRetentionPolicy.shouldKeep(
                    sessionId: session.sessionId,
                    tty: session.tty,
                    pid: session.pid,
                    codexAppPid: codexAppPid,
                    isNonAppPidAlive: nonAppPidAlive,
                    activeGUIThreadIds: codexActiveIDs,
                    lastActivity: session.lastActivity,
                    now: now,
                    observedWindowSeconds: AppSettings.observedWindowSeconds,
                    isKnownArchived: isKnownArchived,
                    isExplicitlyArchived: isExplicitlyArchived
                )
            }
            if session.agentID == .cursor && session.tty == nil {
                // Cursor IDE thread: active-only by transcript recency.
                // CLI cursor (tty != nil) uses the generic PID check below.
                return !cursorActiveIDs.contains(session.sessionId)
            }
            if session.terminalHost == .zed {
                // Zed.app closed → every Zed thread is dead; prune now
                // instead of waiting out the idle window. (The user
                // quit Zed; the pooled claude-acp child is gone.)
                if !zedRunning { return true }
                // Zed.app open: ignore PID-alive (pooled child), key on
                // JSONL idleness — an idle-but-open thread must stay.
                let idle = now.timeIntervalSince(session.lastActivity)
                return idle > zedIdleSeconds
            }
            guard let pid = session.pid else { return false }
            return kill(Int32(pid), 0) != 0
        }.map(\.key)

        for sessionId in deadPidIds {
            guard let session = sessions[sessionId],
                  let provider = AgentRegistry.provider(for: session.agentID)
            else { continue }

            // Before marking ended, try to rebind to a NEW live PID for
            // the same session. Users routinely close a terminal pane
            // and run `claude --resume <name>` in another shell — that
            // produces a fresh PID for the same session id. Without
            // this rebind, the row would flip to .ended even though
            // the CLI is alive and ready for input. Only claude-code
            // exposes this attachment shape via argv; codex/cursor
            // sessions reuse their own session ids on respawn but
            // their argvs don't carry the id, so they go through the
            // existing dead-process action.
            if session.agentID == .claudeCode,
               let attachment = ClaudeSessionPidRebinder.findLiveAttachment(
                    sessionId: sessionId,
                    sessionName: session.sessionName,
                    excludePid: session.pid
               )
            {
                Self.logger.info(
                    "Rebound \(sessionId.prefix(8), privacy: .public) to live PID \(attachment.pid, privacy: .public) (was \(session.pid ?? -1, privacy: .public))"
                )
                applyClaudeReattachment(attachment, sessionId: sessionId)
                didMark = true
                continue
            }

            switch provider.deadProcessAction(for: session) {
            case .remove:
                Self.logger.debug("Removing dead session: \(sessionId.prefix(8), privacy: .public)")
                sessions.removeValue(forKey: sessionId)
                cancelPendingSync(sessionId: sessionId)
                Task { @MainActor in
                    SessionFileWatcherManager.shared.stopWatching(sessionId: sessionId)
                }

            case .markEnded:
                // G4 keeps dead sessions so their transcript stays
                // browsable — but only if there's anything TO browse.
                // SDK/MCP-spawned children (claude-mem observers, tool
                // runners) and aborted launches die with an empty
                // transcript, no title, and no first user message.
                // Retaining them floods the sidebar with "New session"
                // rows that open to nothing. Remove the empties; keep
                // the substantive ones.
                if Self.isEmptyNoiseSession(session) {
                    Self.logger.debug("Removing empty dead session: \(sessionId.prefix(8), privacy: .public)")
                    sessions.removeValue(forKey: sessionId)
                    cancelPendingSync(sessionId: sessionId)
                    Task { @MainActor in
                        SessionFileWatcherManager.shared.stopWatching(sessionId: sessionId)
                    }
                } else {
                    Self.logger.debug("Marking dead-PID session as ended: \(sessionId.prefix(8), privacy: .public)")
                    setSessionPhase(sessionId, .ended, evidenceSource: .rediscovery)
                    if provider.stopsWatchingOnDeath(for: session) {
                        cancelPendingSync(sessionId: sessionId)
                        Task { @MainActor in
                            SessionFileWatcherManager.shared.stopWatching(sessionId: sessionId)
                        }
                    }
                }
            }
            didMark = true
        }

        // 1b. Resurrect ended claude-code sessions whose user just ran
        //    `claude --resume <name>` in a new shell. Without this,
        //    once a session lands in `.ended` the dead-PID filter
        //    above ignores it forever (it filters on phase != .ended)
        //    and the row stays pinned to the "session has ended"
        //    banner even though a live CLI is back at the prompt.
        //    Only claude-code sessions need this — codex/cursor's
        //    argvs don't carry the session id.
        let endedClaudeIds = sessions.filter { _, session in
            session.agentID == .claudeCode && session.phase == .ended
        }.map(\.key)

        for sessionId in endedClaudeIds {
            guard let session = sessions[sessionId] else { continue }
            // SessionEnd can arrive while the same claude PID is still
            // alive and winding down. That PID must not resurrect the row;
            // only a different live PID from an actual resume should.
            let excludePid = SessionRebindCandidatePolicy.excludePidForEndedResurrection(
                currentPid: session.pid
            )
            guard let attachment = ClaudeSessionPidRebinder.findLiveAttachment(
                sessionId: sessionId,
                sessionName: session.sessionName,
                excludePid: excludePid
            ) else { continue }

            Self.logger.info(
                "Resurrected ended session \(sessionId.prefix(8), privacy: .public) → live PID \(attachment.pid, privacy: .public) (was \(session.pid ?? -1, privacy: .public))"
            )
            applyClaudeReattachment(attachment, sessionId: sessionId)
            didMark = true
        }

        // 2. Duplicate-PID dedup. Providers can opt sessions out via
        //    `skipsPidDedup` — Cursor IDE Agents Window sessions all
        //    share Cursor.app's pid (one Electron app, many session
        //    transcripts), so identical pid is the design, not a
        //    duplicate.
        var pidToSessions: [Int: [String]] = [:]
        for (id, session) in sessions {
            guard let pid = session.pid else { continue }
            if let provider = AgentRegistry.provider(for: session.agentID),
               provider.skipsPidDedup(for: session) {
                continue
            }
            pidToSessions[pid, default: []].append(id)
        }
        for (_, sessionIds) in pidToSessions where sessionIds.count > 1 {
            let sorted = sessionIds.sorted { a, b in
                (sessions[a]?.lastActivity ?? .distantPast) > (sessions[b]?.lastActivity ?? .distantPast)
            }
            for staleId in sorted.dropFirst() {
                Self.logger.debug("Pruning duplicate PID session: \(staleId.prefix(8), privacy: .public)")
                sessions.removeValue(forKey: staleId)
                cancelPendingSync(sessionId: staleId)
                Task { @MainActor in
                    SessionFileWatcherManager.shared.stopWatching(sessionId: staleId)
                }
                didMark = true
            }
        }

        if didMark {
            publishStateWithoutPrune()
        }
    }

    private func shouldPruneCursorObservedClaudeSession(_ session: SessionState, now: Date) -> Bool {
        let processAlive = session.pid.map { kill(Int32($0), 0) == 0 } ?? false
        let transcriptModifiedAt: Date? = {
            guard let provider = AgentRegistry.provider(for: .claudeCode) else {
                return nil
            }
            let path = provider.transcriptURL(sessionId: session.sessionId, cwd: session.cwd).path
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }()
        let liveness = CursorHostedSessionLivenessPolicy.classify(
            hasTTY: session.tty != nil,
            entrypoint: "claude-vscode",
            processAlive: processAlive,
            isTerminalStatus: ClaudeCodeSessionMetadataPolicy.isTerminalStatus(
                SessionState.readSessionStatus(pid: session.pid)
            ),
            transcriptModifiedAt: transcriptModifiedAt?.timeIntervalSince1970,
            now: now.timeIntervalSince1970,
            observedWindowSeconds: AppSettings.observedWindowSeconds,
            hasPendingUserAction: session.phase.isWaitingForApproval
                || session.phase == .processing
                || session.phase == .compacting
        )
        return liveness == .drop
    }

    /// Publish state without triggering another prune cycle
    private func publishStateWithoutPrune() {
        send(Array(sessions.values))
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}
