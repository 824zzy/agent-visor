import Foundation

/// Response sent back to claude-code's `PermissionRequest` hook over
/// agent-visor's Unix-socket protocol. The Python hook script
/// (`agent-visor-state.py`) reads these fields and reshapes them
/// into the camelCase JSON claude-code's hook contract expects.
///
/// **Wire convention:** snake_case between Swift (agent-visor) and
/// Python (the hook script); camelCase between Python and claude-code
/// proper. The CodingKey on `updatedInput` is what enforces the
/// snake_case half — without it, Swift's auto-synthesised encoder
/// would emit `"updatedInput"` and the Python script wouldn't see
/// the field.
public struct HookResponse: Codable, Sendable {
    /// `"allow"`, `"deny"`, or `"ask"`. Maps to claude-code's
    /// `PermissionRequest` hook decision behavior.
    public let decision: String
    /// User-visible reason. Surfaced to the model when `deny`-ing,
    /// otherwise informational. Nil when the decision speaks for
    /// itself (e.g. plain allow with no message).
    public let reason: String?
    /// Replacement tool input. Critical for `AskUserQuestion`-style
    /// tools where the hook supplies the answers structurally
    /// instead of routing the user through the in-terminal TUI.
    /// claude-code's `PermissionContext.handleHookAllow` consumes
    /// this as `finalInput = decision.updatedInput ?? input` — it
    /// REPLACES the original input, so callers that want to keep
    /// existing fields must echo them here.
    public let updatedInput: [String: AnyCodable]?
    /// Permission rules to add alongside the allow decision. Mirrors
    /// claude-code's `decision.updatedPermissions` field
    /// (`PermissionUpdate[]` — see hooks.ts in upstream); claude-code
    /// persists these into the project's `settings.local.json` AND
    /// applies them to the in-memory permission context for the
    /// current session, so the same tool invocation won't re-prompt.
    /// We pass each entry through as an opaque `AnyCodable` because
    /// the `permission_suggestions` array claude-code sends in the
    /// hook payload is already in the right shape — we just echo it
    /// back unchanged.
    public let updatedPermissions: [AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case decision, reason
        case updatedInput = "updated_input"
        case updatedPermissions = "updated_permissions"
    }

    public init(
        decision: String,
        reason: String? = nil,
        updatedInput: [String: AnyCodable]? = nil,
        updatedPermissions: [AnyCodable]? = nil
    ) {
        self.decision = decision
        self.reason = reason
        self.updatedInput = updatedInput
        self.updatedPermissions = updatedPermissions
    }
}

/// Type-erasing Codable wrapper for heterogeneous JSON values. Used
/// for `tool_input` payloads (decode side) and for `updated_input`
/// (encode side) where the structure depends on the tool.
///
/// The unsafe-Sendable annotation is necessary because `Any` is not
/// itself Sendable. The wrapper is treated as immutable in practice
/// — value is set once during init/decode and never mutated.
public struct AnyCodable: Codable, @unchecked Sendable {
    public nonisolated(unsafe) let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}
