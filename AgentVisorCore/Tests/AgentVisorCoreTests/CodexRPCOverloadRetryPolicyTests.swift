import XCTest
@testable import AgentVisorCore

final class CodexRPCOverloadRetryPolicyTests: XCTestCase {
    func testRetriesOverloadWithBoundedBackoff() {
        XCTAssertEqual(
            CodexRPCOverloadRetryPolicy.delayNanoseconds(
                errorCode: -32001,
                retryAttempt: 0
            ),
            100_000_000
        )
        XCTAssertEqual(
            CodexRPCOverloadRetryPolicy.delayNanoseconds(
                errorCode: -32001,
                retryAttempt: 2
            ),
            500_000_000
        )
        XCTAssertNil(
            CodexRPCOverloadRetryPolicy.delayNanoseconds(
                errorCode: -32001,
                retryAttempt: 3
            )
        )
    }

    func testDoesNotRetryOtherRPCFailures() {
        XCTAssertNil(
            CodexRPCOverloadRetryPolicy.delayNanoseconds(
                errorCode: -32601,
                retryAttempt: 0
            )
        )
    }
}
