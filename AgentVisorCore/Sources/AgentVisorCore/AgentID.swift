import Foundation

/// Identity of an AI coding agent that agent-visor can host. The hook
/// scripts stamp incoming events with the agent id so a single socket
/// can multiplex across multiple agents (Anthropic claude-code,
/// Augment's Auggie, OpenAI's Codex, Cursor's `cursor-agent`).
///
/// The raw value is what appears on the wire. Keep it lowercase, short,
/// and stable: changing a raw value is a wire-format break.
public enum AgentID: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude"
    case auggie
    case codex
    /// Cursor's standalone `cursor-agent` CLI. Read-only support
    /// (no hook seam exists upstream): we tail the JSONL transcript
    /// at `~/.cursor/projects/<projectKey>/agent-transcripts/<id>/<id>.jsonl`
    /// and surface chat history without intercepting tool calls.
    case cursor
}
