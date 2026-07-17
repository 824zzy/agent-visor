import XCTest
@testable import AgentVisorCore

final class CodexServerRequestRoutingPolicyTests: XCTestCase {
    func testConnectedClientHandlesSupportedRequest() {
        XCTAssertEqual(
            CodexServerRequestRoutingPolicy.route(
                kind: .approval,
                capability: .connected
            ),
            .handle
        )
    }

    func testConnectedClientDefersUnsupportedRequestToDesktopPeer() {
        XCTAssertEqual(
            CodexServerRequestRoutingPolicy.route(
                kind: .unsupported,
                capability: .connected
            ),
            .deferToPeer
        )
    }

    func testManagedClientRejectsUnsupportedRequest() {
        XCTAssertEqual(
            CodexServerRequestRoutingPolicy.route(
                kind: .unsupported,
                capability: .managed
            ),
            .reject
        )
    }
}
