import Foundation

public struct ClaudeSessionReattachmentCandidate: Equatable, Sendable {
    public let pid: Int
    public let matchedSessionId: String?
    public let processCommand: String
    public let isAlive: Bool
    public let tty: String?
    public let terminalHost: TerminalHost?
    public let metadataStatus: String?
    public let sessionName: String?
    public let isInTmux: Bool

    public init(
        pid: Int,
        matchedSessionId: String?,
        processCommand: String,
        isAlive: Bool,
        tty: String?,
        terminalHost: TerminalHost?,
        metadataStatus: String?,
        sessionName: String?,
        isInTmux: Bool
    ) {
        self.pid = pid
        self.matchedSessionId = matchedSessionId
        self.processCommand = processCommand
        self.isAlive = isAlive
        self.tty = tty
        self.terminalHost = terminalHost
        self.metadataStatus = metadataStatus
        self.sessionName = sessionName
        self.isInTmux = isInTmux
    }
}

public struct ClaudeSessionReattachment: Equatable, Sendable {
    public let pid: Int
    public let tty: String?
    public let terminalHost: TerminalHost?
    public let origin: ClaudeHostedSessionOrigin
    public let sessionName: String?
    public let isInTmux: Bool
    public let phase: HookSessionLifecyclePhase
}

public enum ClaudeSessionReattachmentPolicy {
    public static func attachment(
        requestedSessionId: String,
        excludedPid: Int?,
        candidate: ClaudeSessionReattachmentCandidate
    ) -> ClaudeSessionReattachment? {
        guard candidate.isAlive,
              candidate.pid != excludedPid,
              candidate.matchedSessionId == requestedSessionId,
              isClaudeCLI(command: candidate.processCommand),
              !ClaudeCodeSessionMetadataPolicy.isTerminalStatus(candidate.metadataStatus)
        else {
            return nil
        }

        return ClaudeSessionReattachment(
            pid: candidate.pid,
            tty: candidate.tty,
            terminalHost: candidate.terminalHost,
            origin: ClaudeHostedSessionOriginPolicy.origin(
                hasTTY: candidate.tty != nil,
                terminalHost: candidate.terminalHost
            ),
            sessionName: candidate.sessionName,
            isInTmux: candidate.isInTmux,
            phase: .idle
        )
    }

    public static func isClaudeCLI(command: String) -> Bool {
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let executable = normalized.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        if executable == "claude" || executable.hasSuffix("/claude") {
            return true
        }

        return normalized.contains("claude.app/contents/macos/claude")
            || normalized.contains("@anthropic-ai/claude-code/")
            || normalized.contains("/.local/share/claude/versions/")
    }
}
