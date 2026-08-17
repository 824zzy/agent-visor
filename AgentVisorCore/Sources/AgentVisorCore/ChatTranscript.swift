//
//  ChatTranscript.swift
//  AgentVisorCore
//
//  The transcript model a session carries: one item per rendered row, the
//  tool calls inside a row, and the subagent calls a Task tool spawns.
//  `SessionState.chatItems` holds these, so they live beside the session
//  model. The manager that fills them in stays in the app.
//

import Foundation

public struct ChatHistoryItem: Identifiable, Equatable, Sendable {

    public init(
        id: String,
        type: ChatHistoryItemType,
        timestamp: Date
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
    }
    public let id: String
    public let type: ChatHistoryItemType
    public let timestamp: Date

    public static func == (lhs: ChatHistoryItem, rhs: ChatHistoryItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type
    }
}

public enum ChatHistoryItemType: Equatable, Sendable {
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

public struct ToolCallItem: Equatable, Sendable {

    public init(
        name: String,
        input: [String: String],
        status: ToolStatus,
        result: String? = nil,
        structuredResult: ToolResultData? = nil,
        subagentTools: [SubagentToolCall]
    ) {
        self.name = name
        self.input = input
        self.status = status
        self.result = result
        self.structuredResult = structuredResult
        self.subagentTools = subagentTools
    }
    public let name: String
    public let input: [String: String]
    public var status: ToolStatus
    public var result: String?
    public var structuredResult: ToolResultData?

    /// For Task tools: nested subagent tool calls
    public var subagentTools: [SubagentToolCall]

    /// Preview text for the tool (input-based)
    public var inputPreview: String {
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
    public var statusDisplay: ToolStatusDisplay {
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
    public static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.name == rhs.name &&
        lhs.input == rhs.input &&
        lhs.status == rhs.status &&
        lhs.result == rhs.result &&
        lhs.structuredResult == rhs.structuredResult &&
        lhs.subagentTools == rhs.subagentTools
    }
}

public enum ToolStatus: Sendable, CustomStringConvertible {
    case running
    case waitingForApproval
    case success
    case error
    case interrupted

    public nonisolated var description: String {
        switch self {
        case .running: return "running"
        case .waitingForApproval: return "waitingForApproval"
        case .success: return "success"
        case .error: return "error"
        case .interrupted: return "interrupted"
        }
    }
}

/// Represents a tool call made by a subagent (Task tool)
public struct SubagentToolCall: Equatable, Identifiable, Sendable {

    public init(
        id: String,
        name: String,
        input: [String: String],
        status: ToolStatus,
        timestamp: Date
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.status = status
        self.timestamp = timestamp
    }
    public let id: String
    public let name: String
    public let input: [String: String]
    public var status: ToolStatus
    public let timestamp: Date

    /// Short description for display
    public var displayText: String {
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
