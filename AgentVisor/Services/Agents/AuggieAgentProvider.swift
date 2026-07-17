//
//  AuggieAgentProvider.swift
//  AgentVisor
//
//  AgentProvider for Augment's `auggie` CLI. Mirrors the
//  ClaudeCodeAgentProvider shape but points at `~/.augment/` and
//  installs the auggie shim script (which translates Auggie's
//  on-stdin schema into agent-visor's HookEvent shape before
//  forwarding to /tmp/agent-visor.sock).
//
//  Reference: https://docs.augmentcode.com/cli/hooks.md
//
//  Phase 3a scope: hook script install + session discovery. Transcript
//  parsing (chat history) is Phase 3b — Auggie's JSONL layout isn't
//  publicly documented and needs verification against a real session.
//

import Foundation
import AgentVisorCore

struct AuggieAgentProvider: AgentProvider {
    let id: AgentID = .auggie
    let displayName: String = "Auggie"
    let processNameFilter: String = "auggie"

    nonisolated init() {}

    var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".augment")
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
        // Unverified — Auggie's transcript layout isn't publicly
        // documented. Best guess; revisit in Phase 3b after observing
        // a real session.
        configDirectory.appendingPathComponent("projects")
    }

    func projectDirName(forCwd cwd: String) -> String {
        // Reuse claude-code's normalization until we observe Auggie's
        // actual on-disk layout. Pure-logic, agent-agnostic helper.
        ClaudeProjectPathEncoder.projectDirName(forCwd: cwd)
    }

    func transcriptURL(sessionId: String, cwd: String) -> URL {
        projectsDirectory
            .appendingPathComponent(projectDirName(forCwd: cwd))
            .appendingPathComponent("\(sessionId).jsonl")
    }

    // MARK: - Installation

    private static let hookScriptName = "agent-visor-state-auggie.sh"
    private static let hookScriptResource = "agent-visor-state-auggie"
    private static let hookScriptExtension = "sh"

    /// Auggie hook events we subscribe to. Matcher is a regex (Auggie's
    /// docs are explicit on this) — claude-code uses glob `"*"`, Auggie
    /// uses `".*"`. SessionStart / SessionEnd take no matcher.
    private static let hookEvents: [HookEventConfig] = [
        .init(name: "PreToolUse", matcher: .regex),
        .init(name: "PostToolUse", matcher: .regex),
        .init(name: "SessionStart", matcher: .none),
        .init(name: "SessionEnd", matcher: .none),
        .init(name: "Stop", matcher: .none),
    ]

    func installHooks() throws {
        // Don't polute ~/.augment for users who don't have Auggie installed.
        // The binary lives at $(npm config get prefix)/bin/auggie typically;
        // a PATH lookup is the cheapest detection.
        guard Self.isAuggieOnPath() else { return }

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
        let scriptAbsPath = hooksDirectory.appendingPathComponent(Self.hookScriptName).path
        let command = "\(python) \(scriptAbsPath)"
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        for event in Self.hookEvents {
            let config = event.matcher.configEntries(command: command)
            if var existingEvent = hooks[event.name] as? [[String: Any]] {
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
                    hooks[event.name] = existingEvent
                }
            } else {
                hooks[event.name] = config
            }
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true
            )
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

    private static func isAuggieOnPath() -> Bool {
        // GUI-launched apps inherit a minimal PATH that excludes nvm,
        // homebrew, npm global prefixes etc. A bare `/usr/bin/which`
        // would miss most real installs. Probe the standard locations
        // ourselves; also treat an existing `~/.augment/` as evidence
        // the user has run auggie at least once.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let augmentDir = home + "/.augment"
        if FileManager.default.fileExists(atPath: augmentDir) {
            return true
        }
        let candidates = [
            "/usr/local/bin/auggie",
            "/opt/homebrew/bin/auggie",
            home + "/.local/bin/auggie",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return true
            }
        }
        // nvm path glob: ~/.nvm/versions/node/*/bin/auggie. We can't
        // glob with FileManager easily; enumerate the versions dir.
        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in versions {
                let path = nvmRoot + "/" + v + "/bin/auggie"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return true
                }
            }
        }
        return false
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

/// One hook event we register with auggie's settings.
private struct HookEventConfig {
    let name: String
    let matcher: AuggieMatcherShape
}

/// Auggie's matcher is a regex, not a glob. `.regex` produces `".*"`
/// (match everything). `.none` omits the matcher entirely — required
/// by SessionStart / SessionEnd / Stop per Auggie docs.
private enum AuggieMatcherShape {
    case regex
    case none

    func configEntries(command: String) -> [[String: Any]] {
        let hookList: [[String: Any]] = [
            ["type": "command", "command": command]
        ]
        switch self {
        case .none:
            return [["hooks": hookList]]
        case .regex:
            return [["matcher": ".*", "hooks": hookList]]
        }
    }
}
