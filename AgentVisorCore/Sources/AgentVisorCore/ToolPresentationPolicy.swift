import Foundation

public struct ToolPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// Provider-aware copy for a tool row. Canonical identity decides the verb;
/// the raw input supplies a short, useful target without exposing results.
public enum ToolPresentationPolicy {
    public static func presentation(
        rawName: String,
        input: [String: String],
        agent: AgentID
    ) -> ToolPresentation {
        let canonical = ToolNameMapper.canonical(for: rawName, agent: agent)
        return ToolPresentation(
            title: title(for: canonical),
            detail: detail(for: canonical, input: input)
        )
    }

    private static func title(for tool: CanonicalTool) -> String {
        switch tool {
        case .read: return "Read"
        case .edit: return "Edit"
        case .write: return "Write"
        case .bash: return "Run"
        case .grep, .glob: return "Search"
        case .todoWrite: return "Todo"
        case .task: return "Agent"
        case .webFetch: return "Fetch"
        case .webSearch: return "Web Search"
        case .askUserQuestion: return "Question"
        case .bashOutput: return "Shell Output"
        case .killShell: return "Stop Shell"
        case .exitPlanMode, .enterPlanMode: return "Plan"
        case .mcp(let server, let tool):
            return "\(humanized(server)) · \(humanized(tool))"
        case .generic(let name):
            return humanized(name)
        }
    }

    private static func detail(
        for tool: CanonicalTool,
        input: [String: String]
    ) -> String {
        switch tool {
        case .read, .edit, .write:
            if let path = input["file_path"] ?? input["path"], !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case .bash, .bashOutput, .killShell:
            if let command = input["command"], !command.isEmpty {
                return firstLine(command)
            }
        case .grep:
            if let pattern = input["pattern"] ?? input["query"], !pattern.isEmpty {
                return "pattern: \"\(pattern)\""
            }
        case .glob:
            if let pattern = input["pattern"] ?? input["path"], !pattern.isEmpty {
                return pattern
            }
        case .webFetch:
            return input["url"] ?? ""
        case .webSearch:
            return input["query"] ?? ""
        case .task:
            return input["description"] ?? input["prompt"] ?? ""
        case .mcp, .generic:
            for key in ["query", "path", "file_path", "command", "url", "description"] {
                if let value = input[key], !value.isEmpty {
                    return firstLine(value)
                }
            }
        case .todoWrite, .askUserQuestion, .exitPlanMode, .enterPlanMode:
            break
        }
        return ""
    }

    private static func firstLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).first ?? value
    }

    private static func humanized(_ value: String) -> String {
        let words = value
            .replacingOccurrences(of: "-", with: "_")
            .split(separator: "_")
        guard !words.isEmpty else { return value }
        return words.map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
