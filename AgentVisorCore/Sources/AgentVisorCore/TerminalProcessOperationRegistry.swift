import Foundation
import Darwin

/// A real child process plus the completion signal used by the app executor.
/// The registry owns this same termination primitive for production and tests,
/// so a serializer cannot release its lane until the child has exited.
public final class ManagedTerminalProcess: @unchecked Sendable {
    public let process: Process
    private let termination: DispatchSemaphore

    public init(process: Process, termination: DispatchSemaphore) {
        self.process = process
        self.termination = termination
    }

    public func terminateAndWait() {
        if process.isRunning { process.terminate() }
        if termination.wait(timeout: .now() + 1) == .timedOut,
           process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + 1)
        }
    }
}

/// A registration for one bounded terminal child/action.
public struct TerminalProcessOperationToken: Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Owns the process/action registrations for terminal transport operations.
///
/// The app's ProcessExecutor registers every AppleScript/tmux child here with
/// the same operation ID that owns the serializer lane. Termination is a
/// synchronous `terminateAndWait` callback by design: a caller may release a
/// lane only after the child has stopped and cannot write into a reused pane.
/// The registry is deliberately small and bounded by live work; completed
/// registrations are removed immediately by their token.
public final class TerminalProcessOperationRegistry: @unchecked Sendable {
    public static let shared = TerminalProcessOperationRegistry()

    private struct Registration {
        let operationID: String
        let terminateAndWait: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var registrations: [TerminalProcessOperationToken: Registration] = [:]

    public init() {}

    /// Register a live child/action. Empty operation IDs are rejected so a
    /// Chat child can never accidentally become an unscoped cancellation.
    @discardableResult
    public func register(
        operationID: String,
        terminateAndWait: @escaping @Sendable () -> Void
    ) -> TerminalProcessOperationToken? {
        guard !operationID.isEmpty else { return nil }
        let token = TerminalProcessOperationToken()
        lock.withLock {
            registrations[token] = Registration(
                operationID: operationID,
                terminateAndWait: terminateAndWait
            )
        }
        return token
    }

    /// Register a live child using the same production termination path used
    /// by ProcessExecutor. Empty operation IDs remain fail-closed.
    @discardableResult
    public func register(
        operationID: String,
        process: Process,
        termination: DispatchSemaphore
    ) -> TerminalProcessOperationToken? {
        let managed = ManagedTerminalProcess(process: process, termination: termination)
        return register(operationID: operationID, terminateAndWait: managed.terminateAndWait)
    }

    /// Remove a completed registration. Releasing an unknown token is safe.
    public func unregister(_ token: TerminalProcessOperationToken?) {
        guard let token else { return }
        _ = lock.withLock { registrations.removeValue(forKey: token) }
    }

    /// Terminate and await all children owned by an operation. Passing nil is
    /// reserved for the app-wide emergency shutdown path; Chat always passes
    /// its non-empty serializer operation ID.
    public func terminateAndWait(operationID: String? = nil) {
        let callbacks = lock.withLock {
            registrations.values
                .filter { operationID == nil || $0.operationID == operationID }
                .map(\.terminateAndWait)
        }
        callbacks.forEach { $0() }
    }

    /// Test/diagnostic visibility into live work, without exposing callbacks.
    public func liveCount(operationID: String? = nil) -> Int {
        lock.withLock {
            registrations.values.filter {
                operationID == nil || $0.operationID == operationID
            }.count
        }
    }
}
