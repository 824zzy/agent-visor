import Foundation

/// Extracts the user-set thread title from a Claude JSONL transcript.
///
/// **Where the rows come from.** Zed's `claude-acp` adapter wraps the
/// Claude CLI but ALSO writes auxiliary rows of shape
///   `{"type":"custom-title","customTitle":"<name>","sessionId":"..."}`
/// into the same JSONL file (`~/.claude/projects/<encoded>/<id>.jsonl`).
/// Those rows aren't part of the CLI's normal transcript schema; the
/// CLI ignores them on read. agent-visor's parser used to ignore them
/// too, which is why Zed-hosted Claude sessions surfaced as their UUID
/// prefix instead of "misc2", "draft 1", etc.
///
/// **Last-wins.** A user can rename the thread mid-conversation; Zed
/// appends a new `custom-title` row each time. We return the last
/// non-empty one so the sidebar matches Zed's own sidebar.
///
/// **Pure logic.** The caller passes raw JSONL text. No I/O here so
/// the rule can be unit-tested without touching the filesystem.
public enum ClaudeCustomTitleExtractor {
    /// - Parameter jsonl: Raw JSONL transcript (one JSON object per
    ///   line). May contain malformed lines — those are skipped.
    /// - Returns: The most recent non-empty `customTitle` value,
    ///   trimmed of surrounding whitespace. Nil when no usable
    ///   `custom-title` row exists.
    public static func extractTitle(jsonl: String) -> String? {
        guard !jsonl.isEmpty else { return nil }

        var result: String?
        for line in jsonl.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" }) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "custom-title",
                  let raw = obj["customTitle"] as? String
            else { continue }

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result = trimmed
                // Keep scanning — we want the LAST match, not the first.
            }
        }
        return result
    }
}
