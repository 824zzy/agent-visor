//
//  CodexConversationParser.swift
//  AgentVisor
//
//  Adapter from Codex rollout JSONL into Agent Visor's chat-history
//  model. Kept separate from ConversationParser so Claude Code parsing
//  remains untouched.
//

import Foundation
import AgentVisorCore

actor CodexConversationParser {
    static let shared = CodexConversationParser()

    private struct ParsedFile: Sendable {
        let byteCount: Int
        let parsed: CodexParsedTranscript?
    }

    private struct ParseCacheEntry {
        let signature: CodexRolloutFileSignature
        let messages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]
        let info: ConversationInfo
        let marker: TurnMarker
    }

    private var cache: [String: ParseCacheEntry] = [:]
    private var inFlight: [String: (signature: CodexRolloutFileSignature, task: Task<ParsedFile, Never>)] = [:]
    private var completed: [String: Set<String>] = [:]
    private var results: [String: [String: ConversationParser.ToolResult]] = [:]
    private var infos: [String: ConversationInfo] = [:]
    /// Last turn-boundary marker per session, cached from the most recent
    /// parse. Lets phase inference read "is the turn done?" without a
    /// second parse — populated on every `parseFullConversation` (which
    /// already runs on each codex file-extend).
    private var markers: [String: TurnMarker] = [:]

    func parseFullConversation(sessionId: String) async -> [ChatMessage] {
        await parseFullConversationAttempt(sessionId: sessionId)
    }

    private func parseFullConversationAttempt(sessionId: String) async -> [ChatMessage] {
        let path = await MainActor.run {
            CodexThreadStore.thread(id: sessionId)?.rolloutPath
        }
        guard let path,
              let signature = Self.signature(path: path) else {
            completed[sessionId] = []
            results[sessionId] = [:]
            infos[sessionId] = CodexConversationInfoBuilder.empty()
            markers[sessionId] = TurnMarker.none
            await writeLog("[CodexParse] \(sessionId.prefix(8)) NO path/data (path=\(path ?? "nil"))")
            return []
        }

        if let cached = cache[sessionId],
           cached.signature == signature {
            apply(cached, sessionId: sessionId)
            return cached.messages
        }

        let parsedFile: ParsedFile
        if let current = inFlight[sessionId],
           current.signature == signature {
            parsedFile = await current.task.value
        } else {
            let task = Task.detached(priority: .utility) {
                guard let data = FileManager.default.contents(atPath: path) else {
                    return ParsedFile(byteCount: 0, parsed: nil)
                }
                return ParsedFile(
                    byteCount: data.count,
                    parsed: CodexTranscriptParser.parse(data: data)
                )
            }
            inFlight[sessionId] = (signature, task)
            parsedFile = await task.value
            if inFlight[sessionId]?.signature == signature {
                inFlight[sessionId] = nil
            }
        }

        guard let latestSignature = Self.signature(path: path) else {
            completed[sessionId] = []
            results[sessionId] = [:]
            infos[sessionId] = CodexConversationInfoBuilder.empty()
            markers[sessionId] = TurnMarker.none
            cache.removeValue(forKey: sessionId)
            await writeLog("[CodexParse] \(sessionId.prefix(8)) NO path/data (path=\(path))")
            return []
        }
        if latestSignature != signature {
            if let cached = cache[sessionId],
               (cached.signature == latestSignature || cached.signature.byteCount >= signature.byteCount) {
                apply(cached, sessionId: sessionId)
                return cached.messages
            }
        }

        if let cached = cache[sessionId],
           cached.signature == signature {
            apply(cached, sessionId: sessionId)
            return cached.messages
        }

        guard let parsed = parsedFile.parsed else {
            completed[sessionId] = []
            results[sessionId] = [:]
            infos[sessionId] = CodexConversationInfoBuilder.empty()
            markers[sessionId] = TurnMarker.none
            cache.removeValue(forKey: sessionId)
            await writeLog("[CodexParse] \(sessionId.prefix(8)) NO path/data (path=\(path))")
            return []
        }

        var resultMap: [String: ConversationParser.ToolResult] = [:]
        for (id, output) in parsed.toolOutputs {
            // A non-zero exit code marks the command as failed so the chat can
            // render it in the error state. nil (running / MCP) is not an error.
            let failed = (parsed.toolStatuses[id]?.exitCode).map { $0 != 0 } ?? false
            resultMap[id] = ConversationParser.ToolResult(
                content: output, stdout: output, stderr: nil, isError: failed
            )
        }

        let messages = parsed.messages.map { message in
            ChatMessage(
                id: message.id,
                role: chatRole(from: message.role),
                timestamp: message.timestamp,
                content: message.blocks.map(chatBlock(from:)),
                model: message.role == .assistant ? parsed.modelName : nil
            )
        }
        let info = CodexConversationInfoBuilder.build(from: parsed)
        let entry = ParseCacheEntry(
            signature: signature,
            messages: messages,
            completedToolIds: parsed.completedToolIds,
            toolResults: resultMap,
            info: info,
            marker: parsed.lastTurnMarker
        )
        cache[sessionId] = entry
        apply(entry, sessionId: sessionId)
        await writeLog("[CodexParse] \(sessionId.prefix(8)) bytes=\(parsedFile.byteCount) parsedMsgs=\(parsed.messages.count) path=\(path)")
        return messages
    }

    private static func signature(path: String) -> CodexRolloutFileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return CodexRolloutFileSignature(
            path: path,
            byteCount: size.int64Value
        )
    }

    private func apply(_ entry: ParseCacheEntry, sessionId: String) {
        completed[sessionId] = entry.completedToolIds
        results[sessionId] = entry.toolResults
        infos[sessionId] = entry.info
        markers[sessionId] = entry.marker
    }

    private func writeLog(_ message: String) async {
        await MainActor.run {
            AgentDiscoveryUtilities.writeLog(message)
        }
    }

    func completedToolIds(for sessionId: String) -> Set<String> {
        completed[sessionId] ?? []
    }

    func toolResults(for sessionId: String) -> [String: ConversationParser.ToolResult] {
        results[sessionId] ?? [:]
    }

    func conversationInfo(for sessionId: String) -> ConversationInfo {
        infos[sessionId] ?? CodexConversationInfoBuilder.empty()
    }

    /// Last turn-boundary marker from the most recent parse of this
    /// session's rollout. `.completed` ⇒ it's the user's turn.
    func lastTurnMarker(for sessionId: String) -> TurnMarker {
        markers[sessionId] ?? .none
    }

    func updateLastTurnMarker(sessionId: String, marker: TurnMarker) {
        markers[sessionId] = marker
    }

    private func chatRole(from role: CodexParsedRole) -> ChatRole {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        }
    }

    /// Map an enriched Codex tool call onto a ToolUseBlock the chat renderer
    /// understands. Shell calls reuse the command-rendering header (so the row
    /// shows `$ <cmd>` instead of the raw "exec_command"); update_plan reads as
    /// "Plan"; MCP/other keep their function name.
    private func toolUseBlock(from tool: CodexParsedToolCall) -> ToolUseBlock {
        switch tool.kind {
        case .shell:
            var input = tool.input
            input["command"] = tool.command ?? tool.input["cmd"] ?? ""
            return ToolUseBlock(id: tool.id, name: "Shell", input: input)
        case .plan:
            return ToolUseBlock(id: tool.id, name: "Plan", input: tool.input)
        case .mcp, .other:
            return ToolUseBlock(id: tool.id, name: tool.name, input: tool.input)
        }
    }

    private func chatBlock(from block: CodexParsedBlock) -> MessageBlock {
        switch block {
        case .text(let text):
            return .text(text)
        case .image(let image):
            return .image(chatImage(from: image))
        case .detail(let text):
            return .thinking(text)
        case .toolCall(let tool):
            return .toolUse(toolUseBlock(from: tool))
        case .turnDuration(let durationMs):
            return .turnDuration(durationMs: durationMs)
        }
    }

    private func chatImage(from image: CodexParsedImage) -> ChatImageAttachment {
        let source: ChatImageAttachment.Source = {
            switch image.source {
            case .localPath: return .localPath
            case .dataURI: return .dataURI
            }
        }()
        return ChatImageAttachment(source: source, value: image.value)
    }

}
