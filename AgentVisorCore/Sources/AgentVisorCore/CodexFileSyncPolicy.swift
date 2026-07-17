import Foundation

public enum CodexFileSyncMode: Equatable, Sendable {
    case metadataOnly
    case fullReplay
}

public enum CodexFileSyncPolicy {
    public static func mode(
        isAgentVisorOwned: Bool,
        hasRenderedChatItems: Bool
    ) -> CodexFileSyncMode {
        if isAgentVisorOwned || hasRenderedChatItems {
            return .fullReplay
        }
        return .metadataOnly
    }
}
