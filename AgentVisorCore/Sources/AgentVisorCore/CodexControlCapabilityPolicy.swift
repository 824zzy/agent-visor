import Foundation

public enum CodexControlCapability: String, Codable, Equatable, Sendable {
    case observed
    case connected
    case managed
}

public struct CodexSharedRuntimeEvidence: Equatable, Sendable {
    public let threadId: String
    public let transportConnected: Bool
    public let handshakeComplete: Bool
    public let versionCompatible: Bool
    public let subscriptionConfirmed: Bool

    public init(
        threadId: String,
        transportConnected: Bool,
        handshakeComplete: Bool,
        versionCompatible: Bool,
        subscriptionConfirmed: Bool
    ) {
        self.threadId = threadId
        self.transportConnected = transportConnected
        self.handshakeComplete = handshakeComplete
        self.versionCompatible = versionCompatible
        self.subscriptionConfirmed = subscriptionConfirmed
    }
}

public enum CodexControlCapabilityPolicy {
    public static func capability(
        threadId: String,
        isAgentVisorManaged: Bool,
        sharedRuntimeEvidence: CodexSharedRuntimeEvidence?
    ) -> CodexControlCapability {
        if isAgentVisorManaged {
            return .managed
        }
        guard let evidence = sharedRuntimeEvidence,
              evidence.threadId == threadId,
              evidence.transportConnected,
              evidence.handshakeComplete,
              evidence.versionCompatible,
              evidence.subscriptionConfirmed else {
            return .observed
        }
        return .connected
    }
}
