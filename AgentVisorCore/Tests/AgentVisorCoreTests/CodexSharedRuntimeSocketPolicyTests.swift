import XCTest
@testable import AgentVisorCore

final class CodexSharedRuntimeSocketPolicyTests: XCTestCase {
    func testPartialLsofResultStillDetectsConnectedDesktopProcess() {
        let socketPath = "/Users/test/.codex/app-server-control/app-server-control.sock"
        let output = """
        p47435
        f10
        d0x944f99b79ebcf17
        n->0x711a9a83ea624efd
        p72165
        f14
        d0x711a9a83ea624efd
        n/Users/test/.codex/app-server-control/app-server-control.sock
        """

        XCTAssertTrue(
            CodexSharedRuntimeSocketPolicy.hasConnection(
                processIDs: [47435],
                socketPath: socketPath,
                lsofResult: ProcessOutputSnapshot(
                    output: output,
                    exitCode: 1
                )
            )
        )
    }
}
