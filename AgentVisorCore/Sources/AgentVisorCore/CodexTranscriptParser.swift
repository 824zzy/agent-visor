import Foundation

public struct CodexParsedTranscript: Equatable, Sendable {
    public var metadata: CodexTranscriptMetadata?
    public var modelName: String?
    public var effortLevel: String?
    public var approvalPolicy: String?
    public var sandboxPolicyType: String?
    public var contextTokens: Int?
    public var contextWindowTokens: Int?
    public var messages: [CodexParsedMessage]
    public var completedToolIds: Set<String>
    public var toolOutputs: [String: String]
    /// Per-tool-call terminal status (exit code / running), keyed by call id.
    public var toolStatuses: [String: CodexToolStatus]
    /// The last turn-boundary marker seen in the rollout. Drives
    /// deterministic phase inference for observed Codex.app GUI threads:
    /// `.completed` → it's the user's turn, `.started` → a turn is running.
    public var lastTurnMarker: TurnMarker

    public init(
        metadata: CodexTranscriptMetadata? = nil,
        modelName: String? = nil,
        effortLevel: String? = nil,
        approvalPolicy: String? = nil,
        sandboxPolicyType: String? = nil,
        contextTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        messages: [CodexParsedMessage] = [],
        completedToolIds: Set<String> = [],
        toolOutputs: [String: String] = [:],
        toolStatuses: [String: CodexToolStatus] = [:],
        lastTurnMarker: TurnMarker = .none
    ) {
        self.metadata = metadata
        self.modelName = modelName
        self.effortLevel = effortLevel
        self.approvalPolicy = approvalPolicy
        self.sandboxPolicyType = sandboxPolicyType
        self.contextTokens = contextTokens
        self.contextWindowTokens = contextWindowTokens
        self.messages = messages
        self.completedToolIds = completedToolIds
        self.toolOutputs = toolOutputs
        self.toolStatuses = toolStatuses
        self.lastTurnMarker = lastTurnMarker
    }
}

public struct CodexTranscriptMetadata: Equatable, Sendable {
    public let sessionId: String
    public let cwd: String

    public init(sessionId: String, cwd: String) {
        self.sessionId = sessionId
        self.cwd = cwd
    }
}

public struct CodexParsedMessage: Equatable, Sendable {
    public let id: String
    public let role: CodexParsedRole
    public let timestamp: Date
    public let blocks: [CodexParsedBlock]

    public init(id: String, role: CodexParsedRole, timestamp: Date, blocks: [CodexParsedBlock]) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.blocks = blocks
    }
}

public enum CodexParsedRole: String, Equatable, Sendable {
    case user
    case assistant
    case system
}

public struct CodexParsedImage: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case localPath
        case dataURI
    }

    public let source: Source
    public let value: String

    public init(source: Source, value: String) {
        self.source = source
        self.value = value
    }

    public static func fromImageString(_ value: String) -> CodexParsedImage? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:") {
            return CodexParsedImage(source: .dataURI, value: trimmed)
        }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return CodexParsedImage(source: .localPath, value: url.path)
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return CodexParsedImage(source: .localPath, value: trimmed)
        }
        return CodexParsedImage(source: .dataURI, value: trimmed)
    }
}

public enum CodexParsedBlock: Equatable, Sendable {
    case text(String)
    case image(CodexParsedImage)
    case detail(String)
    case toolCall(CodexParsedToolCall)
    case turnDuration(durationMs: Int)
}

/// How a Codex function_call should be presented. `shell` is exec_command
/// (and its folded write_stdin polls); `mcp` is a namespaced tool call;
/// `plan` is update_plan; everything else is `other`.
public enum CodexToolKind: String, Equatable, Sendable {
    case shell
    case mcp
    case plan
    case other
}

public struct CodexParsedToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: CodexToolKind
    /// For `.shell`: the actual command line (exec_command's `cmd`). nil otherwise.
    public let command: String?
    /// For `.mcp`: the originating server namespace (e.g. mcp__github_dotcom). nil otherwise.
    public let server: String?
    public let input: [String: String]

    public init(
        id: String,
        name: String,
        kind: CodexToolKind = .other,
        command: String? = nil,
        server: String? = nil,
        input: [String: String]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.server = server
        self.input = input
    }
}

/// Terminal-style status for a tool call, surfaced so the chat can show a
/// running spinner or a non-zero exit badge without re-parsing the rollout.
public struct CodexToolStatus: Equatable, Sendable {
    public let exitCode: Int?
    public let isRunning: Bool

    public init(exitCode: Int? = nil, isRunning: Bool = false) {
        self.exitCode = exitCode
        self.isRunning = isRunning
    }
}

public enum CodexTranscriptParser {
    public static func parse(data: Data) -> CodexParsedTranscript {
        var parsed = CodexParsedTranscript()
        var ordinal = 0
        // Raw function_call_output bodies, keyed by call_id. Processed in a
        // post-pass so exec_command + its write_stdin polls can be grouped
        // into one terminal session before the envelope is stripped.
        var rawOutputs: [String: String] = [:]

        for line in JSONLLineIterator(data: data) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let topType = json["type"] as? String,
                  let payload = json["payload"] as? [String: Any] else {
                continue
            }

            switch topType {
            case "session_meta":
                if let id = payload["id"] as? String,
                   let cwd = payload["cwd"] as? String {
                    parsed.metadata = CodexTranscriptMetadata(sessionId: id, cwd: cwd)
                }

            case "turn_context":
                if let model = payload["model"] as? String, !model.isEmpty {
                    parsed.modelName = model
                }
                if let effort = payload["effort"] as? String, !effort.isEmpty {
                    parsed.effortLevel = effort
                } else if let collaboration = payload["collaboration_mode"] as? [String: Any],
                          let settings = collaboration["settings"] as? [String: Any],
                          let effort = settings["reasoning_effort"] as? String,
                          !effort.isEmpty {
                    parsed.effortLevel = effort
                }
                if let approvalPolicy = payload["approval_policy"] as? String, !approvalPolicy.isEmpty {
                    parsed.approvalPolicy = approvalPolicy
                }
                if let sandboxPolicy = payload["sandbox_policy"] as? [String: Any],
                   let type = sandboxPolicy["type"] as? String,
                   !type.isEmpty {
                    parsed.sandboxPolicyType = type
                } else if let sandboxMode = payload["sandbox_mode"] as? String, !sandboxMode.isEmpty {
                    parsed.sandboxPolicyType = sandboxMode
                }
                if let permissionProfile = payload["permission_profile"] as? [String: Any],
                   permissionProfile["type"] as? String == "disabled" {
                    if parsed.approvalPolicy == nil {
                        parsed.approvalPolicy = "never"
                    }
                    if parsed.sandboxPolicyType == nil {
                        parsed.sandboxPolicyType = "danger-full-access"
                    }
                }

            case "response_item":
                ordinal += 1
                parseResponseItem(
                    payload,
                    timestamp: parseTimestamp(json["timestamp"]),
                    ordinal: ordinal,
                    into: &parsed,
                    rawOutputs: &rawOutputs
                )

            case "event_msg":
                ordinal += 1
                parseEventMessage(
                    payload,
                    timestamp: parseTimestamp(json["timestamp"]),
                    ordinal: ordinal,
                    into: &parsed
                )

            default:
                continue
            }
        }

        groupTerminalSessions(&parsed, rawOutputs: rawOutputs)
        return parsed
    }

    private static func parseResponseItem(
        _ payload: [String: Any],
        timestamp: Date,
        ordinal: Int,
        into parsed: inout CodexParsedTranscript,
        rawOutputs: inout [String: String]
    ) {
        guard let itemType = payload["type"] as? String else { return }

        switch itemType {
        case "message":
            guard let role = parseRole(payload["role"] as? String),
                  role != .user,
                  let text = textContent(from: payload["content"] as? [[String: Any]]),
                  !text.isEmpty else {
                return
            }
            let id = payload["id"] as? String ?? "codex-message-\(ordinal)"
            let phase = payload["phase"] as? String
            let block: CodexParsedBlock
            let messageRole: CodexParsedRole
            if role == .assistant, phase == "commentary" {
                // Codex collapses a turn's interim commentary inside its
                // "Worked for X" disclosure. Emit it as a nestable detail
                // item (not top-level prose) so groupedTimelineRows tucks it
                // under the turn-duration parent with the tool calls, leaving
                // only the final answer shown.
                block = .detail(text)
                messageRole = .system
            } else {
                guard isVisibleMessage(role: role, text: text, phase: phase) else { return }
                block = .text(text)
                messageRole = role
            }
            parsed.messages.append(CodexParsedMessage(
                id: id,
                role: messageRole,
                timestamp: timestamp,
                blocks: [block]
            ))
            if role == .assistant, phase == "final_answer" {
                parsed.lastTurnMarker = .completed
            }

        case "function_call":
            guard let name = payload["name"] as? String,
                  let callId = payload["call_id"] as? String else {
                return
            }
            let input = parseArguments(payload["arguments"] as? String)
            let namespace = payload["namespace"] as? String
            let (kind, command, server) = classifyTool(name: name, namespace: namespace, input: input)
            parsed.messages.append(CodexParsedMessage(
                id: callId,
                role: .system,
                timestamp: timestamp,
                blocks: [.toolCall(CodexParsedToolCall(
                    id: callId,
                    name: name,
                    kind: kind,
                    command: command,
                    server: server,
                    input: input
                ))]
            ))

        case "function_call_output":
            guard let callId = payload["call_id"] as? String else { return }
            if let output = payload["output"] as? String {
                rawOutputs[callId] = output
            } else if let output = payload["output"],
                      JSONSerialization.isValidJSONObject(output),
                      let data = try? JSONSerialization.data(withJSONObject: output),
                      let json = String(data: data, encoding: .utf8) {
                // Rare: `output` is already a JSON array (e.g. view_image). Keep
                // it as a string so the envelope parser can unwrap it uniformly.
                rawOutputs[callId] = json
            }

        default:
            return
        }
    }

    /// Post-pass: strip the output envelope, fold each long-running
    /// exec_command's write_stdin polls into one terminal session, and record
    /// per-tool status. Run after the full single pass so every output and the
    /// "Process running with session ID N" linkage is available.
    private static func groupTerminalSessions(
        _ parsed: inout CodexParsedTranscript,
        rawOutputs: [String: String]
    ) {
        let cleaned = rawOutputs.mapValues { CodexCommandOutputParser.parse($0) }

        // Gather exec ids and write_stdin children (in document order) from the
        // tool-call blocks. write_stdin carries session_id + chars in `input`.
        var execIds: [String] = []
        var stdinChildren: [(callId: String, sessionID: Int, chars: String)] = []
        for message in parsed.messages {
            for block in message.blocks {
                guard case .toolCall(let call) = block else { continue }
                if call.name == "exec_command" {
                    execIds.append(call.id)
                } else if call.name == "write_stdin",
                          let sid = Int(call.input["session_id"] ?? "") {
                    stdinChildren.append((call.id, sid, call.input["chars"] ?? ""))
                }
            }
        }

        // A PTY session is owned by the exec_command whose own output reported
        // "Process running with session ID N".
        var sessionOwner: [Int: String] = [:]
        for execId in execIds {
            if let sid = cleaned[execId]?.sessionID {
                sessionOwner[sid] = execId
            }
        }

        var childrenByExec: [String: [(callId: String, chars: String)]] = [:]
        var foldedIds: Set<String> = []
        for child in stdinChildren {
            guard let owner = sessionOwner[child.sessionID] else { continue }
            childrenByExec[owner, default: []].append((child.callId, child.chars))
            foldedIds.insert(child.callId)
        }

        var toolOutputs: [String: String] = [:]
        var toolStatuses: [String: CodexToolStatus] = [:]
        var completed: Set<String> = []

        let execIdSet = Set(execIds)
        for execId in execIds {
            let children = childrenByExec[execId] ?? []
            guard cleaned[execId] != nil || !children.isEmpty else {
                toolStatuses[execId] = CodexToolStatus(exitCode: nil, isRunning: true)
                continue
            }

            var pieces: [String] = []
            if let own = cleaned[execId], !own.text.isEmpty {
                pieces.append(own.text)
            }
            var last = cleaned[execId]
            for child in children {
                if !child.chars.isEmpty {
                    pieces.append("› " + caretEscape(child.chars))
                }
                if let out = cleaned[child.callId] {
                    if !out.text.isEmpty { pieces.append(out.text) }
                    last = out
                }
            }
            if !pieces.isEmpty {
                toolOutputs[execId] = pieces.joined(separator: "\n")
            }
            toolStatuses[execId] = CodexToolStatus(
                exitCode: last?.exitCode,
                isRunning: last?.isRunning ?? false
            )
            completed.insert(execId)
        }

        // MCP / plan / other tool calls (anything with output that isn't an
        // exec session or a folded poll).
        for (callId, out) in cleaned where !execIdSet.contains(callId) && !foldedIds.contains(callId) {
            toolOutputs[callId] = out.text
            toolStatuses[callId] = CodexToolStatus(exitCode: out.exitCode, isRunning: out.isRunning)
            completed.insert(callId)
        }

        // Drop the folded write_stdin tool-call blocks (and any message left
        // empty by their removal) so they don't render as standalone rows.
        if !foldedIds.isEmpty {
            parsed.messages = parsed.messages.compactMap { message in
                let kept = message.blocks.filter { block in
                    if case .toolCall(let call) = block { return !foldedIds.contains(call.id) }
                    return true
                }
                guard !kept.isEmpty else { return nil }
                return CodexParsedMessage(
                    id: message.id,
                    role: message.role,
                    timestamp: message.timestamp,
                    blocks: kept
                )
            }
        }

        parsed.toolOutputs = toolOutputs
        parsed.toolStatuses = toolStatuses
        parsed.completedToolIds = completed
    }

    /// Render control characters in caret notation (^C for 0x03) so the agent's
    /// stdin (often an interrupt) is legible in the folded terminal output.
    private static func caretEscape(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x7F:
                result += "^?"
            case let v where v < 0x20:
                result.append("^")
                result.unicodeScalars.append(Unicode.Scalar(v + 64)!)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func parseEventMessage(
        _ payload: [String: Any],
        timestamp: Date,
        ordinal: Int,
        into parsed: inout CodexParsedTranscript
    ) {
        guard let eventType = payload["type"] as? String else { return }

        switch eventType {
        case "user_message":
            let blocks = userMessageBlocks(from: payload)
            guard !blocks.isEmpty else { return }
            parsed.messages.append(CodexParsedMessage(
                id: "codex-user-\(ordinal)",
                role: .user,
                timestamp: timestamp,
                blocks: blocks
            ))

        case "task_started":
            parsed.lastTurnMarker = .started
            if let window = payload["model_context_window"] as? Int, window > 0 {
                parsed.contextWindowTokens = window
            }

        case "turn_aborted":
            // An interrupted turn (Esc / a new prompt sent mid-run) ends the
            // turn without a task_complete. Treat it as a turn boundary so
            // phase inference doesn't leave the thread stuck on .processing
            // until the stale ceiling. No duration block — it's an abort.
            parsed.lastTurnMarker = .completed

        case "task_complete":
            // Record the turn boundary regardless of duration — phase
            // inference cares only that the turn ended, not how long it
            // took. The duration-block insertion below is a separate,
            // cosmetic concern that still requires a valid duration.
            parsed.lastTurnMarker = .completed
            guard let durationMs = payload["duration_ms"] as? Int, durationMs > 0 else {
                return
            }
            let turnId = payload["turn_id"] as? String
            let insertionIndex = durationInsertionIndex(in: parsed.messages)
            let message = CodexParsedMessage(
                id: turnId ?? "codex-duration-\(ordinal)",
                role: .system,
                timestamp: durationTimestamp(
                    in: parsed.messages,
                    insertionIndex: insertionIndex,
                    fallback: timestamp
                ),
                blocks: [.turnDuration(durationMs: durationMs)]
            )
            parsed.messages.insert(message, at: insertionIndex)

        case "token_count":
            guard let info = payload["info"] as? [String: Any] else { return }
            if let usage = info["last_token_usage"] as? [String: Any] {
                parsed.contextTokens = usage["total_tokens"] as? Int
                    ?? usage["input_tokens"] as? Int
            }
            if let window = info["model_context_window"] as? Int, window > 0 {
                parsed.contextWindowTokens = window
            }

        default:
            return
        }
    }

    private static func userMessageBlocks(from payload: [String: Any]) -> [CodexParsedBlock] {
        let images = imageReferences(from: payload)
        let raw = payload["message"] as? String ?? ""
        var blocks: [CodexParsedBlock] = []
        if let text = CodexUserMessageText.visibleText(
            raw: raw,
            imageCount: images.count,
            includeImagePlaceholder: false
        ), !text.isEmpty {
            blocks.append(.text(text))
        }
        blocks.append(contentsOf: images.map { .image($0) })
        return blocks
    }

    private static func imageReferences(from payload: [String: Any]) -> [CodexParsedImage] {
        var images: [CodexParsedImage] = []
        for path in stringArray(payload["local_images"]) {
            if let image = CodexParsedImage.fromImageString(path) {
                images.append(CodexParsedImage(source: .localPath, value: image.value))
            }
        }
        for value in stringArray(payload["images"]) {
            if let image = CodexParsedImage.fromImageString(value) {
                images.append(image)
            }
        }
        return images
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private static func isVisibleMessage(role: CodexParsedRole, text: String, phase: String?) -> Bool {
        switch role {
        case .user:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.hasPrefix("<environment_context>")
                && !trimmed.hasPrefix("<developer_context>")
                && !trimmed.hasPrefix("<permissions instructions>")
                && !trimmed.hasPrefix("<app-context>")
                && !trimmed.hasPrefix("<skills_instructions>")
        case .assistant:
            return phase == nil || phase == "final_answer"
        case .system:
            return true
        }
    }

    private static func durationInsertionIndex(in messages: [CodexParsedMessage]) -> Int {
        if let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) {
            return messages.index(after: lastUserIndex)
        }
        if let lastAssistantIndex = messages.lastIndex(where: { $0.role == .assistant }) {
            return lastAssistantIndex
        }
        return messages.endIndex
    }

    private static func durationTimestamp(
        in messages: [CodexParsedMessage],
        insertionIndex: Int,
        fallback: Date
    ) -> Date {
        let previous = insertionIndex > messages.startIndex ? messages[messages.index(before: insertionIndex)].timestamp : nil
        let next = insertionIndex < messages.endIndex ? messages[insertionIndex].timestamp : nil

        if let previous, let next, next > previous {
            return previous.addingTimeInterval(next.timeIntervalSince(previous) / 2)
        }
        if let previous {
            return previous.addingTimeInterval(0.001)
        }
        if let next {
            return next.addingTimeInterval(-0.001)
        }
        return fallback
    }

    private static func classifyTool(
        name: String,
        namespace: String?,
        input: [String: String]
    ) -> (kind: CodexToolKind, command: String?, server: String?) {
        if let namespace, !namespace.isEmpty {
            return (.mcp, nil, namespace)
        }
        switch name {
        case "exec_command":
            return (.shell, input["cmd"], nil)
        case "write_stdin":
            return (.shell, nil, nil)
        case "update_plan":
            return (.plan, nil, nil)
        default:
            return (.other, nil, nil)
        }
    }

    private static func parseRole(_ raw: String?) -> CodexParsedRole? {
        switch raw {
        case "user": return .user
        case "assistant": return .assistant
        case "system": return .system
        default: return nil
        }
    }

    private static func textContent(from content: [[String: Any]]?) -> String? {
        guard let content else { return nil }
        let parts = content.compactMap { block -> String? in
            guard let type = block["type"] as? String,
                  type == "input_text" || type == "output_text",
                  let text = block["text"] as? String else {
                return nil
            }
            return text
        }
        guard !parts.isEmpty else { return nil }
        // Strip Codex's internal `<oai-mem-citation>…</oai-mem-citation>`
        // memory trailer it appends to final answers — Codex's own UI
        // hides it; without this it leaks into the rendered chat.
        let joined = CodexMemoryCitationStripper.strip(parts.joined(separator: "\n"))
        return joined.isEmpty ? nil : joined
    }

    private static func parseArguments(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return stringifyDictionary(object)
    }

    private static func stringifyDictionary(_ object: [String: Any]) -> [String: String] {
        var output: [String: String] = [:]
        for (key, value) in object {
            if let str = value as? String {
                output[key] = str
            } else if let int = value as? Int {
                output[key] = String(int)
            } else if let double = value as? Double {
                output[key] = String(double)
            } else if let bool = value as? Bool {
                output[key] = bool ? "true" : "false"
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let json = String(data: data, encoding: .utf8) {
                output[key] = json
            }
        }
        return output
    }

    private static func parseTimestamp(_ raw: Any?) -> Date {
        guard let string = raw as? String else { return Date(timeIntervalSince1970: 0) }
        return iso8601.date(from: string) ?? Date(timeIntervalSince1970: 0)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
