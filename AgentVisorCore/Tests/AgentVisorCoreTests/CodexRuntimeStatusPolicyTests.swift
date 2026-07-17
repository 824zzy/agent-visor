import XCTest
@testable import AgentVisorCore

final class CodexRuntimeStatusPolicyTests: XCTestCase {
    func testActiveWaitingOnApprovalNeedsAttention() {
        XCTAssertEqual(
            CodexRuntimeStatusPolicy.phase(
                statusType: "active",
                activeFlags: ["waitingOnApproval"]
            ),
            .waitingForApproval
        )
    }

    func testActiveWaitingOnUserInputNeedsAttention() {
        XCTAssertEqual(
            CodexRuntimeStatusPolicy.phase(
                statusType: "active",
                activeFlags: ["waitingOnUserInput"]
            ),
            .waitingForApproval
        )
    }

    func testIdleIsReadyForInput() {
        XCTAssertEqual(
            CodexRuntimeStatusPolicy.phase(statusType: "idle"),
            .waitingForInput
        )
    }

    func testActiveWithoutHumanFlagIsProcessing() {
        XCTAssertEqual(
            CodexRuntimeStatusPolicy.phase(statusType: "active"),
            .processing
        )
    }

    func testNotLoadedIsUnavailableRatherThanReady() {
        XCTAssertEqual(
            CodexRuntimeStatusPolicy.phase(statusType: "notLoaded"),
            .unavailable
        )
    }
}
