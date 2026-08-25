import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class NativeMenuPanelHitTestTests: XCTestCase {
    func testResolvesOnlyVisibleCapsuleRegionsAndTheSharedUsageSlot() {
        let sessions = ["ready": CGRect(x: 100, y: 20, width: 80, height: 24)]
        let overflow = CGRect(x: 184, y: 20, width: 36, height: 24)
        let usage = [
            "codex": CGRect(x: 224, y: 20, width: 64, height: 24),
            "claude": CGRect(x: 292, y: 20, width: 68, height: 24),
        ]

        func resolve(_ point: CGPoint) -> NativeMenuPanelTarget {
            NativeMenuPanelHitTest.resolve(
                point: point,
                orderedSessionIDs: ["ready"],
                sessionFrames: sessions,
                overflowFrame: overflow,
                orderedUsageIDs: ["codex", "claude"],
                usageFrames: usage
            )
        }

        XCTAssertEqual(resolve(CGPoint(x: 120, y: 32)), .session("ready"))
        XCTAssertEqual(resolve(CGPoint(x: 200, y: 32)), .overflow)
        XCTAssertEqual(resolve(CGPoint(x: 250, y: 32)), .usage("codex"))
        XCTAssertEqual(resolve(CGPoint(x: 320, y: 32)), .usage("claude"))
        XCTAssertEqual(resolve(CGPoint(x: 290, y: 32)), .usage("codex"))
        XCTAssertEqual(resolve(CGPoint(x: 100, y: 20)), .none)
    }
}
