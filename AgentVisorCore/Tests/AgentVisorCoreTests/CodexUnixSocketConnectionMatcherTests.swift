import XCTest
@testable import AgentVisorCore

final class CodexUnixSocketConnectionMatcherTests: XCTestCase {
    private let socketPath = "/Users/test/.codex/app-server-control/app-server-control.sock"

    func testMatchesClientRemoteEndpointToServerSocketDevice() {
        let output = """
        p47435
        f10
        d0x944f99b79ebcf17
        n->0x711a9a83ea624efd
        p72165
        f14
        d0x711a9a83ea624efd
        n/Users/test/.codex/app-server-control/app-server-control.sock
        f31
        d0xcb1003fc681768bb
        n/Users/test/.codex/app-server-control/app-server-control.sock
        """

        XCTAssertTrue(
            CodexUnixSocketConnectionMatcher.hasConnection(
                processIDs: [47435],
                socketPath: socketPath,
                lsofFields: output
            )
        )
    }

    func testDoesNotTreatServerListenerAsClientConnection() {
        let output = """
        p72165
        f31
        d0xcb1003fc681768bb
        n/Users/test/.codex/app-server-control/app-server-control.sock
        """

        XCTAssertFalse(
            CodexUnixSocketConnectionMatcher.hasConnection(
                processIDs: [72165],
                socketPath: socketPath,
                lsofFields: output
            )
        )
    }

    func testRejectsUnrelatedUnixSocketConnection() {
        let output = """
        p20489
        f40
        d0xaaaaaaaaaaaaaaaa
        n->0xbbbbbbbbbbbbbbbb
        p72165
        f31
        d0xcb1003fc681768bb
        n/Users/test/.codex/app-server-control/app-server-control.sock
        """

        XCTAssertFalse(
            CodexUnixSocketConnectionMatcher.hasConnection(
                processIDs: [20489],
                socketPath: socketPath,
                lsofFields: output
            )
        )
    }
}
