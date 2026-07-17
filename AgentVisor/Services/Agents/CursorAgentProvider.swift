//
//  CursorAgentProvider.swift
//  AgentVisor
//
//  AgentProvider for Cursor's standalone `cursor-agent` CLI. Cursor has
//  no hook seam — the binary is closed-source and emits no hook events
//  to settings. Integration is deliberately read-only:
//
//   1. Discover sessions by scanning `~/.cursor/projects/*/agent-transcripts`
//      for live `cursor-agent` processes.
//   2. Tail the JSONL transcript at:
//      `~/.cursor/projects/<projectKey>/agent-transcripts/<sessionId>/<sessionId>.jsonl`
//   3. Surface chat history; never intercept tool calls or approvals.
//
//  This mirrors the read-only model already proven by `CodexAgentProvider`,
//  with two twists:
//   - There's no settings.json to merge into; install/uninstall are no-ops.
//   - The "project directory name" Cursor uses is its own encoding of the
//     CWD path (`/Users/foo/Codes` → `Users-foo-Codes`). We replicate it
//     via `CursorProjectKeyEncoder` (in Core, unit-testable).
//

import AppKit
import Foundation
import AgentVisorCore
import os.log

struct CursorAgentProvider: AgentProvider {
    nonisolated private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "CursorAgent")

    nonisolated let id: AgentID = .cursor
    nonisolated let displayName: String = "Cursor"
    nonisolated let processNameFilter: String = "cursor-agent"

    nonisolated init() {}

    nonisolated static let appBundleID = "com.todesktop.230313mzl4w4u92"

    /// How recently a Cursor IDE Agents Window transcript must have been
    /// written to count as "active". Cursor runs every thread inside one
    /// app process, so there's no per-thread PID to key liveness on
    /// (same constraint as Codex.app) — recency of the transcript is the
    /// only signal. User-configurable via the observed-agent window
    /// setting (shared with Codex, default 42h). Cursor has no hook seam,
    /// so phase stays heuristic-only regardless of this window — the
    /// 30-min stale ceiling in TranscriptPhaseInferrer (not this value)
    /// is what suppresses false "your turn" on quiet threads.
    nonisolated static var activeWindowSeconds: TimeInterval { AppSettings.observedWindowSeconds }

    nonisolated static func isAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
    }

    /// Cursor IDE Agents Window threads (no TTY) are active-only: once
    /// their transcript goes quiet past `activeWindowSeconds`, they're
    /// removed rather than kept as ended rows — mirrors Codex.app GUI
    /// threads and keeps the sidebar to genuinely-live sessions. The
    /// cursor-agent CLI path (has a TTY) keeps the default `.markEnded`.
    nonisolated func deadProcessAction(for session: SessionState) -> DeadProcessAction {
        session.tty == nil ? .remove : .markEnded
    }

    nonisolated var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
    }

    /// Cursor doesn't use a hooks/settings.json file. We point at a
    /// non-existent path; settings I/O paths short-circuit on "no file"
    /// and the install/uninstall stubs below skip writing entirely.
    nonisolated var settingsURL: URL {
        configDirectory.appendingPathComponent(".no-hook-settings")
    }

    nonisolated var hooksDirectory: URL {
        configDirectory.appendingPathComponent("hooks-unused")
    }

    /// Cursor doesn't write a per-PID session metadata file the way
    /// claude-code does. The `~/.cursor` root is what `isCursorAvailable`
    /// keys on for "is the user running cursor-agent at all?" detection.
    nonisolated var sessionMetadataDirectory: URL { configDirectory }

    /// Per-project transcript root: `~/.cursor/projects`. Each project
    /// directory is a sanitized encoding of the CWD; transcripts live in
    /// `<projectsDirectory>/<projectKey>/agent-transcripts/<id>/<id>.jsonl`.
    nonisolated var projectsDirectory: URL {
        configDirectory.appendingPathComponent("projects")
    }

    nonisolated func projectDirName(forCwd cwd: String) -> String {
        CursorProjectKeyEncoder.projectKey(forCwd: cwd)
    }

    nonisolated func transcriptURL(sessionId: String, cwd: String) -> URL {
        let key = projectDirName(forCwd: cwd)
        let candidate = projectsDirectory
            .appendingPathComponent(key)
            .appendingPathComponent("agent-transcripts")
            .appendingPathComponent(sessionId)
            .appendingPathComponent("\(sessionId).jsonl")

        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        // Fallback: walk every projectKey directory looking for a
        // transcript folder named <sessionId>. Cursor sometimes encodes
        // the project key from a different CWD than the active one
        // (e.g. when the user `cd`s mid-session), so the deterministic
        // path can miss. The scan is bounded — typically 5-20 project
        // dirs total.
        if let scanned = scanForTranscript(sessionId: sessionId) {
            Self.logger.info("transcriptURL: deterministic path missed for \(sessionId, privacy: .public); scan resolved to \(scanned.path, privacy: .public)")
            return scanned
        }

        Self.logger.error("transcriptURL: no transcript file for \(sessionId, privacy: .public); returning unresolved path")
        return candidate
    }

    nonisolated private func scanForTranscript(sessionId: String) -> URL? {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDirectory.path) else {
            return nil
        }
        for project in projects {
            let dir = projectsDirectory
                .appendingPathComponent(project)
                .appendingPathComponent("agent-transcripts")
                .appendingPathComponent(sessionId)
                .appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: dir.path) {
                return dir
            }
        }
        return nil
    }

    // MARK: - Installation (no-ops)

    /// Cursor exposes no hook seam. There is nothing to install.
    /// The settings UI still surfaces a "Connect Cursor" toggle for
    /// parity with other agents, but it's metadata-only — toggling it
    /// doesn't change cursor-agent's behavior, just whether agent-visor
    /// tries to discover its sessions.
    nonisolated func installHooks() throws {
        // Intentionally empty. Settings flag is the actual toggle.
    }

    nonisolated func uninstallHooks() {
        // Intentionally empty.
    }

    /// Cursor is "installed" if the `cursor-agent` binary exists on disk
    /// somewhere reasonable, OR if there's already a `~/.cursor` directory
    /// (some users install via Cursor.app's bundled binary path).
    nonisolated func isInstalled() -> Bool {
        Self.isCursorAvailable()
    }

    // MARK: - History parsing

    nonisolated func loadFullHistory(sessionId: String, cwd: String) async -> ParsedHistory {
        let path = transcriptURL(sessionId: sessionId, cwd: cwd).path
        let messages = await CursorConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            transcriptPath: path
        )
        let completed = await CursorConversationParser.shared.completedToolIds(for: sessionId)
        let results = await CursorConversationParser.shared.toolResults(for: sessionId)
        let info = await CursorConversationParser.shared.conversationInfo(for: sessionId)
        return ParsedHistory(
            messages: messages,
            completedToolIds: completed,
            toolResults: results,
            structuredResults: [:],
            conversationInfo: info,
            currentPermissionMode: nil
        )
    }

    /// Cursor's parser caches by session; warm the cache then read
    /// out the conversation info.
    nonisolated func loadConversationInfo(sessionId: String, cwd: String) async -> ConversationInfo {
        let path = transcriptURL(sessionId: sessionId, cwd: cwd).path
        _ = await CursorConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            transcriptPath: path
        )
        return await CursorConversationParser.shared.conversationInfo(for: sessionId)
    }

    // MARK: - Lifecycle

    /// Cursor IDE Agents Window sessions all share Cursor.app's pid
    /// (one Electron app, many session transcripts). Identical pid is
    /// the design here, not a duplicate — without this skip, the
    /// duplicate-PID prune deletes 3 of every 4 IDE sessions on every
    /// cycle. Cursor CLI sessions (with a real tty) still go through
    /// dedup because each runs in its own process.
    nonisolated func skipsPidDedup(for session: SessionState) -> Bool {
        session.tty == nil
    }

    /// Cursor doesn't have an incremental parser; full reparse on
    /// every file extend, same shape as bootstrap. Returned as
    /// `.fullReplay` so SessionStore dispatches `historyLoaded`.
    nonisolated func fileSync(sessionId: String, cwd: String) async -> FileSyncOutcome {
        .fullReplay(await loadFullHistory(sessionId: sessionId, cwd: cwd))
    }

    // MARK: - Discovery

    /// Live cursor-agent CLI sessions: `ps` scan for the bundled-node
    /// wrapper (matched on argv path because comm is truncated by the
    /// kernel), pair with the most recent transcript that shares the
    /// same project key.
    nonisolated func discoverLiveSessions() -> [DiscoveredSession] {
        let processes = discoverCursorProcesses()
        guard !processes.isEmpty else { return [] }

        let candidates = liveCursorTranscriptCandidates()
        let processById = Dictionary(
            uniqueKeysWithValues: processes.map { (String($0.pid), $0) }
        )
        let matches = CursorLiveTranscriptMatcher.match(
            processes: processes.map {
                CursorLiveTranscriptMatcher.Process(id: String($0.pid), cwd: $0.cwd)
            },
            transcripts: candidates.map {
                CursorLiveTranscriptMatcher.Transcript(
                    sessionId: $0.sessionId,
                    projectKey: $0.projectKey,
                    mtime: $0.mtime.timeIntervalSince1970
                )
            }
        )

        var results: [DiscoveredSession] = []
        for match in matches {
            guard let proc = processById[match.process.id] else { continue }
            AgentDiscoveryUtilities.writeLog(
                "[Discovery] Found Cursor: \(match.transcript.sessionId.prefix(8)) PID=\(proc.pid) tty=\(proc.tty ?? "none") cwd=\(proc.cwd)"
            )
            results.append(DiscoveredSession(
                sessionId: match.transcript.sessionId,
                cwd: proc.cwd,
                pid: proc.pid,
                tty: proc.tty,
                agentID: id
            ))
        }
        return results
    }

    /// Historical cursor sessions cover two distinct sources sharing
    /// the same on-disk format:
    ///   1. cursor-agent CLI transcripts whose process exited.
    ///   2. Cursor IDE Agents Window threads — Cursor.app's in-app
    ///      agent feature. There's no `cursor-agent` process; the
    ///      agent runs inside Cursor.app's renderer. The only liveness
    ///      signal is "is Cursor.app running?" — if it is, every
    ///      recent transcript is potentially live, so we surface them
    ///      with pid=Cursor.app.pid (bootstrap reads non-zero pid as
    ///      `.idle`); otherwise pid=0 → `.ended`.
    /// Recency-filtered to `activeWindowSeconds` (active-only): a thread
    /// untouched for longer isn't "live" — surfacing days-old transcripts
    /// here floods the sidebar with stale sessions. The prune drops any
    /// already-tracked IDE thread that ages out of the same window.
    nonisolated func discoverHistoricalSessions(
        excluding liveIds: Set<String>,
        limit: Int
    ) -> [DiscoveredSession] {
        let projectsRoot = projectsDirectory.path
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsRoot) else { return [] }

        let cursorAppPid: Int? = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.todesktop.230313mzl4w4u92"
        ).first.map { Int($0.processIdentifier) }

        struct Hit {
            let sessionId: String
            let cwd: String
            let mtime: Date
        }
        var hits: [Hit] = []

        for project in projects {
            let cwd = CursorProjectKeyDecoder.decode(
                projectKey: project,
                directoryExists: { path in
                    var isDir: ObjCBool = false
                    let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
                    return exists && isDir.boolValue
                }
            )
            let transcriptsDir = projectsRoot + "/" + project + "/agent-transcripts"
            guard let sessions = try? fm.contentsOfDirectory(atPath: transcriptsDir) else { continue }
            for session in sessions {
                if liveIds.contains(session) { continue }
                let path = transcriptsDir + "/" + session + "/" + session + ".jsonl"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                hits.append(Hit(sessionId: session, cwd: cwd, mtime: mtime))
            }
        }

        let now = Date().timeIntervalSince1970
        let recent = CursorHistoricalRecencyFilter.filter(
            hits: hits,
            now: now,
            maxAge: Self.activeWindowSeconds,
            mtime: { $0.mtime.timeIntervalSince1970 }
        )
        let sorted = recent.sorted { $0.mtime > $1.mtime }.prefix(limit)
        let livePid = cursorAppPid ?? 0
        let results = sorted.map {
            DiscoveredSession(
                sessionId: $0.sessionId,
                cwd: $0.cwd,
                pid: livePid,
                tty: nil,
                agentID: id
            )
        }
        if !results.isEmpty {
            AgentDiscoveryUtilities.writeLog("[Discovery] Found \(results.count) historical Cursor sessions")
        }
        return results
    }

    private struct CursorProcessCandidate {
        let pid: Int
        let tty: String?
        let cwd: String
    }

    nonisolated private func discoverCursorProcesses() -> [CursorProcessCandidate] {
        let result = ProcessExecutor.shared.runSync(
            "/bin/ps",
            arguments: ["-axo", "pid=,tty=,comm=,args="]
        )
        guard case .success(let output) = result else { return [] }

        var processes: [CursorProcessCandidate] = []
        for line in output.split(separator: "\n") {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int(parts[0]) else { continue }
            let tty = TTYNormalizer.normalize(String(parts[1]))
            guard tty != nil else { continue }
            // cursor-agent ships as a bundled-node wrapper, so `comm`
            // is the truncated node path; match the install path in
            // the FULL argv (parts[3]) instead. Skip the bundled
            // worker subprocess (re-execs with `worker-server` argv).
            let args = parts.count >= 4 ? String(parts[3]) : ""
            guard args.contains("/.local/share/cursor-agent/") else { continue }
            guard !args.contains(" worker-server") else { continue }
            guard let cwd = AgentDiscoveryUtilities.cwdForProcess(pid: pid) else { continue }
            processes.append(CursorProcessCandidate(pid: pid, tty: tty, cwd: cwd))
        }
        return processes
    }

    private struct CursorTranscriptCandidate {
        let sessionId: String
        let projectKey: String
        let mtime: Date
    }

    /// Walk `~/.cursor/projects/*/agent-transcripts/*` and return every
    /// transcript with its mtime. The directory name IS the session id;
    /// we don't need to peek inside.
    ///
    /// We don't gate on a freshness window: a `cursor-agent` CLI parked
    /// at the prompt waiting for input hasn't touched its JSONL for as
    /// long as the user has been thinking. The pairing step
    /// (`discoverLiveSessions`) only consults this list when there IS
    /// a live CLI process for the matching project key, so a stale
    /// transcript can't manufacture a fake live session — it can only
    /// attach the right transcript to a real running CLI.
    nonisolated private func liveCursorTranscriptCandidates() -> [CursorTranscriptCandidate] {
        let projectsRoot = projectsDirectory.path
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsRoot) else { return [] }

        var results: [CursorTranscriptCandidate] = []
        for project in projects {
            let transcriptsDir = projectsRoot + "/" + project + "/agent-transcripts"
            guard let sessions = try? fm.contentsOfDirectory(atPath: transcriptsDir) else { continue }
            for session in sessions {
                let path = transcriptsDir + "/" + session + "/" + session + ".jsonl"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                results.append(CursorTranscriptCandidate(
                    sessionId: session,
                    projectKey: project,
                    mtime: mtime
                ))
            }
        }
        return results.sorted { $0.mtime > $1.mtime }
    }

    nonisolated static func isCursorAvailable() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            home + "/.local/bin/cursor-agent",
            "/usr/local/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor-agent",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return true
        }
        // Fallback signal: presence of `~/.cursor/projects` means the
        // user has at least authenticated with Cursor at some point.
        return FileManager.default.fileExists(atPath: home + "/.cursor/projects")
    }
}
