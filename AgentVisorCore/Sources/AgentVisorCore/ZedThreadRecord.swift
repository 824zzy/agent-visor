//
//  ZedThreadRecord.swift
//  AgentVisorCore
//
//  One row of Zed's `sidebar_threads` table — the thread list the user
//  sees in Zed's sidebar.
//
//  Why this is the identity source for Zed-hosted sessions: Zed drives
//  its agents over ACP (stdio), and each agent still writes its own
//  canonical transcript, so Agent Visor discovers the session through
//  normal per-agent discovery. But the NAME the user recognizes is Zed's
//  thread title, not anything in the transcript. Zed stores it here,
//  keyed by the agent's own session id:
//
//      session_id            agent_id     title / title_override
//      7752fd3d-…            claude-acp   "hi"
//      019fd629-…            pi-acp       ""  / "pi-test-1"
//      019eb3c1-…            codex-acp    "Do I really use …"
//
//  Verified on Zed 1.14: `session_id` equals the claude-code JSONL uuid,
//  the codex rollout uuid, and the pi session id respectively, so the
//  join needs no heuristics.
//
//  `title_override` is the user's explicit rename in Zed and must win
//  over the model-generated `title`.
//

import Foundation

public struct ZedThreadRecord: Equatable, Sendable {
    /// Hex form of Zed's `thread_id` blob. Stable Zed-side identity;
    /// carried so reveal verification can tell "our thread opened" from
    /// "some other thread opened", and so a future Zed thread deeplink
    /// has the id it needs.
    public let threadID: String
    /// The hosted agent's own session id. Nil for threads that have not
    /// started an ACP session yet (Zed creates the row first).
    public let sessionID: String?
    /// Zed's agent identifier, e.g. `claude-acp`, `codex-acp`, `pi-acp`.
    public let agentIdentifier: String?
    public let title: String?
    public let titleOverride: String?
    public let worktreePaths: [String]
    public let archived: Bool
    public let updatedAt: Date?
    public let interactedAt: Date?

    public init(
        threadID: String,
        sessionID: String?,
        agentIdentifier: String?,
        title: String?,
        titleOverride: String?,
        worktreePaths: [String],
        archived: Bool,
        updatedAt: Date?,
        interactedAt: Date?
    ) {
        self.threadID = threadID
        self.sessionID = sessionID
        self.agentIdentifier = agentIdentifier
        self.title = title
        self.titleOverride = titleOverride
        self.worktreePaths = worktreePaths
        self.archived = archived
        self.updatedAt = updatedAt
        self.interactedAt = interactedAt
    }

    /// The name Zed shows in its sidebar: an explicit rename first, then
    /// the generated title. Nil when Zed has no title yet (a fresh thread
    /// whose first prompt has not been summarized) so callers can fall
    /// back to their normal naming instead of rendering an empty pill.
    public var displayTitle: String? {
        for candidate in [titleOverride, title] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Worktree that identifies the thread's project.
    public var primaryWorktreePath: String? {
        worktreePaths.first
    }

    /// Most recent Zed-side touch. `interacted_at` is the user-activity
    /// stamp; `updated_at` also moves for background bookkeeping.
    public var lastTouchedAt: Date? {
        switch (interactedAt, updatedAt) {
        case let (interacted?, updated?): return max(interacted, updated)
        case let (interacted?, nil): return interacted
        case let (nil, updated?): return updated
        default: return nil
        }
    }

    /// Which Agent Visor agent owns this thread's transcript, or nil for
    /// Zed's own built-in agent (no external transcript to mirror).
    public var agentID: AgentID? {
        Self.agentID(forZedAgentIdentifier: agentIdentifier)
    }

    /// Maps Zed's agent identifiers onto Agent Visor's `AgentID`.
    /// Zed names external agents after their ACP adapter (`claude-acp`),
    /// while built-ins (`zed`, `native`) have no external transcript.
    public static func agentID(forZedAgentIdentifier identifier: String?) -> AgentID? {
        guard let identifier else { return nil }
        var normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        for suffix in ["-acp", "-agent", "_acp"] where normalized.hasSuffix(suffix) {
            normalized = String(normalized.dropLast(suffix.count))
        }
        switch normalized {
        case "claude", "claude-code", "claudecode": return .claudeCode
        case "codex": return .codex
        case "pi": return .pi
        case "cursor": return .cursor
        case "auggie": return .auggie
        default: return nil
        }
    }

    /// Zed serializes a thread's worktree list as newline-separated
    /// absolute paths (single path in the common case).
    public static func worktreePaths(from raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
