import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class NativeMenuPanelHitTestTests: XCTestCase {
    func testResolvesOnlyVisibleCapsuleRegions() {
        let sessions = ["ready": CGRect(x: 100, y: 20, width: 80, height: 24)]
        let overflow = CGRect(x: 184, y: 20, width: 36, height: 24)

        XCTAssertEqual(
            NativeMenuPanelHitTest.resolve(
                point: CGPoint(x: 120, y: 32),
                orderedSessionIDs: ["ready"],
                sessionFrames: sessions,
                overflowFrame: overflow
            ),
            .session("ready")
        )
        XCTAssertEqual(
            NativeMenuPanelHitTest.resolve(
                point: CGPoint(x: 200, y: 32),
                orderedSessionIDs: ["ready"],
                sessionFrames: sessions,
                overflowFrame: overflow
            ),
            .overflow
        )
        XCTAssertEqual(
            NativeMenuPanelHitTest.resolve(
                point: CGPoint(x: 100, y: 20),
                orderedSessionIDs: ["ready"],
                sessionFrames: sessions,
                overflowFrame: overflow
            ),
            .none
        )
    }
}
