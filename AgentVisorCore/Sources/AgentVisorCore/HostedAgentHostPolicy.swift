//
//  HostedAgentHostPolicy.swift
//  AgentVisorCore
//
//  Decides the owning terminal host for a session whose agent can run
//  either as a GUI thread or as an editor's ACP child.
//
//  The bug this fixes: codex host attribution used to short-circuit on
//  "no tty ⇒ Codex.app" BEFORE the process-tree walk. A `codex-acp`
//  child of Zed has no tty either, so every Zed-hosted codex thread was
//  labeled `.codexApp`; clicking its pill ran Codex Desktop's
//  open-thread path and surfaced the thread in the wrong application.
//
//  Correct order: trust the process tree first (it is direct evidence of
//  the owning app), and keep "no tty ⇒ Codex.app" only as the fallback
//  for GUI threads, where there is no live child process to walk.
//

import Foundation

public enum HostedAgentHostPolicy {
    /// - `detectedHost`: result of the parent-process walk; nil when the
    ///   session has no process-backed pid, `.unknown` when the walk found
    ///   no recognized app.
    /// - `zedHostsSession`: Zed's own thread list claims this session id.
    ///   This is the strongest evidence there is — stronger than a process
    ///   walk that can miss Zed's pooled/stdio children, and it overrides the
    ///   Codex.app fallback for a codex-acp thread that also left a `~/.codex`
    ///   rollout behind. Without this, such a thread was attributed to Codex
    ///   Desktop and its pill click opened the wrong app.
    public static func resolve(
        agentID: AgentID,
        tty: String?,
        detectedHost: TerminalHost?,
        zedHostsSession: Bool = false
    ) -> TerminalHost? {
        if zedHostsSession {
            return .zed
        }
        if let detectedHost, detectedHost != .unknown {
            return detectedHost
        }
        if agentID == .codex, tty == nil {
            return .codexApp
        }
        return detectedHost
    }
}
