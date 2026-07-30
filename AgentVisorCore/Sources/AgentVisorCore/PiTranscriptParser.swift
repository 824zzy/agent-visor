import Foundation

public struct PiParsedTranscript: Equatable, Sendable {
    public var metadata: PiTranscriptMetadata?
    public var sessionName: String?
    public var modelName: String?
    public var modelProvider: String?
    public var effortLevel: String?
    public var contextTokens: Int?
    public var messages: [PiParsedMessage]
    public var completedToolIds: Set<String>
    public var failedToolIds: Set<String>
    public var toolOutputs: [String: String]
    public var lastTurnMarker: TurnMarker

    public init(
        metadata: PiTranscriptMetadata? = nil,
        sessionName: String? = nil,
        modelName: String? = nil,
        modelProvider: String? = nil,
        effortLevel: String? = nil,
        contextTokens: Int? = nil,
        messages: [PiParsedMessage] = [],
        completedToolIds: Set<String> = [],
        failedToolIds: Set<String> = [],
        toolOutputs: [String: String] = [:],
        lastTurnMarker: TurnMarker = .none
    ) {
        self.metadata = metadata
        self.sessionName = sessionName
        self.modelName = modelName
        self.modelProvider = modelProvider
        self.effortLevel = effortLevel
        self.contextTokens = contextTokens
        self.messages = messages
        self.completedToolIds = completedToolIds
        self.failedToolIds = failedToolIds
        self.toolOutputs = toolOutputs
        self.lastTurnMarker = lastTurnMarker
    }
}

public struct PiTranscriptMetadata: Equatable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let createdAt: Date

    public init(sessionId: String, cwd: String, createdAt: Date) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.createdAt = createdAt
    }
}

public struct PiParsedMessage: Equatable, Sendable {
    public let id: String
    public let role: PiParsedRole
    public let timestamp: Date
    public let blocks: [PiParsedBlock]

    public init(id: String, role: PiParsedRole, timestamp: Date, blocks: [PiParsedBlock]) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.blocks = blocks
    }
}

public enum PiParsedRole: String, Equatable, Sendable {
    case user
    case assistant
    case system
}

public struct PiParsedImage: Equatable, Sendable {
    public let dataURI: String

    public init(dataURI: String) {
        self.dataURI = dataURI
    }
}

public struct PiParsedToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    public let input: [String: String]

    public init(id: String, name: String, input: [String: String]) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public enum PiParsedBlock: Equatable, Sendable {
    case text(String)
    case image(PiParsedImage)
    case thinking(String)
    case toolCall(PiParsedToolCall)
    case recap(String)
    case compactBoundary(summary: String?, preTokens: Int?)
    case localCommandOutput(String)
    case interrupted
}

public enum PiTranscriptParser {
    public static func parse(data: Data) -> PiParsedTranscript {
        var parsed = PiParsedTranscript()
        var entriesByID: [String: [String: Any]] = [:]
        var entryOrder: [String] = []

        for line in JSONLLineIterator(data: data) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            if type == "session",
               let sessionId = json["id"] as? String,
               let cwd = json["cwd"] as? String,
               let createdAt = parseTimestamp(json["timestamp"]) {
                parsed.metadata = PiTranscriptMetadata(
                    sessionId: sessionId,
                    cwd: cwd,
                    createdAt: createdAt
                )
                continue
            }

            guard let id = json["id"] as? String else { continue }
            entriesByID[id] = json
            entryOrder.append(id)
        }

        guard var entryId = entryOrder.last else { return parsed }
        var branch: [[String: Any]] = []
        var visited: Set<String> = []
        while let entry = entriesByID[entryId], visited.insert(entryId).inserted {
            branch.append(entry)
            guard let parentId = entry["parentId"] as? String else { break }
            entryId = parentId
        }

        for entry in branch.reversed() {
            parseEntry(entry, into: &parsed)
        }
        return parsed
    }

    private static func parseEntry(_ entry: [String: Any], into parsed: inout PiParsedTranscript) {
        switch entry["type"] as? String {
        case "message":
            parseMessage(entry, into: &parsed)

        case "model_change":
            if let model = entry["modelId"] as? String, !model.isEmpty {
                parsed.modelName = model
            }
            if let provider = entry["provider"] as? String, !provider.isEmpty {
                parsed.modelProvider = provider
            }

        case "thinking_level_change":
            if let effort = entry["thinkingLevel"] as? String, !effort.isEmpty {
                parsed.effortLevel = effort
            }

        case "branch_summary":
            guard let id = entry["id"] as? String,
                  let timestamp = parseTimestamp(entry["timestamp"]),
                  let summary = entry["summary"] as? String,
                  !summary.isEmpty else { return }
            parsed.messages.append(PiParsedMessage(
                id: id,
                role: .system,
                timestamp: timestamp,
                blocks: [.recap(summary)]
            ))

        case "compaction":
            guard let id = entry["id"] as? String,
                  let timestamp = parseTimestamp(entry["timestamp"]) else { return }
            parsed.messages.append(PiParsedMessage(
                id: id,
                role: .system,
                timestamp: timestamp,
                blocks: [.compactBoundary(
                    summary: entry["summary"] as? String,
                    preTokens: entry["tokensBefore"] as? Int
                )]
            ))

        case "session_info":
            if let name = entry["name"] as? String, !name.isEmpty {
                parsed.sessionName = name
            }

        default:
            return
        }
    }

    private static func parseMessage(_ entry: [String: Any], into parsed: inout PiParsedTranscript) {
        guard let id = entry["id"] as? String,
              let message = entry["message"] as? [String: Any],
              let rawRole = message["role"] as? String,
              let timestamp = parseTimestamp(entry["timestamp"]) else {
            return
        }

        if rawRole == "toolResult" {
            guard let toolCallId = message["toolCallId"] as? String else { return }
            parsed.completedToolIds.insert(toolCallId)
            if message["isError"] as? Bool == true {
                parsed.failedToolIds.insert(toolCallId)
            }
            if let output = joinedText(message["content"]), !output.isEmpty {
                parsed.toolOutputs[toolCallId] = output
            }
            parsed.lastTurnMarker = .started
            return
        }

        if rawRole == "bashExecution" {
            let command = message["command"] as? String ?? ""
            let output = message["output"] as? String ?? ""
            let text = command.isEmpty ? output : "$ \(command)" + (output.isEmpty ? "" : "\n\(output)")
            guard !text.isEmpty else { return }
            parsed.messages.append(PiParsedMessage(
                id: id,
                role: .system,
                timestamp: timestamp,
                blocks: [.localCommandOutput(text)]
            ))
            return
        }

        guard let role = parseRole(rawRole) else { return }
        let stopReason = message["stopReason"] as? String
        var blocks = contentBlocks(message["content"])
        if role == .assistant && (stopReason == "error" || stopReason == "aborted") {
            blocks.append(.interrupted)
        }
        guard !blocks.isEmpty else { return }
        parsed.messages.append(PiParsedMessage(id: id, role: role, timestamp: timestamp, blocks: blocks))

        if let model = message["model"] as? String, !model.isEmpty {
            parsed.modelName = model
        }
        if let provider = message["provider"] as? String, !provider.isEmpty {
            parsed.modelProvider = provider
        }
        if stopReason != "error", stopReason != "aborted",
           let usage = message["usage"] as? [String: Any] {
            let componentTotal = (usage["input"] as? Int ?? 0)
                + (usage["output"] as? Int ?? 0)
                + (usage["cacheRead"] as? Int ?? 0)
                + (usage["cacheWrite"] as? Int ?? 0)
            let contextTokens = usage["totalTokens"] as? Int ?? componentTotal
            if contextTokens > 0 {
                parsed.contextTokens = contextTokens
            }
        }

        switch role {
        case .user:
            parsed.lastTurnMarker = .started
        case .assistant:
            parsed.lastTurnMarker = stopReason == "toolUse" ? .started : .completed
        case .system:
            break
        }
    }

    private static func parseRole(_ raw: String) -> PiParsedRole? {
        switch raw {
        case "user": return .user
        case "assistant": return .assistant
        default: return nil
        }
    }

    private static func contentBlocks(_ content: Any?) -> [PiParsedBlock] {
        if let text = content as? String, !text.isEmpty {
            return [.text(text)]
        }
        guard let values = content as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            switch value["type"] as? String {
            case "text":
                guard let text = value["text"] as? String, !text.isEmpty else { return nil }
                return .text(text)
            case "thinking":
                guard let text = value["thinking"] as? String, !text.isEmpty else { return nil }
                return .thinking(text)
            case "image":
                guard let data = value["data"] as? String,
                      let mimeType = value["mimeType"] as? String,
                      !data.isEmpty, !mimeType.isEmpty else { return nil }
                return .image(PiParsedImage(dataURI: "data:\(mimeType);base64,\(data)"))
            case "toolCall":
                guard let id = value["id"] as? String,
                      let name = value["name"] as? String else { return nil }
                let input = stringifyDictionary(value["arguments"] as? [String: Any] ?? [:])
                return .toolCall(PiParsedToolCall(id: id, name: name, input: input))
            default:
                return nil
            }
        }
    }

    private static func joinedText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let values = content as? [[String: Any]] else { return nil }
        let parts = values.compactMap { value -> String? in
            guard value["type"] as? String == "text" else { return nil }
            return value["text"] as? String
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func stringifyDictionary(_ object: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                result[key] = string
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let json = String(data: data, encoding: .utf8) {
                result[key] = json
            }
        }
        return result
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return iso8601.date(from: value)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
