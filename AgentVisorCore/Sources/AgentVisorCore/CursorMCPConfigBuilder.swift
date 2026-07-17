//
//  CursorMCPConfigBuilder.swift
//  AgentVisorCore
//
//  Picks the right `~/.claude/ide/<port>.lock` for a given cwd and
//  builds the `--mcp-config` JSON string we hand to a visor-spawned
//  `claude` process. Routing this explicitly (instead of relying on
//  `claude --ide` auto-discovery) lets us support multi-window Cursor
//  cleanly — `--ide` errors out with "exactly one valid IDE" when
//  multiple lock files exist.
//
//  Lock file schema (observed):
//  {
//    "pid": 366,
//    "workspaceFolders": ["/Users/me/foo"],
//    "ideName": "Cursor",
//    "transport": "ws",
//    "authToken": "5e0b06ca-..."
//  }
//
//  Port is encoded in the filename: "29478.lock" → port 29478.
//

import Foundation

public enum CursorMCPConfigBuilder {

    /// Returns the `--mcp-config` JSON string for the Cursor extension
    /// whose `workspaceFolders` best-prefixes `cwd`, or `nil` if no
    /// lock file matches. Longest-prefix wins — sub-workspaces beat
    /// their containing monorepos.
    ///
    /// `lockDir` defaults to `~/.claude/ide` but is injectable for
    /// tests.
    public static func build(
        forCwd cwd: String,
        lockDir: String = NSHomeDirectory() + "/.claude/ide"
    ) -> String? {
        guard let match = findBestLock(forCwd: cwd, lockDir: lockDir) else {
            return nil
        }
        return encode(port: match.port, authToken: match.authToken)
    }

    /// All workspace folders currently advertised by Cursor extension
    /// hosts, deduped and sorted. UI uses this to populate the spawn
    /// picker. Returns `[]` if `lockDir` is missing.
    public static func listWorkspaces(
        lockDir: String = NSHomeDirectory() + "/.claude/ide"
    ) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: lockDir) else {
            return []
        }
        var folders = Set<String>()
        for entry in entries where entry.hasSuffix(".lock") {
            let url = URL(fileURLWithPath: lockDir).appendingPathComponent(entry)
            guard let data = fm.contents(atPath: url.path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["workspaceFolders"] as? [String]
            else { continue }
            for f in list where !f.isEmpty {
                folders.insert(f)
            }
        }
        return folders.sorted()
    }

    // MARK: - Lock discovery

    public struct LockMatch: Equatable {
        public let port: Int
        public let authToken: String
        public let matchedFolder: String
    }

    public static func findBestLock(forCwd cwd: String, lockDir: String) -> LockMatch? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: lockDir) else {
            return nil
        }

        var best: LockMatch?
        for entry in entries where entry.hasSuffix(".lock") {
            let stem = (entry as NSString).deletingPathExtension
            guard let port = Int(stem) else { continue }

            let url = URL(fileURLWithPath: lockDir).appendingPathComponent(entry)
            guard let data = fm.contents(atPath: url.path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folders = json["workspaceFolders"] as? [String],
                  let authToken = json["authToken"] as? String
            else { continue }

            for folder in folders {
                guard cwd == folder || cwd.hasPrefix(folder + "/") else { continue }
                if let existing = best, existing.matchedFolder.count >= folder.count {
                    continue
                }
                best = LockMatch(port: port, authToken: authToken, matchedFolder: folder)
            }
        }
        return best
    }

    // MARK: - Encoding

    private static func encode(port: Int, authToken: String) -> String {
        // Encodable structs + JSONEncoder so we can disable slash
        // escaping. claude's JSON parser handles either form, but
        // `ws://127.0.0.1:…` is what the lockfile spec uses and
        // what users see in logs, so we keep it un-escaped.
        let config = Config(mcpServers: [
            "cursor-ide": Config.Server(
                transport: "ws",
                url: "ws://127.0.0.1:\(port)",
                headers: ["x-claude-code-ide-authorization": authToken]
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(config),
              let str = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return str
    }

    private struct Config: Encodable {
        let mcpServers: [String: Server]
        struct Server: Encodable {
            let transport: String
            let url: String
            let headers: [String: String]
        }
    }
}
