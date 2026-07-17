//
//  CodexAppServerProtocol.swift
//  AgentVisorCore
//
//  Wire types for Codex's `app-server` JSON-RPC-over-stdio protocol
//  (`codex app-server --listen stdio://`). This is the first-party
//  client API the Codex VSCode extension and `--remote` TUI speak; it
//  is how agent-visor drives a Codex thread end-to-end (resume a
//  rollout, start a turn, answer approvals) instead of only observing
//  the on-disk transcript.
//
//  Shapes here are transcribed from the protocol schema emitted by
//  `codex app-server generate-json-schema` (Codex CLI 0.135.0). We
//  model only the subset agent-visor uses:
//    - framing: JSONRPCRequest / Response / Error / Notification
//    - client→server: initialize, thread/resume, turn/start, turn/interrupt
//    - server→client requests: the three approval requests + requestUserInput
//    - server→client notifications: the streaming + lifecycle events we render
//
//  Everything is pure / value-in-value-out so the framing and dispatch
//  logic is unit-testable without spawning a process. The transport
//  actor that owns the pipes lives app-side (CodexAppServerClient).
//

import Foundation

// MARK: - Framing

/// JSON-RPC id. Codex accepts either a string or an integer; we only
/// ever emit integers (a monotonic counter), but the decoder must
/// accept both because server→client requests can carry either.
public enum CodexRPCID: Codable, Equatable, Sendable, Hashable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "RPC id is neither int nor string")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

/// An outgoing request (client→server). `params` is type-erased so one
/// type serves every method; callers build the params dict with the
/// per-method helpers below.
public struct CodexRPCRequest: Encodable, Sendable {
    public let jsonrpc: String
    public let id: CodexRPCID
    public let method: String
    public let params: [String: AnyCodable]?

    public init(id: CodexRPCID, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// An outgoing notification (client→server, no id / no response). Used
/// for the `initialized` handshake completion.
public struct CodexRPCNotificationOut: Encodable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: [String: AnyCodable]?

    public init(method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// A response WE send back to a server→client request (e.g. an approval
/// decision). `result` is type-erased.
public struct CodexRPCResponseOut: Encodable, Sendable {
    public let jsonrpc: String
    public let id: CodexRPCID
    public let result: AnyCodable

    public init(id: CodexRPCID, result: [String: AnyCodable]) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = AnyCodable(result.mapValues { $0.value })
    }
}

/// An error response WE send back to a server→client request we can't
/// satisfy (e.g. a grant-profile permissions request this pass doesn't
/// implement). Codex falls back to its own handling rather than hanging
/// on a reply that never comes.
public struct CodexRPCErrorOut: Encodable, Sendable {
    public struct ErrorBody: Encodable, Sendable {
        public let code: Int
        public let message: String
    }
    public let jsonrpc: String
    public let id: CodexRPCID
    public let error: ErrorBody

    public init(id: CodexRPCID, code: Int, message: String) {
        self.jsonrpc = "2.0"
        self.id = id
        self.error = ErrorBody(code: code, message: message)
    }
}

/// Classification of a single inbound NDJSON line from the app-server.
/// The transport reads one JSON object per line and asks
/// `CodexAppServerProtocol.classify` what it is, so the dispatch logic
/// (continuation resume vs. notification handler vs. server-request
/// handler) is testable without any I/O.
public enum CodexInboundMessage: Equatable, Sendable {
    /// Response to one of our requests, keyed by the id we sent.
    case response(id: CodexRPCID, result: AnyCodableEquatableBox)
    /// Error response to one of our requests.
    case error(id: CodexRPCID?, code: Int, message: String)
    /// Server→client request we must answer (id present + method).
    case serverRequest(id: CodexRPCID, method: String, params: AnyCodableEquatableBox)
    /// Server→client notification (method, no id, no response).
    case notification(method: String, params: AnyCodableEquatableBox)
    /// A line we couldn't classify (kept for logging, never fatal).
    case unrecognized(raw: String)
}

/// Equatable wrapper around a decoded JSON value so `CodexInboundMessage`
/// can conform to Equatable for tests. Compares via re-encoded JSON.
public struct AnyCodableEquatableBox: Equatable, Sendable {
    public let value: AnyCodable

    public init(_ value: AnyCodable) { self.value = value }
    public init(_ raw: Any) { self.value = AnyCodable(raw) }

    /// Convenience: pull a top-level string field out of an object
    /// payload (e.g. `threadId`, `delta`). Returns nil if absent or
    /// the payload isn't an object.
    public func string(_ key: String) -> String? {
        (value.value as? [String: Any])?[key] as? String
    }

    /// Convenience: pull a nested object payload as a dictionary.
    public func object(_ key: String) -> [String: Any]? {
        (value.value as? [String: Any])?[key] as? [String: Any]
    }

    public var dictionary: [String: Any]? { value.value as? [String: Any] }

    public static func == (lhs: AnyCodableEquatableBox, rhs: AnyCodableEquatableBox) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let l = try? enc.encode(lhs.value), let r = try? enc.encode(rhs.value) else {
            return false
        }
        return l == r
    }
}

public struct CodexAssistantDeltaNotification: Equatable, Sendable {
    public let threadId: String
    public let turnId: String
    public let itemId: String
    public let delta: String

    public var syntheticItemId: String {
        Self.syntheticItemId(for: itemId)
    }

    public init?(
        method: String,
        params: AnyCodableEquatableBox
    ) {
        guard method == CodexAppServerProtocol.NotificationMethod.agentMessageDelta,
              let threadId = params.string("threadId"),
              let turnId = params.string("turnId"),
              let delta = params.string("delta"),
              !delta.isEmpty else {
            return nil
        }
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = params.string("itemId") ?? params.string("item_id") ?? turnId
        self.delta = delta
    }

    public static func syntheticItemId(for itemId: String) -> String {
        "codex-stream-\(itemId)"
    }
}

public enum CodexUserMessageText {
    public static func visibleText(
        raw: String,
        imageCount: Int,
        includeImagePlaceholder: Bool = true
    ) -> String? {
        let stripped = stripAttachmentPreamble(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty {
            return stripped
        }
        return imageCount > 0 && includeImagePlaceholder ? "[Image]" : nil
    }

    private static func stripAttachmentPreamble(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let filesPrefix = "Files mentioned by the user:"
        let requestMarker = "My request for Codex:"
        guard headingStripped(trimmed).hasPrefix(filesPrefix),
              let markerRange = trimmed.range(of: requestMarker) else {
            return text
        }
        return String(trimmed[markerRange.upperBound...])
    }

    private static func headingStripped(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    }
}

public struct CodexTurnUserMessageNotification: Equatable, Sendable {
    public let threadId: String
    public let turnId: String
    public let itemId: String
    public let text: String
    public let images: [CodexParsedImage]

    public var syntheticItemId: String {
        Self.syntheticItemId(for: itemId)
    }

    public init?(
        method: String,
        params: AnyCodableEquatableBox
    ) {
        guard method == CodexAppServerProtocol.NotificationMethod.turnStarted,
              let threadId = params.string("threadId"),
              let turn = params.object("turn"),
              let turnId = turn["id"] as? String,
              let items = turn["items"] as? [[String: Any]],
              let userItem = items.first(where: { ($0["type"] as? String) == "userMessage" }),
              let itemId = userItem["id"] as? String,
              let content = userItem["content"] as? [[String: Any]] else {
            return nil
        }

        let textParts = content.compactMap { item -> String? in
            guard (item["type"] as? String) == "text" else { return nil }
            let text = item["text"] as? String ?? ""
            return text.isEmpty ? nil : text
        }
        let images = Self.imageReferences(from: content)
        let renderedText = CodexUserMessageText.visibleText(
            raw: textParts.joined(separator: "\n"),
            imageCount: images.count,
            includeImagePlaceholder: false
        ) ?? ""

        guard !renderedText.isEmpty || !images.isEmpty else { return nil }
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.text = renderedText
        self.images = images
    }

    public static func syntheticItemId(for itemId: String) -> String {
        "codex-stream-user-\(itemId)"
    }

    private static func imageReferences(from content: [[String: Any]]) -> [CodexParsedImage] {
        content.compactMap { item in
            guard let type = item["type"] as? String,
                  type == "localImage" || type == "image" else {
                return nil
            }
            if let path = item["path"] as? String, type == "localImage" {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : CodexParsedImage(source: .localPath, value: trimmed)
            }
            let value = item["path"] as? String
                ?? item["url"] as? String
                ?? item["image_url"] as? String
                ?? item["data"] as? String
            return value.flatMap(CodexParsedImage.fromImageString)
        }
    }
}

// MARK: - Protocol helpers

public enum CodexAppServerProtocol {
    /// JSON-RPC method names we invoke (client→server).
    public enum Method {
        public static let initialize = "initialize"
        public static let initialized = "initialized"
        public static let threadLoadedList = "thread/loaded/list"
        public static let threadRead = "thread/read"
        public static let threadResume = "thread/resume"
        public static let threadUnsubscribe = "thread/unsubscribe"
        public static let threadStart = "thread/start"
        public static let turnStart = "turn/start"
        public static let turnInterrupt = "turn/interrupt"
        public static let threadList = "thread/list"
        public static let accountRateLimitsRead = "account/rateLimits/read"
    }

    /// Server→client request method names that require a response.
    public enum ServerRequestMethod {
        public enum Kind: Equatable, Sendable {
            case approval
            case userInput
            case unsupported
        }

        public static let commandExecutionApproval = "item/commandExecution/requestApproval"
        public static let fileChangeApproval = "item/fileChange/requestApproval"
        public static let permissionsApproval = "item/permissions/requestApproval"
        public static let requestUserInput = "item/tool/requestUserInput"
        public static let execCommandApproval = "execCommandApproval"
        public static let applyPatchApproval = "applyPatchApproval"

        public static func kind(_ method: String) -> Kind {
            switch method {
            case commandExecutionApproval, fileChangeApproval,
                 permissionsApproval,
                 execCommandApproval, applyPatchApproval:
                return .approval
            case requestUserInput:
                return .userInput
            default:
                return .unsupported
            }
        }

        public static func isHandledServerRequest(_ method: String) -> Bool {
            kind(method) != .unsupported
        }

        /// True for the decision-style approval requests agent-visor
        /// answers through its allow/deny approval bar (each maps to a
        /// single decision string — see CodexApprovalDecisionMapper).
        /// The richer `requestUserInput` question request is handled as
        /// `.userInput`, not through this generic allow/deny path.
        public static func isHandledApproval(_ method: String) -> Bool {
            kind(method) == .approval
        }
    }

    /// Server→client notification method names we render.
    public enum NotificationMethod {
        public static let agentMessageDelta = "item/agentMessage/delta"
        public static let reasoningTextDelta = "item/reasoning/textDelta"
        public static let turnStarted = "turn/started"
        public static let turnCompleted = "turn/completed"
        public static let itemCompleted = "item/completed"
        public static let serverRequestResolved = "serverRequest/resolved"
        public static let threadStatusChanged = "thread/status/changed"
        public static let commandExecutionOutputDelta = "item/commandExecution/outputDelta"
        public static let accountRateLimitsUpdated = "account/rateLimits/updated"
    }

    // MARK: Outgoing request builders

    /// `initialize` params. `clientInfo.name` is echoed back in the
    /// result's userAgent — we assert on it to confirm the handshake.
    public static func initializeParams(
        name: String,
        version: String,
        experimentalApi: Bool = false
    ) -> [String: AnyCodable] {
        var params: [String: AnyCodable] = [
            "clientInfo": AnyCodable([
                "name": name,
                "version": version,
            ])
        ]
        if experimentalApi {
            params["capabilities"] = AnyCodable(["experimentalApi": true])
        }
        return params
    }

    /// `thread/resume` params — loads an existing rollout (by thread id,
    /// which is agent-visor's sessionId) into a live thread in the
    /// app-server's engine.
    public static func threadResumeParams(
        threadId: String,
        approvalPolicy: String? = nil,
        sandboxPolicyType: String? = nil,
        excludeTurns: Bool = false
    ) -> [String: AnyCodable] {
        var params = ["threadId": AnyCodable(threadId)]
        if let approvalPolicy = validApprovalPolicy(approvalPolicy) {
            params["approvalPolicy"] = AnyCodable(approvalPolicy)
        }
        if let sandbox = legacySandboxMode(sandboxPolicyType) {
            params["sandbox"] = AnyCodable(sandbox)
        }
        if excludeTurns {
            params["excludeTurns"] = AnyCodable(true)
        }
        return params
    }

    public static func threadReadParams(
        threadId: String,
        includeTurns: Bool = false
    ) -> [String: AnyCodable] {
        [
            "threadId": AnyCodable(threadId),
            "includeTurns": AnyCodable(includeTurns),
        ]
    }

    public static func threadUnsubscribeParams(threadId: String) -> [String: AnyCodable] {
        ["threadId": AnyCodable(threadId)]
    }

    /// `thread/start` params — creates a new non-ephemeral Codex thread
    /// owned by this app-server client.
    public static func threadStartParams(
        cwd: String,
        approvalPolicy: String? = nil,
        sandboxPolicyType: String? = nil,
        model: String? = nil
    ) -> [String: AnyCodable] {
        var params: [String: AnyCodable] = [
            "cwd": AnyCodable(cwd),
            "threadSource": AnyCodable("user"),
        ]
        if let approvalPolicy = validApprovalPolicy(approvalPolicy) {
            params["approvalPolicy"] = AnyCodable(approvalPolicy)
        }
        if let sandbox = legacySandboxMode(sandboxPolicyType) {
            params["sandbox"] = AnyCodable(sandbox)
        }
        if let model, !model.isEmpty {
            params["model"] = AnyCodable(model)
        }
        return params
    }

    /// `turn/start` params — sends one user message and runs a turn.
    /// `input` is an array of UserInput items. Codex accepts text and
    /// local image items (`{"type":"localImage","path":"..."}`).
    public static func turnStartParams(
        threadId: String,
        text: String,
        localImagePaths: [String] = [],
        approvalPolicy: String? = nil,
        sandboxPolicyType: String? = nil
    ) -> [String: AnyCodable] {
        var input: [[String: String]] = []
        if !text.isEmpty {
            input.append(["type": "text", "text": text])
        }
        for path in localImagePaths where !path.isEmpty {
            input.append(["type": "localImage", "path": path])
        }
        var params: [String: AnyCodable] = [
            "threadId": AnyCodable(threadId),
            "input": AnyCodable(input),
        ]
        if let approvalPolicy = validApprovalPolicy(approvalPolicy) {
            params["approvalPolicy"] = AnyCodable(approvalPolicy)
        }
        if isDangerFullAccess(sandboxPolicyType) {
            params["sandboxPolicy"] = AnyCodable(["type": "dangerFullAccess"])
        }
        return params
    }

    /// `turn/interrupt` params — the Ctrl-C / cancel equivalent.
    public static func turnInterruptParams(
        threadId: String,
        turnId: String
    ) -> [String: AnyCodable] {
        [
            "threadId": AnyCodable(threadId),
            "expectedTurnId": AnyCodable(turnId),
        ]
    }

    // MARK: Inbound classification

    /// Classify one decoded inbound JSON object. The transport feeds the
    /// raw bytes; this decides response vs. error vs. server-request vs.
    /// notification by JSON-RPC shape:
    ///   - has `id` + `result`        → response
    ///   - has `id` + `error`         → error
    ///   - has `id` + `method`        → server-request (needs a reply)
    ///   - has `method`, no `id`      → notification
    public static func classify(_ data: Data) -> CodexInboundMessage {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .unrecognized(raw: String(data: data, encoding: .utf8) ?? "<binary>")
        }
        return classify(object: obj)
    }

    /// Object-level overload used by tests (and by `classify(_:Data)`
    /// after JSON parsing).
    public static func classify(object obj: [String: Any]) -> CodexInboundMessage {
        let id = rpcID(from: obj["id"])
        let method = obj["method"] as? String

        if let method, id != nil {
            return .serverRequest(
                id: id!,
                method: method,
                params: AnyCodableEquatableBox(obj["params"] ?? [String: Any]())
            )
        }
        if let method {
            return .notification(
                method: method,
                params: AnyCodableEquatableBox(obj["params"] ?? [String: Any]())
            )
        }
        if let errObj = obj["error"] as? [String: Any] {
            let code = (errObj["code"] as? Int) ?? -1
            let message = (errObj["message"] as? String) ?? "unknown error"
            return .error(id: id, code: code, message: message)
        }
        if let id, obj.keys.contains("result") {
            return .response(
                id: id,
                result: AnyCodableEquatableBox(obj["result"] ?? NSNull())
            )
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let raw = String(data: data, encoding: .utf8) {
            return .unrecognized(raw: raw)
        }
        return .unrecognized(raw: "<obj>")
    }

    private static func rpcID(from any: Any?) -> CodexRPCID? {
        if let i = any as? Int { return .int(i) }
        if let s = any as? String { return .string(s) }
        // JSONSerialization may decode integers as NSNumber.
        if let n = any as? NSNumber { return .int(n.intValue) }
        return nil
    }

    private static func validApprovalPolicy(_ value: String?) -> String? {
        guard let value, ["untrusted", "on-failure", "on-request", "never"].contains(value) else {
            return nil
        }
        return value
    }

    private static func legacySandboxMode(_ value: String?) -> String? {
        switch value {
        case "read-only", "workspace-write", "danger-full-access":
            return value
        case "readOnly":
            return "read-only"
        case "workspaceWrite":
            return "workspace-write"
        case "dangerFullAccess":
            return "danger-full-access"
        default:
            return nil
        }
    }

    private static func isDangerFullAccess(_ value: String?) -> Bool {
        value == "danger-full-access" || value == "dangerFullAccess"
    }

    /// Serialize an outgoing request to a single NDJSON line (no
    /// trailing newline — the transport appends it).
    public static func encodeLine<T: Encodable>(_ message: T) throws -> Data {
        let enc = JSONEncoder()
        // Stable key order keeps tests deterministic; the wire doesn't
        // care about order.
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(message)
    }
}
