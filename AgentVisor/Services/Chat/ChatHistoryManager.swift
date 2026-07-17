//
//  ChatHistoryManager.swift
//  AgentVisor
//

import AgentVisorCore
import Combine
import Foundation
import os.log

@MainActor
class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()

    /// Notice-level diagnostic log. Stays on across builds so we can
    /// trace the missing-response regression all the way through the
    /// publish pipeline without having to re-enable debug-level
    /// subsystem flags.
    nonisolated static let regressionLog = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "MissingRespRegression"
    )

    @Published private(set) var histories: [String: [ChatHistoryItem]] = [:]
    @Published private(set) var agentDescriptions: [String: [String: String]] = [:]

    private var loadedSessions: Set<String> = []
    private var fileLoadedSessions: Set<String> = []
    private var fileLoadTasks: [String: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Per-session "shape fingerprint" of the last published `histories[id]`.
    /// SessionStore republishes its full sessions array on every assistant
    /// streaming chunk (5-10 Hz). Each republish previously triggered a
    /// full O(N) `filterOutSubagentTools` + O(N) task-list filter over
    /// `session.chatItems` for EVERY session in the snapshot — at 154k
    /// items / session that pinned CPU at 99% even though rendered rows
    /// were paginated. Now we skip the rebuild if the fingerprint is
    /// stable, which is true for every session OTHER than the one
    /// currently streaming.
    ///
    /// Fingerprint shape: count + last item id + last item text hash.
    /// Last-item-text-hash catches in-place mutation during streaming
    /// (assistant text grows on the same id without count change),
    /// triggering exactly the rebuilds we want and skipping the rest.
    private var sessionFingerprints: [String: Int] = [:]

    private init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func history(for sessionId: String) -> [ChatHistoryItem] {
        histories[sessionId] ?? []
    }

    func isLoaded(sessionId: String) -> Bool {
        loadedSessions.contains(sessionId)
    }

    /// Whether the full JSONL file has been parsed (not just hook events)
    func isFileLoaded(sessionId: String) -> Bool {
        fileLoadedSessions.contains(sessionId)
    }

    func loadFromFile(sessionId: String, cwd: String) async {
        guard !fileLoadedSessions.contains(sessionId) else { return }
        if let task = fileLoadTasks[sessionId] {
            await task.value
            return
        }
        loadedSessions.insert(sessionId)

        let task = Task { @MainActor in
            // Clear any stale parser offset from a previous failed attempt
            // (e.g., wrong cwd before the launch-cwd fix was in place).
            await ConversationParser.shared.resetState(for: sessionId)

            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))

            // Directly sync from SessionStore after load completes.
            // The Combine pipeline dispatches to next run loop, so histories
            // wouldn't be updated yet when the caller reads them.
            let sessions = await SessionStore.shared.currentSessions()
            updateFromSessions(sessions)
            fileLoadedSessions.insert(sessionId)
            fileLoadTasks[sessionId] = nil
        }
        fileLoadTasks[sessionId] = task
        await task.value
    }

    func syncFromFile(sessionId: String, cwd: String) async {
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        let payload = FileUpdatePayload(
            sessionId: sessionId,
            cwd: cwd,
            messages: messages,
            isIncremental: false,  // Full sync
            completedToolIds: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults
        )

        await SessionStore.shared.process(.fileUpdated(payload))
    }

    func clearHistory(for sessionId: String) {
        loadedSessions.remove(sessionId)
        fileLoadedSessions.remove(sessionId)
        fileLoadTasks[sessionId]?.cancel()
        fileLoadTasks.removeValue(forKey: sessionId)
        histories.removeValue(forKey: sessionId)
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Updates

    private func updateFromSessions(_ sessions: [SessionState]) {
        // Per-session fingerprint cache. Skipping the O(N) filter
        // pipeline for unchanged sessions is the difference between
        // 99% CPU pin and idle on a 154k-item live-streaming session.
        // Critical: the fingerprint must catch in-place mutation of
        // the last item (assistant streaming chunks update the last
        // ChatHistoryItem's text without changing count or id), so
        // we hash the last item's text content into the fingerprint.
        var newHistories = histories
        var newAgentDescriptions = agentDescriptions
        var dirty = false
        var seenSessionIds: Set<String> = []
        seenSessionIds.reserveCapacity(sessions.count)

        for session in sessions {
            seenSessionIds.insert(session.sessionId)
            let fingerprint = chatItemsFingerprint(session.chatItems)
            if sessionFingerprints[session.sessionId] == fingerprint,
               newHistories[session.sessionId] != nil {
                // Stable session, no work needed. The vast majority
                // of "non-active" sessions hit this path on every
                // streaming-chunk republish.
                continue
            }
            sessionFingerprints[session.sessionId] = fingerprint
            let filteredItems = filterOutSubagentTools(session.chatItems)
            let withoutTaskList = filteredItems.filter { !Self.isTaskListTool($0) }
            let prevCount = newHistories[session.sessionId]?.count ?? -1
            newHistories[session.sessionId] = withoutTaskList
            newAgentDescriptions[session.sessionId] = session.subagentState.agentDescriptions
            loadedSessions.insert(session.sessionId)
            dirty = true
            let lastIdShort = String(withoutTaskList.last?.id.prefix(20) ?? "nil")
            Self.regressionLog.notice(
                "CHM.publish sid=\(session.sessionId.prefix(8), privacy: .public) prev=\(prevCount) new=\(withoutTaskList.count) lastId=\(lastIdShort, privacy: .public)"
            )
        }

        // Drop sessions that disappeared from the snapshot. Without
        // this the fingerprint cache and `histories` would leak
        // entries for sessions that ended.
        let stale = Set(newHistories.keys).subtracting(seenSessionIds)
        if !stale.isEmpty {
            for id in stale {
                newHistories.removeValue(forKey: id)
                newAgentDescriptions.removeValue(forKey: id)
                sessionFingerprints.removeValue(forKey: id)
            }
            dirty = true
        }

        // Only republish if something actually changed. Equality on
        // the dictionaries is dirt cheap (Swift's COW means the
        // backing storage is shared until we mutate); the early-exit
        // here saves the @Published wrapper from waking subscribers.
        if dirty {
            histories = newHistories
            agentDescriptions = newAgentDescriptions
        }
    }

    /// Cheap structural fingerprint of a chatItems array. Hashes:
    ///  - count
    ///  - the last `tailWindow` items' ids (catches new appends)
    ///  - those items' size signals (catches in-place streaming
    ///    mutation where assistant text grows or a toolCall's status
    ///    flips after the row is no longer the tail)
    ///
    /// Why a window, not just `last`: when streaming an assistant
    /// turn that ends with a tool_use, the parser appends BOTH the
    /// text row AND a tool placeholder in the same batch. Once the
    /// tool placeholder is the tail, further text growth on the
    /// assistant text item — at index `count-2` — is invisible to
    /// a last-only fingerprint, so the publish gets skipped and the
    /// chat goes silent until the next user turn shifts the count
    /// and forces a refingerprint. Fingerprinting the tail few rows
    /// catches that case without paying the O(N) cost of hashing
    /// every item.
    ///
    /// Skips deep traversal of nested ToolResultData / subagent state —
    /// those mutate too rarely to be worth the per-publish cost.
    private static let tailWindow = 4
    private func chatItemsFingerprint(_ items: [ChatHistoryItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        let start = max(0, items.count - Self.tailWindow)
        for idx in start..<items.count {
            let item = items[idx]
            hasher.combine(item.id)
            switch item.type {
            case .user(let s), .assistant(let s), .thinking(let s),
                 .recap(let s), .localCommandOutput(let s):
                // Bucket the text by length / 64 so we don't
                // refingerprint every keystroke during streaming.
                // ~64-char buckets ≈ a chunk's worth of text →
                // ≤1 republish per 64 chars of streamed output,
                // plenty granular for autoscroll.
                hasher.combine(s.count / 64)
            case .image(let image):
                hasher.combine(image.source.rawValue)
                hasher.combine(image.value.count)
            case .toolCall(let tool):
                hasher.combine(tool.status.description)
                hasher.combine(tool.subagentTools.count)
            case .interrupted, .turnDuration, .compactBoundary:
                break
            }
        }
        return hasher.finalize()
    }

    private func filterOutSubagentTools(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var subagentToolIds = Set<String>()
        for item in items {
            if case .toolCall(let tool) = item.type, tool.name == "Task" {
                for subagentTool in tool.subagentTools {
                    subagentToolIds.insert(subagentTool.id)
                }
            }
        }

        return items.filter { !subagentToolIds.contains($0.id) }
    }

    /// The newer task-management tool family (TaskCreate / TaskUpdate / TaskList /
    /// TaskGet / TaskOutput / TaskStop) replaced the legacy single TodoWrite tool.
    /// Claude Code's TUI condenses them into one live panel; in the notch chat a
    /// per-call row is just noise and a single condensed row carries no real
    /// signal, so we hide them entirely and let the TUI surface todo state.
    private static let taskListToolNames: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskOutput", "TaskStop",
    ]

    private static func isTaskListTool(_ item: ChatHistoryItem) -> Bool {
        if case .toolCall(let tool) = item.type {
            return taskListToolNames.contains(tool.name)
        }
        return false
    }
}

// MARK: - Models

struct ChatHistoryItem: Identifiable, Equatable, Sendable {
    let id: String
    let type: ChatHistoryItemType
    let timestamp: Date

    static func == (lhs: ChatHistoryItem, rhs: ChatHistoryItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type
    }
}

enum ChatHistoryItemType: Equatable, Sendable {
    case user(String)
    case image(ChatImageAttachment)
    case assistant(String)
    case toolCall(ToolCallItem)
    case thinking(String)
    case interrupted
    case turnDuration(seconds: Int)
    case recap(String)
    case compactBoundary(summary: String?, preTokens: Int?, trigger: String?)
    case localCommandOutput(String)
}

struct ToolCallItem: Equatable, Sendable {
    let name: String
    let input: [String: String]
    var status: ToolStatus
    var result: String?
    var structuredResult: ToolResultData?

    /// For Task tools: nested subagent tool calls
    var subagentTools: [SubagentToolCall]

    /// Preview text for the tool (input-based)
    var inputPreview: String {
        if let filePath = input["file_path"] ?? input["path"] {
            return URL(fileURLWithPath: filePath).lastPathComponent
        }
        if let command = input["command"] {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            return String(firstLine.prefix(60))
        }
        if let pattern = input["pattern"] {
            return pattern
        }
        if let query = input["query"] {
            return query
        }
        if let url = input["url"] {
            return url
        }
        if let agentId = input["agentId"] {
            let blocking = input["block"] == "true"
            return blocking ? "Waiting..." : "Checking \(agentId.prefix(8))..."
        }
        return input.values.first.map { String($0.prefix(60)) } ?? ""
    }

    /// Status display text for the tool
    var statusDisplay: ToolStatusDisplay {
        if status == .running {
            return ToolStatusDisplay.running(for: name, input: input)
        }
        if status == .waitingForApproval {
            return ToolStatusDisplay(text: "Waiting for approval...", isRunning: true)
        }
        if status == .interrupted {
            return ToolStatusDisplay(text: "Interrupted", isRunning: false)
        }
        return ToolStatusDisplay.completed(for: name, result: structuredResult)
    }

    // Custom Equatable implementation to handle structuredResult
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.name == rhs.name &&
        lhs.input == rhs.input &&
        lhs.status == rhs.status &&
        lhs.result == rhs.result &&
        lhs.structuredResult == rhs.structuredResult &&
        lhs.subagentTools == rhs.subagentTools
    }
}

enum ToolStatus: Sendable, CustomStringConvertible {
    case running
    case waitingForApproval
    case success
    case error
    case interrupted

    nonisolated var description: String {
        switch self {
        case .running: return "running"
        case .waitingForApproval: return "waitingForApproval"
        case .success: return "success"
        case .error: return "error"
        case .interrupted: return "interrupted"
        }
    }
}

// Explicit nonisolated Equatable conformance to avoid actor isolation issues
extension ToolStatus: Equatable {
    nonisolated static func == (lhs: ToolStatus, rhs: ToolStatus) -> Bool {
        switch (lhs, rhs) {
        case (.running, .running): return true
        case (.waitingForApproval, .waitingForApproval): return true
        case (.success, .success): return true
        case (.error, .error): return true
        case (.interrupted, .interrupted): return true
        default: return false
        }
    }
}

// MARK: - Subagent Tool Call

/// Represents a tool call made by a subagent (Task tool)
struct SubagentToolCall: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let input: [String: String]
    var status: ToolStatus
    let timestamp: Date

    /// Short description for display
    var displayText: String {
        switch name {
        case "Read":
            if let path = input["file_path"] {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return "Reading..."
        case "Grep":
            if let pattern = input["pattern"] {
                return "grep: \(pattern)"
            }
            return "Searching..."
        case "Glob":
            if let pattern = input["pattern"] {
                return "glob: \(pattern)"
            }
            return "Finding files..."
        case "Bash":
            if let desc = input["description"] {
                return desc
            }
            if let cmd = input["command"] {
                let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
                return String(firstLine.prefix(40))
            }
            return "Running command..."
        case "Edit":
            if let path = input["file_path"] {
                return "Edit: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Editing..."
        case "Write":
            if let path = input["file_path"] {
                return "Write: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Writing..."
        case "WebFetch":
            if let url = input["url"] {
                return "Fetching: \(url.prefix(30))..."
            }
            return "Fetching..."
        case "WebSearch":
            if let query = input["query"] {
                return "Search: \(query.prefix(30))"
            }
            return "Searching web..."
        default:
            return name
        }
    }
}
