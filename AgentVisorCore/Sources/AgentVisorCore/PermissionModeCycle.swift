import Foundation

/// Predicts the next Claude Code permission mode after a Shift+Tab
/// cycle. agent-visor uses this to update the chip optimistically
/// before the JSONL `permission-mode` line lands.
///
/// `auto` is intentionally absent from forward predictions: it's
/// enterprise-gated (TRANSCRIPT_CLASSIFIER feature flag) and the hook
/// protocol carries no signal we can read to tell whether the current
/// backend supports it. Predicting `auto` after `plan` mispredicts on
/// Bedrock / Vertex / standard Anthropic API, where the TUI actually
/// lands on `default`. Enterprise users who do have auto see a brief
/// (~1.5s) `default` chip until the AX probe reads the `⏵⏵ auto`
/// chevron from the terminal and reconciles. We accept that small
/// transient over a permanent wrong state on every other backend.
public enum PermissionModeCycle {
    public static func next(after current: String) -> String? {
        switch current {
        case "default":           return "acceptEdits"
        case "acceptEdits":       return "plan"
        case "plan":              return "default"
        case "auto":              return "default"
        case "bypassPermissions": return "default"
        default:                  return nil
        }
    }
}
