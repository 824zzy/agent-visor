public struct AgentBrandLogoSource: Equatable, Sendable {
    public let assetName: String
    public let runtimeBundleIdentifier: String?

    public init(assetName: String, runtimeBundleIdentifier: String? = nil) {
        self.assetName = assetName
        self.runtimeBundleIdentifier = runtimeBundleIdentifier
    }
}

public enum AgentBrandLogoSourcePolicy {
    public static func source(for agent: AgentID) -> AgentBrandLogoSource {
        switch agent {
        case .claudeCode:
            return AgentBrandLogoSource(
                assetName: "AgentClaude",
                runtimeBundleIdentifier: "com.anthropic.claudefordesktop"
            )
        case .auggie:
            return AgentBrandLogoSource(assetName: "AgentAuggie")
        case .codex:
            return AgentBrandLogoSource(
                assetName: "AgentCodex",
                runtimeBundleIdentifier: "com.openai.codex"
            )
        case .cursor:
            return AgentBrandLogoSource(
                assetName: "AgentCursor",
                runtimeBundleIdentifier: "com.todesktop.230313mzl4w4u92"
            )
        }
    }
}
