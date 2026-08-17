//
//  ConversationInfo.swift
//  AgentVisorCore
//
//  Parsed summary of a session's conversation file. `SessionState` carries
//  one, so it lives beside the session model; the parser that produces it
//  stays in the app.
//

import Foundation

public struct ConversationInfo: Equatable, Sendable {
    public let summary: String?
    public let lastMessage: String?
    public let lastMessageRole: String?  // "user", "assistant", or "tool"
    public let lastToolName: String?  // Tool name if lastMessageRole is "tool"
    public let firstUserMessage: String?  // Fallback title when no summary
    public let lastUserMessageDate: Date?  // Timestamp of last user message (for stable sorting)
    /// Timestamp of the last real message of any role (user/assistant).
    /// Drives the idle/waitingForInput status-color fade. We can't use the
    /// JSONL file mtime for this: GUI-spawned sessions (Claude Desktop, Zed)
    /// keep the file alive with non-conversational rows (`permission-mode`,
    /// `mode`, summaries), so mtime reads "fresh" long after the last turn
    /// and the status stripe stays green on a conversationally-stale session.
    public let lastActivityDate: Date?
    public let lastCwd: String?  // Most recent working directory from JSONL messages
    /// User-set thread title from Zed's `{"type":"custom-title",...}`
    /// auxiliary rows. Nil for plain Claude CLI sessions; non-nil only
    /// when the agent ran inside Zed (`claude-acp`). See
    /// [[ClaudeCustomTitleExtractor]].
    public let customTitle: String?

    // Lightweight metadata extracted from the tail — allows bootstrap to
    // populate session chips without a full incremental parse.
    public let lastModelName: String?
    public let lastModelDisplayName: String?
    public let lastContextTokens: Int?
    public let lastContextWindowTokens: Int?
    public let lastEffortLevel: String?
    public let lastPermissionMode: String?
    public let lastCodexApprovalPolicy: String?
    public let lastCodexSandboxPolicyType: String?

    public nonisolated init(
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
        lastModelDisplayName: String? = nil,
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
        self.lastModelDisplayName = lastModelDisplayName
        self.lastContextTokens = lastContextTokens
        self.lastContextWindowTokens = lastContextWindowTokens
        self.lastEffortLevel = lastEffortLevel
        self.lastPermissionMode = lastPermissionMode
        self.lastCodexApprovalPolicy = lastCodexApprovalPolicy
        self.lastCodexSandboxPolicyType = lastCodexSandboxPolicyType
    }
}
