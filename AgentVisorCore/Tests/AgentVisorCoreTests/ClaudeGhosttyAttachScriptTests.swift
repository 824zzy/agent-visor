import XCTest
@testable import AgentVisorCore

final class ClaudeGhosttyAttachScriptTests: XCTestCase {
    func testOpensOneWindowInTheRunningGhosttyWithAQuotedCommand() {
        let script = ClaudeGhosttyAttachScript.make(target: NativeHelperClaudeAttachTarget(
            cwd: "/tmp/it's \"here\"",
            executable: "/Users/me/.local/bin/claude",
            jobId: "62c740e7"
        ))

        XCTAssertEqual(script, """
        tell application "Ghostty"
            activate
            set attachCfg to new surface configuration
            set initial working directory of attachCfg to "/tmp/it's \\"here\\""
            set command of attachCfg to "'/Users/me/.local/bin/claude' attach '62c740e7'"
            new window with configuration attachCfg
            return "ok"
        end tell
        """)
    }
}
