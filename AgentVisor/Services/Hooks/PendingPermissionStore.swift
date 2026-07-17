//
//  PendingPermissionStore.swift
//  AgentVisor
//
//  Persists `PermissionRequest` hook payloads as sidecar files so claude-
//  visor can recover an in-flight AskUserQuestion (and any other
//  permission-gated tool) across a process restart.
//
//  Why this is needed: claude-code buffers an assistant message's
//  thinking + tool_use blocks in process memory until the trailing tool
//  resolves. While a question is pending, *nothing* about it lands in
//  JSONL — agent-visor's only knowledge comes from the live hook
//  events (PreToolUse + PermissionRequest). Without a sidecar, a
//  restart loses that state entirely: the menubar pill drops back to
//  idle/green and the inline question form vanishes from chat.
//
//  Lifecycle:
//   - PermissionRequest arrives → HookSocketServer writes a sidecar.
//   - User responds via socket → HookSocketServer deletes the sidecar.
//   - Tool resolves out-of-band (e.g. user answered in TUI after a
//     agent-visor restart broke the socket) → SessionStore deletes
//     the sidecar when PostToolUse arrives.
//   - agent-visor relaunches → `replayOnStartup` reads each sidecar,
//     checks JSONL for a tool_result (skip + delete if present —
//     "stale, resolved during downtime"), otherwise re-fires the
//     PermissionRequest event into SessionStore as if it had just
//     come over the socket.
//

import Foundation
import AgentVisorCore
import os.log

enum PendingPermissionStore {
    nonisolated private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "PendingPermissions")

    /// Directory holding sidecars. Lives under Application Support so the
    /// OS doesn't reap it on logout/restart and it survives upgrades.
    nonisolated static func directory() -> URL {
        AppPaths.appSupportDirectory()
            .appendingPathComponent("pending-permissions")
    }

    /// Stable filename for `(sessionId, toolUseId)`. Both are
    /// already filesystem-safe (UUIDs / claude-code's `toolu_…`).
    nonisolated private static func fileURL(sessionId: String, toolUseId: String) -> URL {
        directory().appendingPathComponent("\(sessionId)-\(toolUseId).json")
    }

    /// Persist a PermissionRequest event as a sidecar so we can replay
    /// it after a restart. Idempotent — overwrites any existing file
    /// for the same `(sessionId, toolUseId)`.
    static func save(_ event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(event)
            let url = fileURL(sessionId: event.sessionId, toolUseId: toolUseId)
            // Atomic write via temp + replaceItemAt so a crash midway
            // doesn't leave a half-written file the replay would choke
            // on. Same pattern as ConversationParser's cache.
            let tempURL = url.appendingPathExtension("tmp")
            try? FileManager.default.removeItem(at: tempURL)
            try data.write(to: tempURL)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            logger.info("saved sidecar session=\(event.sessionId.prefix(8), privacy: .public) tool=\(toolUseId.prefix(12), privacy: .public)")
        } catch {
            logger.error("save sidecar failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove a sidecar. Called when the tool resolves through any
    /// channel — socket response, PostToolUse hook, or a stale-replay
    /// sweep on startup.
    nonisolated static func delete(sessionId: String, toolUseId: String) {
        let url = fileURL(sessionId: sessionId, toolUseId: toolUseId)
        if (try? FileManager.default.removeItem(at: url)) != nil {
            logger.info("deleted sidecar session=\(sessionId.prefix(8), privacy: .public) tool=\(toolUseId.prefix(12), privacy: .public)")
        }
    }

    /// All sidecars currently on disk, decoded back into HookEvents.
    /// Files that fail to decode (corrupt, schema-evolved) are dropped
    /// and unlinked.
    static func listAll() -> [HookEvent] {
        let dir = directory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        var events: [HookEvent] = []
        for url in entries where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let event = try decoder.decode(HookEvent.self, from: data)
                events.append(event)
            } catch {
                logger.error("drop corrupt sidecar \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        return events
    }

    /// Replay any sidecars left on disk from a prior run as synthetic
    /// `.hookReceived(PermissionRequest)` events into `SessionStore`.
    /// Call once after `bootstrapSessions` finishes so the synthesized
    /// session phase doesn't get clobbered by discovery.
    ///
    /// Staleness check: if `ConversationParser` reports the tool's
    /// tool_use_id in `completedToolIds`, the tool resolved during our
    /// downtime (e.g. user answered in the TUI after our socket died) —
    /// delete the sidecar and skip replay so we don't synthesize a
    /// phantom pending state.
    static func replayOnStartup() async {
        let events = listAll()
        guard !events.isEmpty else { return }
        logger.info("replayOnStartup: \(events.count, privacy: .public) sidecar(s)")

        for event in events {
            guard let toolUseId = event.toolUseId else {
                // save() requires toolUseId, so this only triggers on a
                // hand-edited or schema-skewed file. Drop it.
                logger.error("sidecar missing toolUseId: dropping")
                let url = directory().appendingPathComponent("\(event.sessionId)-.json")
                try? FileManager.default.removeItem(at: url)
                continue
            }

            // Hook events carry the process's CURRENT cwd, which
            // drifts after `cd` commands. claude-code's JSONL path is
            // keyed on the *launch* cwd. Prefer the session's
            // bootstrapped cwd (read from ~/.claude/sessions/<pid>.json
            // at discovery time) so path lookups don't silently fail
            // and return empty messages. Falls back to event.cwd if
            // the session isn't in store (sidecar from a session that
            // ended during downtime — still worth a best-effort try).
            let storeSession = await SessionStore.shared.getSession(id: event.sessionId)
            let resolvedCwd = storeSession?.cwd ?? event.cwd

            // Pre-warm the parser for this session, then check whether
            // a tool_result for our toolUseId has already landed in
            // JSONL. parseFullConversation is cache-aware so this is
            // a millisecond-scale op when the cache covers the file.
            _ = await ConversationParser.shared.parseFullConversation(
                sessionId: event.sessionId,
                cwd: resolvedCwd
            )
            let completed = await ConversationParser.shared.completedToolIds(
                for: event.sessionId
            )
            if completed.contains(toolUseId) {
                logger.info("stale sidecar (already resolved in JSONL): session=\(event.sessionId.prefix(8), privacy: .public) tool=\(toolUseId.prefix(12), privacy: .public)")
                delete(sessionId: event.sessionId, toolUseId: toolUseId)
                continue
            }

            // Belt-and-suspenders: grep the JSONL directly for a
            // tool_result line referencing our toolUseId. This catches
            // edge cases where ConversationParser fails to populate
            // completedToolIds (corrupted cache, parse failure on a
            // single line, schema drift) but the raw JSONL still has
            // unambiguous evidence the tool was resolved. Without this,
            // certain sidecars can leak across restarts indefinitely.
            if jsonlContainsToolResult(
                sessionId: event.sessionId,
                cwd: resolvedCwd,
                toolUseId: toolUseId
            ) {
                logger.info("stale sidecar (grep-detected resolution in JSONL): session=\(event.sessionId.prefix(8), privacy: .public) tool=\(toolUseId.prefix(12), privacy: .public)")
                delete(sessionId: event.sessionId, toolUseId: toolUseId)
                continue
            }

            logger.info("replaying sidecar: session=\(event.sessionId.prefix(8), privacy: .public) tool=\(toolUseId.prefix(12), privacy: .public)")

            // Force a full history load before synthesizing the
            // permission event. Without this, chatItems is empty when
            // the placeholder is created and the user sees a form
            // floating in an empty chat panel (the normal chat-open
            // path that triggers loadHistory hasn't fired yet on
            // launch).
            await SessionStore.shared.process(
                .loadHistory(sessionId: event.sessionId, cwd: resolvedCwd)
            )
            await SessionStore.shared.process(.hookReceived(event))

            // Replay only carries the PermissionRequest payload, but
            // the live AX-scrape that backfills the assistant text
            // above the question is triggered from the PreToolUse
            // handler in SessionStore (line ~435). Replicate it here
            // so the replayed pending state still gets its surrounding
            // text from the terminal scrollback. Idempotent — the
            // inject path skips if a synthetic already exists.
            if event.tool == "AskUserQuestion",
               let session = await SessionStore.shared.getSession(id: event.sessionId) {
                let sid = event.sessionId
                let sessionSnapshot = session
                let boundToolId = toolUseId
                Task.detached(priority: .userInitiated) {
                    await SessionStore.scrapeAndInjectAssistantText(
                        session: sessionSnapshot,
                        boundToolUseId: boundToolId,
                        sessionId: sid
                    )
                }
            }
        }
    }

    /// Raw-bytes scan of a session's JSONL for a line that contains
    /// BOTH `"type":"tool_result"` AND our toolUseId. Doesn't parse
    /// JSON — just substring matching — so it survives any parser
    /// edge case that would prevent ConversationParser from
    /// populating completedToolIds. False positives are vanishingly
    /// unlikely because the toolUseId is a 24-char random suffix and
    /// the tool_result type marker only appears in actual tool_result
    /// blocks.
    private static func jsonlContainsToolResult(
        sessionId: String,
        cwd: String,
        toolUseId: String
    ) -> Bool {
        let projectDir = ConversationParser.projectDirName(from: cwd)
        let path = NSHomeDirectory()
            + "/.claude/projects/\(projectDir)/\(sessionId).jsonl"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        // Find any line that names this toolUseId in a tool_result
        // context. Both markers must appear on the same line.
        let needleId = "\"tool_use_id\":\"\(toolUseId)\""
        let needleType = "\"type\":\"tool_result\""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.contains(needleId) && line.contains(needleType) {
                return true
            }
        }
        return false
    }
}
