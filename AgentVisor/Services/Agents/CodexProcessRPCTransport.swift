import AgentVisorCore
import Foundation
import os.log

actor CodexProcessRPCTransport: CodexRPCTransport {
    nonisolated private static let logger = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "CodexUnixTransport"
    )
    enum TransportError: Error, Equatable {
        case alreadyStarted
        case notStarted
        case closed
        case writeFailed
        case handshakeTimedOut
    }

    typealias ProcessFactory = @Sendable () -> Process

    private enum State: Equatable {
        case idle
        case handshaking
        case running
        case closed
    }

    private enum OutputEvent: Sendable {
        case data(Data)
        case closed
    }

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let processFactory: ProcessFactory

    private var state = State.idle
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var writer: CodexPipeWriter?
    private var outputContinuation: AsyncStream<OutputEvent>.Continuation?
    private var outputTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private var handshakeBuffer = Data()
    private var decoder = CodexWebSocketStreamDecoder()
    private var onMessage: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        processFactory: @escaping ProcessFactory = { Process() }
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.processFactory = processFactory
    }

    func start(
        onMessage: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws {
        switch state {
        case .idle:
            break
        case .handshaking, .running:
            throw TransportError.alreadyStarted
        case .closed:
            throw TransportError.closed
        }

        let process = processFactory()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processDidTerminate() }
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        writer = CodexPipeWriter(handle: inputPipe.fileHandleForWriting)
        self.onMessage = onMessage
        self.onClose = onClose
        state = .handshaking

        do {
            try process.run()
        } catch {
            resetAfterFailedStart()
            throw error
        }

        let outputHandle = outputPipe.fileHandleForReading
        let (outputEvents, outputContinuation) = AsyncStream<OutputEvent>.makeStream()
        self.outputContinuation = outputContinuation
        outputTask = Task { [weak self] in
            for await event in outputEvents {
                guard !Task.isCancelled, let self else { return }
                await self.consumeOutput(event)
            }
        }
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                outputContinuation.yield(.closed)
                outputContinuation.finish()
            } else {
                outputContinuation.yield(.data(data))
            }
        }

        let key = Self.makeHandshakeKey()
        try await withCheckedThrowingContinuation { continuation in
            handshakeContinuation = continuation
            handshakeKey = key
            handshakeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.handshakeTimedOut()
            }
            do {
                try writeRaw(
                    CodexWebSocketCodec.handshakeRequest(
                        path: "/rpc",
                        host: "localhost",
                        key: key
                    )
                )
            } catch {
                finish(error: error, notifyClose: false, terminateProcess: true)
            }
        }
    }

    func send(_ message: Data) async throws {
        switch state {
        case .idle, .handshaking:
            throw TransportError.notStarted
        case .closed:
            throw TransportError.closed
        case .running:
            break
        }
        guard let writer else { throw TransportError.closed }
        do {
            try await writer.write(
                frame(payload: message, opcode: .text)
            )
            guard state == .running else { throw TransportError.closed }
        } catch {
            finish(error: error, notifyClose: true, terminateProcess: true)
            throw TransportError.writeFailed
        }
    }

    func close() async {
        switch state {
        case .idle:
            state = .closed
        case .handshaking, .running:
            if state == .running, let writer {
                try? await writer.write(
                    frame(payload: Data(), opcode: .close),
                    timeout: 0.25
                )
            }
            finish(error: TransportError.closed, notifyClose: false, terminateProcess: true)
        case .closed:
            break
        }
    }

    private var handshakeKey: String?

    private func consumeOutput(_ event: OutputEvent) async {
        switch event {
        case .data(let data):
            await receive(data)
        case .closed:
            outputDidClose()
        }
    }

    private func receive(_ data: Data) async {
        Self.logger.debug("proxy stdout bytes=\(data.count, privacy: .public)")
        switch state {
        case .handshaking:
            await receiveHandshake(data)
        case .running:
            await receiveFrames(data)
        case .idle, .closed:
            break
        }
    }

    private func receiveHandshake(_ data: Data) async {
        handshakeBuffer.append(data)
        let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = handshakeBuffer.range(of: delimiter),
              let key = handshakeKey else { return }

        let headerEnd = range.upperBound
        let response = Data(handshakeBuffer[..<headerEnd])
        let remainder = Data(handshakeBuffer[headerEnd...])
        handshakeBuffer.removeAll(keepingCapacity: false)
        do {
            try CodexWebSocketCodec.validateHandshakeResponse(response, key: key)
            state = .running
            handshakeKey = nil
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            let continuation = handshakeContinuation
            handshakeContinuation = nil
            if !remainder.isEmpty {
                await receiveFrames(remainder)
            }
            continuation?.resume()
        } catch {
            finish(error: error, notifyClose: false, terminateProcess: true)
        }
    }

    private func receiveFrames(_ data: Data) async {
        do {
            for event in try decoder.append(data) {
                switch event {
                case .message(let payload):
                    onMessage?(payload)
                case .ping(let payload):
                    guard let writer else { throw TransportError.closed }
                    try await writer.write(frame(payload: payload, opcode: .pong))
                case .pong:
                    break
                case .close(let payload):
                    if let writer {
                        try? await writer.write(
                            frame(payload: payload, opcode: .close),
                            timeout: 0.25
                        )
                    }
                    finish(
                        error: TransportError.closed,
                        notifyClose: true,
                        terminateProcess: true
                    )
                    return
                }
            }
        } catch {
            finish(error: error, notifyClose: true, terminateProcess: true)
        }
    }

    private func processDidTerminate() {
        guard state == .handshaking || state == .running else { return }
        try? inputPipe?.fileHandleForWriting.close()
    }

    private func outputDidClose() {
        guard state == .handshaking || state == .running else { return }
        finish(
            error: TransportError.closed,
            notifyClose: state == .running,
            terminateProcess: process?.isRunning == true
        )
    }

    private func handshakeTimedOut() {
        guard state == .handshaking else { return }
        Self.logger.error(
            "proxy websocket handshake timed out buffered=\(self.handshakeBuffer.count, privacy: .public)"
        )
        finish(
            error: TransportError.handshakeTimedOut,
            notifyClose: false,
            terminateProcess: true
        )
    }

    private func frame(payload: Data, opcode: CodexWebSocketOpcode) -> Data {
        CodexWebSocketCodec.clientFrame(
            payload: payload,
            opcode: opcode,
            maskKey: (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        )
    }

    private func writeRaw(_ data: Data) throws {
        guard let process, process.isRunning, let inputPipe else {
            throw TransportError.closed
        }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw TransportError.writeFailed
        }
    }

    private func finish(
        error: Error,
        notifyClose: Bool,
        terminateProcess: Bool
    ) {
        guard state != .closed else { return }
        let wasStarted = state != .idle
        state = .closed
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        handshakeKey = nil
        handshakeBuffer.removeAll(keepingCapacity: false)
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        let closeHandler = onClose
        onMessage = nil
        onClose = nil
        cleanUpProcess(terminate: terminateProcess)
        continuation?.resume(throwing: error)
        if notifyClose, wasStarted {
            closeHandler?()
        }
    }

    private func resetAfterFailedStart() {
        state = .idle
        onMessage = nil
        onClose = nil
        handshakeKey = nil
        handshakeBuffer.removeAll(keepingCapacity: false)
        cleanUpProcess(terminate: false)
    }

    private func cleanUpProcess(terminate: Bool) {
        process?.terminationHandler = nil
        writer?.close()
        writer = nil
        outputContinuation?.finish()
        outputContinuation = nil
        outputTask?.cancel()
        outputTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        try? inputPipe?.fileHandleForReading.close()
        try? outputPipe?.fileHandleForReading.close()
        try? outputPipe?.fileHandleForWriting.close()
        if terminate, let process, process.isRunning {
            process.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
    }

    private static func makeHandshakeKey() -> String {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }
}

nonisolated private final class CodexPipeWriter: @unchecked Sendable {
    enum WriterError: Error {
        case timedOut
        case closed
        case writeFailed
    }

    private let handle: FileHandle
    private let queue = DispatchQueue(
        label: AppBranding.loggerSubsystem + ".codex-pipe-writer"
    )
    private let lock = NSLock()
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data, timeout: TimeInterval = 2) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completion = CodexPipeWriteCompletion(continuation: continuation)
            queue.async { [weak self] in
                guard let self, !self.isClosed else {
                    completion.resume(.failure(WriterError.closed))
                    return
                }
                do {
                    try self.handle.write(contentsOf: data)
                    completion.resume(.success(()))
                } catch {
                    completion.resume(.failure(WriterError.writeFailed))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout
            ) { [weak self] in
                if completion.resume(.failure(WriterError.timedOut)) {
                    self?.close()
                }
            }
        }
    }

    func close() {
        lock.lock()
        let shouldClose = !closed
        closed = true
        lock.unlock()
        if shouldClose {
            try? handle.close()
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

nonisolated private final class CodexPipeWriteCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}

protocol CodexProcessRPCTransportBuilding: Sendable {
    func makeTransport(
        launchPlan: CodexSharedRuntimeLaunchPlan
    ) throws -> CodexProcessRPCTransport
    func makeSession(
        launchPlan: CodexSharedRuntimeLaunchPlan
    ) throws -> CodexRPCSession
}

struct CodexProcessRPCTransportFactory: CodexProcessRPCTransportBuilding {
    private let binaryResolver: any CodexSharedRuntimeBinaryResolving

    init(
        binaryResolver: any CodexSharedRuntimeBinaryResolving = CodexSharedRuntimeBinaryResolver()
    ) {
        self.binaryResolver = binaryResolver
    }

    func makeTransport(
        launchPlan: CodexSharedRuntimeLaunchPlan
    ) throws -> CodexProcessRPCTransport {
        CodexProcessRPCTransport(
            executableURL: try binaryResolver.bundledCodexBinaryURL(),
            arguments: launchPlan.proxyArguments
        )
    }

    func makeSession(
        launchPlan: CodexSharedRuntimeLaunchPlan
    ) throws -> CodexRPCSession {
        CodexRPCSession(transport: try makeTransport(launchPlan: launchPlan))
    }
}
