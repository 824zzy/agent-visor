import Foundation

/// Encodes a working-directory path into the on-disk project directory
/// name that claude-code uses under `~/.claude/projects/<dir>/`. Must
/// stay byte-for-byte compatible with claude-code's own normalization:
/// any drift means we'd write to a different directory than the JSONL
/// transcripts actually live in.
///
/// This lives in `AgentVisorCore` so we can lock the rule in via
/// XCTest. Other agents (Auggie, Codex) get their own encoders when
/// their layout is verified upstream.
public enum ClaudeProjectPathEncoder {
    public static func projectDirName(forCwd cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
           .replacingOccurrences(of: ".", with: "-")
           .replacingOccurrences(of: "_", with: "-")
    }
}
