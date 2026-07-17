//
//  AgentDiscoveryUtilities.swift
//  AgentVisor
//
//  Shared helpers used by `AgentProvider.discoverLiveSessions` /
//  `discoverHistoricalSessions` implementations across providers.
//  Earlier this logic was inlined in `ClaudeSessionMonitor` as a
//  3-way switch on agent identity; pulling discovery into providers
//  needed a common home for these process / fs primitives.
//

import AgentVisorCore
import Foundation

enum AgentDiscoveryUtilities {
    /// Synchronous `Process` runner returning stdout. Returns "" on
    /// any error (mirrors the legacy `try? runProcess(...)` pattern in
    /// ClaudeSessionMonitor). `stderr` is discarded.
    nonisolated static func runProcess(_ path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Resolve a process's current working directory via `lsof`.
    /// Used by codex / cursor discovery to pair processes with
    /// transcript files. nil when the process doesn't exist or `lsof`
    /// can't read it.
    nonisolated static func cwdForProcess(pid: Int) -> String? {
        let result = ProcessExecutor.shared.runSync(
            "/usr/sbin/lsof",
            arguments: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        )
        guard case .success(let output) = result else { return nil }
        for line in output.split(separator: "\n") {
            if line.hasPrefix("n") {
                let path = String(line.dropFirst())
                return path.isEmpty ? nil : path
            }
        }
        return nil
    }

    /// Append a discovery log line to the same file
    /// `ClaudeSessionMonitor.writeLog` uses, keeping one tail target
    /// across the app. Provider-side discovery emits identical-shape
    /// lines via this helper so existing log-tailing workflows keep
    /// working.
    nonisolated static func writeLog(_ message: String) {
        let line = "\(Date()): \(message)\n"
        let path = AppPaths.navLogPath
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }
}
