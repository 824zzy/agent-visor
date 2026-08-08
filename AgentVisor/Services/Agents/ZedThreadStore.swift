//
//  ZedThreadStore.swift
//  AgentVisor
//
//  Read-only access to Zed's own thread list.
//
//  Zed keeps the threads it shows in its sidebar in `sidebar_threads`
//  inside `<data dir>/db/0-<channel>/db.sqlite`, keyed by the hosted
//  agent's session id. That row is the only place the title the user
//  recognizes exists: the ACP child writes its transcript but never
//  learns the name Zed generated or the user typed.
//
//  Same shape as [[CodexThreadStore]]: fork `/usr/bin/sqlite3 -readonly`
//  (load-bearing — Zed writes this database continuously and a default
//  invocation would try to recover the WAL on the writer's behalf), then
//  cache the decoded rows against an mtime+size signature of the
//  database and its `-wal` sibling so a 3-second refresh tick costs one
//  `stat` when nothing changed.
//
//  Everything here is best-effort: an older Zed has no `sidebar_threads`
//  table, and a machine may have no Zed at all. Both cases resolve to an
//  empty snapshot, never an error surfaced to the user.
//

import AgentVisorCore
import AppKit
import Foundation
import os.log

/// Decoded, indexed view of Zed's thread list at one signature.
nonisolated struct ZedThreadSnapshot: Sendable {
    let channel: ZedChannel?
    let records: [ZedThreadRecord]
    let bySessionID: [String: ZedThreadRecord]

    static let empty = ZedThreadSnapshot(channel: nil, records: [], bySessionID: [:])
}

enum ZedThreadStore {
    nonisolated private static let logger = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "ZedThreadStore"
    )

    /// Zed rewrites `updated_at` on background bookkeeping, so ordering by
    /// the interaction stamp keeps the list in the order the user sees.
    /// `limit` is generous: the sidebar is the user's full thread history.
    nonisolated private static let threadsSQL = """
    select
      hex(thread_id) as thread_id,
      session_id,
      agent_id,
      substr(coalesce(title, ''), 1, 500) as title,
      substr(coalesce(title_override, ''), 1, 500) as title_override,
      updated_at,
      interacted_at,
      main_worktree_paths,
      archived
    from sidebar_threads
    order by coalesce(interacted_at, updated_at) desc
    limit 500
    """

    /// Zed persists its front-to-back window stack, each window's active
    /// workspace, and each workspace's exact Agent Panel selection. Joining
    /// all three is the navigation receipt: it proves both that the requested
    /// workspace is actually frontmost and that it loaded the requested
    /// thread. (`sidebar_threads.interacted_at` does not move for the
    /// keyboard-driven path.)
    nonisolated private static let activePanelSelectionSQL = """
    with front_window(window_id) as (
      select cast(json_extract(value, '$[0]') as text)
      from kv_store
      where key = 'session_window_stack'
    ), active_workspace(workspace_id) as (
      select cast(json_extract(state.value, '$.active_workspace_id') as text)
      from front_window
      join scoped_kv_store state
        on state.namespace = 'multi_workspace_state'
       and state.key = front_window.window_id
    )
    select
      w.paths,
      json_extract(panel.value, '$.last_active_thread.thread_id') as thread_id,
      json_extract(panel.value, '$.last_active_thread.session_id') as session_id
    from active_workspace
    join workspaces w
      on cast(w.workspace_id as text) = active_workspace.workspace_id
    join scoped_kv_store panel
      on panel.namespace = 'agent_panel'
     and panel.key = active_workspace.workspace_id
    where json_extract(panel.value, '$.last_active_thread.thread_id') is not null
       or json_extract(panel.value, '$.last_active_thread.session_id') is not null
    limit 1
    """

    // MARK: - Cache

    nonisolated private struct Signature: Equatable {
        let databasePath: String
        let database: FileStamp
        let wal: FileStamp
    }

    nonisolated private struct FileStamp: Equatable {
        let modifiedAt: TimeInterval
        let size: UInt64

        static let missing = FileStamp(modifiedAt: 0, size: 0)
    }

    nonisolated(unsafe) private static var cachedSignature: Signature?
    nonisolated(unsafe) private static var cachedSnapshot: ZedThreadSnapshot = .empty
    nonisolated(unsafe) private static var loggedMissingTable = false
    nonisolated private static let cacheLock = NSLock()

    // MARK: - Running app

    /// Channels whose app is running right now. Drives database selection
    /// (a stale `0-dev` must not outrank the running stable install) and
    /// the Zed-liveness sweep in SessionStore.
    nonisolated static func runningChannels() -> Set<ZedChannel> {
        let running = NSWorkspace.shared.runningApplications
        var result: Set<ZedChannel> = []
        for app in running {
            guard let bundleID = app.bundleIdentifier,
                  let channel = ZedChannel.channel(forBundleID: bundleID) else { continue }
            result.insert(channel)
        }
        return result
    }

    nonisolated static var isZedRunning: Bool {
        !runningChannels().isEmpty
    }

    /// Running Zed app plus its channel, preferring the channel that owns
    /// the database we read so toasts name the app the user launched.
    nonisolated static func runningApp() -> (app: NSRunningApplication, channel: ZedChannel)? {
        let channels = runningChannels()
        guard !channels.isEmpty else { return nil }
        let preferred = resolvedDatabase()?.channel
        var ordered = ZedChannel.allCases
        if let preferred {
            ordered.removeAll { $0 == preferred }
            ordered.insert(preferred, at: 0)
        }
        for channel in ordered where channels.contains(channel) {
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: channel.bundleID).first {
                return (app, channel)
            }
        }
        return nil
    }

    // MARK: - Database location

    nonisolated static func resolvedDatabase() -> (channel: ZedChannel, path: String)? {
        ZedDatabaseLocator.resolve(
            home: NSHomeDirectory(),
            exists: { FileManager.default.fileExists(atPath: $0) },
            modifiedAt: {
                (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
            },
            runningChannels: runningChannels()
        )
    }

    nonisolated static func metadataWatchPaths() -> [String] {
        guard let resolved = resolvedDatabase() else { return [] }
        return ZedDatabaseLocator.watchPaths(databasePath: resolved.path)
    }

    // MARK: - Reads

    /// Cached snapshot; re-queries only when the database signature moved.
    nonisolated static func snapshot() -> ZedThreadSnapshot {
        guard let resolved = resolvedDatabase() else { return .empty }
        let signature = self.signature(databasePath: resolved.path)

        cacheLock.lock()
        if cachedSignature == signature {
            let cached = cachedSnapshot
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let snapshot = query(channel: resolved.channel, databasePath: resolved.path)
        // Never cache an empty read: an empty list is far more likely a
        // truncated read while Zed was committing than a real "no threads"
        // state, and caching it would freeze every Zed pill title until the
        // next write. The next tick self-heals. Same rule as CodexThreadStore.
        if !snapshot.records.isEmpty {
            cacheLock.lock()
            cachedSignature = signature
            cachedSnapshot = snapshot
            cacheLock.unlock()
        }
        return snapshot
    }

    nonisolated static func thread(sessionID: String) -> ZedThreadRecord? {
        snapshot().bySessionID[sessionID]
    }

    /// True when Zed is currently hosting this session as a non-archived
    /// thread. This is the authority for host attribution: a codex-acp or
    /// claude-acp thread inside Zed also writes a `~/.codex` rollout or
    /// `~/.claude` JSONL, so its own provider would otherwise claim it and
    /// stamp Codex.app / a pooled pid. Presence here means Zed owns it.
    nonisolated static func hostsSession(_ sessionID: String) -> Bool {
        guard let record = snapshot().bySessionID[sessionID] else { return false }
        return !record.archived
    }

    /// Title Zed shows for this session's thread, or nil when Zed has no
    /// title yet (fresh thread) or does not know the session.
    nonisolated static func displayTitle(sessionID: String) -> String? {
        thread(sessionID: sessionID)?.displayTitle
    }

    /// Whether the truncated query identifies exactly one live Zed row.
    /// Comparing reveal queries rather than full titles catches long titles
    /// that differ only after the 48 characters Agent Visor types.
    nonisolated static func hasUniqueLiveRevealQuery(_ thread: ZedThreadRecord) -> Bool {
        guard let query = ZedThreadRevealPlanner.query(forTitle: thread.displayTitle) else {
            return false
        }
        let normalized = normalizeTitle(query)
        return snapshot().records.lazy.filter {
            guard !$0.archived,
                  let candidate = ZedThreadRevealPlanner.query(forTitle: $0.displayTitle)
            else { return false }
            return normalizeTitle(candidate) == normalized
        }.prefix(2).count == 1
    }

    /// The frontmost Zed window's active-workspace selection, but only when
    /// that workspace owns `worktreePath`. Every workspace retains its last
    /// Agent Panel thread, so checking the window/workspace chain prevents a
    /// stale background receipt from being mistaken for successful navigation.
    nonisolated static func activePanelSelection(worktreePath: String) -> ZedThreadSelection? {
        guard let resolved = resolvedDatabase() else { return nil }
        let result = ProcessExecutor.shared.runSync(
            "/usr/bin/sqlite3",
            arguments: [
                "-readonly",
                "-cmd", ".timeout 500",
                "-json",
                resolved.path,
                activePanelSelectionSQL
            ]
        )
        guard case .success(let output) = result,
              let data = output.data(using: .utf8),
              let rows = try? JSONDecoder().decode([PanelSelectionRow].self, from: data)
        else { return nil }

        let target = normalizePath(worktreePath)
        guard let row = rows.first,
              ZedThreadRecord.worktreePaths(from: row.paths)
                .map(normalizePath)
                .contains(target)
        else { return nil }
        return ZedThreadSelection(threadID: row.thread_id, sessionID: row.session_id)
    }

    /// Non-archived threads Zed is hosting for one agent, newest first.
    /// Discovery uses this to find sessions whose process shape hides them
    /// from `ps`-based scans (Zed runs `node …/pi-acp`, not `pi`).
    nonisolated static func liveThreads(agentID: AgentID) -> [ZedThreadRecord] {
        snapshot().records.filter {
            !$0.archived && $0.sessionID != nil && $0.agentID == agentID
        }
    }

    // MARK: - Internals

    nonisolated private static func signature(databasePath: String) -> Signature {
        func stamp(_ path: String) -> FileStamp {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                return .missing
            }
            return FileStamp(
                modifiedAt: (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0,
                size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            )
        }
        return Signature(
            databasePath: databasePath,
            database: stamp(databasePath),
            wal: stamp(databasePath + "-wal")
        )
    }

    nonisolated private struct ThreadRow: Decodable {
        let thread_id: String
        let session_id: String?
        let agent_id: String?
        let title: String?
        let title_override: String?
        let updated_at: String?
        let interacted_at: String?
        let main_worktree_paths: String?
        let archived: Int?
    }

    nonisolated private struct PanelSelectionRow: Decodable {
        let paths: String?
        let thread_id: String?
        let session_id: String?
    }

    nonisolated private static func query(
        channel: ZedChannel,
        databasePath: String
    ) -> ZedThreadSnapshot {
        let result = ProcessExecutor.shared.runSync(
            "/usr/bin/sqlite3",
            arguments: ["-readonly", "-json", databasePath, threadsSQL]
        )
        guard case .success(let output) = result,
              let data = output.data(using: .utf8) else {
            // An older Zed has no `sidebar_threads` table. That is a
            // supported state (no titles, no Zed-driven discovery), so log
            // it once at debug level instead of repeating an error every
            // refresh tick.
            if case .failure(let error) = result {
                logOnce(error: error, databasePath: databasePath)
            }
            return ZedThreadSnapshot(channel: channel, records: [], bySessionID: [:])
        }
        let rows: [ThreadRow] = (try? JSONDecoder().decode([ThreadRow].self, from: data)) ?? []
        let records = rows.map { row in
            ZedThreadRecord(
                threadID: row.thread_id,
                sessionID: row.session_id?.isEmpty == false ? row.session_id : nil,
                agentIdentifier: row.agent_id,
                title: row.title,
                titleOverride: row.title_override,
                worktreePaths: ZedThreadRecord.worktreePaths(from: row.main_worktree_paths),
                archived: (row.archived ?? 0) != 0,
                updatedAt: date(from: row.updated_at),
                interactedAt: date(from: row.interacted_at)
            )
        }
        var bySessionID: [String: ZedThreadRecord] = [:]
        for record in records {
            guard let sessionID = record.sessionID else { continue }
            // Rows arrive newest-first; keep the first (freshest) row when
            // an agent reuses a session id across threads.
            if bySessionID[sessionID] == nil {
                bySessionID[sessionID] = record
            }
        }
        logger.debug("read rows=\(records.count, privacy: .public) channel=\(channel.rawValue, privacy: .public)")
        return ZedThreadSnapshot(channel: channel, records: records, bySessionID: bySessionID)
    }

    nonisolated private static func logOnce(error: ProcessExecutorError, databasePath: String) {
        cacheLock.lock()
        let alreadyLogged = loggedMissingTable
        loggedMissingTable = true
        cacheLock.unlock()
        guard !alreadyLogged else { return }
        logger.debug("sqlite read unavailable db=\(databasePath, privacy: .public) err=\(String(describing: error), privacy: .public)")
    }

    /// Zed writes RFC3339 with fractional seconds and an explicit offset
    /// (`2026-08-06T08:45:38.659861+00:00`).
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated private static func date(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }

    nonisolated private static func normalizeTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated private static func normalizePath(_ value: String) -> String {
        (value as NSString).standardizingPath
    }
}
