import Foundation
import AgentVisorCore

struct PiConversationLoadResult: Sendable {
    let history: ParsedHistory
    let didChange: Bool
    let fileChange: PiTranscriptFileChange?
}

/// Adapts Pi's versioned tree-shaped session JSONL to Agent Visor's shared
/// transcript model. Each session retains one signature-aware Core file parser,
/// so full Chat loads and live refreshes share the same incremental tree index.
actor PiConversationParser {
    static let shared = PiConversationParser()

    private var fileParsers: [String: PiIncrementalTranscriptFileParser] = [:]
    private var histories: [String: ParsedHistory] = [:]
    private var markers: [String: TurnMarker] = [:]

    func loadHistory(
        sessionId: String,
        transcriptPath: String
    ) -> PiConversationLoadResult {
        // Take the parser out of the cache while mutating it. A subscript read would
        // leave the cached value sharing the accumulator's CoW dictionaries and turn
        // each small append into a copy of the retained transcript index.
        var fileParser = fileParsers.removeValue(forKey: sessionId)
            ?? PiIncrementalTranscriptFileParser()
        defer {
            fileParsers[sessionId] = fileParser
        }
        let result: PiTranscriptFileParseResult
        do {
            result = try fileParser.parse(path: transcriptPath)
        } catch {
            // Keep the last good projection. A transient replacement/read race
            // must not blank Chat; later watcher or hook evidence retries it.
            return PiConversationLoadResult(
                history: histories[sessionId] ?? Self.emptyHistory(),
                didChange: false,
                fileChange: nil
            )
        }

        let requiresProjection = result.didChange
            || result.change == .rebuilt
            || histories[sessionId] == nil
        guard requiresProjection else {
            return PiConversationLoadResult(
                history: histories[sessionId] ?? Self.emptyHistory(),
                didChange: false,
                fileChange: result.change
            )
        }

        let history = Self.projectHistory(from: result.transcript)
        histories[sessionId] = history
        markers[sessionId] = result.transcript.lastTurnMarker
        return PiConversationLoadResult(
            history: history,
            didChange: true,
            fileChange: result.change
        )
    }

    /// Compatibility seam for phase inference. It now shares the same file
    /// cache instead of performing an independent whole-file read.
    func parseFullConversation(sessionId: String, transcriptPath: String) -> [ChatMessage] {
        loadHistory(sessionId: sessionId, transcriptPath: transcriptPath).history.messages
    }

    func completedToolIds(for sessionId: String) -> Set<String> {
        histories[sessionId]?.completedToolIds ?? []
    }

    func toolResults(for sessionId: String) -> [String: ConversationParser.ToolResult] {
        histories[sessionId]?.toolResults ?? [:]
    }

    func conversationInfo(for sessionId: String) -> ConversationInfo {
        histories[sessionId]?.conversationInfo ?? Self.emptyInfo()
    }

    func lastTurnMarker(for sessionId: String) -> TurnMarker {
        markers[sessionId] ?? .none
    }

    nonisolated static func projectHistory(from parsed: PiParsedTranscript) -> ParsedHistory {
        let messages = parsed.messages.map { message in
            ChatMessage(
                id: message.id,
                role: chatRole(from: message.role),
                timestamp: message.timestamp,
                content: message.blocks.map(chatBlock(from:)),
                model: message.role == .assistant ? parsed.modelName : nil
            )
        }
        let toolResults = Dictionary(uniqueKeysWithValues: parsed.toolOutputs.map { id, output in
            (id, ConversationParser.ToolResult(
                content: output,
                stdout: output,
                stderr: nil,
                isError: parsed.failedToolIds.contains(id)
            ))
        })
        return ParsedHistory(
            messages: messages,
            completedToolIds: parsed.completedToolIds,
            toolResults: toolResults,
            structuredResults: [:],
            conversationInfo: buildInfo(parsed: parsed, messages: messages),
            currentPermissionMode: nil
        )
    }

    nonisolated private static func chatRole(from role: PiParsedRole) -> ChatRole {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        }
    }

    nonisolated private static func chatBlock(from block: PiParsedBlock) -> MessageBlock {
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

    nonisolated private static func buildInfo(
        parsed: PiParsedTranscript,
        messages: [ChatMessage]
    ) -> ConversationInfo {
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

    nonisolated private static func piModelMetadata(
        for parsed: PiParsedTranscript
    ) -> PiModelCatalogMetadata? {
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

    nonisolated static func emptyHistory() -> ParsedHistory {
        ParsedHistory(
            messages: [],
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:],
            conversationInfo: emptyInfo(),
            currentPermissionMode: nil
        )
    }

    nonisolated static func emptyInfo() -> ConversationInfo {
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
