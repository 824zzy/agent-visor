import XCTest
@testable import AgentVisorCore

final class PendingEchoScopeAdmissionPolicyTests: XCTestCase {
    func testFullScopeTableRejectsWithoutEvictingExistingScopes() {
        var policy = PendingEchoScopeAdmissionPolicy()
        for index in 0..<PendingEchoScopeAdmissionPolicy.maxScopes {
            XCTAssertTrue(policy.admit("session-\(index)"))
        }

        XCTAssertFalse(policy.admit("session-over-cap"))
        XCTAssertEqual(policy.count, PendingEchoScopeAdmissionPolicy.maxScopes)
        XCTAssertTrue(policy.contains("session-0"))
        XCTAssertTrue(policy.contains("session-31"))
    }

    func testForgetReleasesExactlyOneScopeForDeterministicReuse() {
        var policy = PendingEchoScopeAdmissionPolicy()
        for index in 0..<PendingEchoScopeAdmissionPolicy.maxScopes {
            XCTAssertTrue(policy.admit("session-\(index)"))
        }

        XCTAssertFalse(policy.admit("session-new"))
        XCTAssertTrue(policy.forget("session-7"))
        XCTAssertFalse(policy.contains("session-7"))
        XCTAssertTrue(policy.admit("session-new"))
        XCTAssertFalse(policy.admit("session-newer"))
        XCTAssertEqual(policy.count, PendingEchoScopeAdmissionPolicy.maxScopes)
    }

    func testRepeatedAdmissionIsIdempotentAndEmptyIDsAreRejected() {
        var policy = PendingEchoScopeAdmissionPolicy()
        XCTAssertFalse(policy.admit(""))
        XCTAssertTrue(policy.admit("session-a"))
        XCTAssertTrue(policy.admit("session-a"))
        XCTAssertEqual(policy.count, 1)
        XCTAssertFalse(policy.forget("missing"))
        XCTAssertTrue(policy.forget("session-a"))
        XCTAssertEqual(policy.count, 0)
    }
}
