import Foundation

public enum ClaudeCodeSessionMetadataPolicy {
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
