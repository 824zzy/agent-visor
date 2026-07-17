import Foundation

/// Picks the workspace folder to hand to LaunchServices when bringing a
/// Cursor session to the foreground. Pure logic so the routing rule can
/// be unit-tested without touching `~/.claude/ide/` or running Cursor.
///
/// Rationale:
///   - Cursor IDE Agents Window and cursor-agent CLI sessions
///     (`agentID == .cursor`) have NO `~/.claude/ide/<port>.lock`
///     entry — those locks belong to the claude-code Cursor extension.
///     For these sessions the session's own `cwd` is the canonical
///     workspace folder; LaunchServices can use it directly to focus
///     or open the matching workspace window.
///   - claude-code sessions running INSIDE Cursor (`agentID == .claudeCode`)
///     should still resolve through the lock file: each lock exposes
///     one extension host's `workspaceFolders`, and matching the
///     longest folder that's a prefix of `cwd` picks the host that
///     actually owns the session — which is the host that can route
///     a `cursor://anthropic.claude-code/open` URL to the correct
///     existing chat tab.
///   - Other agents return nil so callers fall back to whatever
///     non-Cursor focus path they already use.
public enum CursorWorkspaceResolver {
    /// - Parameters:
    ///   - sessionCwd: The session's working directory.
    ///   - agentID: Which agent is hosting the session.
    ///   - candidateFolders: All `workspaceFolders` aggregated across
    ///     `~/.claude/ide/*.lock` files (claude-code path only). Pass
    ///     an empty array for cursor-agent sessions — they don't read
    ///     these.
    /// - Returns: The workspace folder to hand to LaunchServices, or
    ///   nil when the caller should use its non-LaunchServices
    ///   fallback.
    public static func resolveWorkspaceFolder(
        sessionCwd: String,
        agentID: AgentID,
        candidateFolders: [String]
    ) -> String? {
        switch agentID {
        case .cursor:
            // The session's cwd IS its workspace folder. We don't need
            // a lock file because Cursor's Apple Event handler will
            // open the workspace if it's not yet open and focus the
            // matching window if it is.
            return sessionCwd
        case .claudeCode:
            return longestPrefixMatch(sessionCwd: sessionCwd, candidateFolders: candidateFolders)
        case .codex, .auggie:
            return nil
        }
    }

    /// Pick the candidate that is `sessionCwd` or its ancestor
    /// (boundary at `/`), returning the longest one. Boundary check
    /// prevents `/foo` from matching a session in `/foobar`.
    private static func longestPrefixMatch(
        sessionCwd: String,
        candidateFolders: [String]
    ) -> String? {
        var best: (folder: String, length: Int)?
        for folder in candidateFolders {
            let matches = sessionCwd == folder || sessionCwd.hasPrefix(folder + "/")
            guard matches else { continue }
            if best == nil || folder.count > best!.length {
                best = (folder, folder.count)
            }
        }
        return best?.folder
    }
}
