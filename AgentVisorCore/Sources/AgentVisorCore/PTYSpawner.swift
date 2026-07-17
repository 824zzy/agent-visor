//
//  PTYSpawner.swift
//  AgentVisorCore
//
//  Spawns a child process attached to a pseudo-terminal so the parent
//  owns one end (the primary fd) and can read/write silently. This is
//  how agent-visor hosts interactive `claude` for Cursor workspaces
//  without going through a visible terminal emulator: the spawned
//  `claude` sees a real TTY on fd 1 (so it runs in interactive mode,
//  using subscription auth), but the "terminal" is the parent process,
//  not a window the user has to focus.
//
//  Output of the spawned process is intentionally read-and-discarded by
//  callers — agent-visor's source of truth for chat state is JSONL,
//  not terminal scrollback.
//

import Foundation
import Darwin

public enum PTYSpawner {

    public struct SpawnResult {
        public let primaryFD: Int32
        public let pid: pid_t

        public init(primaryFD: Int32, pid: pid_t) {
            self.primaryFD = primaryFD
            self.pid = pid
        }
    }

    public enum SpawnError: Error, Equatable {
        case openPTYFailed(errno: Int32)
        case spawnFailed(errno: Int32)
    }

    /// Spawn `executable` with `arguments` under a freshly allocated
    /// pty. The returned `primaryFD` is non-blocking — read/write with
    /// `poll(2)` or a `DispatchSourceRead`.
    ///
    /// `windowSize` is set on the pty before spawn so TUIs that key
    /// off `winsize` (claude does) have a sane initial layout to lay
    /// against. We discard the rendered output anyway, but a zero
    /// winsize tends to make TUI libraries fall over.
    public static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        windowSize: (rows: UInt16, cols: UInt16) = (24, 80)
    ) throws -> SpawnResult {

        // 1. Allocate the pty pair with the desired initial winsize.
        var primary: Int32 = -1
        var replica: Int32 = -1
        var ws = winsize(
            ws_row: windowSize.rows,
            ws_col: windowSize.cols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let openRC = withUnsafeMutablePointer(to: &ws) { wsPtr in
            openpty(&primary, &replica, nil, nil, wsPtr)
        }
        guard openRC == 0 else {
            throw SpawnError.openPTYFailed(errno: errno)
        }

        // Make the parent end non-blocking so DispatchSource readers
        // (and tests using poll) don't hang on empty reads.
        let flags = fcntl(primary, F_GETFL)
        _ = fcntl(primary, F_SETFL, flags | O_NONBLOCK)

        // 2. File actions: in the child, the replica becomes 0/1/2 and
        // both the original primary and replica fds are closed (the
        // dup'd copies on 0/1/2 are what stays). Order matters: we
        // dup2 BEFORE closing replica so dup2's source is still open.
        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(primary); close(replica)
            throw SpawnError.spawnFailed(errno: errno)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_addclose(&fileActions, primary)
        posix_spawn_file_actions_adddup2(&fileActions, replica, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, replica, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, replica, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, replica)

        // 3. Attributes: SETSID so the child becomes its own session
        // leader. macOS doesn't auto-establish a controlling terminal
        // from posix_spawn, but for our use (no /dev/tty access, no
        // job control) that's fine — the dup2'd replica being a TTY
        // on fd 1 is what claude checks.
        var attr: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else {
            close(primary); close(replica)
            throw SpawnError.spawnFailed(errno: errno)
        }
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        // 4. Build argv / envp as null-terminated C arrays.
        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { if let p = $0 { free(p) } } }

        let envSource = environment ?? ProcessInfo.processInfo.environment
        let envp: [UnsafeMutablePointer<CChar>?] =
            envSource.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { if let p = $0 { free(p) } } }

        // 5. Spawn. Parent closes the replica end regardless of result.
        var pid: pid_t = 0
        let spawnRC = posix_spawn(&pid, executable, &fileActions, &attr, argv, envp)
        close(replica)

        guard spawnRC == 0 else {
            close(primary)
            throw SpawnError.spawnFailed(errno: spawnRC)
        }

        return SpawnResult(primaryFD: primary, pid: pid)
    }
}
