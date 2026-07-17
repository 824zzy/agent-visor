//
//  CursorConversationParser.swift
//  AgentVisor
//
//  Adapter from Cursor's `cursor-agent` rollout JSONL into Claude
//  Visor's chat-history model. Kept separate from `ConversationParser`
//  and `CodexConversationParser` so each agent's parser can evolve
//  independently of the others.
//
//  Cursor transcript parsing is read-only. Host-specific send paths live
//  outside the parser because Cursor exposes no transcript-side hook seam.
//

import Foundation
import AgentVisorCore

actor CursorConversationParser {
    static let shared = CursorConversationParser()

    private var completed: [String: Set<String>] = [:]
    private var infos: [String: ConversationInfo] = [:]

    func parseFullConversation(sessionId: String, transcriptPath: String) -> [ChatMessage] {
        guard let data = FileManager.default.contents(atPath: transcriptPath) else {
            completed[sessionId] = []
            infos[sessionId] = emptyInfo()
            return []
        }

        let parsed = CursorTranscriptParser.parse(data: data)
        completed[sessionId] = parsed.completedToolIds

        let messages = parsed.messages.map { message in
            ChatMessage(
                id: message.id,
                role: chatRole(from: message.role),
                timestamp: message.timestamp,
                content: message.blocks.map(chatBlock(from:)),
                model: nil
            )
        }

        infos[sessionId] = buildInfo(from: messages)
        return messages
    }

    func completedToolIds(for sessionId: String) -> Set<String> {
        completed[sessionId] ?? []
    }

    /// Cursor doesn't store tool outputs in its rollout, so we have no
    /// `ToolResult` payloads to surface. Returning empty matches the
    /// shape ChatHistoryManager expects without forcing it to special-
    /// case Cursor at the call site.
    func toolResults(for sessionId: String) -> [String: ConversationParser.ToolResult] {
        [:]
    }

    func conversationInfo(for sessionId: String) -> ConversationInfo {
        infos[sessionId] ?? emptyInfo()
    }

    private func chatRole(from role: CursorParsedRole) -> ChatRole {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        }
    }

    private func chatBlock(from block: CursorParsedBlock) -> MessageBlock {
        switch block {
        case .text(let text):
            return .text(text)
        case .toolCall(let tool):
            return .toolUse(ToolUseBlock(id: tool.id, name: tool.name, input: tool.input))
        }
    }

    private func buildInfo(from messages: [ChatMessage]) -> ConversationInfo {
        let firstUser = messages.first { $0.role == .user }?.textContent
        let lastRenderable = messages.last
        let lastTool = messages.reversed().compactMap { message -> String? in
            for block in message.content.reversed() {
                if case .toolUse(let tool) = block {
                    return tool.name
                }
            }
            return nil
        }.first
        let lastRole: String? = {
            guard let message = lastRenderable else { return nil }
            if message.content.contains(where: { if case .toolUse = $0 { return true } else { return false } }) {
                return "tool"
            }
            return message.role.rawValue
        }()
        let lastUserDate = messages.last { $0.role == .user }?.timestamp
        return ConversationInfo(
            summary: nil,
            lastMessage: lastRenderable?.textContent,
            lastMessageRole: lastRole,
            lastToolName: lastTool,
            firstUserMessage: firstUser,
            lastUserMessageDate: lastUserDate,
            lastActivityDate: lastRenderable?.timestamp,
            lastCwd: nil,
            lastModelName: nil,
            lastContextTokens: nil,
            lastContextWindowTokens: nil,
            lastEffortLevel: nil,
            lastPermissionMode: nil
        )
    }

    private func emptyInfo() -> ConversationInfo {
        ConversationInfo(
            summary: nil,
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            firstUserMessage: nil,
            lastUserMessageDate: nil,
            lastCwd: nil,
            lastModelName: nil,
            lastContextTokens: nil,
            lastContextWindowTokens: nil,
            lastEffortLevel: nil,
            lastPermissionMode: nil
        )
    }
}
