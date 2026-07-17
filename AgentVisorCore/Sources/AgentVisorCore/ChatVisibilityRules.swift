//
//  ChatVisibilityRules.swift
//  AgentVisorCore
//
//  Pure-data, pure-logic filter for the chat timeline. The user toggles
//  per-kind visibility in Settings; the chat view applies these rules
//  at render time. No mutation of the canonical SessionState timeline —
//  the filter runs over the published `chatItems` array each frame.
//
//  Render-time only. Earlier we tried filtering at parse time
//  (CanceledUserTurnDetector) and the destructive removal during JSONL
//  streaming caused a 99% CPU regression — every fresh user line was
//  transiently flagged "canceled" and SwiftUI thrashed on the mutating
//  array. Lesson: filter on the way out, never on the way in. See
//  [[feedback_lazyvstack_count_animation]].
//

import Foundation

/// Discriminated identity of a chat row, agent-agnostic. The main app
/// projects its `ChatHistoryItemType` (which carries payload) onto this
/// case-only enum so the filter can be unit-tested without dragging
/// SwiftUI / AppKit into the test bundle.
public enum ChatItemKind: Equatable, Sendable {
    case userMessage
    case assistantMessage
    case thinking
    case interrupted
    case turnDuration
    case recap
    case compactBoundary
    case localCommandOutput
    /// Tool invocation row. Carries a CanonicalTool so the filter can
    /// per-tool gate (Bash visible, Read hidden, etc.).
    case toolCall(CanonicalTool)
}

/// User-controlled visibility settings. Defaults are "show everything"
/// — power users opt-in to hiding noise rather than missing content
/// on first launch. Boolean per kind so future categories can be added
/// without touching the wire format. Codable so AppSettings can
/// persist via JSONEncoder → UserDefaults Data.
public struct ChatVisibilityRules: Equatable, Codable, Sendable {
    // Non-tool kinds
    public var showUserMessage: Bool
    public var showAssistantMessage: Bool
    public var showThinking: Bool
    public var showInterrupted: Bool
    public var showTurnDuration: Bool
    public var showRecap: Bool
    public var showCompactBoundary: Bool
    public var showLocalCommandOutput: Bool

    // Per-tool kinds
    public var showBash: Bool
    public var showRead: Bool
    public var showWrite: Bool
    public var showEdit: Bool
    public var showGrep: Bool
    public var showGlob: Bool
    public var showWebFetch: Bool
    public var showWebSearch: Bool
    public var showTodoWrite: Bool
    public var showTask: Bool
    public var showAskUserQuestion: Bool
    public var showBashOutput: Bool
    public var showKillShell: Bool
    public var showPlanMode: Bool
    public var showMCP: Bool
    /// Catch-all for tools not enumerated above (custom tools, future
    /// additions, etc.). Toggling this off doesn't accidentally hide
    /// known tools that the user has explicit toggles for.
    public var showOtherTools: Bool

    // MARK: - Behavior (not a per-kind visibility gate)

    /// Codex-style turn collapsing for Claude Code: fold each completed
    /// turn's work under a "Worked for X" header and show only the final
    /// answer (dropping intermediate narration). OFF reverts to the flat
    /// transcript with every assistant block shown — the escape hatch,
    /// since collapsing drops narration that can't otherwise be recovered
    /// in-app.
    public var collapseClaudeTurns: Bool

    /// Same Codex-style turn collapsing, for Codex sessions. Codex inserts
    /// its `turn_duration` marker at the START of a turn (and only on
    /// `task_complete`), so the collapse is driven by `CodexTurnGrouper`
    /// (prompt-boundary segmentation) rather than the Claude trailing-marker
    /// grouper — but the user-facing behavior and escape hatch match
    /// `collapseClaudeTurns`. OFF reverts to the flat transcript with the
    /// legacy consecutive-tool-run coalescing.
    public var collapseCodexTurns: Bool

    public static let defaults = ChatVisibilityRules(
        showUserMessage: true,
        showAssistantMessage: true,
        showThinking: true,
        showInterrupted: true,
        showTurnDuration: true,
        showRecap: true,
        showCompactBoundary: true,
        showLocalCommandOutput: true,
        showBash: true,
        showRead: true,
        showWrite: true,
        showEdit: true,
        showGrep: true,
        showGlob: true,
        showWebFetch: true,
        showWebSearch: true,
        showTodoWrite: true,
        showTask: true,
        showAskUserQuestion: true,
        showBashOutput: true,
        showKillShell: true,
        showPlanMode: true,
        showMCP: true,
        showOtherTools: true,
        collapseClaudeTurns: true,
        collapseCodexTurns: true
    )

    public init(
        showUserMessage: Bool,
        showAssistantMessage: Bool,
        showThinking: Bool,
        showInterrupted: Bool,
        showTurnDuration: Bool,
        showRecap: Bool,
        showCompactBoundary: Bool,
        showLocalCommandOutput: Bool,
        showBash: Bool,
        showRead: Bool,
        showWrite: Bool,
        showEdit: Bool,
        showGrep: Bool,
        showGlob: Bool,
        showWebFetch: Bool,
        showWebSearch: Bool,
        showTodoWrite: Bool,
        showTask: Bool,
        showAskUserQuestion: Bool,
        showBashOutput: Bool,
        showKillShell: Bool,
        showPlanMode: Bool,
        showMCP: Bool,
        showOtherTools: Bool,
        collapseClaudeTurns: Bool,
        collapseCodexTurns: Bool
    ) {
        self.showUserMessage = showUserMessage
        self.showAssistantMessage = showAssistantMessage
        self.showThinking = showThinking
        self.showInterrupted = showInterrupted
        self.showTurnDuration = showTurnDuration
        self.showRecap = showRecap
        self.showCompactBoundary = showCompactBoundary
        self.showLocalCommandOutput = showLocalCommandOutput
        self.showBash = showBash
        self.showRead = showRead
        self.showWrite = showWrite
        self.showEdit = showEdit
        self.showGrep = showGrep
        self.showGlob = showGlob
        self.showWebFetch = showWebFetch
        self.showWebSearch = showWebSearch
        self.showTodoWrite = showTodoWrite
        self.showTask = showTask
        self.showAskUserQuestion = showAskUserQuestion
        self.showBashOutput = showBashOutput
        self.showKillShell = showKillShell
        self.showPlanMode = showPlanMode
        self.showMCP = showMCP
        self.showOtherTools = showOtherTools
        self.collapseClaudeTurns = collapseClaudeTurns
        self.collapseCodexTurns = collapseCodexTurns
    }

    // MARK: - Codable with default-tolerant decoding
    //
    // Custom decoder fills missing keys with `defaults` so that adding
    // a new kind in a future build doesn't reset every other toggle to
    // false on first read of a stale on-disk blob.

    private enum CodingKeys: String, CodingKey {
        case showUserMessage, showAssistantMessage, showThinking
        case showInterrupted, showTurnDuration, showRecap
        case showCompactBoundary, showLocalCommandOutput
        case showBash, showRead, showWrite, showEdit, showGrep, showGlob
        case showWebFetch, showWebSearch, showTodoWrite, showTask
        case showAskUserQuestion, showBashOutput, showKillShell
        case showPlanMode, showMCP, showOtherTools
        case collapseClaudeTurns
        case collapseCodexTurns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChatVisibilityRules.defaults
        self.showUserMessage = (try? c.decode(Bool.self, forKey: .showUserMessage)) ?? d.showUserMessage
        self.showAssistantMessage = (try? c.decode(Bool.self, forKey: .showAssistantMessage)) ?? d.showAssistantMessage
        self.showThinking = (try? c.decode(Bool.self, forKey: .showThinking)) ?? d.showThinking
        self.showInterrupted = (try? c.decode(Bool.self, forKey: .showInterrupted)) ?? d.showInterrupted
        self.showTurnDuration = (try? c.decode(Bool.self, forKey: .showTurnDuration)) ?? d.showTurnDuration
        self.showRecap = (try? c.decode(Bool.self, forKey: .showRecap)) ?? d.showRecap
        self.showCompactBoundary = (try? c.decode(Bool.self, forKey: .showCompactBoundary)) ?? d.showCompactBoundary
        self.showLocalCommandOutput = (try? c.decode(Bool.self, forKey: .showLocalCommandOutput)) ?? d.showLocalCommandOutput
        self.showBash = (try? c.decode(Bool.self, forKey: .showBash)) ?? d.showBash
        self.showRead = (try? c.decode(Bool.self, forKey: .showRead)) ?? d.showRead
        self.showWrite = (try? c.decode(Bool.self, forKey: .showWrite)) ?? d.showWrite
        self.showEdit = (try? c.decode(Bool.self, forKey: .showEdit)) ?? d.showEdit
        self.showGrep = (try? c.decode(Bool.self, forKey: .showGrep)) ?? d.showGrep
        self.showGlob = (try? c.decode(Bool.self, forKey: .showGlob)) ?? d.showGlob
        self.showWebFetch = (try? c.decode(Bool.self, forKey: .showWebFetch)) ?? d.showWebFetch
        self.showWebSearch = (try? c.decode(Bool.self, forKey: .showWebSearch)) ?? d.showWebSearch
        self.showTodoWrite = (try? c.decode(Bool.self, forKey: .showTodoWrite)) ?? d.showTodoWrite
        self.showTask = (try? c.decode(Bool.self, forKey: .showTask)) ?? d.showTask
        self.showAskUserQuestion = (try? c.decode(Bool.self, forKey: .showAskUserQuestion)) ?? d.showAskUserQuestion
        self.showBashOutput = (try? c.decode(Bool.self, forKey: .showBashOutput)) ?? d.showBashOutput
        self.showKillShell = (try? c.decode(Bool.self, forKey: .showKillShell)) ?? d.showKillShell
        self.showPlanMode = (try? c.decode(Bool.self, forKey: .showPlanMode)) ?? d.showPlanMode
        self.showMCP = (try? c.decode(Bool.self, forKey: .showMCP)) ?? d.showMCP
        self.showOtherTools = (try? c.decode(Bool.self, forKey: .showOtherTools)) ?? d.showOtherTools
        self.collapseClaudeTurns = (try? c.decode(Bool.self, forKey: .collapseClaudeTurns)) ?? d.collapseClaudeTurns
        self.collapseCodexTurns = (try? c.decode(Bool.self, forKey: .collapseCodexTurns)) ?? d.collapseCodexTurns
    }
}

public enum ChatVisibilityFilter {
    /// Returns true if the kind should be rendered. Pure function; no
    /// side effects, no allocations beyond enum dispatch.
    public static func shouldShow(_ kind: ChatItemKind, rules: ChatVisibilityRules) -> Bool {
        switch kind {
        case .userMessage: return rules.showUserMessage
        case .assistantMessage: return rules.showAssistantMessage
        case .thinking: return rules.showThinking
        case .interrupted: return rules.showInterrupted
        case .turnDuration: return rules.showTurnDuration
        case .recap: return rules.showRecap
        case .compactBoundary: return rules.showCompactBoundary
        case .localCommandOutput: return rules.showLocalCommandOutput
        case .toolCall(let tool): return showsTool(tool, rules: rules)
        }
    }

    private static func showsTool(_ tool: CanonicalTool, rules: ChatVisibilityRules) -> Bool {
        switch tool {
        case .read: return rules.showRead
        case .edit: return rules.showEdit
        case .write: return rules.showWrite
        case .bash: return rules.showBash
        case .grep: return rules.showGrep
        case .glob: return rules.showGlob
        case .webFetch: return rules.showWebFetch
        case .webSearch: return rules.showWebSearch
        case .todoWrite: return rules.showTodoWrite
        case .task: return rules.showTask
        case .askUserQuestion: return rules.showAskUserQuestion
        case .bashOutput: return rules.showBashOutput
        case .killShell: return rules.showKillShell
        case .exitPlanMode, .enterPlanMode: return rules.showPlanMode
        case .mcp: return rules.showMCP
        case .generic: return rules.showOtherTools
        }
    }
}
