public enum PiConnectionState: Equatable, Sendable {
    case notDetected
    case observing
    case connected
}

public enum PiConnectionStatePolicy {
    public static func state(isDetected: Bool, hasHeartbeat: Bool) -> PiConnectionState {
        guard isDetected else { return .notDetected }
        return hasHeartbeat ? .connected : .observing
    }
}
