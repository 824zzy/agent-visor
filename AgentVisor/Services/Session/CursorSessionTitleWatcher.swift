//
//  CursorSessionTitleWatcher.swift
//  AgentVisor
//
//  Tails Cursor's claude-code extension log files to extract per-session
//  titles. The webview-to-extension protocol sends `update_session_state`
//  and `rename_session` messages with {sessionId, title} fields whenever
//  a chat is renamed (which Cursor does automatically based on
//  conversation content). We mirror those titles into
//  CursorSessionTitleStore so agent-visor's pills can show the same
//  name Cursor uses.
//
//  Log path: ~/Library/Application Support/Cursor/logs/<timestamp>/
//            window<N>/exthost/Anthropic.claude-code/Claude VSCode.log
//
//  Each Cursor process run creates a new timestamped dir; each window
//  has its own subdir. We watch all CC logs under the most-recent
//  timestamped dir, and re-detect every 30 s so new windows / log
//  rotations are picked up without restart.
//

import AgentVisorCore
import Foundation
import os.log

private let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "TitleWatcher")

@MainActor
final class CursorSessionTitleWatcher {
    static let shared = CursorSessionTitleWatcher()

    private var fileWatchers: [String: FileLogTail] = [:]
    private var redetectTimer: Timer?

    func start() {
        redetect()
        redetectTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task { @MainActor in CursorSessionTitleWatcher.shared.redetect() }
        }
    }

    func stop() {
        redetectTimer?.invalidate()
        redetectTimer = nil
        for (_, w) in fileWatchers { w.stop() }
        fileWatchers.removeAll()
    }

    private func redetect() {
        let logsRoot = NSHomeDirectory() + "/Library/Application Support/Cursor/logs"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: logsRoot) else { return }
        // Timestamp-named dirs (e.g. 20260515T115104). Latest is the
        // currently-running Cursor process.
        let stampDirs = dirs.filter { $0.first.map { ("0"..."9").contains($0) } ?? false }
        guard let latest = stampDirs.sorted().last else { return }
        let activeRoot = logsRoot + "/" + latest

        guard let windows = try? fm.contentsOfDirectory(atPath: activeRoot) else { return }
        for window in windows where window.hasPrefix("window") {
            let path = activeRoot + "/" + window
                + "/exthost/Anthropic.claude-code/Claude VSCode.log"
            guard fm.fileExists(atPath: path) else { continue }
            if fileWatchers[path] == nil {
                let w = FileLogTail(path: path) { sessionId, title in
                    Task { @MainActor in
                        CursorSessionTitleStore.shared.setTitle(title, forSessionId: sessionId)
                    }
                }
                w.start()
                fileWatchers[path] = w
                logger.info("Watching CC log: \(path, privacy: .public)")
            }
        }
    }
}

// MARK: - File tailer

/// Tails one log file: on initial open, scans existing content for
/// title events; thereafter, on file-extend events, parses appended
/// bytes. Each parsed (sessionId, title) pair is delivered via the
/// callback.
private final class FileLogTail {
    private let path: String
    private let onEvent: (String, String) -> Void

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var residual: String = ""
    private let queue = DispatchQueue(
        label: AppBranding.loggerSubsystem + ".titletail",
        qos: .utility
    )

    init(path: String, onEvent: @escaping (String, String) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [weak self] in self?.startInternal() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }
    }

    private func startInternal() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        fileHandle = handle
        // Initial scan: read entire file once to seed the title map.
        // Existing CC logs can be tens of MB; the parse is fast (we
        // pre-filter lines for the literal substring `"title":`).
        readNew()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.readNew() }
        src.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }
        source = src
        src.resume()
    }

    private func readNew() {
        guard let h = fileHandle else { return }
        do {
            try h.seek(toOffset: offset)
            let data = h.readDataToEndOfFile()
            offset += UInt64(data.count)
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            let full = residual + chunk
            let parts = full.split(separator: "\n", omittingEmptySubsequences: false)
            residual = String(parts.last ?? "")
            for line in parts.dropLast() {
                parseLine(String(line))
            }
        } catch {
            // File may be rotated or vanished. Re-detect will rebuild.
        }
    }

    private func parseLine(_ line: String) {
        // Pre-filter: only lines carrying a title field. Avoids JSON
        // parsing the bulk of the log (settings updates, MCP traffic,
        // claude-process stdout, etc.).
        guard line.contains("\"title\":") else { return }
        guard let sessionId = jsonField("sessionId", in: line),
              let title = jsonField("title", in: line)
        else { return }
        onEvent(sessionId, title)
    }

    /// Extract a JSON string field by name from a log line. Handles
    /// backslash-escaped characters inside the string. Returns nil if
    /// the field is missing or the string is unterminated.
    private func jsonField(_ name: String, in line: String) -> String? {
        let key = "\"\(name)\":\""
        guard let r = line.range(of: key) else { return nil }
        var i = r.upperBound
        var out = ""
        while i < line.endIndex {
            let c = line[i]
            if c == "\\" {
                let next = line.index(after: i)
                if next < line.endIndex {
                    let escaped = line[next]
                    switch escaped {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    default: out.append(escaped)
                    }
                    i = line.index(after: next)
                    continue
                }
            }
            if c == "\"" { return out }
            out.append(c)
            i = line.index(after: i)
        }
        return nil
    }
}
