import XCTest
@testable import AgentVisorCore

final class NativeMenuFailureDismissalPolicyTests: XCTestCase {
    func testOnlyExplicitFailureAlertsExposeDismissIntent() {
        let failure = NativeHelperPill(
            id: "failed-session",
            title: "Failed turn",
            phase: .needsYou,
            failureAlert: true,
            priority: 0,
            accessibilityLabel: "Failed turn, needs you"
        )
        let blocked = NativeHelperPill(
            id: "blocked-session",
            title: "Approval needed",
            phase: .needsYou,
            priority: 1,
            accessibilityLabel: "Approval needed, needs you"
        )

        XCTAssertEqual(
            NativeMenuFailureDismissalPolicy.intent(for: failure),
            .dismiss
        )
        XCTAssertNil(NativeMenuFailureDismissalPolicy.intent(for: blocked))
    }
}
