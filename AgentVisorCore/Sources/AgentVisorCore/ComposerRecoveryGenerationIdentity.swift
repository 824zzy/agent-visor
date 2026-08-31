import Foundation

/// The provider identity observed by the authoritative SessionStore snapshot.
///
/// A visible session ID is not sufficient ownership for composer recovery: a
/// resumed process may reuse it while its PID, start token, TTY, or host has
/// changed.  The app-level recovery service compares this value at each
/// authoritative refresh and advances the provider generation only when the
/// replacement is proven.  Missing fields are treated as an observation gap,
/// not as evidence that the process changed.
public struct ComposerRecoveryGenerationIdentity: Equatable, Sendable {
    public let pid: Int?
    public let processStartToken: String?
    public let tty: String?
    public let terminalHost: TerminalHost?
    public let agentID: AgentID
    public let origin: SessionOrigin

    public init(
        pid: Int?,
        processStartToken: String?,
        tty: String?,
        terminalHost: TerminalHost?,
        agentID: AgentID,
        origin: SessionOrigin
    ) {
        self.pid = pid
        self.processStartToken = processStartToken
        self.tty = tty.map(TerminalProcessIdentity.normalizeTTY)
        self.terminalHost = terminalHost
        self.agentID = agentID
        self.origin = origin
    }

    /// Convenience constructor used by authoritative app snapshots.
    public init(session: SessionState) {
        self.init(
            pid: session.pid,
            processStartToken: session.processStartToken,
            tty: session.tty,
            terminalHost: session.terminalHost,
            agentID: session.agentID,
            origin: session.origin
        )
    }

    /// Whether `comparedTo` proves that this is a new provider generation.
    ///
    /// The receiver is the prior observation and the argument is the latest
    /// observation.  We compare only values present on both sides so a
    /// transient discovery gap cannot retire valid recovery content.  Host
    /// `.unknown` is also non-authoritative until a known route is observed.
    public func requiresReplacement(comparedTo latest: Self) -> Bool {
        guard agentID == latest.agentID, origin == latest.origin else {
            return true
        }
        if let pid, let latestPID = latest.pid, pid != latestPID {
            return true
        }
        if let processStartToken,
           let latestToken = latest.processStartToken,
           processStartToken != latestToken {
            return true
        }
        if let tty, let latestTTY = latest.tty, tty != latestTTY {
            return true
        }
        if let terminalHost,
           let latestHost = latest.terminalHost,
           terminalHost != .unknown,
           latestHost != .unknown,
           terminalHost != latestHost {
            return true
        }
        return false
    }
}
