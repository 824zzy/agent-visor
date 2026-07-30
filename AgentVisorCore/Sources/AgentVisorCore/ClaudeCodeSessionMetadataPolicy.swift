import Foundation

public enum ClaudeCodeSessionMetadataActivity: Equatable, Sendable {
    case working
    case idle
    case terminal
    case unknown
}

public enum ClaudeCodeSessionMetadataPolicy {
    public static func activity(for status: String?) -> ClaudeCodeSessionMetadataActivity {
        let normalizedStatus = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedStatus, !normalizedStatus.isEmpty else {
            return .unknown
        }
        if normalizedStatus == "busy" {
            return .working
        }
        if normalizedStatus == "idle" {
            return .idle
        }
        if isTerminalStatus(normalizedStatus) {
            return .terminal
        }
        return .unknown
    }

    public static func isTerminalStatus(_ status: String?) -> Bool {
        let normalizedStatus = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedStatus else { return false }
        return ["ended", "exited", "closed", "deactivated", "inactive", "stopped", "terminated"].contains(normalizedStatus)
    }

    public static func shouldDiscover(
        kind: String,
        entrypoint: String,
        cwd: String,
        status: String? = nil
    ) -> Bool {
        guard kind == "interactive" else { return false }
        if cwd.contains(".claude-mem") || cwd.contains("observer-sessions") {
            return false
        }

        if isTerminalStatus(status) {
            return false
        }

        let normalizedEntrypoint = entrypoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedEntrypoint.hasPrefix("sdk") {
            return false
        }

        return true
    }
}

/// Claude Desktop keeps one long-lived worker process for a conversation, and
/// some desktop builds omit the busy/idle field or miss a completion hook.
/// In that narrow case the transcript may recover completion, but it must
/// never override newer hook evidence or an authoritative metadata status.
public enum ClaudeDesktopTranscriptFallbackPolicy {
    public static func isEligible(
        terminalHost: TerminalHost?,
        hasTTY: Bool
    ) -> Bool {
        terminalHost == .claudeDesktop && !hasTTY
    }

    public static func shouldApply(
        metadataActivity: ClaudeCodeSessionMetadataActivity,
        transcriptModifiedAt: TimeInterval,
        hookObservedAt: TimeInterval?
    ) -> Bool {
        guard metadataActivity == .unknown else { return false }
        guard let hookObservedAt else { return true }
        return transcriptModifiedAt >= hookObservedAt
    }
}
