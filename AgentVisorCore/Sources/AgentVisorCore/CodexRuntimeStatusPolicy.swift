import Foundation

public enum CodexRuntimePhase: Equatable, Sendable {
    case processing
    case waitingForApproval
    case waitingForInput
    case unavailable
}

public enum CodexRuntimeStatusPolicy {
    public static func phase(
        statusType: String,
        activeFlags: [String] = []
    ) -> CodexRuntimePhase {
        switch statusType {
        case "active":
            let needsUser = activeFlags.contains { flag in
                let normalized = flag.lowercased()
                return normalized.contains("approval") || normalized.contains("userinput")
            }
            return needsUser ? .waitingForApproval : .processing
        case "idle":
            return .waitingForInput
        default:
            return .unavailable
        }
    }
}
