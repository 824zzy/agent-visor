//
//  ClaudeTurnActivitySummary.swift
//  AgentVisorCore
//
//  Content-aware summary for a collapsed Claude Code turn header. Instead
//  of a bare "N steps", describe WHAT the turn did — "Edited 3 files · Ran
//  1 command" — the way the Codex desktop app does, but more accurately:
//  Claude's tools are strongly typed (Read / Edit / Bash / …), so we
//  categorize from the canonical tool rather than guessing from a shell
//  verb.
//
//  Pure / value-in-value-out so it's unit-testable without view state.
//

import Foundation

/// Buckets a turn's tool calls into a few human verbs. Counts are kept
/// separate so the renderer can decide how many clauses to show.
public struct ClaudeTurnActivity: Equatable, Sendable {
    public var read = 0        // Read / Glob — looked at files
    public var searched = 0    // Grep — searched content
    public var edited = 0      // Edit / MultiEdit / Write — changed files
    public var ran = 0         // Bash / BashOutput / KillShell — ran commands
    public var web = 0         // WebFetch / WebSearch — fetched from the web
    public var delegated = 0   // Task — spawned a subagent
    public var planned = 0     // ExitPlanMode / EnterPlanMode — planning
    public var other = 0       // MCP + anything uncategorized

    public init() {}

    /// Total categorized + uncategorized tool calls — the "N steps" count.
    public var total: Int {
        read + searched + edited + ran + web + delegated + planned + other
    }

    /// Ordered clauses, highest-signal first. "Edited" and "Ran" lead
    /// because they're the actions that changed state; reads/searches are
    /// supporting context. Each clause pluralizes its noun.
    public var clauses: [String] {
        var out: [String] = []
        func add(_ n: Int, _ singular: String, _ plural: String, verb: String) {
            guard n > 0 else { return }
            out.append("\(verb) \(n) \(n == 1 ? singular : plural)")
        }
        add(edited, "file", "files", verb: "Edited")
        add(ran, "command", "commands", verb: "Ran")
        add(read, "file", "files", verb: "Read")
        add(searched, "search", "searches", verb: "Searched")
        add(web, "page", "pages", verb: "Fetched")
        add(delegated, "task", "tasks", verb: "Delegated")
        add(planned, "plan", "plans", verb: "Planned")
        return out
    }

    /// Header label. Shows up to `maxClauses` highest-signal clauses; if
    /// nothing categorized (only `.other`/MCP) or the clause list is empty,
    /// falls back to a plain step count so the header is never blank.
    public func label(maxClauses: Int = 2) -> String {
        let c = clauses
        guard !c.isEmpty else {
            let n = total
            return n == 1 ? "1 step" : "\(n) steps"
        }
        if c.count <= maxClauses {
            return c.joined(separator: " · ")
        }
        // Too many categories — keep the top ones and roll the rest into
        // "+N more" so the header stays short.
        let shown = Array(c.prefix(maxClauses))
        let remainder = total - shownCount(for: shown)
        if remainder > 0 {
            return shown.joined(separator: " · ") + " · +\(remainder) more"
        }
        return shown.joined(separator: " · ")
    }

    /// Sum the counts represented by an already-rendered clause list, so
    /// the "+N more" remainder is accurate.
    private func shownCount(for shown: [String]) -> Int {
        var sum = 0
        for clause in shown {
            // Clause shape is "Verb N noun"; pull the N.
            let parts = clause.split(separator: " ")
            if parts.count >= 2, let n = Int(parts[1]) { sum += n }
        }
        return sum
    }
}

public enum ClaudeTurnActivitySummarizer {
    /// Categorize one canonical tool into the activity buckets.
    public static func accumulate(_ tool: CanonicalTool, into activity: inout ClaudeTurnActivity) {
        switch tool {
        case .read, .glob:
            activity.read += 1
        case .grep:
            activity.searched += 1
        case .edit, .write:
            activity.edited += 1
        case .bash, .bashOutput, .killShell:
            activity.ran += 1
        case .webFetch, .webSearch:
            activity.web += 1
        case .task:
            activity.delegated += 1
        case .exitPlanMode, .enterPlanMode:
            activity.planned += 1
        case .todoWrite, .askUserQuestion, .mcp, .generic:
            activity.other += 1
        }
    }

    /// Build an activity from a sequence of canonical tools.
    public static func summarize(_ tools: [CanonicalTool]) -> ClaudeTurnActivity {
        var activity = ClaudeTurnActivity()
        for tool in tools { accumulate(tool, into: &activity) }
        return activity
    }
}
