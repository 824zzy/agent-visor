//
//  CodexAppServerClient.swift
//  AgentVisor
//
//  Long-lived JSON-RPC-over-stdio client for `codex app-server`. This
//  is how agent-visor drives a Codex thread end-to-end — resume a
//  rollout, start a turn from the composer, and answer the approval
//  requests Codex's engine sends back — instead of only tailing the
//  on-disk transcript.
//
//  Transport: spawns `codex app-server --listen stdio://`, writes
//  newline-delimited JSON requests to its stdin, and reads NDJSON
//  responses/notifications/requests from its stdout. The wire types and
//  the line-classification logic live in AgentVisorCore
//  (CodexAppServerProtocol) and are unit-tested there; this actor owns
//  only the process, the pipes, and request/response correlation.
//
//  Ownership note: agent-visor runs ITS OWN app-server. A thread that
//  is actively running inside Codex.app or a live `codex` CLI is owned
//  by that engine's rollout writer; we only `thread/resume` + drive
//  threads the user has left idle (the "I don't want to switch back to
//  the app" case). The drivability decision is made upstream in
//  CodexAgentProvider.originForSession; this client assumes the caller
//  already vetted that.
//

import Foundation
import os.log
import AgentVisorCore

/// Inbound events the client surfaces to its owner. Notifications and
/// approval requests are delivered through these closures (set once at
/// construction); request/response correlation is handled internally.
struct CodexAppServerHandlers: Sendable {
    /// A server→client notification (streaming deltas, lifecycle).
    var onNotification: @Sendable (_ method: String, _ params: AnyCodableEquatableBox) async -> Void = { _, _ in }
    /// A server→client request that needs a reply. The handler must
    /// eventually call `client.respond(id:result:)` (or the turn will
    /// hang waiting for approval). `params` carries threadId/turnId so
    /// the owner can route it to the right session's approval UI.
    var onServerRequest: @Sendable (_ id: CodexRPCID, _ method: String, _ params: AnyCodableEquatableBox) async -> Void = { _, _, _ in }
    var onClose: @Sendable () async -> Void = {}

    nonisolated init(
        onNotification: @escaping @Sendable (_ method: String, _ params: AnyCodableEquatableBox) async -> Void = { _, _ in },
        onServerRequest: @escaping @Sendable (_ id: CodexRPCID, _ method: String, _ params: AnyCodableEquatableBox) async -> Void = { _, _, _ in },
        onClose: @escaping @Sendable () async -> Void = {}
    ) {
        self.onNotification = onNotification
        self.onServerRequest = onServerRequest
        self.onClose = onClose
    }
}

actor CodexAppServerClient {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "CodexAppServer")

    struct StartedThread: Sendable, Equatable {
        let id: String
        let cwd: String
        let path: String?
    }

    enum ClientError: Error, Equatable {
        case notStarted
        case spawnFailed(String)
        case rpcError(code: Int, message: String)
        case transportClosed
        case malformedResponse(String)
    }

    static let shared = CodexAppServerClient()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var started = false
    private var handshakeComplete = false
    private var inMemoryStartedThreadIds = Set<String>()

    /// Monotonic request id. Int form keeps correlation a plain dict.
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<AnyCodableEquatableBox, Error>] = [:]

    /// Partial-line buffer for the stdout reader (NDJSON can split
    /// across read chunks).
    private var readBuffer = Data()

    private var handlers = CodexAppServerHandlers()

    /// Resolved app-server `userAgent` string from the initialize
    /// result, for version gating + diagnostics. Nil until handshake.
    private(set) var serverUserAgent: String?

    // MARK: - Lifecycle

    func setHandlers(_ handlers: CodexAppServerHandlers) {
        self.handlers = handlers
    }

    /// Ensure the app-server is spawned and the initialize→initialized
    /// handshake has completed. Idempotent; safe to call before every
    /// request.
    func ensureStarted() async throws {
        if started && handshakeComplete { return }
        if !started { try spawn() }
        if !handshakeComplete { try await handshake() }
    }

    private func spawn() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.resolveCodexBinary())
        proc.arguments = ["app-server", "--listen", "stdio://"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        // stderr → our log stream; app-server is chatty on it.
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Stdout reader: buffer + split on newline, hand each complete
        // line to the actor. readabilityHandler runs off the main thread;
        // hop into the actor via a Task.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { await self?.ingest(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let s = String(data: chunk, encoding: .utf8) else { return }
            CodexAppServerClient.logger.debug("app-server stderr: \(s, privacy: .public)")
        }

        proc.terminationHandler = { [weak self] p in
            CodexAppServerClient.logger.error("app-server exited code=\(p.terminationStatus)")
            Task { await self?.handleTermination() }
        }

        do {
            try proc.run()
        } catch {
            throw ClientError.spawnFailed(error.localizedDescription)
        }
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.started = true
        Self.logger.info("app-server spawned pid=\(proc.processIdentifier)")
    }

    private func handshake() async throws {
        let result = try await request(
            method: CodexAppServerProtocol.Method.initialize,
            params: CodexAppServerProtocol.initializeParams(
                name: "agent-visor",
                version: Self.appVersion()
            )
        )
        serverUserAgent = result.string("userAgent")
        // Complete the handshake (notification, no response expected).
        try writeLine(CodexRPCNotificationOut(method: CodexAppServerProtocol.Method.initialized))
        handshakeComplete = true
        Self.logger.info("app-server handshake ok ua=\(self.serverUserAgent ?? "?", privacy: .public)")
    }

    private func handleTermination() async {
        started = false
        handshakeComplete = false
        process = nil
        stdinHandle = nil
        inMemoryStartedThreadIds.removeAll()
        readBuffer.removeAll()
        // Fail any in-flight requests so callers don't hang forever.
        let inflight = pending
        pending.removeAll()
        for (_, cont) in inflight {
            cont.resume(throwing: ClientError.transportClosed)
        }
        await handlers.onClose()
    }

    // MARK: - Public RPC surface

    func startThread(
        cwd: String,
        approvalPolicy: String? = nil,
        sandboxPolicyType: String? = nil,
        model: String? = nil
    ) async throws -> StartedThread {
        try await ensureStarted()
        let result = try await request(
            method: CodexAppServerProtocol.Method.threadStart,
            params: CodexAppServerProtocol.threadStartParams(
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandboxPolicyType: sandboxPolicyType,
                model: model
            )
        )
        guard let thread = result.object("thread"),
              let id = thread["id"] as? String,
              !id.isEmpty else {
            throw ClientError.malformedResponse("thread/start response missing thread.id")
        }
        inMemoryStartedThreadIds.insert(id)
        return StartedThread(
            id: id,
            cwd: (thread["cwd"] as? String) ?? cwd,
            path: thread["path"] as? String
        )
    }

    /// Resume a thread (load a rollout into the app-server engine), then
    /// start a turn with user input. Fresh `thread/start` threads are only
    /// in memory until their first `turn/start`, so their first turn must
    /// skip resume.
    func sendTurn(
        threadId: String,
        text: String,
        localImagePaths: [String] = [],
        approvalPolicy: String? = nil,
        sandboxPolicyType: String? = nil
    ) async throws {
        try await ensureStarted()
        let isFreshInMemoryThread = inMemoryStartedThreadIds.contains(threadId)
        if !isFreshInMemoryThread {
            _ = try await request(
                method: CodexAppServerProtocol.Method.threadResume,
                params: CodexAppServerProtocol.threadResumeParams(
                    threadId: threadId,
                    approvalPolicy: approvalPolicy,
                    sandboxPolicyType: sandboxPolicyType
                )
            )
        }
        _ = try await request(
            method: CodexAppServerProtocol.Method.turnStart,
            params: CodexAppServerProtocol.turnStartParams(
                threadId: threadId,
                text: text,
                localImagePaths: localImagePaths,
                approvalPolicy: approvalPolicy,
                sandboxPolicyType: sandboxPolicyType
            )
        )
        if isFreshInMemoryThread {
            inMemoryStartedThreadIds.remove(threadId)
        }
    }

    /// Interrupt the running turn (cancel / Ctrl-C equivalent).
    func interrupt(threadId: String, turnId: String) async throws {
        try await ensureStarted()
        _ = try await request(
            method: CodexAppServerProtocol.Method.turnInterrupt,
            params: CodexAppServerProtocol.turnInterruptParams(threadId: threadId, turnId: turnId)
        )
    }

    func readAccountRateLimits() async throws -> CodexUsageSnapshot {
        try await ensureStarted()
        let result = try await request(
            method: CodexAppServerProtocol.Method.accountRateLimitsRead,
            params: nil
        )
        guard let snapshot = CodexUsageSnapshotParser.response(
            result,
            observedAt: Date()
        ) else {
            throw ClientError.malformedResponse(
                "account/rateLimits/read response missing rate-limit windows"
            )
        }
        return snapshot
    }

    /// Answer a server→client request (e.g. an approval decision). Fire
    /// and forget — the engine doesn't ack our reply.
    func respond(id: CodexRPCID, result: [String: AnyCodable]) {
        do {
            try writeLine(CodexRPCResponseOut(id: id, result: result))
        } catch {
            Self.logger.error("respond write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reject a server→client request we can't satisfy with a JSON-RPC
    /// error, so the engine falls back to its own handling instead of
    /// waiting forever for a reply.
    func respondError(id: CodexRPCID, code: Int = -32601, message: String) {
        do {
            try writeLine(CodexRPCErrorOut(id: id, code: code, message: message))
        } catch {
            Self.logger.error("respondError write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Request/response correlation

    private func request(
        method: String,
        params: [String: AnyCodable]?
    ) async throws -> AnyCodableEquatableBox {
        let id = nextId
        nextId += 1
        let req = CodexRPCRequest(id: .int(id), method: method, params: params)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try writeLine(req)
            } catch {
                pending[id] = nil
                cont.resume(throwing: error)
            }
        }
    }

    private func writeLine<T: Encodable>(_ message: T) throws {
        guard let handle = stdinHandle else { throw ClientError.notStarted }
        var data = try CodexAppServerProtocol.encodeLine(message)
        data.append(0x0A)  // newline framing
        handle.write(data)
    }

    // MARK: - Inbound ingest

    private func ingest(_ chunk: Data) async {
        readBuffer.append(chunk)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            await dispatch(line)
        }
    }

    private func dispatch(_ line: Data) async {
        switch CodexAppServerProtocol.classify(line) {
        case let .response(id, box):
            if case let .int(i) = id, let cont = pending.removeValue(forKey: i) {
                cont.resume(returning: box)
            }
        case let .error(id, code, message):
            if case let .int(i)? = id, let cont = pending.removeValue(forKey: i) {
                cont.resume(throwing: ClientError.rpcError(code: code, message: message))
            } else {
                Self.logger.error("app-server error (unmatched id) code=\(code) msg=\(message, privacy: .public)")
            }
        case let .serverRequest(id, method, params):
            switch CodexServerRequestRoutingPolicy.route(
                kind: CodexAppServerProtocol.ServerRequestMethod.kind(method),
                capability: .managed
            ) {
            case .handle:
                await handlers.onServerRequest(id, method, params)
            case .reject:
                // Reject requests we don't implement so the engine isn't
                // left hanging on a reply we'll never send. This client owns
                // its private app-server, so there is no peer UI to defer to.
                Self.logger.info("rejecting unhandled server-request method=\(method, privacy: .public)")
                respondError(id: id, message: "unsupported by agent-visor: \(method)")
            case .deferToPeer:
                break
            }
        case let .notification(method, params):
            await handlers.onNotification(method, params)
        case let .unrecognized(raw):
            Self.logger.debug("unrecognized app-server line: \(raw, privacy: .public)")
        }
    }

    // MARK: - Helpers

    static func resolveCodexBinary() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/codex"
    }

    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
}
