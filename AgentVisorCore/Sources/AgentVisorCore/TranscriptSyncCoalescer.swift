public enum TranscriptSyncRequestDisposition: Equatable, Sendable {
    /// Start or reset the debounce for the latest pending request.
    case debounceLatest
    /// A run is active; replace its sole pending rerun without starting work.
    case coalescedIntoRunning
}

public enum TranscriptSyncCompletionDisposition: Equatable, Sendable {
    case idle
    case debounceLatest
}

/// Bounded state machine for transcript refresh requests.
///
/// It retains at most one running request and one replaceable pending request.
/// Scheduling and task cancellation remain at the app boundary; this value
/// owns only queue semantics so every provider signal cannot become another
/// expensive parser invocation.
public struct TranscriptSyncCoalescer<Request: Equatable & Sendable>: Sendable {
    private var running: Request?
    private var pending: Request?

    public init() {}

    public var isRunning: Bool { running != nil }

    @discardableResult
    public mutating func request(_ request: Request) -> TranscriptSyncRequestDisposition {
        pending = request
        return running == nil ? .debounceLatest : .coalescedIntoRunning
    }

    /// Moves the latest pending request into the running slot. Returns nil
    /// while another run is active or when cancellation removed the request.
    public mutating func beginPendingRun() -> Request? {
        guard running == nil, let pending else { return nil }
        self.pending = nil
        running = pending
        return pending
    }

    /// Completes the active run and reports whether one latest rerun remains.
    @discardableResult
    public mutating func completeRun() -> TranscriptSyncCompletionDisposition {
        running = nil
        return pending == nil ? .idle : .debounceLatest
    }

    /// Drops debounced work or an active run's pending rerun. The active run
    /// itself remains represented until its caller observes completion.
    public mutating func cancelPending() {
        pending = nil
    }
}
