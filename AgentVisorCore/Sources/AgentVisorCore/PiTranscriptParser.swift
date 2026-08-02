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

private struct PiIndexedEntry {
    let id: String
    let parentID: String?
    let projection: PiEntryProjection
}

/// Typed active-branch effects retained after each JSON object is released.
/// Large tool output and message strings are held once without keeping the
/// substantially heavier Foundation dictionary graph alive.
private struct PiEntryProjection {
    var message: PiParsedMessage?
    var completedToolID: String?
    var toolFailed = false
    var toolOutput: String?
    var modelName: String?
    var modelProvider: String?
    var effortLevel: String?
    var contextTokens: Int?
    var sessionName: String?
    var turnMarker: TurnMarker?
}

/// Incremental index for Pi's append-only, tree-shaped JSONL transcript.
/// Complete records are decoded once. A trailing partial record remains
/// buffered until a later append supplies its newline.
public struct PiTranscriptAccumulator {
    private var metadata: PiTranscriptMetadata?
    private var entriesByID: [String: PiIndexedEntry] = [:]
    private var entryOrder: [String] = []
    private var pendingLine = Data()

    public init() {}

    /// Appends newly read bytes and returns the number of valid session or
    /// tree records accepted from complete JSONL lines.
    @discardableResult
    public mutating func append(_ bytes: Data) -> Int {
        guard !bytes.isEmpty else { return 0 }

        var buffer: Data
        if pendingLine.isEmpty {
            buffer = bytes
        } else {
            buffer = pendingLine
            buffer.append(bytes)
            pendingLine.removeAll(keepingCapacity: false)
        }

        guard let lastNewline = buffer.lastIndex(of: 0x0A) else {
            pendingLine = buffer
            return 0
        }

        let completeEnd = buffer.index(after: lastNewline)
        let completeData = buffer[..<completeEnd]
        if completeEnd < buffer.endIndex {
            pendingLine = Data(buffer[completeEnd...])
        }

        var accepted = 0
        for line in JSONLLineIterator(data: completeData) {
            accepted += ingest(line: line)
        }
        return accepted
    }

    /// Materializes the latest active branch. Whole-buffer callers may ask
    /// to accept a valid unterminated final line for compatibility; live file
    /// parsing leaves that line pending until a later append completes it.
    public func transcript(includingUnterminatedFinalLine: Bool = false) -> PiParsedTranscript {
        guard includingUnterminatedFinalLine, !pendingLine.isEmpty else {
            return materializedTranscript()
        }

        var copy = self
        _ = copy.ingest(line: pendingLine)
        copy.pendingLine.removeAll(keepingCapacity: false)
        return copy.materializedTranscript()
    }

    private mutating func ingest(line: Data) -> Int {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let type = json["type"] as? String else {
            return 0
        }

        if type == "session",
           let sessionId = json["id"] as? String,
           let cwd = json["cwd"] as? String,
           let createdAt = PiTranscriptParser.parseTimestamp(json["timestamp"]) {
            metadata = PiTranscriptMetadata(
                sessionId: sessionId,
                cwd: cwd,
                createdAt: createdAt
            )
            return 1
        }

        guard let id = json["id"] as? String else { return 0 }
        entriesByID[id] = PiTranscriptParser.indexedEntry(from: json, id: id)
        entryOrder.append(id)
        return 1
    }

    private func materializedTranscript() -> PiParsedTranscript {
        var parsed = PiParsedTranscript(metadata: metadata)
        guard var entryID = entryOrder.last else { return parsed }

        var branch: [PiIndexedEntry] = []
        var visited: Set<String> = []
        while let entry = entriesByID[entryID], visited.insert(entryID).inserted {
            branch.append(entry)
            guard let parentID = entry.parentID else { break }
            entryID = parentID
        }

        for entry in branch.reversed() {
            PiTranscriptParser.apply(entry.projection, to: &parsed)
        }
        return parsed
    }
}

public enum PiTranscriptParser {
    public static func parse(data: Data) -> PiParsedTranscript {
        var accumulator = PiTranscriptAccumulator()
        accumulator.append(data)
        return accumulator.transcript(includingUnterminatedFinalLine: true)
    }

    fileprivate static func indexedEntry(
        from entry: [String: Any],
        id: String
    ) -> PiIndexedEntry {
        var projection = PiEntryProjection()

        switch entry["type"] as? String {
        case "message":
            projection = messageProjection(entry, id: id)

        case "model_change":
            if let model = entry["modelId"] as? String, !model.isEmpty {
                projection.modelName = model
            }
            if let provider = entry["provider"] as? String, !provider.isEmpty {
                projection.modelProvider = provider
            }

        case "thinking_level_change":
            if let effort = entry["thinkingLevel"] as? String, !effort.isEmpty {
                projection.effortLevel = effort
            }

        case "branch_summary":
            if let timestamp = parseTimestamp(entry["timestamp"]),
               let summary = entry["summary"] as? String,
               !summary.isEmpty {
                projection.message = PiParsedMessage(
                    id: id,
                    role: .system,
                    timestamp: timestamp,
                    blocks: [.recap(summary)]
                )
            }

        case "compaction":
            if let timestamp = parseTimestamp(entry["timestamp"]) {
                projection.message = PiParsedMessage(
                    id: id,
                    role: .system,
                    timestamp: timestamp,
                    blocks: [.compactBoundary(
                        summary: entry["summary"] as? String,
                        preTokens: entry["tokensBefore"] as? Int
                    )]
                )
            }

        case "session_info":
            if let name = entry["name"] as? String, !name.isEmpty {
                projection.sessionName = name
            }

        default:
            break
        }

        return PiIndexedEntry(
            id: id,
            parentID: entry["parentId"] as? String,
            projection: projection
        )
    }

    private static func messageProjection(
        _ entry: [String: Any],
        id: String
    ) -> PiEntryProjection {
        var projection = PiEntryProjection()
        guard let message = entry["message"] as? [String: Any],
              let rawRole = message["role"] as? String,
              let timestamp = parseTimestamp(entry["timestamp"]) else {
            return projection
        }

        if rawRole == "toolResult" {
            guard let toolCallID = message["toolCallId"] as? String else {
                return projection
            }
            projection.completedToolID = toolCallID
            projection.toolFailed = message["isError"] as? Bool == true
            if let output = joinedText(message["content"]), !output.isEmpty {
                projection.toolOutput = output
            }
            projection.turnMarker = .started
            return projection
        }

        if rawRole == "bashExecution" {
            let command = message["command"] as? String ?? ""
            let output = message["output"] as? String ?? ""
            let text = command.isEmpty
                ? output
                : "$ \(command)" + (output.isEmpty ? "" : "\n\(output)")
            if !text.isEmpty {
                projection.message = PiParsedMessage(
                    id: id,
                    role: .system,
                    timestamp: timestamp,
                    blocks: [.localCommandOutput(text)]
                )
            }
            return projection
        }

        guard let role = parseRole(rawRole) else { return projection }
        let stopReason = message["stopReason"] as? String
        var blocks = contentBlocks(message["content"])
        if role == .assistant && (stopReason == "error" || stopReason == "aborted") {
            blocks.append(.interrupted)
        }
        guard !blocks.isEmpty else { return projection }
        projection.message = PiParsedMessage(
            id: id,
            role: role,
            timestamp: timestamp,
            blocks: blocks
        )

        if let model = message["model"] as? String, !model.isEmpty {
            projection.modelName = model
        }
        if let provider = message["provider"] as? String, !provider.isEmpty {
            projection.modelProvider = provider
        }
        if stopReason != "error", stopReason != "aborted",
           let usage = message["usage"] as? [String: Any] {
            let componentTotal = (usage["input"] as? Int ?? 0)
                + (usage["output"] as? Int ?? 0)
                + (usage["cacheRead"] as? Int ?? 0)
                + (usage["cacheWrite"] as? Int ?? 0)
            let contextTokens = usage["totalTokens"] as? Int ?? componentTotal
            if contextTokens > 0 {
                projection.contextTokens = contextTokens
            }
        }

        switch role {
        case .user:
            projection.turnMarker = .started
        case .assistant:
            projection.turnMarker = stopReason == "toolUse" ? .started : .completed
        case .system:
            break
        }
        return projection
    }

    fileprivate static func apply(
        _ projection: PiEntryProjection,
        to parsed: inout PiParsedTranscript
    ) {
        if let message = projection.message {
            parsed.messages.append(message)
        }
        if let toolID = projection.completedToolID {
            parsed.completedToolIds.insert(toolID)
            if projection.toolFailed {
                parsed.failedToolIds.insert(toolID)
            }
            if let output = projection.toolOutput {
                parsed.toolOutputs[toolID] = output
            }
        }
        if let modelName = projection.modelName {
            parsed.modelName = modelName
        }
        if let modelProvider = projection.modelProvider {
            parsed.modelProvider = modelProvider
        }
        if let effortLevel = projection.effortLevel {
            parsed.effortLevel = effortLevel
        }
        if let contextTokens = projection.contextTokens {
            parsed.contextTokens = contextTokens
        }
        if let sessionName = projection.sessionName {
            parsed.sessionName = sessionName
        }
        if let turnMarker = projection.turnMarker {
            parsed.lastTurnMarker = turnMarker
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

    fileprivate static func parseTimestamp(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return iso8601.date(from: value)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
