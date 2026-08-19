import Foundation

/// Admission control for work that blocks the thread it runs on.
///
/// Reading a session's state means asking the machine: run `ps`, read a sqlite
/// file, ask an app whether it is running. Those calls hold their thread until
/// the answer arrives. Swift gives the app a small pool of worker threads, one
/// per core, and every `await` in the app waits for one of them. So a sweep that
/// fans out over two hundred sessions can hold every worker at once, and then
/// nothing else in the app runs: no hook event, no phase change, no click.
///
/// This gate hands out a fixed number of permits. A caller with no permit is a
/// suspended task, not a held thread, so waiting costs nothing. Permits are
/// handed out in the order they were asked for, so a sweep of many rows cannot
/// starve one click that arrived later.
///
/// The gate does not run the work and knows nothing about processes. It only
/// says how many may run at once, which is what makes it testable.
public actor BlockingWorkGate {
    /// How many blocking calls may run at once.
    ///
    /// Higher is not faster here. These calls spend their time waiting for a
    /// child process or a disk read, so a handful in flight already keeps the
    /// machine busy, and a bound is what stops a fan-out from becoming a storm.
    public static let defaultPermits = 4

    private let permits: Int
    private var inUse = 0
    private var waiting: [@Sendable () -> Void] = []

    public init(permits: Int = BlockingWorkGate.defaultPermits) {
        self.permits = max(1, permits)
    }

    /// How many permits are in use. For tests and for logging.
    public var busy: Int { inUse }

    /// How many callers are waiting for a permit. For tests and for logging.
    public var queued: Int { waiting.count }

    /// Wait until a permit is free. Returns as soon as one is.
    public func acquire() async {
        if inUse < permits {
            inUse += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append { continuation.resume() }
        }
    }

    /// Give a permit back. The oldest waiter takes it, so the order of arrival
    /// is the order of service.
    public func release() {
        guard !waiting.isEmpty else {
            inUse = max(0, inUse - 1)
            return
        }
        let resume = waiting.removeFirst()
        resume()
    }

    /// Run `body` while holding a permit.
    ///
    /// The permit comes back whether `body` returns or throws, so a failing read
    /// cannot leak a permit and shrink the gate for the rest of the run.
    public func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }
}
