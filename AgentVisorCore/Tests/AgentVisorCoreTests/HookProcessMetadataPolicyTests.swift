import XCTest
@testable import AgentVisorCore

final class HookProcessMetadataPolicyTests: XCTestCase {
    func testSharedProcessHookPreservesDiscoveredOwnerMetadata() {
        let merged = HookProcessMetadataPolicy.merge(
            existing: HookProcessMetadata(pid: 100, tty: nil),
            reported: HookProcessMetadata(pid: 200, tty: "ttys009"),
            sharesProcessAcrossSessions: true
        )

        XCTAssertEqual(merged, HookProcessMetadata(pid: 100, tty: nil))
    }

    func testExclusiveProcessHookRefreshesPidAndTTY() {
        let merged = HookProcessMetadataPolicy.merge(
            existing: HookProcessMetadata(pid: 100, tty: "ttys001"),
            reported: HookProcessMetadata(pid: 200, tty: "ttys009"),
            sharesProcessAcrossSessions: false
        )

        XCTAssertEqual(merged, HookProcessMetadata(pid: 200, tty: "ttys009"))
    }

    func testExclusiveProcessHookKeepsTTYWhenEventOmitsIt() {
        let merged = HookProcessMetadataPolicy.merge(
            existing: HookProcessMetadata(pid: 100, tty: "ttys001"),
            reported: HookProcessMetadata(pid: 200, tty: nil),
            sharesProcessAcrossSessions: false
        )

        XCTAssertEqual(merged, HookProcessMetadata(pid: 200, tty: "ttys001"))
    }

    func testSharedProcessCollisionNeverRemovesAnotherSession() {
        XCTAssertFalse(HookProcessMetadataPolicy.shouldRemoveCollidingSession(
            incomingSharesProcessAcrossSessions: true,
            existingSharesProcessAcrossSessions: false
        ))
        XCTAssertFalse(HookProcessMetadataPolicy.shouldRemoveCollidingSession(
            incomingSharesProcessAcrossSessions: false,
            existingSharesProcessAcrossSessions: true
        ))
    }

    func testExclusiveProcessCollisionRemovesStaleSession() {
        XCTAssertTrue(HookProcessMetadataPolicy.shouldRemoveCollidingSession(
            incomingSharesProcessAcrossSessions: false,
            existingSharesProcessAcrossSessions: false
        ))
    }
}
