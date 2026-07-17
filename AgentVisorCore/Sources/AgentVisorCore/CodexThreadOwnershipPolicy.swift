import Foundation

public enum CodexThreadDrivability: Equatable, Sendable {
    case externalOwner
    case agentVisorAppServer
}

public enum CodexThreadOwnershipPolicy {
    public static func drivability(
        tty: String?,
        source _: String,
        isAgentVisorOwned: Bool
    ) -> CodexThreadDrivability {
        guard tty == nil, isAgentVisorOwned else {
            return .externalOwner
        }
        return .agentVisorAppServer
    }
}
