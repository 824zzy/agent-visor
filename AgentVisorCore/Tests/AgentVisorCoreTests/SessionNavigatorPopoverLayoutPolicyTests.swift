import XCTest
@testable import AgentVisorCore

final class SessionNavigatorPopoverLayoutPolicyTests: XCTestCase {
    func testUsesPreferredWidthOnWideScreens() {
        XCTAssertEqual(
            SessionNavigatorPopoverLayoutPolicy.width(forVisibleScreenWidth: 1440),
            560
        )
    }

    func testClampsWidthAgainstVisibleScreenInset() {
        XCTAssertEqual(
            SessionNavigatorPopoverLayoutPolicy.width(forVisibleScreenWidth: 500),
            420
        )
    }

    func testDoesNotShrinkBelowMinimumReadableWidth() {
        XCTAssertEqual(
            SessionNavigatorPopoverLayoutPolicy.width(forVisibleScreenWidth: 200),
            360
        )
    }
}
