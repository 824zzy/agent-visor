import Foundation

/// A run of consecutive Codex tool calls collapses into one summary line that
/// mirrors the Codex desktop app, e.g. "Explored 8 files · Ran 4 commands".
public struct CodexToolActivity: Equatable, Sendable {
    public let exploredCount: Int
    public let ranCount: Int

    public init(exploredCount: Int, ranCount: Int) {
        self.exploredCount = exploredCount
        self.ranCount = ranCount
    }

    public var totalCount: Int { exploredCount + ranCount }

    public var summary: String {
        var clauses: [String] = []
        if exploredCount > 0 {
            clauses.append("Explored \(exploredCount) file\(exploredCount == 1 ? "" : "s")")
        }
        if ranCount > 0 {
            clauses.append("Ran \(ranCount) command\(ranCount == 1 ? "" : "s")")
        }
        return clauses.isEmpty ? "No activity" : clauses.joined(separator: " · ")
    }
}

public enum CodexShellCategory: Equatable, Sendable {
    case explore
    case run
}

public enum CodexToolActivitySummarizer {
    /// Read-only inspection verbs. Codex surfaces these as "Explored N files";
    /// everything else (build/test/git-mutate/network) reads as "Ran N commands".
    /// This is a heuristic on the command's leading verb — Codex itself knows
    /// from its tool plumbing, we only have the shell line.
    static let exploreVerbs: Set<String> = [
        "sed", "rg", "grep", "egrep", "fgrep", "nl", "cat", "head", "tail",
        "ls", "find", "fd", "tree", "stat", "wc", "file", "less", "more",
        "bat", "awk", "cut", "diff",
    ]

    public static func category(forCommand command: String) -> CodexShellCategory {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstToken = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
        else { return .run }
        let verb = (firstToken as Substring).split(separator: "/").last.map(String.init) ?? String(firstToken)
        return exploreVerbs.contains(verb) ? .explore : .run
    }

    public static func summarize(_ calls: [CodexParsedToolCall]) -> CodexToolActivity {
        var explored = 0
        var ran = 0
        for call in calls {
            switch call.kind {
            case .shell:
                if category(forCommand: call.command ?? "") == .explore {
                    explored += 1
                } else {
                    ran += 1
                }
            case .mcp, .other, .plan:
                // MCP/other tool calls read as actions Codex "ran".
                ran += 1
            }
        }
        return CodexToolActivity(exploredCount: explored, ranCount: ran)
    }
}
