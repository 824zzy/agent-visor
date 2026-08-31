import XCTest
@testable import AgentVisorCore

final class ComposerRecoveryLifecycleCoordinatorTests: XCTestCase {
    func testExpiryIsDurableWhenTheViewIsAbsent() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(coordinator.register(
            sessionID: "A",
            generationID: "g1",
            echoID: "echo-a",
            deliveryID: "delivery-a",
            expiresAt: start.addingTimeInterval(30)
        ))

        let expired = coordinator.expire(at: start.addingTimeInterval(30))
        XCTAssertEqual(expired.map(\.echoID), ["echo-a"])
        XCTAssertEqual(expired.first?.deliveryID, "delivery-a")
        XCTAssertTrue(coordinator.pendingEchoes(sessionID: "A", generationID: "g1").isEmpty)
    }

    func testCanonicalWhileViewIsAbsentConsumesExactEchoOnlyOnce() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let expiry = Date(timeIntervalSince1970: 130)
        XCTAssertTrue(coordinator.register(
            sessionID: "A", generationID: "g1", echoID: "echo-a",
            deliveryID: "delivery-a", expiresAt: expiry
        ))

        XCTAssertEqual(
            coordinator.canonical(sessionID: "A", generationID: "g1", echoID: "echo-a")?.deliveryID,
            "delivery-a"
        )
        XCTAssertNil(coordinator.canonical(sessionID: "A", generationID: "g1", echoID: "echo-a"))
        XCTAssertTrue(coordinator.expire(at: expiry).isEmpty)
    }

    func testAtoBtoAPreservesEachScopeAndGeneration() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let expiry = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(coordinator.register(
            sessionID: "A", generationID: "a1", echoID: "echo-a",
            deliveryID: "delivery-a", expiresAt: expiry
        ))
        XCTAssertTrue(coordinator.register(
            sessionID: "B", generationID: "b1", echoID: "echo-b",
            deliveryID: "delivery-b", expiresAt: expiry
        ))

        // Reattaching A sees its original exact pending delivery. B remains
        // untouched while A's view is mounted.
        XCTAssertEqual(
            coordinator.pendingEchoes(sessionID: "A", generationID: "a1").map(\.deliveryID),
            ["delivery-a"]
        )
        XCTAssertEqual(
            coordinator.pendingEchoes(sessionID: "B", generationID: "b1").map(\.deliveryID),
            ["delivery-b"]
        )
    }

    func testSamePidProcessTokenReplacementRetiresOldEcho() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let expiry = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(coordinator.register(
            sessionID: "A", generationID: "old", echoID: "echo-old",
            deliveryID: "delivery-old", expiresAt: expiry
        ))

        let retired = coordinator.replaceGeneration(
            sessionID: "A", from: "old", to: "new"
        )
        XCTAssertEqual(retired.map(\.echoID), ["echo-old"])
        XCTAssertTrue(coordinator.pendingEchoes(sessionID: "A", generationID: "old").isEmpty)
        XCTAssertEqual(coordinator.currentGeneration(for: "A"), "new")
    }

    func testGenerationReplacementDoesNotTouchOtherScope() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let expiry = Date(timeIntervalSince1970: 100)
        _ = coordinator.register(
            sessionID: "A", generationID: "old", echoID: "echo-a",
            deliveryID: "delivery-a", expiresAt: expiry
        )
        _ = coordinator.register(
            sessionID: "B", generationID: "b", echoID: "echo-b",
            deliveryID: "delivery-b", expiresAt: expiry
        )

        _ = coordinator.replaceGeneration(sessionID: "A", from: "old", to: "new")
        XCTAssertEqual(
            coordinator.pendingEchoes(sessionID: "B", generationID: "b").map(\.echoID),
            ["echo-b"]
        )
    }

    func testLateCanonicalAfterExpiryCannotClearARecoveryTwice() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let expiry = Date(timeIntervalSince1970: 100)
        _ = coordinator.register(
            sessionID: "A", generationID: "g", echoID: "echo-a",
            deliveryID: "delivery-a", expiresAt: expiry
        )
        XCTAssertEqual(coordinator.expire(at: expiry).count, 1)
        XCTAssertNil(coordinator.canonical(sessionID: "A", generationID: "g", echoID: "echo-a"))
    }

    func testExpiryOrderIsDeterministicAcrossScopes() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let start = Date(timeIntervalSince1970: 100)
        _ = coordinator.register(
            sessionID: "B", generationID: "g", echoID: "echo-z",
            deliveryID: "delivery-z", expiresAt: start.addingTimeInterval(10)
        )
        _ = coordinator.register(
            sessionID: "A", generationID: "g", echoID: "echo-a",
            deliveryID: "delivery-a", expiresAt: start.addingTimeInterval(10)
        )
        XCTAssertEqual(
            coordinator.expire(at: start.addingTimeInterval(10)).map(\.echoID),
            ["echo-a", "echo-z"]
        )
    }

    func testDuplicateIdentityIsIdempotentButConflictingDeliveryIsRejected() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let expiry = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(coordinator.register(
            sessionID: "A", generationID: "g", echoID: "echo-a",
            deliveryID: "delivery-a", expiresAt: expiry
        ))
        XCTAssertTrue(coordinator.register(
            sessionID: "A", generationID: "g", echoID: "echo-a",
            deliveryID: "delivery-a", expiresAt: expiry
        ))
        XCTAssertFalse(coordinator.register(
            sessionID: "A", generationID: "g", echoID: "echo-a",
            deliveryID: "delivery-b", expiresAt: expiry
        ))
        XCTAssertEqual(coordinator.pendingEchoCount, 1)
    }

    func testForgetClearsAllGenerationsForOneSessionOnly() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let expiry = Date(timeIntervalSince1970: 100)
        _ = coordinator.register(
            sessionID: "A", generationID: "a1", echoID: "echo-a1",
            deliveryID: "delivery-a1", expiresAt: expiry
        )
        _ = coordinator.register(
            sessionID: "A", generationID: "a2", echoID: "echo-a2",
            deliveryID: "delivery-a2", expiresAt: expiry
        )
        _ = coordinator.register(
            sessionID: "B", generationID: "b1", echoID: "echo-b1",
            deliveryID: "delivery-b1", expiresAt: expiry
        )

        XCTAssertEqual(coordinator.forget(sessionID: "A").count, 2)
        XCTAssertNil(coordinator.currentGeneration(for: "A"))
        XCTAssertEqual(coordinator.pendingEchoCount, 1)
        XCTAssertEqual(coordinator.currentGeneration(for: "B"), "b1")
    }

    func testPendingEchoCapRejectsWithoutDroppingExistingContent() {
        var coordinator = ComposerRecoveryLifecycleCoordinator()
        let expiry = Date(timeIntervalSince1970: 100)
        for index in 0..<ComposerRecoveryLifecycleCoordinator.maxPendingEchoes {
            XCTAssertTrue(coordinator.register(
                sessionID: "A", generationID: "g", echoID: "echo-\(index)",
                deliveryID: "delivery-\(index)", expiresAt: expiry
            ))
        }
        XCTAssertFalse(coordinator.register(
            sessionID: "A", generationID: "g", echoID: "echo-over-cap",
            deliveryID: "delivery-over-cap", expiresAt: expiry
        ))
        XCTAssertEqual(
            coordinator.pendingEchoes(sessionID: "A", generationID: "g").count,
            ComposerRecoveryLifecycleCoordinator.maxPendingEchoes
        )
    }
}
