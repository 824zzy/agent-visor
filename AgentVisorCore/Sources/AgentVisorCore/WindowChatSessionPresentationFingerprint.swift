import Foundation

public struct WindowChatSessionPresentationFingerprint: Equatable, Sendable {
    public let displayTitle: String
    public let projectName: String
    public let phaseTag: String
    public let permissionMode: String?
    public let modelName: String?
    public let contextWindowTokens: Int
    public let contextTokenBucket: Int
    public let effortLevel: String?
    public let cwd: String
    public let agentID: AgentID
    public let originTag: String
    public let codexControlCapability: CodexControlCapability
    public let tty: String?
    public let terminalHost: TerminalHost?

    public init(
        displayTitle: String,
        projectName: String,
        phaseTag: String,
        permissionMode: String?,
        modelName: String?,
        contextWindowTokens: Int,
        contextTokenBucket: Int,
        effortLevel: String?,
        cwd: String,
        agentID: AgentID,
        originTag: String,
        codexControlCapability: CodexControlCapability,
        tty: String?,
        terminalHost: TerminalHost?
    ) {
        self.displayTitle = displayTitle
        self.projectName = projectName
        self.phaseTag = phaseTag
        self.permissionMode = permissionMode
        self.modelName = modelName
        self.contextWindowTokens = contextWindowTokens
        self.contextTokenBucket = contextTokenBucket
        self.effortLevel = effortLevel
        self.cwd = cwd
        self.agentID = agentID
        self.originTag = originTag
        self.codexControlCapability = codexControlCapability
        self.tty = tty
        self.terminalHost = terminalHost
    }
}
