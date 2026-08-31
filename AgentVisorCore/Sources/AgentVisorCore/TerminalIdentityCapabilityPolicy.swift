import Foundation

/// The exact identity used to cache a terminal capability observation.
///
/// A session id alone is not enough: a provider process can restart while
/// retaining its visible session id.  The UI cache therefore keys every
/// observation by the complete process/terminal identity and never reuses an
/// older result for a new target.
public struct TerminalIdentityCapabilityKey: Equatable, Hashable, Sendable {
    public let sessionID: String
    public let generationID: String
    public let pid: Int?
    public let processStartToken: String?
    public let tty: String?
    public let terminalHost: TerminalHost?

    public init(
        sessionID: String,
        generationID: String,
        pid: Int?,
        processStartToken: String?,
        tty: String?,
        terminalHost: TerminalHost?
    ) {
        self.sessionID = sessionID
        self.generationID = generationID
        self.pid = pid
        self.processStartToken = processStartToken
        self.tty = tty.map(TerminalProcessIdentity.normalizeTTY)
        self.terminalHost = terminalHost
    }
}

public enum TerminalIdentityCapabilityStatus: Equatable, Sendable {
    case loading
    case verified
    case unverified
}

/// Immutable UI state for one cached identity observation.  Loading and
/// unverified are both fail-closed: callers must not advertise Stop or start
/// an approval fallback until the exact identity has been verified.
public struct TerminalIdentityCapability: Equatable, Sendable {
    public let key: TerminalIdentityCapabilityKey
    public let status: TerminalIdentityCapabilityStatus
    public let reason: String?

    public init(
        key: TerminalIdentityCapabilityKey,
        status: TerminalIdentityCapabilityStatus,
        reason: String? = nil
    ) {
        self.key = key
        self.status = status
        self.reason = reason
    }

    public var isVerified: Bool {
        status == .verified
    }

    public var isLoading: Bool {
        status == .loading
    }

    public var accessibilityLabel: String {
        switch status {
        case .loading:
            return reason ?? "Verifying terminal target before enabling stopping"
        case .verified:
            return "Terminal target verified"
        case .unverified:
            return reason ?? "Terminal target could not be verified"
        }
    }

    public static func loading(for key: TerminalIdentityCapabilityKey) -> Self {
        Self(
            key: key,
            status: .loading,
            reason: "Stopping is unavailable while the terminal target is being verified."
        )
    }

    public static func resolved(
        for key: TerminalIdentityCapabilityKey,
        isVerified: Bool
    ) -> Self {
        if isVerified {
            return Self(key: key, status: .verified)
        }
        return Self(
            key: key,
            status: .unverified,
            reason: "Stopping is unavailable because the terminal target could not be verified."
        )
    }

    /// Applies an asynchronous result only when it belongs to this exact
    /// request key. A stale completion returns nil and must not mutate UI
    /// state for a newer process identity.
    public func applying(
        isVerified: Bool,
        for resultKey: TerminalIdentityCapabilityKey
    ) -> Self? {
        guard key == resultKey else { return nil }
        return Self.resolved(for: key, isVerified: isVerified)
    }
}

public enum TerminalIdentityCapabilityPolicy {
    public static func key(
        session: SessionState,
        generationID: String
    ) -> TerminalIdentityCapabilityKey {
        TerminalIdentityCapabilityKey(
            sessionID: session.sessionId,
            generationID: generationID,
            pid: session.pid,
            processStartToken: session.processStartToken,
            tty: session.tty,
            terminalHost: session.terminalHost
        )
    }
}
