/// Detects Ready entries using durable session identity, independent of PID/TTY churn.
public struct ReadySessionEpisodeTracker: Sendable {
    private var currentReadySessionIDs: Set<String> = []

    public init() {}

    public mutating func update(readySessionIDs: Set<String>) -> Set<String> {
        let newlyReadySessionIDs = readySessionIDs.subtracting(currentReadySessionIDs)
        currentReadySessionIDs = readySessionIDs
        return newlyReadySessionIDs
    }
}
