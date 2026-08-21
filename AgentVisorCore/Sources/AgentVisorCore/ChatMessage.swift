//
//  ChatMessage.swift
//  AgentVisor
//
//  Models for conversation messages parsed from JSONL
//

import Foundation

public struct ChatMessage: Identifiable, Equatable, Codable {

    public init(
        id: String,
        role: ChatRole,
        timestamp: Date,
        content: [MessageBlock],
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.content = content
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }
    public let id: String
    public let role: ChatRole
    public let timestamp: Date
    public let content: [MessageBlock]
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?

    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }

    /// Plain text content combined
    public nonisolated var textContent: String {
        let textParts = content.compactMap { block in
            if case .text(let text) = block {
                return text
            }
            return nil
        }
        if !textParts.isEmpty {
            return textParts.joined(separator: "\n")
        }
        return content.contains { block in
            if case .image = block { return true }
            return false
        } ? "[Image]" : ""
    }
}

public enum ChatRole: String, Equatable, Codable {
    case user
    case assistant
    case system
}

public enum MessageBlock: Equatable, Identifiable, Codable {
    case text(String)
    case image(ChatImageAttachment)
    case toolUse(ToolUseBlock)
    case thinking(String)
    case interrupted
    case turnDuration(durationMs: Int)
    case recap(String)
    case compactBoundary(summary: String?, preTokens: Int?, trigger: String?)
    case localCommandOutput(String)

    public var id: String {
        switch self {
        case .text(let text):
            return "text-\(text.prefix(20).hashValue)"
        case .image(let image):
            return "image-\(image.value.prefix(40).hashValue)"
        case .toolUse(let block):
            return "tool-\(block.id)"
        case .thinking(let text):
            return "thinking-\(text.prefix(20).hashValue)"
        case .interrupted:
            return "interrupted"
        case .turnDuration(let ms):
            return "duration-\(ms)"
        case .recap(let text):
            return "recap-\(text.prefix(20).hashValue)"
        case .compactBoundary(_, let preTokens, _):
            return "compact-\(preTokens ?? 0)"
        case .localCommandOutput(let text):
            return "local-cmd-\(text.prefix(20).hashValue)"
        }
    }

    /// Type prefix for generating stable IDs
    public nonisolated var typePrefix: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .toolUse: return "tool"
        case .thinking: return "thinking"
        case .interrupted: return "interrupted"
        case .turnDuration: return "duration"
        case .recap: return "recap"
        case .compactBoundary: return "compact"
        case .localCommandOutput: return "local-cmd"
        }
    }
}

public struct ChatImageAttachment: Equatable, Codable, Sendable {

    public init(
        source: Source,
        value: String
    ) {
        self.source = source
        self.value = value
    }
    public enum Source: String, Codable, Sendable {
        case localPath
        case dataURI
    }

    public let source: Source
    public let value: String

    public nonisolated var displayName: String {
        switch source {
        case .localPath:
            return URL(fileURLWithPath: value).lastPathComponent
        case .dataURI:
            return "Attached image"
        }
    }
}

public struct ToolUseBlock: Equatable, Codable {

    public init(
        id: String,
        name: String,
        input: [String: String]
    ) {
        self.id = id
        self.name = name
        self.input = input
    }
    public let id: String
    public let name: String
    public let input: [String: String]

    /// Short preview of the tool input
    public var preview: String {
        if let filePath = input["file_path"] ?? input["path"] {
            return filePath
        }
        if let command = input["command"] {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            return String(firstLine.prefix(50))
        }
        if let pattern = input["pattern"] {
            return pattern
        }
        return input.values.first.map { String($0.prefix(50)) } ?? ""
    }
}
