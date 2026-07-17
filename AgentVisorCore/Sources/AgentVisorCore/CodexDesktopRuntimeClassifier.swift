public enum CodexDesktopRuntime: Equatable, Sendable {
    case notRunning
    case privateRuntime
    case sharedRuntime
    case starting
    case unknown
}

public struct CodexDesktopRuntimeEvidence: Equatable, Sendable {
    public let desktopRunning: Bool
    public let launchedAfterActivation: Bool
    public let privateAppServerChildPresent: Bool
    public let sharedRuntimeSocketPresent: Bool
    public let sharedRuntimeHealthy: Bool
    public let agentVisorHandshake: Bool

    public init(
        desktopRunning: Bool,
        launchedAfterActivation: Bool,
        privateAppServerChildPresent: Bool,
        sharedRuntimeSocketPresent: Bool = false,
        sharedRuntimeHealthy: Bool,
        agentVisorHandshake: Bool
    ) {
        self.desktopRunning = desktopRunning
        self.launchedAfterActivation = launchedAfterActivation
        self.privateAppServerChildPresent = privateAppServerChildPresent
        self.sharedRuntimeSocketPresent = sharedRuntimeSocketPresent
        self.sharedRuntimeHealthy = sharedRuntimeHealthy
        self.agentVisorHandshake = agentVisorHandshake
    }
}

public enum CodexDesktopRuntimeClassifier {
    public static func classify(
        _ evidence: CodexDesktopRuntimeEvidence
    ) -> CodexDesktopRuntime {
        guard evidence.desktopRunning else { return .notRunning }
        if evidence.privateAppServerChildPresent { return .privateRuntime }
        if evidence.launchedAfterActivation, evidence.sharedRuntimeSocketPresent {
            return evidence.agentVisorHandshake ? .sharedRuntime : .starting
        }
        if evidence.launchedAfterActivation, evidence.sharedRuntimeHealthy {
            return .starting
        }
        return .unknown
    }
}
