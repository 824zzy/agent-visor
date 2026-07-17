import XCTest
@testable import AgentVisorCore

final class CodexThreadActivityPolicyTests: XCTestCase {
    func testRolloutMTimeWinsWhenSqliteUpdatedAtIsStale() {
        XCTAssertEqual(
            CodexThreadActivityPolicy.effectiveUpdatedAt(
                sqliteUpdatedAt: 100,
                rolloutModifiedAt: 250
            ),
            250
        )
    }
}
