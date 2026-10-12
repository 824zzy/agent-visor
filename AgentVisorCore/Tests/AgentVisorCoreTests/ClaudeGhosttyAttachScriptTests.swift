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
            set command of attachCfg to "/usr/bin/env CLAUDE_CODE_DISABLE_TERMINAL_TITLE=0 '/Users/me/.local/bin/claude' --settings '{\\"env\\":{\\"CLAUDE_CODE_DISABLE_TERMINAL_TITLE\\":\\"0\\"}}' attach '62c740e7'"
            set wait after command of attachCfg to false
            set attachWindow to new window with configuration attachCfg
            return id of focused terminal of selected tab of attachWindow
        end tell
        """)
    }
}
