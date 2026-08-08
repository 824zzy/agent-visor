//
//  ZedHostedIdentityPolicy.swift
//  AgentVisorCore
//
//  Who names a Zed-hosted session.
//
//  Zed runs claude-code / codex / pi as ACP children. Each child keeps
//  writing its own transcript AND its own name store, so two sources
//  compete for the pill title:
//
//    * the agent's derived name — e.g. claude-code writes
//      `~/.claude/sessions/<pid>.json` with `{"name":"codes-92",
//      "nameSource":"derived"}` for `entrypoint: sdk-ts` children;
//    * Zed's thread title — what the user actually sees and renames in
//      Zed's sidebar ("hi", or an explicit `title_override`).
//
//  Observed before this policy existed: a Zed thread titled "hi" showed
//  up as the pill `codes-92`. Two Zed threads in one worktree were also
//  indistinguishable, because both fell back to the project name.
//
//  Rule: for `.zed`-hosted sessions the HOST owns identity. This is a
//  host-driven rule (like `deadProcessAction` for Zed), not an
//  agent-driven one — it must hold for every agent Zed can host, so it
//  lives here rather than inside any one provider.
//

import Foundation

public enum ZedHostedIdentityPolicy {
    /// True when an agent-resolved name (claude's `<pid>.json`, codex's
    /// sqlite index) must not be written onto the session, because the
    /// host's thread title is the name the user recognizes.
    ///
    /// Suppression is deliberately unconditional for Zed rather than
    /// "only when a Zed title exists": a derived name like `codes-92` is
    /// worse than the project-name fallback even while Zed is still
    /// generating the thread title.
    public static func suppressesAgentResolvedName(host: TerminalHost?) -> Bool {
        host == .zed
    }

    /// Session name for a Zed-hosted session.
    ///
    /// Priority: Zed's thread title → an existing non-placeholder name →
    /// the transcript title. Returning nil means "no session name", which
    /// lets the pill fall back to the project name.
    public static func sessionName(
        zedTitle: String?,
        currentName: String?,
        transcriptTitle: String? = nil
    ) -> String? {
        for candidate in [zedTitle, currentName, transcriptTitle] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Whether applying `resolved` would actually change the stored name.
    /// Keeps callers from publishing no-op session mutations on every
    /// 3-second refresh tick.
    public static func shouldApply(resolved: String?, currentName: String?) -> Bool {
        let normalizedResolved = resolved?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrent = currentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedResolved, !normalizedResolved.isEmpty else { return false }
        return normalizedResolved != normalizedCurrent
    }
}
