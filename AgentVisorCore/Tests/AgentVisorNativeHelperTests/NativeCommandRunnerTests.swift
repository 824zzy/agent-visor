@testable import AgentVisorNativeHelper
import Darwin
import Foundation
import XCTest

final class NativeCommandRunnerTests: XCTestCase {
    func testCapturesOutputAndNonzeroStatusWithoutStderr() throws {
        let result = try XCTUnwrap(NativeCommandRunner.run(
            "/bin/sh", arguments: ["-c", "printf 'session ✓'; printf 'private stderr' >&2; exit 7"], timeout: 1
        ))
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "session ✓")
    }

    func testDiscardedOutputKeepsExitStatus() throws {
        let result = try XCTUnwrap(NativeCommandRunner.run(
            "/bin/sh", arguments: ["-c", "printf ignored; exit 3"], captureOutput: false, timeout: 1
        ))
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.output.isEmpty)
    }

    func testRepeatedSuccessAndLaunchFailureReleaseDescriptors() {
        XCTAssertNotNil(NativeCommandRunner.run("/usr/bin/true", arguments: [], timeout: 1))
        let before = openDescriptorCount()
        for _ in 0..<64 {
            XCTAssertNotNil(NativeCommandRunner.run("/usr/bin/true", arguments: [], timeout: 1))
            XCTAssertNil(NativeCommandRunner.run("/nonexistent/agent-visor-command", arguments: [], timeout: 1))
        }
        XCTAssertLessThanOrEqual(openDescriptorCount(), before + 4)
    }

    func testTimeoutKillsTermResistantChildAndReleasesDescriptors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let before = openDescriptorCount()
        let start = Date()
        let result = NativeCommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; exec /bin/sleep 30", "fixture", pidFile.path],
            timeout: 0.3, terminationGrace: 0.1
        )
        // Ensure a failing assertion still stops only the child owned by this test.
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertLessThanOrEqual(openDescriptorCount(), before + 4)
    }

    private func openDescriptorCount() -> Int {
        var limit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &limit), 0)
        return (0..<Int32(min(limit.rlim_cur, 8_192))).reduce(0) { count, fd in
            count + (fcntl(fd, F_GETFD) >= 0 ? 1 : 0)
        }
    }
}
