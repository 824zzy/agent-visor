import Foundation

/// Errors from the per-session terminal transport lane.
public enum TerminalTransportSerializerError: Error, Equatable, Sendable {
    case acquisitionTimedOut
    case operationTimedOut
    case queueFull
    case reentrantOwnership
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .acquisitionTimedOut:
            return "The terminal transport lane was busy too long."
        case .operationTimedOut:
            return "The terminal transport operation did not finish in time."
        case .queueFull:
            return "Too many terminal actions are waiting for this session."
        case .reentrantOwnership:
            return "The same terminal transport owner already holds this lane."
        case .cancelled:
            return "The terminal transport operation was cancelled."
        }
    }
}

/// An exclusive lease for one session's terminal transport lane.
public struct TerminalTransportLease: Hashable, Sendable {
    public let sessionID: String
    public let ownerID: String

    fileprivate init(sessionID: String, ownerID: String) {
        self.sessionID = sessionID
        self.ownerID = ownerID
    }
}

/// Serializes terminal writes per session and gives each potentially blocking
/// action a bounded, cancellation-aware lifetime.
///
/// A terminal prompt is one mutable remote buffer: image paste, text submit,
/// Escape, and destructive clearing must never interleave with one another,
/// while unrelated sessions remain independent. The serializer does not claim
/// that cancellation magically stops an arbitrary closure. The caller supplies
/// `terminate` for the real transport (for example, terminate and await an
/// `osascript` child). The lane is released only after the operation task has
/// returned, which prevents a timed-out action from writing late.
public actor TerminalTransportSerializer {
    public static let shared = TerminalTransportSerializer()

    /// Maximum time a queued action may wait for its session lane.
    public static let defaultAcquisitionTimeout: TimeInterval = 2
    /// Maximum time a transport action may run before its terminator is asked
    /// to stop it. The terminator must still prove that the action has ended.
    public static let defaultOperationTimeout: TimeInterval = 30
    /// A bounded queue prevents a burst of repeated clicks from retaining an
    /// unbounded number of closures and snapshots.
    // ponytail: if this cap changes, review the recovery record cap and UI
    // repeated-action policy together; rejecting a new action is safer than
    // silently evicting an in-flight user action.
    public static let maximumWaitersPerSession = 64

    private struct Waiter {
        let ownerID: String
        let continuation: CheckedContinuation<TerminalTransportLease, Error>
    }

    private var holders: [String: TerminalTransportLease] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private var legacyLeases: [String: TerminalTransportLease] = [:]

    public init() {}

    /// Acquire a bounded, explicitly-owned session lane.
    ///
    /// `ownerID` is intentionally supplied by the caller for compound
    /// operations. Reusing it while the owner already holds the lane fails
    /// fast instead of creating a same-lane deadlock.
    public func acquire(
        sessionID: String,
        ownerID: String = UUID().uuidString,
        acquisitionTimeout: TimeInterval = TerminalTransportSerializer.defaultAcquisitionTimeout
    ) async throws -> TerminalTransportLease {
        let timeout = boundedAcquisitionTimeout(acquisitionTimeout)
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: timeout))
                await self?.timeoutWaiter(sessionID: sessionID, ownerID: ownerID)
            } catch {
                // The lease arrived or the caller cancelled before the bound.
            }
        }
        defer { timeoutTask.cancel() }

        let lease: TerminalTransportLease = try await withTaskCancellationHandler {
            try await enqueue(sessionID: sessionID, ownerID: ownerID)
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(sessionID: sessionID, ownerID: ownerID)
            }
        }

        // Cancellation can race with an immediately available lane. Do not
        // return a lease to a cancelled caller without first giving it back.
        guard !Task.isCancelled else {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    /// Compatibility wrapper for the original acquire/release API. New
    /// transport code must use the throwing lease API or `withLane`, so a
    /// bounded failure cannot accidentally be mistaken for ownership.
    @available(*, deprecated, message: "Use acquire(sessionID:ownerID:acquisitionTimeout:)")
    public func acquire(sessionID: String) async {
        // Keep each compatibility call independent. A literal UUID expression
        // would make concurrent legacy callers look like a reentrant owner.
        let ownerID = "legacy-\(UUID().uuidString)"
        guard let lease = try? await acquire(
            sessionID: sessionID,
            ownerID: ownerID,
            acquisitionTimeout: Self.defaultAcquisitionTimeout
        ) else { return }
        legacyLeases[sessionID] = lease
    }

    /// Release an exact lease. A stale or duplicate release is a no-op.
    public func release(_ lease: TerminalTransportLease) {
        guard holders[lease.sessionID] == lease else { return }
        advance(sessionID: lease.sessionID)
    }

    /// Compatibility release for the original acquire/release API.
    @available(*, deprecated, message: "Use release(_ lease:)")
    public func release(sessionID: String) {
        guard let lease = legacyLeases.removeValue(forKey: sessionID) else { return }
        release(lease)
    }

    /// Number of live waiters for tests and diagnostics.
    public func waiterCount(sessionID: String) -> Int {
        waiters[sessionID]?.count ?? 0
    }

    /// Run one complete terminal transaction under one lane.
    ///
    /// On timeout or task cancellation, the operation is cancelled, then the
    /// supplied terminator runs, and then the operation task is awaited before
    /// the lease is released. This ordering is the key safety property: a
    /// later send cannot overlap a late write from a timed-out action.
    public func withLane<Value: Sendable>(
        sessionID: String,
        ownerID: String = UUID().uuidString,
        acquisitionTimeout: TimeInterval = TerminalTransportSerializer.defaultAcquisitionTimeout,
        operationTimeout: TimeInterval = TerminalTransportSerializer.defaultOperationTimeout,
        operation: @escaping () async throws -> Value,
        terminate: @escaping () async -> Void
    ) async throws -> Value {
        let lease = try await acquire(
            sessionID: sessionID,
            ownerID: ownerID,
            acquisitionTimeout: acquisitionTimeout
        )
        defer { release(lease) }

        let race = OperationRace<Value>()
        let operationTask = Task {
            do {
                await race.finish(.success(try await operation()))
            } catch {
                await race.finish(.failure(error))
            }
        }
        let timerTask = Task {
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        for: boundedOperationTimeout(operationTimeout)
                    )
                )
                await race.finish(.timedOut)
            } catch {
                // The operation completed or the caller cancelled first.
            }
        }

        let event = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            Task { await race.finish(.cancelled) }
        }
        timerTask.cancel()

        switch event {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .timedOut:
            operationTask.cancel()
            await terminate()
            // Do not release the lane until the action has actually returned.
            _ = await operationTask.result
            throw TerminalTransportSerializerError.operationTimedOut
        case .cancelled:
            operationTask.cancel()
            await terminate()
            _ = await operationTask.result
            throw CancellationError()
        }
    }

    /// Source-compatible convenience for pure callers whose operation is
    /// guaranteed to cooperate with task cancellation. Chat production paths
    /// must use the overload above and provide the real child-process/transport
    /// terminator; this shim deliberately cannot be used to claim bounded
    /// cancellation of an arbitrary external action.
    @available(*, deprecated, message: "Provide terminate for bounded production transport actions")
    public func withLane<Value: Sendable>(
        sessionID: String,
        ownerID: String = UUID().uuidString,
        acquisitionTimeout: TimeInterval = TerminalTransportSerializer.defaultAcquisitionTimeout,
        operationTimeout: TimeInterval = TerminalTransportSerializer.defaultOperationTimeout,
        operation: @escaping () async throws -> Value
    ) async throws -> Value {
        try await withLane(
            sessionID: sessionID,
            ownerID: ownerID,
            acquisitionTimeout: acquisitionTimeout,
            operationTimeout: operationTimeout,
            operation: operation,
            terminate: {
                // Compatibility is intentionally a no-op only for callers
                // that have not adopted an external action. The production
                // send/cancel call sites pass an explicit terminator.
            }
        )
    }

    /// Legacy convenience retained for callers that have no error surface yet.
    /// It still uses one lane, but cannot expose bounded failures; production
    /// sends and cancels therefore use `withLane` directly.
    @available(*, deprecated, message: "Use withLane for bounded terminal actions")
    public func run<Value>(
        sessionID: String,
        operation: @escaping () async -> Value
    ) async -> Value {
        await acquire(sessionID: sessionID)
        defer { release(sessionID: sessionID) }
        return await operation()
    }

    private func enqueue(
        sessionID: String,
        ownerID: String
    ) async throws -> TerminalTransportLease {
        try Task.checkCancellation()
        if let holder = holders[sessionID], holder.ownerID == ownerID {
            throw TerminalTransportSerializerError.reentrantOwnership
        }
        if waiters[sessionID]?.contains(where: { $0.ownerID == ownerID }) == true {
            throw TerminalTransportSerializerError.reentrantOwnership
        }

        let lease = TerminalTransportLease(sessionID: sessionID, ownerID: ownerID)
        guard holders[sessionID] == nil else {
            guard waiters[sessionID, default: []].count < Self.maximumWaitersPerSession else {
                throw TerminalTransportSerializerError.queueFull
            }
            return try await withCheckedThrowingContinuation { continuation in
                waiters[sessionID, default: []].append(
                    Waiter(ownerID: ownerID, continuation: continuation)
                )
            }
        }
        holders[sessionID] = lease
        return lease
    }

    private func timeoutWaiter(sessionID: String, ownerID: String) {
        guard let index = waiters[sessionID]?.firstIndex(where: { $0.ownerID == ownerID }) else {
            return
        }
        let waiter = waiters[sessionID]!.remove(at: index)
        if waiters[sessionID]?.isEmpty == true { waiters[sessionID] = nil }
        waiter.continuation.resume(throwing: TerminalTransportSerializerError.acquisitionTimedOut)
    }

    private func cancelWaiter(sessionID: String, ownerID: String) {
        guard let index = waiters[sessionID]?.firstIndex(where: { $0.ownerID == ownerID }) else {
            return
        }
        let waiter = waiters[sessionID]!.remove(at: index)
        if waiters[sessionID]?.isEmpty == true { waiters[sessionID] = nil }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func advance(sessionID: String) {
        guard holders[sessionID] != nil else { return }
        guard var queued = waiters[sessionID], !queued.isEmpty else {
            holders[sessionID] = nil
            waiters[sessionID] = nil
            return
        }
        let next = queued.removeFirst()
        waiters[sessionID] = queued.isEmpty ? nil : queued
        let lease = TerminalTransportLease(sessionID: sessionID, ownerID: next.ownerID)
        holders[sessionID] = lease
        next.continuation.resume(returning: lease)
    }

    private func boundedAcquisitionTimeout(_ requested: TimeInterval) -> TimeInterval {
        // ponytail: keep acquisition and operation deadlines finite. If a
        // caller needs a longer provider command, it must also prove that the
        // underlying process can be terminated before increasing this bound.
        max(0.001, min(requested > 0 ? requested : Self.defaultAcquisitionTimeout, 120))
    }

    private func boundedOperationTimeout(_ requested: TimeInterval) -> TimeInterval {
        max(0.001, min(requested > 0 ? requested : Self.defaultOperationTimeout, 120))
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        UInt64(max(1, seconds * 1_000_000_000))
    }
}

private enum OperationRaceEvent<Value: Sendable> {
    case success(Value)
    case failure(Error)
    case timedOut
    case cancelled
}

private actor OperationRace<Value: Sendable> {
    private var event: OperationRaceEvent<Value>?
    private var continuation: CheckedContinuation<OperationRaceEvent<Value>, Never>?

    func finish(_ event: OperationRaceEvent<Value>) {
        guard self.event == nil else { return }
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: event)
        } else {
            self.event = event
        }
    }

    func wait() async -> OperationRaceEvent<Value> {
        if let event { return event }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
