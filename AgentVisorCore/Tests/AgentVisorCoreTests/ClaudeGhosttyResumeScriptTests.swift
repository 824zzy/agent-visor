import XCTest
@testable import AgentVisorCore

final class ClaudeGhosttyResumeScriptTests: XCTestCase {
    func testUsesOnlyRetainedLaunchReferencesAndDoesNotManufactureProviderOverrides() {
        let sessionID = "123e4567-e89b-12d3-a456-426614174000"
        let script = ClaudeGhosttyResumeScript.make(target: NativeHelperGhosttyResumeTarget(
            attemptId: "attempt-1",
            sessionId: sessionID,
            cwd: "/tmp/project",
            executable: "/Users/me/.local/share/claude/versions/2.1.296",
            configRoot: "/Users/me/.claude",
            settingsFile: "/Users/me/settings.json",
            profileState: "verified_absent",
            nonce: "0123456789abcdef0123456789abcdef"
        ), homeDirectory: "/Users/me")

        XCTAssertTrue(script.contains("env -i"))
        XCTAssertTrue(script.contains("--settings"))
        XCTAssertTrue(script.contains(sessionID))
        XCTAssertTrue(script.contains("AGENT_VISOR_RESUME_NONCE='0123456789abcdef0123456789abcdef'"))
        XCTAssertFalse(script.contains("CLAUDE_CODE_DISABLE_TERMINAL_TITLE"))
        XCTAssertFalse(script.contains("API_KEY"))
        XCTAssertFalse(script.contains("processStartToken"))
    }
}
