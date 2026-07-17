import Foundation

public protocol CodexRPCTransport: Sendable {
    func start(
        onMessage: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws
    func send(_ message: Data) async throws
    func close() async
}

public enum CodexRPCSessionError: Error, Equatable, Sendable {
    case transportClosed
    case requestTimedOut(method: String)
    case rpcError(code: Int, message: String)
    case malformedResponse(String)
}

public struct CodexRPCSessionHandlers: Sendable {
    public var onNotification: @Sendable (String, AnyCodableEquatableBox) async -> Void
    public var onServerRequest: @Sendable (CodexRPCID, String, AnyCodableEquatableBox) async -> Void
    public var onClose: @Sendable () async -> Void

    public init(
        onNotification: @escaping @Sendable (String, AnyCodableEquatableBox) async -> Void = { _, _ in },
        onServerRequest: @escaping @Sendable (CodexRPCID, String, AnyCodableEquatableBox) async -> Void = { _, _, _ in },
        onClose: @escaping @Sendable () async -> Void = {}
    ) {
        self.onNotification = onNotification
        self.onServerRequest = onServerRequest
        self.onClose = onClose
    }
}

public actor CodexRPCSession {
    private enum InboundEvent: Sendable {
        case message(Data)
        case closed
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<AnyCodableEquatableBox, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let transport: any CodexRPCTransport
    private let requestTimeoutNanoseconds: UInt64
    private var nextId = 1
    private var pending: [Int: PendingRequest] = [:]
    private var connected = false
    private var handlers = CodexRPCSessionHandlers()
    private var inboundContinuation: AsyncStream<InboundEvent>.Continuation?
    private var inboundTask: Task<Void, Never>?

    public init(
        transport: any CodexRPCTransport,
        requestTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.transport = transport
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
    }

    public func setHandlers(_ handlers: CodexRPCSessionHandlers) {
        self.handlers = handlers
    }

    public func connect(
        clientName: String,
        clientVersion: String,
        experimentalApi: Bool = false
    ) async throws -> String {
        if connected {
            throw CodexRPCSessionError.malformedResponse("session already connected")
        }
        let inbound = startInboundPump()
        do {
            try await transport.start(
                onMessage: { message in
                    inbound.yield(.message(message))
                },
                onClose: {
                    inbound.yield(.closed)
                    inbound.finish()
                }
            )
        } catch {
            stopInboundPump()
            throw error
        }
        let result = try await request(
            method: CodexAppServerProtocol.Method.initialize,
            params: CodexAppServerProtocol.initializeParams(
                name: clientName,
                version: clientVersion,
                experimentalApi: experimentalApi
            )
        )
        try await sendNotification(method: CodexAppServerProtocol.Method.initialized)
        guard let userAgent = result.string("userAgent"), !userAgent.isEmpty else {
            throw CodexRPCSessionError.malformedResponse("initialize response missing userAgent")
        }
        connected = true
        return userAgent
    }

    public func request(
        method: String,
        params: [String: AnyCodable]? = nil
    ) async throws -> AnyCodableEquatableBox {
        let id = nextId
        nextId += 1
        let message = try CodexAppServerProtocol.encodeLine(
            CodexRPCRequest(id: .int(id), method: method, params: params)
        )
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(nanoseconds: self.requestTimeoutNanoseconds)
                    } catch {
                        return
                    }
                    await self.failRequest(
                        id: id,
                        error: CodexRPCSessionError.requestTimedOut(method: method)
                    )
                }
                pending[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self, transport] in
                    guard await self?.hasPendingRequest(id: id) == true else { return }
                    do {
                        try await transport.send(message)
                    } catch {
                        await self?.failRequest(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failRequest(id: id, error: CancellationError())
            }
        }
    }

    public func respond(
        id: CodexRPCID,
        result: [String: AnyCodable]
    ) async throws {
        let message = try CodexAppServerProtocol.encodeLine(
            CodexRPCResponseOut(id: id, result: result)
        )
        try await transport.send(message)
    }

    public func respondError(
        id: CodexRPCID,
        code: Int = -32601,
        message: String
    ) async throws {
        let data = try CodexAppServerProtocol.encodeLine(
            CodexRPCErrorOut(id: id, code: code, message: message)
        )
        try await transport.send(data)
    }

    public func close() async {
        connected = false
        await transport.close()
        stopInboundPump()
        failPending(with: CodexRPCSessionError.transportClosed)
    }

    private func sendNotification(method: String) async throws {
        let message = try CodexAppServerProtocol.encodeLine(
            CodexRPCNotificationOut(method: method)
        )
        try await transport.send(message)
    }

    private func receive(_ message: Data) async {
        switch CodexAppServerProtocol.classify(message) {
        case let .response(id, result):
            guard case let .int(value) = id,
                  let request = pending.removeValue(forKey: value) else { return }
            request.timeoutTask.cancel()
            request.continuation.resume(returning: result)
        case let .error(id, code, message):
            guard case let .int(value)? = id,
                  let request = pending.removeValue(forKey: value) else { return }
            request.timeoutTask.cancel()
            request.continuation.resume(
                throwing: CodexRPCSessionError.rpcError(code: code, message: message)
            )
        case let .serverRequest(id, method, params):
            await handlers.onServerRequest(id, method, params)
        case let .notification(method, params):
            await handlers.onNotification(method, params)
        case .unrecognized:
            break
        }
    }

    private func failRequest(id: Int, error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func transportDidClose() async {
        connected = false
        failPending(with: CodexRPCSessionError.transportClosed)
        await handlers.onClose()
    }

    private func failPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func hasPendingRequest(id: Int) -> Bool {
        pending[id] != nil
    }

    private func startInboundPump() -> AsyncStream<InboundEvent>.Continuation {
        stopInboundPump()
        let (stream, continuation) = AsyncStream<InboundEvent>.makeStream()
        inboundContinuation = continuation
        inboundTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .message(let message):
                    await self.receive(message)
                case .closed:
                    await self.transportDidClose()
                }
            }
        }
        return continuation
    }

    private func stopInboundPump() {
        inboundContinuation?.finish()
        inboundContinuation = nil
        inboundTask?.cancel()
        inboundTask = nil
    }
}
