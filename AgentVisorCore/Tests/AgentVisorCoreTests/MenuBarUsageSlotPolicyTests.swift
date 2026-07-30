import XCTest
@testable import AgentVisorCore

final class MenuBarUsageSlotPolicyTests: XCTestCase {
    func testCombinedSlotUsesExactProviderWidthsPlusOneInternalGap() {
        let compact = MenuBarUsageSlotPolicy.layout(
            usableWidth: 500,
            spacing: 4,
            codexWidth: 64,
            claudeWidth: 84
        )
        let expanded = MenuBarUsageSlotPolicy.layout(
            usableWidth: 500,
            spacing: 4,
            codexWidth: 114,
            claudeWidth: 84
        )

        XCTAssertEqual(compact.usageSlotWidth, 152)
        XCTAssertEqual(expanded.usageSlotWidth, 202)
    }

    func testLayoutReservesProviderCapsulesAndGapsFromSessions() {
        let layout = MenuBarUsageSlotPolicy.layout(
            usableWidth: 500,
            spacing: 4,
            codexWidth: 64,
            claudeWidth: 84
        )

        XCTAssertTrue(layout.showsCodex)
        XCTAssertTrue(layout.showsClaude)
        XCTAssertEqual(layout.sessionUsableWidth, 344)
    }
}
