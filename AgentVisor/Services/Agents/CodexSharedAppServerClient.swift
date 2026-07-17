import Foundation
import os.log
import AgentVisorCore

actor CodexSharedAppServerClient {
    enum ClientError: Error, Equatable {
        case threadMismatch(expected: String, actual: String?)
        case threadNotAttached(String)
    }

    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "CodexConnected")

    private let rpcSession: CodexRPCSession
    private var handlers = CodexAppServerHandlers()
    private var attachedThreadIds = Set<String>()
    private(set) var serverUserAgent: String?

    init(rpcSession: CodexRPCSession) {
        self.rpcSession = rpcSession
    }

    func setHandlers(_ handlers: CodexAppServerHandlers) {
        self.handlers = handlers
    }

    func connect(clientVersion: String) async throws {
        await rpcSession.setHandlers(CodexRPCSessionHandlers(
            onNotification: { [weak self] method, params in
                await self?.deliverNotification(method: method, params: params)
            },
            onServerRequest: { [weak self] id, method, params in
                await self?.deliverServerRequest(id: id, method: method, params: params)
            },
            onClose: { [weak self] in
                await self?.connectionClosed()
            }
        ))
        serverUserAgent = try await rpcSession.connect(
            clientName: "agent-visor-connected-codex",
            clientVersion: clientVersion,
            experimentalApi: true
        )
    }

    func attach(threadId: String) async throws -> CodexSharedRuntimeEvidence {
        let read = try await requestWithOverloadRetry(
            method: CodexAppServerProtocol.Method.threadRead,
            params: CodexAppServerProtocol.threadReadParams(threadId: threadId)
        )
        try Self.requireThreadId(threadId, in: read)

        let resumed = try await requestWithOverloadRetry(
            method: CodexAppServerProtocol.Method.threadResume,
            params: CodexAppServerProtocol.threadResumeParams(
                threadId: threadId,
                excludeTurns: true
            )
        )
        try Self.requireThreadId(threadId, in: resumed)
        attachedThreadIds.insert(threadId)
        if let status = resumed.object("thread")?["status"] as? [String: Any] {
            await handlers.onNotification(
                CodexAppServerProtocol.NotificationMethod.threadStatusChanged,
                AnyCodableEquatableBox([
                    "threadId": threadId,
                    "status": status,
                ])
            )
        }
        return CodexSharedRuntimeEvidence(
            threadId: threadId,
            transportConnected: true,
            handshakeComplete: true,
            versionCompatible: serverUserAgent != nil,
            subscriptionConfirmed: true
        )
    }

    func sendTurn(
        threadId: String,
        text: String,
        localImagePaths: [String]
    ) async throws {
        guard attachedThreadIds.contains(threadId) else {
            throw ClientError.threadNotAttached(threadId)
        }
        _ = try await requestWithOverloadRetry(
            method: CodexAppServerProtocol.Method.turnStart,
            params: CodexAppServerProtocol.turnStartParams(
                threadId: threadId,
                text: text,
                localImagePaths: localImagePaths
            )
        )
    }

    func interrupt(threadId: String, turnId: String) async throws {
        guard attachedThreadIds.contains(threadId) else {
            throw ClientError.threadNotAttached(threadId)
        }
        _ = try await requestWithOverloadRetry(
            method: CodexAppServerProtocol.Method.turnInterrupt,
            params: CodexAppServerProtocol.turnInterruptParams(threadId: threadId, turnId: turnId)
        )
    }

    func respond(id: CodexRPCID, result: [String: AnyCodable]) async throws {
        try await rpcSession.respond(id: id, result: result)
    }

    func respondError(id: CodexRPCID, message: String) async throws {
        try await rpcSession.respondError(id: id, message: message)
    }

    func detach(threadId: String) async {
        guard attachedThreadIds.remove(threadId) != nil else { return }
        _ = try? await requestWithOverloadRetry(
            method: CodexAppServerProtocol.Method.threadUnsubscribe,
            params: CodexAppServerProtocol.threadUnsubscribeParams(threadId: threadId)
        )
    }

    func close() async {
        attachedThreadIds.removeAll()
        await rpcSession.close()
    }

    private func requestWithOverloadRetry(
        method: String,
        params: [String: AnyCodable]? = nil
    ) async throws -> AnyCodableEquatableBox {
        var retryAttempt = 0
        while true {
            do {
                return try await rpcSession.request(method: method, params: params)
            } catch let error as CodexRPCSessionError {
                guard case .rpcError(let code, _) = error,
                      let delay = CodexRPCOverloadRetryPolicy.delayNanoseconds(
                        errorCode: code,
                        retryAttempt: retryAttempt
                      ) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: delay)
                retryAttempt += 1
            }
        }
    }

    private func deliverNotification(
        method: String,
        params: AnyCodableEquatableBox
    ) async {
        await handlers.onNotification(method, params)
    }

    private func deliverServerRequest(
        id: CodexRPCID,
        method: String,
        params: AnyCodableEquatableBox
    ) async {
        switch CodexServerRequestRoutingPolicy.route(
            kind: CodexAppServerProtocol.ServerRequestMethod.kind(method),
            capability: .connected
        ) {
        case .handle:
            await handlers.onServerRequest(id, method, params)
        case .reject:
            try? await rpcSession.respondError(
                id: id,
                message: "unsupported by agent-visor: \(method)"
            )
        case .deferToPeer:
            Self.logger.debug(
                "deferring server request to Codex Desktop method=\(method, privacy: .public)"
            )
        }
    }

    private func connectionClosed() async {
        attachedThreadIds.removeAll()
        await handlers.onClose()
    }

    private static func requireThreadId(
        _ expected: String,
        in response: AnyCodableEquatableBox
    ) throws {
        let actual = response.object("thread")?["id"] as? String
        guard actual == expected else {
            throw ClientError.threadMismatch(expected: expected, actual: actual)
        }
    }
}
