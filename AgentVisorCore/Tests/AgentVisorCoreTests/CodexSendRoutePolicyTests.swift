import XCTest
@testable import AgentVisorCore

final class CodexSendRoutePolicyTests: XCTestCase {
    func testConnectedSessionRoutesToSharedRuntimeNotManagedClient() {
        XCTAssertEqual(
            CodexSendRoutePolicy.route(for: .connected),
            .sharedAppServer
        )
    }

    func testObservedSessionHasNoSendRoute() {
        XCTAssertEqual(CodexSendRoutePolicy.route(for: .observed), .unavailable)
    }

    func testManagedSessionKeepsExistingAppServerRoute() {
        XCTAssertEqual(CodexSendRoutePolicy.route(for: .managed), .managedAppServer)
    }
}
