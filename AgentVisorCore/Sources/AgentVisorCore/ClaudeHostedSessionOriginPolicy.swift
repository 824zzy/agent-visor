import Foundation

public enum ClaudeHostedSessionOrigin: Equatable, Sendable {
    case terminal
    case cursorObserved
    case observed
}

public enum ClaudeHostedSessionOriginPolicy {
    public static func origin(
        hasTTY: Bool,
        terminalHost: TerminalHost?
    ) -> ClaudeHostedSessionOrigin {
        if hasTTY { return .terminal }
        return terminalHost == .cursor ? .cursorObserved : .observed
    }
}
