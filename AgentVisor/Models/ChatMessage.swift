//
//  ChatMessage.swift
//  AgentVisor
//
//  Models for conversation messages parsed from JSONL
//

import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: String
    let role: ChatRole
    let timestamp: Date
    let content: [MessageBlock]
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheCreationTokens: Int?

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }

    /// Plain text content combined
    nonisolated var textContent: String {
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

enum ChatRole: String, Equatable, Codable {
    case user
    case assistant
    case system
}

enum MessageBlock: Equatable, Identifiable, Codable {
    case text(String)
    case image(ChatImageAttachment)
    case toolUse(ToolUseBlock)
    case thinking(String)
    case interrupted
    case turnDuration(durationMs: Int)
    case recap(String)
    case compactBoundary(summary: String?, preTokens: Int?, trigger: String?)
    case localCommandOutput(String)

    var id: String {
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
    nonisolated var typePrefix: String {
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

struct ChatImageAttachment: Equatable, Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case localPath
        case dataURI
    }

    let source: Source
    let value: String

    nonisolated var displayName: String {
        switch source {
        case .localPath:
            return URL(fileURLWithPath: value).lastPathComponent
        case .dataURI:
            return "Attached image"
        }
    }
}

struct ToolUseBlock: Equatable, Codable {
    let id: String
    let name: String
    let input: [String: String]

    /// Short preview of the tool input
    var preview: String {
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
