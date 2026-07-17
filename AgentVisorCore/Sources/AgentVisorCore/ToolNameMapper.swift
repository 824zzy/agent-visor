import Foundation

/// Canonical, agent-agnostic identity of a tool invocation. UI dispatch
/// (icons, status labels, result formatting) keys on this enum rather
/// than the agent's raw tool name string, so adding a new agent only
/// requires extending the per-agent name table — not the call sites.
///
/// Cases are deliberately payload-free. The parsed *result* payload
/// lives in `ToolResultData` in the main app; this enum is just the
/// identity used at and before invocation time, when no result exists
/// yet.
public enum CanonicalTool: Equatable, Hashable, Sendable {
    case read
    case edit
    case write
    case bash
    case grep
    case glob
    case todoWrite
    case task
    case webFetch
    case webSearch
    case askUserQuestion
    case bashOutput
    case killShell
    case exitPlanMode
    case enterPlanMode
    case mcp(server: String, tool: String)
    case generic(name: String)
}

/// Maps an agent's raw tool name string (e.g. claude-code's "Read") to
/// a `CanonicalTool`. Tables are per-agent so divergent vocabularies
/// stay declarative.
public enum ToolNameMapper {
    public static func canonical(for raw: String, agent: AgentID) -> CanonicalTool {
        if let mcp = parseMCP(raw) {
            return mcp
        }
        if let table = tables[agent], let hit = table[raw] {
            return hit
        }
        return .generic(name: raw)
    }

    /// MCP tool names follow `mcp__<server>__<tool>`. The server segment
    /// runs up to the first double-underscore separator; everything after
    /// that is the tool, which may itself contain underscores.
    private static func parseMCP(_ raw: String) -> CanonicalTool? {
        guard raw.hasPrefix("mcp__") else { return nil }
        let body = raw.dropFirst("mcp__".count)
        guard let sep = body.range(of: "__") else { return nil }
        let server = String(body[..<sep.lowerBound])
        let tool = String(body[sep.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return .mcp(server: server, tool: tool)
    }

    private static let claudeCodeTable: [String: CanonicalTool] = [
        "Read": .read,
        "Edit": .edit,
        "MultiEdit": .edit,
        "Write": .write,
        "Bash": .bash,
        "Grep": .grep,
        "Glob": .glob,
        "TodoWrite": .todoWrite,
        "Task": .task,
        "WebFetch": .webFetch,
        "WebSearch": .webSearch,
        "AskUserQuestion": .askUserQuestion,
        "BashOutput": .bashOutput,
        "KillShell": .killShell,
        "ExitPlanMode": .exitPlanMode,
        "EnterPlanMode": .enterPlanMode,
    ]

    private static let tables: [AgentID: [String: CanonicalTool]] = [
        .claudeCode: claudeCodeTable,
    ]
}
