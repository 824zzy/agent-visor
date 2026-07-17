//
//  HookSocketServer.swift
//  AgentVisor
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Foundation
import os.log
import AgentVisorCore

/// Logger for hook socket server
private let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "Hooks")

/// Event received from a coding agent's hook (Claude Code today;
/// Auggie / Codex in later phases). The hook script stamps `agent` so
/// the single socket can multiplex. Older claude-code scripts that
/// predate this field decode as nil; callers fall back to the default
/// provider via `agentID`.
struct HookEvent: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?
    /// Wire identifier of the agent that emitted this event. Optional
    /// for backwards compatibility with older claude-code hook scripts.
    let agent: String?
    /// Presence-only signal. claude-code's TUI uses `permission_suggestions`
    /// field PRESENCE (not contents) as its "is option 2 eligible?"
    /// gate: when its safety classifier rejects the tool input (e.g.
    /// `cd ... && grep ...` compound with output redirection), or when
    /// the tool isn't allowlist-eligible at all, it omits the field
    /// entirely. agent-visor reads the same signal — `nil` here means
    /// hide option 2; non-nil means show it (label + rule come from
    /// the local `PermissionSuggestionBuilder`, which produces better
    /// Bash-prefix labels than the Read rules upstream often supplies
    /// for Bash invocations).
    let permissionSuggestions: [AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message, agent
        case permissionSuggestions = "permission_suggestions"
    }

    /// Create a copy with updated toolUseId
    init(
        sessionId: String,
        cwd: String,
        event: String,
        status: String,
        pid: Int?,
        tty: String?,
        tool: String?,
        toolInput: [String: AnyCodable]?,
        toolUseId: String?,
        notificationType: String?,
        message: String?,
        agent: String? = nil,
        permissionSuggestions: [AnyCodable]? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
        self.agent = agent
        self.permissionSuggestions = permissionSuggestions
    }

    /// Resolved agent id, falling back to claude-code when the wire
    /// payload doesn't carry an explicit stamp (older hook scripts).
    nonisolated var agentID: AgentID {
        guard let raw = agent, let id = AgentID(rawValue: raw) else {
            return .claudeCode
        }
        return id
    }

    var sessionPhase: SessionPhase {
        switch HookSessionLifecyclePolicy.phase(
            event: event,
            reportedStatus: status,
            isTerminalLifecycleStatus: isTerminalLifecycleStatus
        ) {
        case .waitingForApproval:
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: PendingActionPresentation.storedToolName(tool),
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case .waitingForInput: return .waitingForInput
        case .processing: return .processing
        case .compacting: return .compacting
        case .ended: return .ended
        case .idle: return .idle
        }
    }

    /// Whether this event expects a response (permission request) that
    /// Agent Visor itself will answer. Gated to claude-code: only its hook
    /// blocks reading our decision back over the socket. Codex/auggie are
    /// observe-only — their `waiting_for_approval` still drives the phase
    /// (via `determinePhase`'s status case) but must NOT hold the socket
    /// open or register an answerable pending permission, since their
    /// native UI owns the approval.
    nonisolated var expectsResponse: Bool {
        event == "PermissionRequest"
            && status == "waiting_for_approval"
            && agentID == .claudeCode
    }
}

// `HookResponse` lives in AgentVisorCore/HookWireTypes.swift so the
// JSON wire format can be unit-tested without dragging in BSD-socket
// dependencies. Imported via `import AgentVisorCore`.

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/agent-visor.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(
        label: AppBranding.loggerSubsystem + ".socket",
        qos: .userInitiated
    )

    /// Pending permission requests indexed by toolUseId
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Correlates PermissionRequest events (which omit tool_use_id) with
    /// preceding PreToolUse events. Completion events evict auto-approved
    /// tools before a later identical request can consume the wrong ID.
    private var toolUseCorrelations = ToolUseCorrelationBuffer()
    private let cacheLock = NSLock()

    private init() {}

    /// Start the socket server
    func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o777)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    /// Stop the socket server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }

    /// Respond to a pending permission request by toolUseId.
    ///
    /// `updatedInput` is forwarded into the `HookResponse`'s
    /// `updated_input` field. The Python hook reshapes it into
    /// `decision.updatedInput` (camelCase) on the way out to
    /// claude-code, where it REPLACES the original tool input — see
    /// claude-code's `PermissionContext.handleHookAllow` for the
    /// `finalInput = decision.updatedInput ?? input` semantics.
    /// Used by the AskUserQuestion form to deliver structured
    /// `{questions, answers}` instead of synthesizing keystrokes.
    func respondToPermission(
        toolUseId: String,
        decision: String,
        reason: String? = nil,
        updatedInput: [String: AnyCodable]? = nil,
        updatedPermissions: [AnyCodable]? = nil
    ) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(
                toolUseId: toolUseId,
                decision: decision,
                reason: reason,
                updatedInput: updatedInput,
                updatedPermissions: updatedPermissions
            )
        }
    }

    /// Respond to permission by sessionId (finds the most recent pending for that session).
    /// See `respondToPermission(toolUseId:decision:reason:updatedInput:updatedPermissions:)`
    /// for `updatedInput` and `updatedPermissions` semantics.
    func respondToPermissionBySession(
        sessionId: String,
        decision: String,
        reason: String? = nil,
        updatedInput: [String: AnyCodable]? = nil,
        updatedPermissions: [AnyCodable]? = nil
    ) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(
                sessionId: sessionId,
                decision: decision,
                reason: reason,
                updatedInput: updatedInput,
                updatedPermissions: updatedPermissions
            )
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    /// Check if there's a pending permission request for a session
    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    /// Get the pending permission details for a session (if any)
    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
        PendingPermissionStore.delete(sessionId: pending.sessionId, toolUseId: toolUseId)
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
            PendingPermissionStore.delete(sessionId: sessionId, toolUseId: toolUseId)
        }
        permissionsLock.unlock()
    }

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Generate cache key from event properties
    private func cacheKey(toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        toolUseCorrelations.record(
            sessionId: event.sessionId,
            correlationKey: key,
            toolUseId: toolUseId,
            at: Date().timeIntervalSince1970
        )
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let toolUseId = toolUseCorrelations.consume(
            sessionId: event.sessionId,
            correlationKey: key,
            at: Date().timeIntervalSince1970
        ) else { return nil }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
        return toolUseId
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let before = toolUseCorrelations.count
        toolUseCorrelations.removeSession(sessionId, at: Date().timeIntervalSince1970)
        let removedCount = before - toolUseCorrelations.count
        cacheLock.unlock()

        if removedCount > 0 {
            logger.debug("Cleaned up \(removedCount) cached tool IDs for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    private func completeCachedToolUseId(_ toolUseId: String) {
        cacheLock.lock()
        toolUseCorrelations.complete(
            toolUseId: toolUseId,
            at: Date().timeIntervalSince1970
        )
        cacheLock.unlock()
    }

    // MARK: - Private

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 0.5 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult == 0 {
                if !allData.isEmpty {
                    break
                }
            } else {
                break
            }
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            return
        }

        let data = allData

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            close(clientSocket)
            return
        }

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

        if event.event == "PreToolUse" {
            cacheToolUseId(event: event)
        }

        if (event.event == "PostToolUse" || event.event == "PostToolUseFailure"),
           let toolUseId = event.toolUseId {
            completeCachedToolUseId(toolUseId)
        }

        if event.event == "SessionEnd" {
            cleanupCache(sessionId: event.sessionId)
        }

        if event.expectsResponse {
            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
                completeCachedToolUseId(eventToolUseId)
            } else if let cachedToolUseId = popCachedToolUseId(event: event) {
                toolUseId = cachedToolUseId
            } else {
                logger.warning("Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) - no cache hit")
                close(clientSocket)
                eventHandler?(event)
                return
            }

            logger.debug("Permission request - keeping socket open for \(event.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")

            let updatedEvent = HookEvent(
                sessionId: event.sessionId,
                cwd: event.cwd,
                event: event.event,
                status: event.status,
                pid: event.pid,
                tty: event.tty,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: toolUseId,  // Use resolved toolUseId
                notificationType: event.notificationType,
                message: event.message,
                agent: event.agent,
                permissionSuggestions: event.permissionSuggestions
            )

            let pending = PendingPermission(
                sessionId: event.sessionId,
                toolUseId: toolUseId,
                clientSocket: clientSocket,
                event: updatedEvent,
                receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            permissionsLock.unlock()

            // Persist a sidecar so an agent-visor restart while this
            // permission is still pending can recover the state. The
            // sidecar lives at:
            //   ~/Library/Application Support/agent-visor/
            //   pending-permissions/<sessionId>-<toolUseId>.json
            // Deleted from sendPermissionResponse below (user
            // answered via agent-visor's socket) or from
            // SessionStore's PostToolUse handler (user answered
            // via the TUI, or the tool resolved any other way).
            PendingPermissionStore.save(updatedEvent)

            eventHandler?(updatedEvent)
            return
        } else {
            close(clientSocket)
        }

        eventHandler?(event)
    }

    private func sendPermissionResponse(
        toolUseId: String,
        decision: String,
        reason: String?,
        updatedInput: [String: AnyCodable]?,
        updatedPermissions: [AnyCodable]?
    ) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            return
        }
        permissionsLock.unlock()

        // Sidecar no longer needed — the user just decided. The replay
        // path's JSONL staleness check catches any sidecar we miss here.
        PendingPermissionStore.delete(sessionId: pending.sessionId, toolUseId: toolUseId)

        let response = HookResponse(
            decision: decision,
            reason: reason,
            updatedInput: updatedInput,
            updatedPermissions: updatedPermissions
        )
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
            }
        }

        close(pending.clientSocket)
    }

    private func sendPermissionResponseBySession(
        sessionId: String,
        decision: String,
        reason: String?,
        updatedInput: [String: AnyCodable]?,
        updatedPermissions: [AnyCodable]?
    ) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        PendingPermissionStore.delete(sessionId: sessionId, toolUseId: pending.toolUseId)

        let response = HookResponse(
            decision: decision,
            reason: reason,
            updatedInput: updatedInput,
            updatedPermissions: updatedPermissions
        )
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
    }
}

// `AnyCodable` lives in AgentVisorCore/HookWireTypes.swift alongside
// `HookResponse`. Imported via `import AgentVisorCore`.
