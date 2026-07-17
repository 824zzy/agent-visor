//
//  SpawnedSessionManager.swift
//  AgentVisor
//
//  Owns the lifecycle of `claude` subprocesses that agent-visor
//  spawns under a pty (the Cursor silent-send path). For each spawned
//  session we hold the primary pty fd, the child pid, a background
//  drain source that pulls and discards TUI output, and a process
//  source that fires when the child exits.
//
//  Why this exists: Cursor's claude-code extension owns the stdin of
//  the claude processes it launches, so agent-visor cannot inject
//  text into those sessions without focus-stealing keystroke tricks
//  (proven broken). The escape hatch is to spawn our own `claude`
//  under a pty we control end-to-end — the pty's primary fd is our
//  silent send channel. See plan: atomic-nibbling-brooks.md.
//
//  This actor does NOT integrate with `SessionStore` yet — that's a
//  separate wiring step. It exposes lifecycle events via an observer
//  closure for callers to bridge.
//

import Foundation
import Darwin
import os.log
import AgentVisorCore

actor SpawnedSessionManager {

    static let shared = SpawnedSessionManager()

    // MARK: - Public types

    public struct SpawnSpec: Sendable {
        public let cwd: String
        public let attachCursorIDE: Bool
        /// Override `claude` binary path. Defaults to a `which`-style
        /// resolution; tests can swap in `/bin/cat` to exercise the
        /// orchestration without depending on claude.
        public let executablePath: String

        public init(
            cwd: String,
            attachCursorIDE: Bool = true,
            executablePath: String = SpawnedSessionManager.defaultClaudeBinaryPath()
        ) {
            self.cwd = cwd
            self.attachCursorIDE = attachCursorIDE
            self.executablePath = executablePath
        }
    }

    public struct SpawnInfo: Sendable, Equatable {
        public let sessionId: String
        public let pid: pid_t
        public let cwd: String
        public let attachedCursorPort: Int?
    }

    public enum SpawnError: Error, Equatable {
        case executableNotFound(path: String)
        case ptyFailed(String)
    }

    public enum LifecycleEvent: Sendable {
        case spawned(SpawnInfo)
        case exited(sessionId: String, status: Int32)
    }

    // MARK: - Claimed-IDs registry (synchronous, nonisolated)

    /// Set of sessionIds agent-visor itself has spawned. Used by
    /// `SessionStore.originForHostedSession` (a sync code path inside
    /// another actor) to decide that a discovered session is
    /// `.visorSpawned` rather than the default `.terminal` /
    /// `.cursorObserved` inferred from TTY. Updated from `spawn()`
    /// (insert) and `handleChildExit()` (no-op — we keep the claim so
    /// late-arriving hook events still get the right origin).
    nonisolated private static let claimedLock = NSLock()
    nonisolated(unsafe) private static var _claimedIds: Set<String> = []

    nonisolated public static func isVisorSpawned(_ sessionId: String) -> Bool {
        claimedLock.lock()
        defer { claimedLock.unlock() }
        return _claimedIds.contains(sessionId)
    }

    nonisolated private static func registerClaim(_ sessionId: String) {
        claimedLock.lock()
        defer { claimedLock.unlock() }
        _claimedIds.insert(sessionId)
    }

    // MARK: - Private state

    private let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "SpawnedSessions")

    private struct SpawnedClaude {
        let info: SpawnInfo
        let primaryFD: Int32
        let drainSource: DispatchSourceRead
        let exitSource: DispatchSourceProcess
        let debugBuffer: RingBuffer
    }

    private var sessions: [String: SpawnedClaude] = [:]
    private var observers: [UUID: @Sendable (LifecycleEvent) -> Void] = [:]

    /// Last 64 KiB of TUI output, kept for diagnostics only. The
    /// authoritative state for the chat is JSONL on disk.
    private static let debugBufferCapacity = 64 * 1024

    // MARK: - Lifecycle event observers

    @discardableResult
    public func addObserver(
        _ block: @escaping @Sendable (LifecycleEvent) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }

    public func removeObserver(id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func emit(_ event: LifecycleEvent) {
        for block in observers.values {
            block(event)
        }
    }

    // MARK: - Spawn

    /// Spawn a fresh `claude` session under a pty.
    /// Returns a `SpawnInfo` synchronously; lifecycle events arrive
    /// later via the observer closure.
    public func spawn(_ spec: SpawnSpec) throws -> SpawnInfo {
        guard FileManager.default.isExecutableFile(atPath: spec.executablePath) else {
            throw SpawnError.executableNotFound(path: spec.executablePath)
        }

        let sessionId = UUID().uuidString.lowercased()
        // Claim BEFORE spawning so the very first hook event (which
        // can fire within milliseconds) sees the visor-spawn origin.
        Self.registerClaim(sessionId)
        var args = [String]()
        var attachedPort: Int?

        // claude needs --session-id (lowercase UUID) to keep its
        // JSONL path stable from our caller's perspective.
        if spec.executablePath.hasSuffix("/claude") {
            args += ["--session-id", sessionId]
        }

        // Wire to the Cursor extension's MCP server if there's a
        // matching lock file. No match → spawn anyway, just without
        // IDE features.
        if spec.attachCursorIDE,
           let lockMatch = CursorMCPConfigBuilder.findBestLock(
               forCwd: spec.cwd,
               lockDir: NSHomeDirectory() + "/.claude/ide"
           ),
           let mcpConfig = CursorMCPConfigBuilder.build(forCwd: spec.cwd) {
            args += ["--mcp-config", mcpConfig]
            attachedPort = lockMatch.port
        }

        // Child must inherit a cwd. posix_spawn doesn't take a cwd
        // arg; we set it on the parent before spawning, then restore.
        // PTYSpawner inherits the parent's cwd at spawn time.
        let fm = FileManager.default
        let savedCwd = fm.currentDirectoryPath
        if !fm.changeCurrentDirectoryPath(spec.cwd) {
            logger.error("could not chdir to spawn cwd: \(spec.cwd, privacy: .public)")
        }
        defer { _ = fm.changeCurrentDirectoryPath(savedCwd) }

        let result: PTYSpawner.SpawnResult
        do {
            result = try PTYSpawner.spawn(
                executable: spec.executablePath,
                arguments: args
            )
        } catch {
            throw SpawnError.ptyFailed(String(describing: error))
        }

        let info = SpawnInfo(
            sessionId: sessionId,
            pid: result.pid,
            cwd: spec.cwd,
            attachedCursorPort: attachedPort
        )

        // Background drain — reads primary fd into a ring buffer so
        // claude's tty doesn't block on a full pipe. We never parse
        // these bytes; they're a diagnostic.
        let drainQueue = DispatchQueue(
            label: AppBranding.loggerSubsystem + ".spawn.\(sessionId.prefix(8))",
            qos: .utility
        )
        let drainSource = DispatchSource.makeReadSource(
            fileDescriptor: result.primaryFD,
            queue: drainQueue
        )
        let debugBuffer = RingBuffer(capacity: Self.debugBufferCapacity)
        let fd = result.primaryFD
        drainSource.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                debugBuffer.append(Data(buf.prefix(Int(n))))
            }
        }
        drainSource.resume()

        // Child-exit watcher. macOS DispatchSourceProcess fires .exit
        // for any monitored pid the calling process is allowed to
        // observe (which it always is for its own children).
        let exitQueue = DispatchQueue(
            label: AppBranding.loggerSubsystem + ".spawn-exit.\(sessionId.prefix(8))",
            qos: .utility
        )
        let exitSource = DispatchSource.makeProcessSource(
            identifier: result.pid,
            eventMask: .exit,
            queue: exitQueue
        )
        let sidForExit = sessionId
        let pidForExit = result.pid
        exitSource.setEventHandler { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pidForExit, &status, WNOHANG)
            Task { await self?.handleChildExit(sessionId: sidForExit, status: status) }
        }
        exitSource.resume()

        sessions[sessionId] = SpawnedClaude(
            info: info,
            primaryFD: result.primaryFD,
            drainSource: drainSource,
            exitSource: exitSource,
            debugBuffer: debugBuffer
        )

        logger.info(
            "spawned session=\(sessionId.prefix(8), privacy: .public) pid=\(info.pid) cwd=\(spec.cwd, privacy: .public) ide-port=\(attachedPort?.description ?? "none", privacy: .public)"
        )
        emit(.spawned(info))
        return info
    }

    // MARK: - Send / cancel / kill

    /// Write a user message to a spawned session's pty. Appends `\r`
    /// (terminal Enter) so claude's TUI input box submits.
    public func writeMessage(_ text: String, to sessionId: String) throws {
        guard let session = sessions[sessionId] else {
            throw SpawnError.executableNotFound(path: "session:\(sessionId)")
        }
        let payload = Data((text + "\r").utf8)
        let n = payload.withUnsafeBytes { ptr -> ssize_t in
            write(session.primaryFD, ptr.baseAddress, ptr.count)
        }
        if n < 0 {
            logger.error("write failed errno=\(errno) session=\(sessionId.prefix(8), privacy: .public)")
        }
    }

    /// Send SIGINT (Ctrl-C) to interrupt the current generation
    /// without ending the session. claude's TUI handles it as cancel.
    public func cancel(_ sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        // 0x03 is the ETX byte; writing it to the pty is equivalent to
        // typing Ctrl-C in a terminal — the line discipline turns it
        // into SIGINT for the foreground process.
        let etx: [UInt8] = [0x03]
        _ = etx.withUnsafeBufferPointer { write(session.primaryFD, $0.baseAddress, 1) }
    }

    /// Terminate the spawned process for `sessionId`. SIGTERM first;
    /// the exit watcher cleans up state when the child dies.
    public func killSession(_ sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        logger.info("killSession \(sessionId.prefix(8), privacy: .public) pid=\(session.info.pid)")
        kill(session.info.pid, SIGTERM)
    }

    /// Kill every spawned session. Called from AppDelegate on quit.
    public func terminateAll() {
        for (sid, session) in sessions {
            logger.info("terminateAll \(sid.prefix(8), privacy: .public) pid=\(session.info.pid)")
            kill(session.info.pid, SIGTERM)
        }
    }

    public func isManaged(_ sessionId: String) -> Bool {
        sessions[sessionId] != nil
    }

    public func debugBuffer(_ sessionId: String) -> Data {
        sessions[sessionId]?.debugBuffer.snapshot() ?? Data()
    }

    public func managedSessionIds() -> Set<String> {
        Set(sessions.keys)
    }

    // MARK: - Child exit

    private func handleChildExit(sessionId: String, status: Int32) {
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        session.drainSource.cancel()
        session.exitSource.cancel()
        close(session.primaryFD)
        logger.info("exited session=\(sessionId.prefix(8), privacy: .public) status=\(status)")
        emit(.exited(sessionId: sessionId, status: status))
    }

    // MARK: - Binary path resolution

    /// Best-effort `which claude` lookup at app launch. Cached.
    nonisolated public static func defaultClaudeBinaryPath() -> String {
        if let cached = cachedClaudePath.value { return cached }
        let resolved = resolveClaudeBinaryPath()
        cachedClaudePath.value = resolved
        return resolved
    }

    private static let cachedClaudePath = AtomicReference<String?>(nil)

    private static func resolveClaudeBinaryPath() -> String {
        // Common install locations, in order of preference.
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: invoke `/usr/bin/which`.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if let str = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        } catch {
            // fall through
        }
        return candidates[0]  // sensible default even if missing
    }
}

// MARK: - Small thread-safe wrappers

/// Append-only ring buffer keeping the most recent N bytes. Used for
/// surfacing recent TUI output in a diagnostics panel.
nonisolated final class RingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    private let capacity: Int

    nonisolated init(capacity: Int) {
        self.capacity = capacity
        self.data = Data()
        self.data.reserveCapacity(capacity)
    }

    nonisolated func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > capacity {
            data.removeFirst(data.count - capacity)
        }
    }

    nonisolated func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Minimal atomic reference for the cached binary path. Doesn't need
/// to be fancy — set-once-then-read.
nonisolated final class AtomicReference<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    nonisolated init(_ value: T) { self._value = value }

    nonisolated var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
