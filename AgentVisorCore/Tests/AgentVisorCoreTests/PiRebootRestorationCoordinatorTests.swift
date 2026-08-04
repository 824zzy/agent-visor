import XCTest
@testable import AgentVisorCore

final class PiRebootRestorationCoordinatorTests: XCTestCase {
    private let first = PiRestorableSession(
        sessionId: "session-a",
        sessionFile: "/tmp/session-a.jsonl",
        cwd: "/tmp/project-a",
        sessionName: "Project A",
        layout: .init(windowIndex: 1, tabIndex: 1, terminalIndex: 1),
        observedAt: Date(timeIntervalSince1970: 100)
    )

    private let second = PiRestorableSession(
        sessionId: "session-b",
        sessionFile: "/tmp/session-b.jsonl",
        cwd: "/tmp/project-b",
        sessionName: nil,
        layout: .init(windowIndex: 1, tabIndex: 2, terminalIndex: 1),
        observedAt: Date(timeIntervalSince1970: 110)
    )

    func testNewBootRestoresExactlyThePriorLiveSetOnce() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.observe(second)

        let firstPlan = coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: [])
        let duplicatePlan = coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: [])

        XCTAssertEqual(firstPlan, [first, second])
        XCTAssertEqual(duplicatePlan, [])
        XCTAssertEqual(coordinator.snapshot.state, .claimed)
        XCTAssertEqual(coordinator.snapshot.attemptedSessionIDs, ["session-a", "session-b"])
    }

    func testSameBootLaunchNeverRestoresSessions() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)

        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-1", liveSessionIDs: []),
            []
        )
        XCTAssertEqual(coordinator.snapshot.state, .active)
    }

    func testIntentionalEndRemovesSessionBeforeReboot() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.observe(second)
        coordinator.end(sessionID: first.sessionId)

        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: []),
            [second]
        )
    }

    func testPowerOffFreezeIgnoresTeardownEnds() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.freezeForSystemPowerOff(at: Date(timeIntervalSince1970: 120))
        coordinator.end(sessionID: first.sessionId)

        XCTAssertEqual(coordinator.snapshot.state, .frozen)
        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: []),
            [first]
        )
    }

    func testCleanAppTerminationOutsidePowerOffInvalidatesRestore() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.invalidateForCleanAppTermination()

        XCTAssertEqual(coordinator.snapshot.state, .invalidated)
        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: []),
            []
        )
    }

    func testSessionReplacementKeepsOnlyNewExactIdentity() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.replace(sessionID: first.sessionId, with: second)

        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: []),
            [second]
        )
    }

    func testAlreadyLiveSessionIsSuppressedFromRestorePlan() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.observe(second)

        XCTAssertEqual(
            coordinator.claimRestorePlan(
                currentBootID: "boot-2",
                liveSessionIDs: [second.sessionId]
            ),
            [first]
        )
        XCTAssertEqual(coordinator.snapshot.attemptedSessionIDs, ["session-a"])
    }

    func testSnapshotRoundTripsWithoutConversationContent() throws {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)

        let encoded = try JSONEncoder().encode(coordinator.snapshot)
        let restored = try JSONDecoder().decode(PiRestorationSnapshot.self, from: encoded)

        XCTAssertEqual(restored, coordinator.snapshot)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("prompt"))
        XCTAssertFalse(json.contains("tool"))
        XCTAssertFalse(json.contains("message"))
    }
}
