//
//  CodexAgentProvider.swift
//  AgentVisor
//
//  OpenAI Codex integration. Mirrors Codex-owned desktop/CLI sessions through
//  hooks and rollout transcripts, and drives Agent Visor-owned Codex threads
//  through Codex's app-server protocol.
//

import AppKit
import Foundation
import AgentVisorCore
import os.log

struct CodexAgentProvider: AgentProvider {
    nonisolated private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "CodexAgent")

    nonisolated let id: AgentID = .codex
    nonisolated let displayName: String = "Codex"
    nonisolated let processNameFilter: String = "codex"
    // Spawnable: a new thread is created via codex app-server JSON-RPC
    // (CodexAppServerClient.startThread) and driven over the same socket.
    nonisolated let canSpawnSession: Bool = true

    nonisolated init() {}

    /// Codex.app's bundle identifier — used to detect whether the GUI
    /// is running (its threads have no per-thread PID, so liveness keys
    /// on the app being alive + thread recency).
    nonisolated static let codexAppBundleID = "com.openai.codex"

    /// PID of the running Codex.app GUI, or nil if it isn't running.
    /// `NSWorkspace.runningApplications` returns a cached snapshot and
    /// is safe to read off the main thread.
    nonisolated static func runningCodexAppPid() -> Int? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == codexAppBundleID }
            .map { Int($0.processIdentifier) }
    }

    /// Open an observed Codex Desktop thread in Codex.app.
    @MainActor
    static func openThreadInApp(_ threadId: String) {
        guard let deepLink = URL(string: "codex://threads/\(threadId)") else {
            logger.error("openThreadInApp: invalid Codex thread URL for thread=\(threadId.prefix(8), privacy: .public)")
            focusCodexApplication(threadId, reason: "invalid-url")
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexAppBundleID) else {
            if NSWorkspace.shared.open(deepLink) {
                logger.notice("openThreadInApp: opened Codex thread URL via default handler thread=\(threadId.prefix(8), privacy: .public)")
            } else {
                logger.error("openThreadInApp: Codex.app not found and default URL handler failed for thread=\(threadId.prefix(8), privacy: .public)")
                focusCodexApplication(threadId, reason: "missing-app-url")
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([deepLink], withApplicationAt: appURL, configuration: configuration) { app, error in
            if let error {
                logger.error("openThreadInApp: failed to open Codex thread URL for thread=\(threadId.prefix(8), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    focusCodexApplication(threadId, reason: "deep-link-error")
                }
            } else {
                logger.notice("openThreadInApp: opened Codex thread URL pid=\(app?.processIdentifier ?? -1) thread=\(threadId.prefix(8), privacy: .public)")
            }
        }
    }

    @MainActor
    private static func focusCodexApplication(_ threadId: String, reason: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: codexAppBundleID).first {
            _ = running.activate()
            logger.notice("openThreadInApp: focused running Codex.app fallback reason=\(reason, privacy: .public) thread=\(threadId.prefix(8), privacy: .public)")
            return
        }
        logger.error("openThreadInApp: Codex.app focus fallback failed reason=\(reason, privacy: .public) thread=\(threadId.prefix(8), privacy: .public)")
    }

    /// Thread ids that should be surfaced as live codex sessions right
    /// now: GUI threads active within the recency window while Codex.app
    /// runs. Shared by discovery (to add) and the prune (to remove) so
    /// both agree on exactly one definition of "active". Reads the
    /// mtime-cached thread list, so calling it on the 3s prune cadence
    /// is cheap when the db hasn't changed.
    nonisolated static func activeGUIThreadIDs() -> Set<String> {
        let candidates = CodexThreadStore.liveThreadCandidates()
        let active = CodexActiveThreadSelector.activeThreads(
            candidates: candidates,
            now: Int(Date().timeIntervalSince1970),
            windowSeconds: Int(AppSettings.observedWindowSeconds)
        )
        return Set(
            active.map(\.id)
        )
    }

    nonisolated var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    nonisolated var settingsURL: URL {
        configDirectory.appendingPathComponent("hooks.json")
    }

    nonisolated var hooksDirectory: URL {
        configDirectory.appendingPathComponent("hooks")
    }

    nonisolated var sessionMetadataDirectory: URL {
        configDirectory
    }

    nonisolated var projectsDirectory: URL {
        configDirectory.appendingPathComponent("sessions")
    }

    nonisolated func projectDirName(forCwd cwd: String) -> String {
        URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    nonisolated func transcriptURL(sessionId: String, cwd: String) -> URL {
        if let path = CodexThreadStore.thread(id: sessionId)?.rolloutPath {
            return URL(fileURLWithPath: path)
        }
        // sqlite lookup missed — codex hadn't yet written the threads
        // row, the row was archived/purged, or the db is unreadable.
        // Fall back to scanning the actual rollout layout
        // (~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl). The
        // earlier flat fallback (`<sessions>/<id>.jsonl`) never resolved
        // and silently produced empty transcripts.
        if let scanned = Self.rolloutFileURL(sessionId: sessionId, sessionsRoot: projectsDirectory) {
            Self.logger.info("transcriptURL: sqlite lookup miss for \(sessionId, privacy: .public); resolved via dated scan to \(scanned.path, privacy: .public)")
            return scanned
        }
        Self.logger.error("transcriptURL: sqlite lookup miss for \(sessionId, privacy: .public); dated scan also missed — returning unresolved fallback path")
        return projectsDirectory.appendingPathComponent("\(sessionId).jsonl")
    }

    // MARK: - History parsing

    nonisolated func loadFullHistory(sessionId: String, cwd: String) async -> ParsedHistory {
        let messages = await CodexConversationParser.shared.parseFullConversation(sessionId: sessionId)
        let completed = await CodexConversationParser.shared.completedToolIds(for: sessionId)
        let results = await CodexConversationParser.shared.toolResults(for: sessionId)
        let info = await CodexConversationParser.shared.conversationInfo(for: sessionId)
        return ParsedHistory(
            messages: messages,
            completedToolIds: completed,
            toolResults: results,
            structuredResults: [:],
            conversationInfo: info,
            currentPermissionMode: nil
        )
    }

    /// Bootstrap/sidebar metadata uses a bounded head+tail read. Full
    /// chat rendering still goes through `loadFullHistory`, so the
    /// session list no longer parses 100+ MB rollout files just to
    /// populate titles, model, context, and last-message previews.
    nonisolated func loadConversationInfo(sessionId: String, cwd: String) async -> ConversationInfo {
        await CodexConversationSummary.shared.parse(
            sessionId: sessionId,
            rolloutPath: transcriptURL(sessionId: sessionId, cwd: cwd).path
        )
    }

    /// Codex doesn't have an incremental parser; full reparse on
    /// every file extend. The parser caches by file mtime so identical-
    /// content syncs are cheap. Returned as `.fullReplay` so SessionStore
    /// dispatches `historyLoaded` (not the incremental `fileUpdated`).
    nonisolated func fileSync(sessionId: String, cwd: String) async -> FileSyncOutcome {
        .fullReplay(await loadFullHistory(sessionId: sessionId, cwd: cwd))
    }

    // MARK: - Metadata

    /// Codex stores user-set thread titles in `state_5.sqlite`'s
    /// `threads` table, keyed by thread id (= our session id), not
    /// by pid. The pid is irrelevant here.
    nonisolated func resolveSessionName(sessionId: String, pid: Int?) -> String? {
        guard let title = CodexThreadStore.thread(id: sessionId)?.title,
              !title.isEmpty else { return nil }
        return title
    }

    /// Codex thread origin = drivability.
    ///
    /// Agent Visor only drives threads it created/claimed through its
    /// own `codex app-server`. Codex.app GUI rows and live CLI sessions
    /// are externally owned, so they stay observed/read-only here.
    nonisolated func originForSession(sessionId: String, tty: String?) -> SessionOrigin {
        let source = CodexThreadStore.thread(id: sessionId)?.source ?? ""
        let drivability = CodexThreadOwnershipPolicy.drivability(
            tty: tty,
            source: source,
            isAgentVisorOwned: CodexAgentVisorOwnershipStore.isClaimed(sessionId)
        )
        switch drivability {
        case .agentVisorAppServer: return .codexAppServer
        case .externalOwner: return .observed
        }
    }

    /// Codex's JSONL rollouts don't persist a model name across turns
    /// the way claude-code's transcripts do. Every parse pulls the
    /// model from the most recent assistant message; without
    /// overwriting, the session.modelName stays pinned at whatever
    /// the very first turn used. Overwrite on every parse so the chip
    /// reflects the model actually in use right now.
    nonisolated func overwritesModelName() -> Bool { true }

    // MARK: - Discovery

    /// Live codex sessions, from two sources, deduped by thread id:
    ///
    ///   1. **Terminal CLI** — `ps` for a `codex` process with a
    ///      controlling tty, paired with its `state_5.sqlite` thread row
    ///      by cwd. Each has its own PID.
    ///   2. **Codex.app GUI** — the app runs every thread inside one
    ///      process, so there's no per-thread PID. We surface the
    ///      threads active within the recency window (see
    ///      `CodexActiveThreadSelector`) and stamp them with Codex.app's
    ///      PID so bootstrap treats them as live (pid != 0) and the
    ///      prune's `kill(pid,0)` keeps them while the app is alive.
    ///
    /// Historical / idle threads are intentionally NOT surfaced — codex
    /// is active-only everywhere (user decision), so the pills and
    /// sidebar show just what you're currently working in.
    nonisolated func discoverLiveSessions() -> [DiscoveredSession] {
        var results: [DiscoveredSession] = []
        var seen = Set<String>()

        // 1. Terminal CLI sessions.
        let processes = discoverCodexProcesses()
        if !processes.isEmpty {
            let threads = CodexThreadStore.liveThreadCandidates()
            let matches = CodexLiveThreadMatcher.matchLiveThreads(processes: processes, threads: threads)
            for match in matches where seen.insert(match.thread.id).inserted {
                AgentDiscoveryUtilities.writeLog(
                    "[Discovery] Found Codex CLI: \(match.thread.id.prefix(8)) PID=\(match.process.pid) tty=\(match.process.tty ?? "none") cwd=\(match.thread.cwd)"
                )
                results.append(DiscoveredSession(
                    sessionId: match.thread.id,
                    cwd: match.thread.cwd,
                    pid: match.process.pid,
                    tty: match.process.tty,
                    agentID: id
                ))
            }
        }

        // 2. Codex.app GUI threads active within the observed window.
        //    Surfaced whether or not Codex.app is running — the threads live
        //    in state_5.sqlite + rollout files on disk, are read-only here,
        //    and original-host navigation can only focus Codex.app.
        //    pid is the app's pid when running, else a 0 sentinel (matching
        //    the Cursor app-closed convention); GUI threads opt out of PID
        //    dedup (tty == nil), so the shared 0 doesn't collapse them.
        let activeIDs = Self.activeGUIThreadIDs()
        if !activeIDs.isEmpty {
            let appPid = Self.runningCodexAppPid() ?? 0
            let byId = Dictionary(
                CodexThreadStore.liveThreadCandidates().map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for threadId in activeIDs where seen.insert(threadId).inserted {
                guard let thread = byId[threadId] else { continue }
                AgentDiscoveryUtilities.writeLog(
                    "[Discovery] Found Codex GUI: \(thread.id.prefix(8)) appPID=\(appPid) cwd=\(thread.cwd)"
                )
                results.append(DiscoveredSession(
                    sessionId: thread.id,
                    cwd: thread.cwd,
                    pid: appPid,
                    tty: nil,
                    agentID: id
                ))
            }
        }
        return results
    }

    /// Active-only everywhere: no historical codex rows in the sidebar
    /// or pills. Past transcripts stay on disk and are reachable through
    /// Codex.app itself; surfacing 30+ ended rows here only floods the
    /// list (user decision). Live threads come from `discoverLiveSessions`.
    nonisolated func discoverHistoricalSessions(
        excluding _: Set<String>,
        limit _: Int
    ) -> [DiscoveredSession] {
        []
    }

    /// Codex threads have no recovery path once they drop out of the
    /// active set — Codex.app owns re-opening them. Remove on death
    /// rather than keeping an ended row (active-only everywhere).
    nonisolated func deadProcessAction(for session: SessionState) -> DeadProcessAction {
        .remove
    }

    /// Codex.app GUI threads all share one Electron process, so they all
    /// carry Codex.app's pid. Identical pid is the design, not a
    /// duplicate — without this skip the duplicate-PID prune collapses
    /// every GUI thread down to a single sidebar row. CLI codex sessions
    /// (real tty, own process) still go through dedup. Mirrors the cursor
    /// provider, which has the same one-process-many-threads shape.
    nonisolated func skipsPidDedup(for session: SessionState) -> Bool {
        session.tty == nil
    }

    nonisolated private func discoverCodexProcesses() -> [CodexProcessCandidate] {
        let result = ProcessExecutor.shared.runSync(
            "/bin/ps",
            arguments: ["-axo", "pid=,tty=,comm=,args="]
        )
        guard case .success(let output) = result else { return [] }

        var processes: [CodexProcessCandidate] = []
        for line in output.split(separator: "\n") {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int(parts[0]) else { continue }
            let tty = TTYNormalizer.normalize(String(parts[1]))
            guard tty != nil else { continue }
            let comm = String(parts[2])
            let args = String(parts[3])
            guard URL(fileURLWithPath: comm).lastPathComponent == processNameFilter else { continue }
            guard !args.contains(" app-server "), !args.contains(" mcp-server "), !args.contains(" exec-server ") else { continue }
            guard let cwd = AgentDiscoveryUtilities.cwdForProcess(pid: pid) else { continue }
            processes.append(CodexProcessCandidate(pid: pid, tty: tty, cwd: cwd))
        }
        return processes
    }

    /// Walk `~/.codex/sessions/YYYY/MM/DD/` looking for a rollout file
    /// whose name contains `sessionId`. Codex names files as
    /// `rollout-<ISO8601>-<sessionId>.jsonl`, so a substring match on
    /// the id is unambiguous (UUIDs are 36 chars). Walks newest-first
    /// so the first hit wins for the common case where the session
    /// was started today.
    nonisolated static func rolloutFileURL(sessionId: String, sessionsRoot: URL? = nil) -> URL? {
        let root = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        return scanForRolloutFile(sessionId: sessionId, in: root)
    }

    nonisolated private static func scanForRolloutFile(sessionId: String, in root: URL) -> URL? {
        let fm = FileManager.default
        guard let years = try? fm.contentsOfDirectory(atPath: root.path) else {
            return nil
        }
        for year in years.sorted(by: >) {
            let yearDir = root.appendingPathComponent(year)
            guard let months = try? fm.contentsOfDirectory(atPath: yearDir.path) else { continue }
            for month in months.sorted(by: >) {
                let monthDir = yearDir.appendingPathComponent(month)
                guard let days = try? fm.contentsOfDirectory(atPath: monthDir.path) else { continue }
                for day in days.sorted(by: >) {
                    let dayDir = monthDir.appendingPathComponent(day)
                    guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
                    if let match = files.first(where: { $0.contains(sessionId) }) {
                        return dayDir.appendingPathComponent(match)
                    }
                }
            }
        }
        return nil
    }

    // Keep this integration-specific name distinct from the Claude Code hook.
    nonisolated private static let hookScriptName = "agent-visor-codex-state.py"
    nonisolated private static let hookScriptResource = "agent-visor-codex-state"
    nonisolated private static let hookScriptExtension = "py"

    nonisolated private static let hookEvents: [HookEventConfig] = [
        .init(name: "UserPromptSubmit", matcher: .none),
        .init(name: "PreToolUse", matcher: .wildcard),
        .init(name: "PostToolUse", matcher: .wildcard),
        .init(name: "PermissionRequest", matcher: .wildcard),
        .init(name: "Stop", matcher: .none),
        .init(name: "SessionStart", matcher: .none),
        .init(name: "SessionEnd", matcher: .none),
        .init(name: "PreCompact", matcher: .preCompact),
    ]

    nonisolated func installHooks() throws {
        guard Self.isCodexAvailable() else { return }

        try FileManager.default.createDirectory(
            at: hooksDirectory,
            withIntermediateDirectories: true
        )

        let scriptPath = hooksDirectory.appendingPathComponent(Self.hookScriptName)
        if let bundled = Bundle.main.url(
            forResource: Self.hookScriptResource,
            withExtension: Self.hookScriptExtension
        ) {
            let tempScript = hooksDirectory.appendingPathComponent("\(Self.hookScriptName).tmp")
            try? FileManager.default.removeItem(at: tempScript)
            try FileManager.default.copyItem(at: bundled, to: tempScript)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tempScript.path
            )
            _ = try FileManager.default.replaceItemAt(scriptPath, withItemAt: tempScript)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptPath.path
            )
        }

        try mergeSettings()
    }

    nonisolated func uninstallHooks() {
        let scriptPath = hooksDirectory.appendingPathComponent(Self.hookScriptName)
        try? FileManager.default.removeItem(at: scriptPath)
        try? removeOurEntriesFromSettings()
    }

    nonisolated func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                if let entryHooks = entry["hooks"] as? [[String: Any]] {
                    for hook in entryHooks {
                        if let cmd = hook["command"] as? String,
                           cmd.contains(Self.hookScriptName) {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    nonisolated private func mergeSettings() throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = Self.detectPython()
        let scriptPath = hooksDirectory.appendingPathComponent(Self.hookScriptName).path
        let command = "\(python) '\(scriptPath)'"
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        for event in Self.hookEvents {
            let config = event.matcher.configEntries(command: command)
            if var existingEvent = hooks[event.name] as? [[String: Any]] {
                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains(Self.hookScriptName)
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    hooks[event.name] = existingEvent
                }
            } else {
                hooks[event.name] = config
            }
        }

        json["hooks"] = hooks
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try data.write(to: settingsURL)
        }
    }

    nonisolated private func removeOurEntriesFromSettings() throws {
        try removeEntriesFromSettings(matchingScriptNames: [Self.hookScriptName])
    }

    nonisolated private func removeEntriesFromSettings(matchingScriptNames names: [String]) throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                if let entryHooks = entry["hooks"] as? [[String: Any]] {
                    return entryHooks.contains { hook in
                        let cmd = hook["command"] as? String ?? ""
                        return names.contains { cmd.contains($0) }
                    }
                }
                return false
            }
            hooks[event] = entries.isEmpty ? nil : entries
        }

        json["hooks"] = hooks
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try data.write(to: settingsURL)
        }
    }

    nonisolated private static func isCodexAvailable() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if FileManager.default.fileExists(atPath: home + "/.codex") {
            return true
        }
        for path in ["/usr/local/bin/codex", "/opt/homebrew/bin/codex", home + "/.local/bin/codex"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return true
            }
        }
        return FileManager.default.isExecutableFile(atPath: "/Applications/Codex.app/Contents/Resources/codex")
    }

    nonisolated private static func detectPython() -> String {
        let result = ProcessExecutor.shared.runSync("/usr/bin/which", arguments: ["python3"])
        if case .success = result {
            return "python3"
        }
        return "python"
    }
}

private struct HookEventConfig: Sendable {
    let name: String
    let matcher: CodexMatcherShape
}

private enum CodexMatcherShape: Sendable {
    case none
    case wildcard
    case preCompact

    nonisolated func configEntries(command: String) -> [[String: Any]] {
        let hookList: [[String: Any]] = [["type": "command", "command": command]]
        switch self {
        case .none:
            return [["hooks": hookList]]
        case .wildcard:
            return [["matcher": "*", "hooks": hookList]]
        case .preCompact:
            return [
                ["matcher": "auto", "hooks": hookList],
                ["matcher": "manual", "hooks": hookList],
            ]
        }
    }
}
