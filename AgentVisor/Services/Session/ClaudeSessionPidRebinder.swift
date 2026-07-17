//
//  ClaudeSessionPidRebinder.swift
//  AgentVisor
//
//  Locates a *new* live `claude` PID for a session whose previously-
//  bound PID has died. Without this, the dead-PID sweeper in
//  `SessionStore.pruneDeadSessions` would mark `claude --resume <name>`
//  reattachments as `.ended` even though the user's CLI is alive and
//  ready for input.
//
//  The matcher walks `ps`'s full-argv output (no `comm`, which
//  truncates at 16 chars and would lose `--resume <name>`) and
//  matches on:
//    - `--session-id <sessionId>`         — exact id present in argv
//    - `--resume <sessionId>` / `<name>`  — resume-style attach
//
//  When both shapes are present we prefer the `--session-id` match
//  (UUID is unambiguous) over the `--resume <name>` match (a name
//  could theoretically collide across projects).
//
//  Performance: one `ps -A -ww -o pid,command` per call. Argv
//  output for a typical machine fits in ~50 KB; line scanning is
//  microseconds. The prune loop runs every ~3s and only invokes
//  this for sessions that just-dead, not all sessions.
//

import Foundation
import AgentVisorCore

enum ClaudeSessionPidRebinder {
    /// Returns a validated live Claude attachment, or nil if no
    /// rebind candidate exists. Excludes the previously-known dead
    /// PID so a stale entry can't accidentally re-match.
    ///
    /// - Parameters:
    ///   - sessionId: The session UUID. Matched against
    ///     `--session-id <sessionId>` in argv.
    ///   - sessionName: The custom-title name, if the user named
    ///     the session. Matched against `--resume <name>` (or
    ///     `--resume=<name>`).
    ///   - excludePid: PID to ignore even if it's listed (typically
    ///     the previously-bound, now-dead PID — defensive).
    nonisolated static func findLiveAttachment(
        sessionId: String,
        sessionName: String?,
        excludePid: Int? = nil
    ) -> ClaudeSessionReattachment? {
        // Authoritative path: walk `~/.claude/sessions/<pid>.json`
        // files. Claude Code writes one of these for every live
        // interactive session and stamps the sessionId inside.
        // This bypasses argv parsing entirely and works whether
        // the user invoked `claude --resume <name>`,
        // `claude --resume <id>`, or `claude --session-id <id>`.
        if let attachment = findViaSessionFiles(
            sessionId: sessionId,
            excludePid: excludePid
        ) {
            return attachment
        }

        // Fallback: scan `ps` for `--resume`/`--session-id` argv.
        // Useful when the per-PID json file is stale or missing
        // (e.g. user is mid-startup and hasn't written it yet).
        return findViaProcessList(
            sessionId: sessionId,
            sessionName: sessionName,
            excludePid: excludePid
        )
    }

    /// Authoritative lookup: search `~/.claude/sessions/*.json` for a
    /// file whose `sessionId` matches and whose `pid` is alive. Robust
    /// to all `claude` invocation shapes (`--resume <name>`,
    /// `--session-id <id>`, etc.) because the per-PID json is written
    /// by Claude Code itself.
    nonisolated private static func findViaSessionFiles(
        sessionId: String,
        excludePid: Int?
    ) -> ClaudeSessionReattachment? {
        let dir = NSHomeDirectory() + "/.claude/sessions"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return nil
        }

        let candidates = entries.compactMap { entry -> (Int, [String: Any])? in
            guard entry.hasSuffix(".json") else { return nil }
            let pidString = String(entry.dropLast(".json".count))
            guard let pid = Int(pidString) else { return nil }
            let path = "\(dir)/\(entry)"
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["sessionId"] as? String == sessionId
            else { return nil }
            return (pid, json)
        }.sorted { $0.0 > $1.0 }

        for (pid, metadata) in candidates {
            if let attachment = makeAttachment(
                pid: pid,
                matchedSessionId: metadata["sessionId"] as? String,
                metadata: metadata,
                command: nil,
                requestedSessionId: sessionId,
                excludePid: excludePid
            ) {
                return attachment
            }
        }
        return nil
    }

    /// Argv-based fallback. See `findLiveAttachment` for what shapes
    /// are matched.
    nonisolated private static func findViaProcessList(
        sessionId: String,
        sessionName: String?,
        excludePid: Int?
    ) -> ClaudeSessionReattachment? {
        guard let output = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps",
            arguments: ["-A", "-ww", "-o", "pid=,command="]
        ) else {
            return nil
        }

        var bySessionId: (pid: Int, command: String)?
        var byResume: (pid: Int, command: String)?

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let firstSpace = trimmed.firstIndex(of: " ") else { continue }
            let pidPart = String(trimmed[..<firstSpace])
            let cmd = String(trimmed[trimmed.index(after: firstSpace)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int(pidPart) else { continue }
            if let excl = excludePid, pid == excl { continue }

            guard ClaudeSessionReattachmentPolicy.isClaudeCLI(command: cmd) else { continue }
            if cmd.contains("--input-format stream-json") { continue }

            if cmd.contains("--session-id \(sessionId)")
                || cmd.contains("--session-id=\(sessionId)") {
                bySessionId = (pid, cmd)
                continue
            }

            if let name = sessionName, !name.isEmpty {
                if cmd.contains("--resume \(name)")
                    || cmd.contains("--resume=\(name)") {
                    byResume = (pid, cmd)
                    continue
                }
            }

            if cmd.contains("--resume \(sessionId)")
                || cmd.contains("--resume=\(sessionId)") {
                byResume = (pid, cmd)
            }
        }

        for match in [bySessionId, byResume].compactMap({ $0 }) {
            if let attachment = makeAttachment(
                pid: match.pid,
                matchedSessionId: sessionId,
                metadata: readMetadata(pid: match.pid),
                command: match.command,
                requestedSessionId: sessionId,
                excludePid: excludePid
            ) {
                return attachment
            }
        }
        return nil
    }

    nonisolated private static func makeAttachment(
        pid: Int,
        matchedSessionId: String?,
        metadata: [String: Any]?,
        command: String?,
        requestedSessionId: String,
        excludePid: Int?
    ) -> ClaudeSessionReattachment? {
        let tree = ProcessTreeBuilder.shared.buildTree()
        let tty = tree[pid]?.tty.flatMap(TTYNormalizer.normalize)
        let host = TerminalHostDetector.detect(
            pid: pid_t(pid),
            reader: LiveProcessInfoReader.shared
        )
        let candidate = ClaudeSessionReattachmentCandidate(
            pid: pid,
            matchedSessionId: matchedSessionId,
            processCommand: command ?? processCommand(pid: pid) ?? "",
            isAlive: kill(Int32(pid), 0) == 0,
            tty: tty,
            terminalHost: host == .unknown ? nil : host,
            metadataStatus: metadata?["status"] as? String,
            sessionName: metadata?["name"] as? String,
            isInTmux: ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        )
        return ClaudeSessionReattachmentPolicy.attachment(
            requestedSessionId: requestedSessionId,
            excludedPid: excludePid,
            candidate: candidate
        )
    }

    nonisolated private static func readMetadata(pid: Int) -> [String: Any]? {
        let path = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated private static func processCommand(pid: Int) -> String? {
        ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps",
            arguments: ["-ww", "-p", String(pid), "-o", "command="]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
