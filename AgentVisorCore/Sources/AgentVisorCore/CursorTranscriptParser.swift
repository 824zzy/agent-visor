import Foundation

/// Parsed snapshot of a Cursor (`cursor-agent`) chat rollout. Mirrors
/// `CodexParsedTranscript` but adapted to Cursor's much simpler JSONL
/// format — one `{role, message: {content: [...] }}` per line with no
/// per-line timestamps and no tool-result rows.
public struct CursorParsedTranscript: Equatable, Sendable {
    public var messages: [CursorParsedMessage]
    public var completedToolIds: Set<String>

    public init(
        messages: [CursorParsedMessage] = [],
        completedToolIds: Set<String> = []
    ) {
        self.messages = messages
        self.completedToolIds = completedToolIds
    }
}

public struct CursorParsedMessage: Equatable, Sendable {
    public let id: String
    public let role: CursorParsedRole
    public let timestamp: Date
    public let blocks: [CursorParsedBlock]

    public init(
        id: String,
        role: CursorParsedRole,
        timestamp: Date,
        blocks: [CursorParsedBlock]
    ) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.blocks = blocks
    }
}

public enum CursorParsedRole: String, Equatable, Sendable {
    case user
    case assistant
    case system
}

public enum CursorParsedBlock: Equatable, Sendable {
    case text(String)
    case toolCall(CursorParsedToolCall)
}

public struct CursorParsedToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    public let input: [String: String]

    public init(id: String, name: String, input: [String: String]) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// Format reference (observed against `cursor-agent` 2025.09.18-7ae6800):
///
///   {"role":"user","message":{"content":[
///     {"type":"text","text":"<timestamp>...</timestamp>\\n<user_query>\\nhi\\n</user_query>"}
///   ]}}
///   {"role":"assistant","message":{"content":[
///     {"type":"text","text":"..."},
///     {"type":"tool_use","name":"Shell","input":{"command":"ls","description":"..."}}
///   ]}}
///
/// Notes:
/// - There are no per-line timestamps, no tool-call ids, no tool-result
///   blocks. Tool ids are synthesized from `(line, ordinal)`. Tool
///   results live server-side; the rollout shows only what the agent
///   wrote.
/// - `<timestamp>` and `<user_query>` XML wrappers are stripped from
///   user text — they're internal scaffolding, not user input.
/// - The parser is purposely lenient: garbage lines are skipped, missing
///   fields fall back to safe defaults. The contract is "preserve every
///   message that has at least a recognizable role and content array."
public enum CursorTranscriptParser {
    public static func parse(data: Data) -> CursorParsedTranscript {
        var parsed = CursorParsedTranscript()
        var lineNumber = 0
        var fallbackTimestamp = Date(timeIntervalSince1970: 0)

        for line in JSONLLineIterator(data: data) {
            lineNumber += 1
            guard
                let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let roleRaw = json["role"] as? String,
                let role = CursorParsedRole(rawValue: roleRaw),
                let message = json["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }

            // Bump our fallback timestamp by one second per line so the
            // resulting `messages` array is deterministically ordered
            // even when rolldown.jsonl hasn't grown timestamps yet.
            fallbackTimestamp = fallbackTimestamp.addingTimeInterval(1)

            var timestamp = fallbackTimestamp
            var blocks: [CursorParsedBlock] = []
            var ordinal = 0

            for block in content {
                guard let type = block["type"] as? String else { continue }
                ordinal += 1

                switch type {
                case "text":
                    let raw = (block["text"] as? String) ?? ""
                    if role == .user, let extracted = extractUserQuery(raw) {
                        blocks.append(.text(extracted.text))
                        if let ts = extracted.timestamp {
                            timestamp = ts
                            // Anchor the running fallback to this real
                            // user timestamp so subsequent assistant
                            // lines (which carry no `<timestamp>` of
                            // their own) inherit a date near the turn
                            // that prompted them. Without this, every
                            // assistant message stays in 1970-epoch
                            // territory and SessionStore's sort-by-
                            // timestamp groups all assistants above
                            // all users.
                            fallbackTimestamp = ts
                        }
                    } else {
                        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            blocks.append(.text(trimmed))
                        }
                    }

                case "tool_use":
                    let name = (block["name"] as? String) ?? ""
                    guard !name.isEmpty else { continue }
                    let input = stringifyInput(block["input"])
                    let id = "cursor-\(lineNumber)-\(ordinal)"
                    blocks.append(.toolCall(CursorParsedToolCall(id: id, name: name, input: input)))
                    parsed.completedToolIds.insert(id)

                default:
                    // Unknown block types (`tool_result`, future kinds) are
                    // skipped. Cursor's server holds tool outputs; we can't
                    // surface what we don't see.
                    continue
                }
            }

            guard !blocks.isEmpty else { continue }
            parsed.messages.append(
                CursorParsedMessage(
                    id: "cursor-line-\(lineNumber)",
                    role: role,
                    timestamp: timestamp,
                    blocks: blocks
                )
            )
        }

        return parsed
    }

    // MARK: - Helpers

    private struct ExtractedUserQuery {
        let text: String
        let timestamp: Date?
    }

    /// Strip the `<timestamp>...</timestamp>\n<user_query>\n...\n</user_query>`
    /// wrappers Cursor injects around plain user text. Returns nil when
    /// the wrapper is absent (so the caller can fall back to verbatim
    /// text — assistant turns, internal system messages).
    private static func extractUserQuery(_ raw: String) -> ExtractedUserQuery? {
        guard
            let queryStart = raw.range(of: "<user_query>"),
            let queryEnd = raw.range(of: "</user_query>", range: queryStart.upperBound..<raw.endIndex)
        else { return nil }

        let queryText = String(raw[queryStart.upperBound..<queryEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var ts: Date? = nil
        if let tsStart = raw.range(of: "<timestamp>"),
           let tsEnd = raw.range(of: "</timestamp>", range: tsStart.upperBound..<raw.endIndex) {
            let header = String(raw[tsStart.upperBound..<tsEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ts = parseHumanTimestamp(header)
        }

        return ExtractedUserQuery(text: queryText, timestamp: ts)
    }

    /// Parse Cursor's human-readable `<timestamp>` header. Format observed:
    /// `Sunday, May 31, 2026, 2:19 AM (UTC-7)`. The DateFormatter pattern
    /// is best-effort; if it fails we return nil and let the caller fall
    /// back to the deterministic line-ordinal timestamp.
    private static func parseHumanTimestamp(_ raw: String) -> Date? {
        // Strip any trailing parenthesized timezone before feeding to the
        // formatter, since DateFormatter struggles with `(UTC-7)`.
        var text = raw
        if let paren = text.range(of: " (") {
            text = String(text[..<paren.lowerBound])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        return formatter.date(from: text)
    }

    /// Tool-call inputs are arbitrary JSON dicts. Down-cast to
    /// `[String: String]` so the rest of the app (which key-walks string
    /// values for display) doesn't have to handle Any. Numbers/bools/null
    /// stringify; nested objects/arrays JSON-encode.
    private static func stringifyInput(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, raw) in dict {
            out[key] = stringify(raw)
        }
        return out
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            // NSNumber can be a bool wearing a number's clothes — check
            // first or "true" comes back as "1".
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        case is NSNull: return ""
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return String(describing: value)
        }
    }
}
