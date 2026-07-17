import XCTest
@testable import AgentVisorCore

final class TerminalFocusVerificationPolicyTests: XCTestCase {
    func testSelectedPaneIsNotSuccessfulWhileHostRemainsInBackground() {
        XCTAssertFalse(
            TerminalFocusVerificationPolicy.isSuccessful(
                selectedTargetMatches: true,
                hostIsFrontmost: false
            )
        )
    }

    func testFrontmostHostIsNotSuccessfulWhenWrongPaneIsSelected() {
        XCTAssertFalse(
            TerminalFocusVerificationPolicy.isSuccessful(
                selectedTargetMatches: false,
                hostIsFrontmost: true
            )
        )
    }

    func testFrontmostHostAndExactPaneAreSuccessful() {
        XCTAssertTrue(
            TerminalFocusVerificationPolicy.isSuccessful(
                selectedTargetMatches: true,
                hostIsFrontmost: true
            )
        )
    }
}
