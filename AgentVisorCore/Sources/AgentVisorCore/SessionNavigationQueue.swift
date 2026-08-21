import Foundation

/// Runs session navigation away from the main thread without allowing stale
/// clicks to compete for app focus.
public final class SessionNavigationQueue: @unchecked Sendable {
    private let queue: OperationQueue
    private let submitLock = NSLock()
    private let navigate: @Sendable (SessionState) -> Void

    public init(navigate: @escaping @Sendable (SessionState) -> Void) {
        self.navigate = navigate
        queue = OperationQueue()
        queue.name = "com.824zzy.agentvisor.session-navigation"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
    }

    public func submit(_ session: SessionState) {
        submitLock.lock()
        queue.cancelAllOperations()
        queue.addOperation { [navigate] in
            navigate(session)
        }
        submitLock.unlock()
    }
}
