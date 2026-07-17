//
//  SlashCommandService.swift
//  AgentVisor
//
//  Disk-side glue for the slash-command autocomplete feature. Pulls
//  enabled plugins out of ~/.claude/settings.json, resolves their cached
//  install dirs, and hands the result to AgentVisorCore's catalog loader.
//

import Foundation
import AgentVisorCore

/// Production filesystem adapter that walks the real disk. Hand-rolled
/// recursion because FileManager.DirectoryEnumerator silently skips
/// symlinks-to-directories, and ~/.claude/skills is full of symlinks
/// like `tdd -> ../../.agents/skills/tdd` that we need to follow.
struct DefaultSlashCommandFileSystem: SlashCommandFileSystem {
    private static let maxDepth = 4

    func enumerateMarkdownFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        var seenDirs = Set<String>()  // resolved paths, prevents symlink loops
        var result: [URL] = []
        walk(directory, depth: 0, seenDirs: &seenDirs, into: &result)
        return result.sorted { $0.path < $1.path }
    }

    private func walk(_ dir: URL, depth: Int, seenDirs: inout Set<String>, into result: inout [URL]) {
        let resolvedDir = dir.resolvingSymlinksInPath().standardizedFileURL.path
        if seenDirs.contains(resolvedDir) { return }
        seenDirs.insert(resolvedDir)
        guard depth <= Self.maxDepth else { return }

        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            return
        }

        // If this directory IS a skill (contains SKILL.md, case-insensitive),
        // the SKILL.md file is the only command artifact. Sibling .md
        // files in the same dir are documentation referenced by the
        // skill, not separate commands. Skip recursion entirely.
        if let skillFile = entries.first(where: { $0.lastPathComponent.uppercased() == "SKILL.MD" }) {
            result.append(skillFile)
            return
        }

        for entry in entries {
            let resolvedEntry = entry.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolvedEntry.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                walk(resolvedEntry, depth: depth + 1, seenDirs: &seenDirs, into: &result)
            } else if entry.pathExtension.lowercased() == "md" {
                let base = entry.lastPathComponent.uppercased()
                if base == "CLAUDE.MD" || base == "README.MD" { continue }
                result.append(entry)
            }
        }
    }

    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Loads the list of enabled plugins from `~/.claude/settings.json` and
/// resolves each to a concrete directory under `~/.claude/plugins/cache`.
/// Tolerates missing / malformed settings — returns `[]` rather than
/// throwing.
enum EnabledPluginLoader {

    static func load() -> [EnabledPlugin] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let pluginsRoot = home.appendingPathComponent(".claude/plugins/cache")

        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Settings stores enabled plugins as { "name@marketplace": true }.
        // A `false` value or a value of `null` means disabled; treat any
        // truthy form leniently.
        let enabled: [String]
        if let bools = json["enabledPlugins"] as? [String: Bool] {
            enabled = bools.compactMap { $0.value ? $0.key : nil }
        } else if let map = json["enabledPlugins"] as? [String: Any] {
            enabled = map.compactMap { (key, value) in
                if let b = value as? Bool, b { return key }
                return nil
            }
        } else {
            return []
        }

        var result: [EnabledPlugin] = []
        for key in enabled {
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0]
            let marketplace = parts[1]
            let cacheDir = pluginsRoot
                .appendingPathComponent(marketplace)
                .appendingPathComponent(name)
            // Resolve to the single version dir, or the latest if multiple.
            guard let versionDirs = try? FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            // Sort descending so the highest version-number folder wins.
            let sorted = versionDirs.sorted { $0.lastPathComponent > $1.lastPathComponent }
            guard let dir = sorted.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else {
                continue
            }
            result.append(EnabledPlugin(name: name, marketplace: marketplace, directory: dir))
        }
        return result
    }
}

/// Builds a fresh `SlashCommandCatalog` from the current disk state.
/// Caller is responsible for caching the result and deciding when to
/// reload (typically: lazily on first `/`, again on chat-panel focus-in).
enum SlashCommandCatalogBuilder {

    /// Build the catalog for a session at `cwd`. Pass `nil` for `cwd`
    /// to skip project-scoped sources (e.g., when no terminal is bound).
    static func build(cwd: URL? = nil) -> SlashCommandCatalog {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userSkills = home.appendingPathComponent(".claude/skills")
        let userCommands = home.appendingPathComponent(".claude/commands")
        let projectSkills = cwd?.appendingPathComponent(".claude/skills")
        let projectCommands = cwd?.appendingPathComponent(".claude/commands")
        let plugins = EnabledPluginLoader.load()

        return SlashCommandCatalogLoader.load(
            fileSystem: DefaultSlashCommandFileSystem(),
            builtins: SlashCommandBuiltins.all,
            userSkillsDir: userSkills,
            userCommandsDir: userCommands,
            projectSkillsDir: projectSkills,
            projectCommandsDir: projectCommands,
            enabledPlugins: plugins
        )
    }
}
