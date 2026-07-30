import Foundation
import AgentVisorCore

/// Adapts Pi's versioned tree-shaped session JSONL to Agent Visor's shared
/// transcript model. PiTranscriptParser owns active-branch reconstruction;
/// this actor only projects Core values and caches the latest derived state.
actor PiConversationParser {
    static let shared = PiConversationParser()

    private var completed: [String: Set<String>] = [:]
    private var results: [String: [String: ConversationParser.ToolResult]] = [:]
    private var infos: [String: ConversationInfo] = [:]
    private var markers: [String: TurnMarker] = [:]

    func parseFullConversation(sessionId: String, transcriptPath: String) -> [ChatMessage] {
        guard let data = FileManager.default.contents(atPath: transcriptPath) else {
            clear(sessionId)
            return []
        }

        let parsed = PiTranscriptParser.parse(data: data)
        completed[sessionId] = parsed.completedToolIds
        results[sessionId] = Dictionary(uniqueKeysWithValues: parsed.toolOutputs.map { id, output in
            (id, ConversationParser.ToolResult(
                content: output,
                stdout: output,
                stderr: nil,
                isError: parsed.failedToolIds.contains(id)
            ))
        })
        markers[sessionId] = parsed.lastTurnMarker

        let messages = parsed.messages.map { message in
            ChatMessage(
                id: message.id,
                role: chatRole(from: message.role),
                timestamp: message.timestamp,
                content: message.blocks.map(chatBlock(from:)),
                model: message.role == .assistant ? parsed.modelName : nil
            )
        }
        infos[sessionId] = buildInfo(parsed: parsed, messages: messages)
        return messages
    }

    func completedToolIds(for sessionId: String) -> Set<String> {
        completed[sessionId] ?? []
    }

    func toolResults(for sessionId: String) -> [String: ConversationParser.ToolResult] {
        results[sessionId] ?? [:]
    }

    func conversationInfo(for sessionId: String) -> ConversationInfo {
        infos[sessionId] ?? emptyInfo()
    }

    func lastTurnMarker(for sessionId: String) -> TurnMarker {
        markers[sessionId] ?? .none
    }

    private func clear(_ sessionId: String) {
        completed[sessionId] = []
        results[sessionId] = [:]
        infos[sessionId] = emptyInfo()
        markers[sessionId] = TurnMarker.none
    }

    private func chatRole(from role: PiParsedRole) -> ChatRole {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        }
    }

    private func chatBlock(from block: PiParsedBlock) -> MessageBlock {
        switch block {
        case .text(let text):
            return .text(text)
        case .image(let image):
            return .image(ChatImageAttachment(source: .dataURI, value: image.dataURI))
        case .thinking(let text):
            return .thinking(text)
        case .toolCall(let tool):
            return .toolUse(ToolUseBlock(id: tool.id, name: tool.name, input: tool.input))
        case .recap(let summary):
            return .recap(summary)
        case .compactBoundary(let summary, let preTokens):
            return .compactBoundary(summary: summary, preTokens: preTokens, trigger: nil)
        case .localCommandOutput(let output):
            return .localCommandOutput(output)
        case .interrupted:
            return .interrupted
        }
    }

    private func buildInfo(parsed: PiParsedTranscript, messages: [ChatMessage]) -> ConversationInfo {
        let firstUser = messages.first { $0.role == .user }?.textContent
        let lastRenderable = messages.last
        let lastTool = messages.reversed().compactMap { message -> String? in
            for block in message.content.reversed() {
                if case .toolUse(let tool) = block { return tool.name }
            }
            return nil
        }.first
        let catalogMetadata = piModelMetadata(for: parsed)
        let lastRole: String? = {
            guard let message = lastRenderable else { return nil }
            if message.content.contains(where: { if case .toolUse = $0 { return true } else { return false } }) {
                return "tool"
            }
            return message.role.rawValue
        }()
        return ConversationInfo(
            summary: nil,
            lastMessage: lastRenderable?.textContent,
            lastMessageRole: lastRole,
            lastToolName: lastTool,
            firstUserMessage: firstUser,
            lastUserMessageDate: messages.last { $0.role == .user }?.timestamp,
            lastActivityDate: lastRenderable?.timestamp,
            lastCwd: parsed.metadata?.cwd,
            customTitle: parsed.sessionName,
            lastModelName: parsed.modelName,
            lastModelDisplayName: catalogMetadata?.displayName,
            lastContextTokens: parsed.contextTokens,
            lastContextWindowTokens: catalogMetadata?.contextWindowTokens,
            lastEffortLevel: parsed.effortLevel,
            lastPermissionMode: nil
        )
    }

    private func piModelMetadata(for parsed: PiParsedTranscript) -> PiModelCatalogMetadata? {
        let catalogURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi")
            .appendingPathComponent("agent")
            .appendingPathComponent("models-store.json")
        guard let catalogData = FileManager.default.contents(atPath: catalogURL.path) else {
            return nil
        }
        return PiModelCatalogResolver.metadata(
            catalogData: catalogData,
            provider: parsed.modelProvider,
            modelID: parsed.modelName
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
