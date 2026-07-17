//
//  CodexConversationInfoBuilder.swift
//  AgentVisor
//
//  Shared projection from the Core Codex rollout model into Agent Visor's
//  lightweight session metadata.
//

import Foundation
import AgentVisorCore

enum CodexConversationInfoBuilder {
    nonisolated static func build(from parsed: CodexParsedTranscript) -> ConversationInfo {
        let firstUser = parsed.messages.first { $0.role == .user }
            .map(textContent(from:))
        let lastRenderable = parsed.messages.last
        let lastTool = parsed.messages.reversed().compactMap { message -> String? in
            for block in message.blocks.reversed() {
                if case .toolCall(let tool) = block {
                    return displayToolName(for: tool)
                }
            }
            return nil
        }.first
        let lastRole: String? = {
            guard let message = lastRenderable else { return nil }
            if message.blocks.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
                return "tool"
            }
            return message.role.rawValue
        }()
        let lastUserDate = parsed.messages.last { $0.role == .user }?.timestamp

        return ConversationInfo(
            summary: nil,
            lastMessage: lastRenderable.map(textContent(from:)),
            lastMessageRole: lastRole,
            lastToolName: lastTool,
            firstUserMessage: firstUser,
            lastUserMessageDate: lastUserDate,
            lastActivityDate: lastRenderable?.timestamp,
            lastCwd: parsed.metadata?.cwd,
            lastModelName: parsed.modelName,
            lastContextTokens: parsed.contextTokens,
            lastContextWindowTokens: parsed.contextWindowTokens,
            lastEffortLevel: parsed.effortLevel,
            lastPermissionMode: nil,
            lastCodexApprovalPolicy: parsed.approvalPolicy,
            lastCodexSandboxPolicyType: parsed.sandboxPolicyType
        )
    }

    nonisolated static func empty() -> ConversationInfo {
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

    nonisolated private static func textContent(from message: CodexParsedMessage) -> String {
        let textParts = message.blocks.compactMap { block -> String? in
            if case .text(let text) = block {
                return text
            }
            return nil
        }
        if !textParts.isEmpty {
            return textParts.joined(separator: "\n")
        }
        return message.blocks.contains { block in
            if case .image = block { return true }
            return false
        } ? "[Image]" : ""
    }

    nonisolated private static func displayToolName(for tool: CodexParsedToolCall) -> String {
        switch tool.kind {
        case .shell:
            return "Shell"
        case .plan:
            return "Plan"
        case .mcp, .other:
            return tool.name
        }
    }
}
