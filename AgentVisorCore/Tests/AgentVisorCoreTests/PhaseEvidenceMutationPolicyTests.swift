import XCTest
@testable import AgentVisorCore

final class PhaseEvidenceMutationPolicyTests: XCTestCase {
    func testSameEvidenceDoesNotPublishAgain() {
        XCTAssertFalse(PhaseEvidenceMutationPolicy.didChange(
            currentSource: "transcriptMarker",
            currentObservedAt: 100,
            newSource: "transcriptMarker",
            newObservedAt: 100
        ))
    }

    func testNewTimestampOrSourcePublishesEvidence() {
        XCTAssertTrue(PhaseEvidenceMutationPolicy.didChange(
            currentSource: "transcriptMarker",
            currentObservedAt: 100,
            newSource: "transcriptMarker",
            newObservedAt: 101
        ))
        XCTAssertTrue(PhaseEvidenceMutationPolicy.didChange(
            currentSource: "hook",
            currentObservedAt: 100,
            newSource: "rediscovery",
            newObservedAt: 100
        ))
        XCTAssertTrue(PhaseEvidenceMutationPolicy.didChange(
            currentSource: nil,
            currentObservedAt: nil,
            newSource: "hook",
            newObservedAt: 100
        ))
    }
}
