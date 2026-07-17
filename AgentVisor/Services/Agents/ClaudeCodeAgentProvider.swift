//
//  ClaudeCodeAgentProvider.swift
//  AgentVisor
//
//  AgentProvider implementation for Anthropic's claude-code CLI.
//  Encapsulates the `~/.claude` layout and the hook-installer logic
//  that previously lived directly in HookInstaller.
//

import Foundation
import AgentVisorCore

struct ClaudeCodeAgentProvider: AgentProvider {
    let id: AgentID = .claudeCode
    let displayName: String = "Claude Code"
    let processNameFilter: String = "claude"
    // Spawnable: a new session is forked under a headless PTY via
    // SpawnedSessionManager and driven through the pty (writeMessage).
    let canSpawnSession: Bool = true

    nonisolated init() {}

    var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    var settingsURL: URL {
        configDirectory.appendingPathComponent("settings.json")
    }

    var hooksDirectory: URL {
        configDirectory.appendingPathComponent("hooks")
    }

    var sessionMetadataDirectory: URL {
        configDirectory.appendingPathComponent("sessions")
    }

    var projectsDirectory: URL {
        configDirectory.appendingPathComponent("projects")
    }

    func projectDirName(forCwd cwd: String) -> String {
        ClaudeProjectPathEncoder.projectDirName(forCwd: cwd)
    }

    func transcriptURL(sessionId: String, cwd: String) -> URL {
        projectsDirectory
            .appendingPathComponent(projectDirName(forCwd: cwd))
            .appendingPathComponent("\(sessionId).jsonl")
    }

    // MARK: - Discovery

    /// Walks `~/.claude/sessions/*.json` (one file per live PID) and
    /// returns one DiscoveredSession per interactive session. Skips
    /// SDK / observer / claude-mem sessions. PID is verified alive +
    /// belonging to a `claude` process (defends against PID reuse).
    /// Historical claude-code sessions are not surfaced — its session
    /// ids are PID-bound, so a dead PID means a transcript nothing
    /// else will reference.
    func discoverLiveSessions() -> [DiscoveredSession] {
        let fm = FileManager.default
        let sessionsDir = sessionMetadataDirectory.path

        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            AgentDiscoveryUtilities.writeLog("[Discovery] No claude-code sessions directory found")
            return []
        }

        var results: [DiscoveredSession] = []
        for file in files {
            guard file.hasSuffix(".json") else { continue }
            let pidStr = String(file.dropLast(5))
            guard let pid = Int(pidStr) else { continue }

            // Process still alive?
            guard kill(Int32(pid), 0) == 0 else { continue }

            let filePath = sessionsDir + "/" + file
            guard let data = fm.contents(atPath: filePath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String else { continue }

            let kind = json["kind"] as? String ?? ""
            let entrypoint = json["entrypoint"] as? String ?? ""
            let status = json["status"] as? String
            guard ClaudeCodeSessionMetadataPolicy.shouldDiscover(
                kind: kind,
                entrypoint: entrypoint,
                cwd: cwd,
                status: status
            ) else { continue }

            // Defend against PID reuse: confirm the process is actually
            // a claude binary, not some other tool that picked up the
            // stale PID after claude exited.
            let procName = AgentDiscoveryUtilities
                .runProcess("/bin/ps", arguments: ["-p", "\(pid)", "-o", "comm="])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !procName.isEmpty, !procName.contains(processNameFilter) { continue }

            // tty == nil for sessions with no controlling terminal
            // (canonical case: Cursor's claude-code extension launches
            // the binary as a stdio child with ppid = "Cursor Helper
            // (Plugin): extension-host"). Downstream send paths guard
            // on `session.tty != nil`; bootstrap reads no-tty as
            // `.cursorObserved` origin via originForHostedSession.
            let rawTTY = AgentDiscoveryUtilities
                .runProcess("/bin/ps", arguments: ["-p", "\(pid)", "-o", "tty="])
            let tty = TTYNormalizer.normalize(rawTTY)

            let transcriptPath = transcriptURL(sessionId: sessionId, cwd: cwd).path
            let transcriptModifiedAt = (try? fm.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date
            let liveness = CursorHostedSessionLivenessPolicy.classify(
                hasTTY: tty != nil,
                entrypoint: entrypoint,
                processAlive: true,
                isTerminalStatus: ClaudeCodeSessionMetadataPolicy.isTerminalStatus(status),
                transcriptModifiedAt: transcriptModifiedAt?.timeIntervalSince1970,
                now: Date().timeIntervalSince1970,
                observedWindowSeconds: AppSettings.observedWindowSeconds
            )
            guard liveness != .drop else {
                AgentDiscoveryUtilities.writeLog(
                    "[Discovery] Dropped metadata-only Cursor Claude session: \(sessionId.prefix(8)) PID=\(pid) tty=\(tty ?? "none") cwd=\(cwd)"
                )
                continue
            }

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                pid: pid,
                tty: tty,
                agentID: id
            ))
            AgentDiscoveryUtilities.writeLog(
                "[Discovery] Found: \(sessionId.prefix(8)) PID=\(pid) tty=\(tty ?? "none") cwd=\(cwd)"
            )
        }
        return results
    }

    // MARK: - History parsing

    func loadFullHistory(sessionId: String, cwd: String) async -> ParsedHistory {
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId, cwd: cwd
        )
        let completed = await ConversationParser.shared.completedToolIds(for: sessionId)
        let results = await ConversationParser.shared.toolResults(for: sessionId)
        let structured = await ConversationParser.shared.structuredResults(for: sessionId)
        let info = await ConversationSummary.shared.parse(sessionId: sessionId, cwd: cwd)
        let mode = await ConversationParser.shared.currentPermissionMode(for: sessionId)
        return ParsedHistory(
            messages: messages,
            completedToolIds: completed,
            toolResults: results,
            structuredResults: structured,
            conversationInfo: info,
            currentPermissionMode: mode
        )
    }

    /// claude-code's `ConversationSummary` reads only the head+tail of
    /// the JSONL — much cheaper than a full parse and the only thing
    /// bootstrap needs.
    func loadConversationInfo(sessionId: String, cwd: String) async -> ConversationInfo {
        await ConversationSummary.shared.parse(sessionId: sessionId, cwd: cwd)
    }

    // MARK: - Lifecycle

    /// Claude-code session ids are pid-bound: once the pid dies, the
    /// transcript file is final and nothing else will append to it.
    /// Stop the watcher to free the resource.
    func stopsWatchingOnDeath(for session: SessionState) -> Bool { true }

    /// Claude-code stores `/rename` state in `~/.claude/sessions/<pid>.json`,
    /// keyed by pid. Returns nil for processes that didn't originate
    /// from `/rename` (including every Zed-hosted claude-acp session)
    /// — the caller mustn't let nil clobber a `customTitle` already
    /// surfaced from `{"type":"custom-title",...}` JSONL rows.
    func resolveSessionName(sessionId: String, pid: Int?) -> String? {
        guard let pid else { return nil }
        return SessionState.readSessionName(pid: pid)
    }

    /// Incremental delta: read only the bytes appended since the last
    /// call. Required for claude-code where streaming output extends
    /// the JSONL at high frequency and a full reparse would be wasteful.
    func fileSync(sessionId: String, cwd: String) async -> FileSyncOutcome {
        let result = await ConversationParser.shared.parseIncremental(
            sessionId: sessionId, cwd: cwd
        )
        let mode = await ConversationParser.shared.currentPermissionMode(for: sessionId)
        return .incremental(IncrementalSyncResult(
            newMessages: result.newMessages,
            completedToolIds: result.completedToolIds,
            toolResults: result.toolResults,
            structuredResults: result.structuredResults,
            clearDetected: result.clearDetected,
            currentPermissionMode: mode
        ))
    }

    // MARK: - Installation

    private static let hookScriptName = "agent-visor-state.py"
    private static let hookScriptResource = "agent-visor-state"
    private static let hookScriptExtension = "py"

    private static let hookEvents = ClaudeHookSubscriptionPolicy.subscriptions

    func installHooks() throws {
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
        }

        try mergeSettings()
    }

    func uninstallHooks() {
        let scriptPath = hooksDirectory.appendingPathComponent(Self.hookScriptName)
        try? FileManager.default.removeItem(at: scriptPath)
        try? removeOurEntriesFromSettings()
    }

    func isInstalled() -> Bool {
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

    // MARK: - Settings merge

    private func mergeSettings() throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = Self.detectPython()
        let command = "\(python) ~/.claude/hooks/\(Self.hookScriptName)"
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        for event in Self.hookEvents {
            let config = event.matcher.configEntries(command: command, timeout: event.timeoutSeconds)
            if var existingEvent = hooks[event.event] as? [[String: Any]] {
                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains(Self.hookScriptName)
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    hooks[event.event] = existingEvent
                }
            } else {
                hooks[event.event] = config
            }
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try data.write(to: settingsURL)
        }
    }

    private func removeOurEntriesFromSettings() throws {
        try removeEntriesFromSettings(matchingScriptNames: [Self.hookScriptName])
    }

    private func removeEntriesFromSettings(matchingScriptNames names: [String]) throws {
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
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try data.write(to: settingsURL)
        }
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}
        return "python"
    }
}

private extension ClaudeHookMatcher {
    func configEntries(command: String, timeout: Int?) -> [[String: Any]] {
        let hookEntry: [String: Any]
        if let timeout = timeout {
            hookEntry = ["type": "command", "command": command, "timeout": timeout]
        } else {
            hookEntry = ["type": "command", "command": command]
        }
        let hookList: [[String: Any]] = [hookEntry]

        switch self {
        case .none:
            return [["hooks": hookList]]
        case .wildcard:
            return [["matcher": "*", "hooks": hookList]]
        case .compaction:
            return [
                ["matcher": "auto", "hooks": hookList],
                ["matcher": "manual", "hooks": hookList],
            ]
        }
    }
}
