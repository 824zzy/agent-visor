import XCTest
import Darwin
@testable import AgentVisorCore

final class PTYSpawnerTests: XCTestCase {

    func testCatRoundTrip() throws {
        // Spawn /bin/cat under a pty. Write a line to the primary, read it
        // back. With the default termios (echo on, canonical mode), the
        // tty driver echoes our write back to the primary, and cat copies
        // its stdin to stdout — both land on the primary. Two ways for
        // "hello" to appear on the primary is fine; we just assert that
        // it does, within a generous timeout.
        let result = try PTYSpawner.spawn(executable: "/bin/cat", arguments: [])
        defer { cleanup(result) }

        let primary = FileHandle(fileDescriptor: result.primaryFD, closeOnDealloc: false)
        try primary.write(contentsOf: Data("hello\n".utf8))

        let received = readUntilContains("hello", fd: result.primaryFD, timeout: 3.0)
        XCTAssertTrue(received.contains("hello"),
                      "expected 'hello' echo, got: \(received.debugDescription)")
    }

    func testSpawnNonExistentExecutableThrows() {
        XCTAssertThrowsError(
            try PTYSpawner.spawn(executable: "/nonexistent/bin", arguments: [])
        )
    }

    func testChildHasTTYOnStdout() throws {
        // /usr/bin/tty prints the slave pty's device path when stdout is
        // a tty, "not a tty" otherwise. Proves the spawned child sees a
        // real terminal on fd 1 — the property `claude` checks with
        // `isatty(STDOUT_FILENO)` to decide interactive vs --print mode.
        let result = try PTYSpawner.spawn(executable: "/usr/bin/tty", arguments: [])
        defer { cleanup(result) }

        let received = readUntilContains("/dev/", fd: result.primaryFD, timeout: 3.0)
        XCTAssertTrue(received.contains("/dev/"),
                      "expected /dev/<pty> from tty(1), got: \(received.debugDescription)")
        XCTAssertFalse(received.contains("not a tty"),
                       "child saw non-tty stdout: \(received.debugDescription)")
    }

    // MARK: - helpers

    private func cleanup(_ result: PTYSpawner.SpawnResult) {
        kill(result.pid, SIGTERM)
        var status: Int32 = 0
        _ = waitpid(result.pid, &status, 0)
        close(result.primaryFD)
    }

    /// Poll-based read with timeout. `availableData` on a FileHandle
    /// blocks; we want a bounded wait that yields what arrived so the
    /// test can assert against it.
    private func readUntilContains(_ needle: String, fd: Int32, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var accumulator = ""
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 100)
            if pr > 0, pfd.revents & Int16(POLLIN) != 0 {
                let n = read(fd, &buf, buf.count)
                if n > 0, let s = String(bytes: buf.prefix(Int(n)), encoding: .utf8) {
                    accumulator += s
                    if accumulator.contains(needle) {
                        return accumulator
                    }
                }
            }
        }
        return accumulator
    }
}
