import XCTest
@testable import AgentVisorCore

final class CodexControlCapabilityPolicyTests: XCTestCase {
    func testExternalThreadWithoutSharedRuntimeEvidenceRemainsObserved() {
        XCTAssertEqual(
            CodexControlCapabilityPolicy.capability(
                threadId: "thread-1",
                isAgentVisorManaged: false,
                sharedRuntimeEvidence: nil
            ),
            .observed
        )
    }

    func testVerifiedSharedRuntimeMakesExternalThreadConnected() {
        let evidence = CodexSharedRuntimeEvidence(
            threadId: "thread-1",
            transportConnected: true,
            handshakeComplete: true,
            versionCompatible: true,
            subscriptionConfirmed: true
        )

        XCTAssertEqual(
            CodexControlCapabilityPolicy.capability(
                threadId: "thread-1",
                isAgentVisorManaged: false,
                sharedRuntimeEvidence: evidence
            ),
            .connected
        )
    }

    func testEvidenceForAnotherThreadFailsClosed() {
        let evidence = CodexSharedRuntimeEvidence(
            threadId: "thread-2",
            transportConnected: true,
            handshakeComplete: true,
            versionCompatible: true,
            subscriptionConfirmed: true
        )

        XCTAssertEqual(
            CodexControlCapabilityPolicy.capability(
                threadId: "thread-1",
                isAgentVisorManaged: false,
                sharedRuntimeEvidence: evidence
            ),
            .observed
        )
    }

    func testDisconnectedEvidenceFailsClosed() {
        let evidence = CodexSharedRuntimeEvidence(
            threadId: "thread-1",
            transportConnected: false,
            handshakeComplete: true,
            versionCompatible: true,
            subscriptionConfirmed: true
        )

        XCTAssertEqual(
            CodexControlCapabilityPolicy.capability(
                threadId: "thread-1",
                isAgentVisorManaged: false,
                sharedRuntimeEvidence: evidence
            ),
            .observed
        )
    }

    func testManagedOwnershipWinsWithoutSharedRuntimeEvidence() {
        XCTAssertEqual(
            CodexControlCapabilityPolicy.capability(
                threadId: "thread-1",
                isAgentVisorManaged: true,
                sharedRuntimeEvidence: nil
            ),
            .managed
        )
    }
}
