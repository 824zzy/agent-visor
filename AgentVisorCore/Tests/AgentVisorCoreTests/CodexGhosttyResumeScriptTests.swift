import XCTest
@testable import AgentVisorCore

final class CodexGhosttyResumeScriptTests: XCTestCase {
    func testUsesFullUUIDv7HomeAndCdWithoutProfileOverlay() {
        let threadID = "019f3931-ec11-7f31-8400-1c8624aa9e4d"
        let script = CodexGhosttyResumeScript.make(target: NativeHelperGhosttyResumeTarget(
            attemptId: "attempt-1",
            provider: "codex_cli",
            sessionId: threadID,
            cwd: "/tmp/project",
            executable: "/Users/me/.local/bin/codex",
            configRoot: "/Users/me/.codex-work",
            profileState: "verified_absent",
            nonce: "0123456789abcdef0123456789abcdef"
        ), homeDirectory: "/Users/me")

        XCTAssertTrue(script.contains("CODEX_HOME"))
        XCTAssertTrue(script.contains(threadID))
        XCTAssertTrue(script.contains("--cd"))
        XCTAssertFalse(script.contains("--profile"))
        XCTAssertFalse(script.contains("processStartToken"))
        XCTAssertFalse(script.contains("API_KEY"))
    }

    func testEmitsOnlyObservedProfileName() {
        let script = CodexGhosttyResumeScript.make(target: NativeHelperGhosttyResumeTarget(
            attemptId: "attempt-1",
            provider: "codex_cli",
            sessionId: "019f3931-ec11-7f31-8400-1c8624aa9e4d",
            cwd: "/tmp/project",
            executable: "/Users/me/.local/bin/codex",
            configRoot: "/Users/me/.codex",
            profileRef: "work",
            profileState: "present",
            nonce: "0123456789abcdef0123456789abcdef"
        ), homeDirectory: "/Users/me")

        XCTAssertTrue(script.contains("--profile 'work'"))
        XCTAssertFalse(script.contains("--profile 'default'"))
    }
}
