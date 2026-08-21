import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class MenuBarGeometryFreshnessTests: XCTestCase {
    private let builtInAsMain = CGRect(x: 0, y: 0, width: 2056, height: 1329)

    func testGeometryIsFreshWhenTheDisplayStillReportsTheSameFrame() {
        XCTAssertTrue(
            MenuBarGeometryFreshness.isFresh(captured: builtInAsMain, live: builtInAsMain)
        )
        XCTAssertFalse(
            MenuBarGeometryFreshness.isStale(captured: builtInAsMain, live: builtInAsMain)
        )
    }

    func testGeometryIsStaleWhenTheDisplayIsGone() {
        XCTAssertTrue(MenuBarGeometryFreshness.isStale(captured: builtInAsMain, live: nil))
    }

    /// The reported regression: geometry captured while the built-in display
    /// was main kept claiming clicks after the display moved below an
    /// external monitor, so its rectangle floated over the external display.
    func testGeometryIsStaleWhenTheDisplayMoved() {
        let builtInBelowExternal = CGRect(x: 406, y: -1329, width: 2056, height: 1329)
        XCTAssertTrue(
            MenuBarGeometryFreshness.isStale(captured: builtInAsMain, live: builtInBelowExternal),
            "A frame that moved describes a different region in global coordinates."
        )
    }

    func testGeometryIsStaleWhenTheDisplayResized() {
        let scaledMode = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        XCTAssertTrue(
            MenuBarGeometryFreshness.isStale(captured: builtInAsMain, live: scaledMode)
        )
    }
}
