import XCTest
@testable import AgentVisorCore

final class PiRuntimeOwnershipPolicyTests: XCTestCase {
    func testCompetingPiRuntimeCannotReplaceLiveOwner() {
        XCTAssertEqual(
            disposition(existingPid: 101, existingOwnerIsAlive: true, eventPid: 202),
            .ignoreCompetingRuntime
        )
    }

    func testUnidentifiedPiRuntimeCannotMutateLiveOwner() {
        XCTAssertEqual(
            disposition(existingPid: 101, existingOwnerIsAlive: true, eventPid: nil),
            .ignoreCompetingRuntime
        )
    }

    func testMatchingPiRuntimeRemainsAccepted() {
        XCTAssertEqual(
            disposition(existingPid: 101, existingOwnerIsAlive: true, eventPid: 101),
            .accept
        )
    }

    func testReplacementPiRuntimeIsAcceptedAfterOwnerExits() {
        XCTAssertEqual(
            disposition(existingPid: 101, existingOwnerIsAlive: false, eventPid: 202),
            .accept
        )
    }

    func testFirstPiRuntimeCanClaimAnUnownedSession() {
        XCTAssertEqual(
            disposition(
                hasExistingSession: false,
                existingPid: nil,
                existingOwnerIsAlive: false,
                eventPid: 202
            ),
            .accept
        )
    }

    func testOtherProvidersAreUnaffected() {
        XCTAssertEqual(
            PiRuntimeOwnershipPolicy.disposition(
                agentID: .claudeCode,
                hasExistingSession: true,
                existingPid: 101,
                existingOwnerIsAlive: true,
                eventPid: 202
            ),
            .accept
        )
    }

    func testPiDiscoveryIsRejectedWhenPidOwnedByAnotherLiveSession() {
        XCTAssertEqual(
            PiRuntimeOwnershipPolicy.admitsDiscoveredSession(
                agentID: .pi,
                discoveredPid: 70934,
                pidOwnedByOtherLiveSession: true
            ),
            .ignoreCompetingRuntime
        )
    }

    func testPiDiscoveryIsAdmittedWhenPidIsUnowned() {
        XCTAssertEqual(
            PiRuntimeOwnershipPolicy.admitsDiscoveredSession(
                agentID: .pi,
                discoveredPid: 70934,
                pidOwnedByOtherLiveSession: false
            ),
            .accept
        )
    }

    func testHistoricalPiDiscoveryWithoutPidIsAlwaysAdmitted() {
        XCTAssertEqual(
            PiRuntimeOwnershipPolicy.admitsDiscoveredSession(
                agentID: .pi,
                discoveredPid: nil,
                pidOwnedByOtherLiveSession: true
            ),
            .accept
        )
    }

    func testNonPiDiscoveryIgnoresPidOwnership() {
        XCTAssertEqual(
            PiRuntimeOwnershipPolicy.admitsDiscoveredSession(
                agentID: .cursor,
                discoveredPid: 70934,
                pidOwnedByOtherLiveSession: true
            ),
            .accept
        )
    }

    private func disposition(
        hasExistingSession: Bool = true,
        existingPid: Int?,
        existingOwnerIsAlive: Bool,
        eventPid: Int?
    ) -> PiRuntimeOwnershipPolicy.Disposition {
        PiRuntimeOwnershipPolicy.disposition(
            agentID: .pi,
            hasExistingSession: hasExistingSession,
            existingPid: existingPid,
            existingOwnerIsAlive: existingOwnerIsAlive,
            eventPid: eventPid
        )
    }
}
