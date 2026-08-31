import XCTest
@testable import AgentVisorCore

final class ComposerSnapshotLifecyclePolicyTests: XCTestCase {
    private let entries = [
        ComposerSnapshotLedgerEntry(submissionId: "a", sessionId: "session-a", pendingEchoId: "echo-a"),
        ComposerSnapshotLedgerEntry(submissionId: "b", sessionId: "session-a", pendingEchoId: "echo-b"),
        ComposerSnapshotLedgerEntry(submissionId: "c", sessionId: "session-b", pendingEchoId: "echo-c"),
    ]

    private func recoverySnapshot(
        deliveryID: String = "delivery-a",
        sessionID: String = "session-a",
        generationID: String = "generation-a",
        text: String = "submitted",
        attachments: [String] = [],
        pendingEchoID: String? = "echo-a"
    ) -> ComposerSendRecoverySnapshot {
        ComposerSendRecoverySnapshot(
            deliveryID: deliveryID,
            sessionID: sessionID,
            generationID: generationID,
            text: text,
            attachmentIDs: attachments,
            pendingEchoID: pendingEchoID,
            submittedRevision: 1,
            clearedRevision: 2
        )
    }

    func testCanonicalOrExpiryRemovesOnlyExactEchoAndSession() {
        XCTAssertEqual(
            ComposerSnapshotLifecyclePolicy.submissionIdsToRemove(
                entries: entries,
                event: .canonical(sessionId: "session-a", pendingEchoId: "echo-b")
            ),
            ["b"]
        )
        XCTAssertEqual(
            ComposerSnapshotLifecyclePolicy.submissionIdsToRemove(
                entries: entries,
                event: .expired(sessionId: "session-b", pendingEchoId: "echo-a")
            ),
            []
        )
    }

    func testPhaseCompletionAndSessionSwitchPreserveOtherSessions() {
        XCTAssertEqual(
            ComposerSnapshotLifecyclePolicy.submissionIdsToRemove(
                entries: entries,
                event: .phaseCompleted(sessionId: "session-a")
            ),
            ["a", "b"]
        )
        XCTAssertEqual(
            ComposerSnapshotLifecyclePolicy.submissionIdsToRemove(
                entries: entries,
                event: .sessionChanged(sessionId: "session-b")
            ),
            ["c"]
        )
    }

    func testLateDeliveredAckRetainsExpiredTextRecoverySnapshot() {
        let snapshot = recoverySnapshot()
        var ledger = ComposerRecoveryScopeLedger()
        XCTAssertEqual(ledger.admitFailure(snapshot, reason: "echo expired"), .retained)
        let key = ComposerRecoveryScopeKey(
            sessionID: snapshot.sessionID,
            generationID: snapshot.generationID
        )
        XCTAssertEqual(
            ComposerSnapshotLifecyclePolicy.deliveredAckDisposition(
                snapshot: snapshot,
                deliveryID: snapshot.deliveryID,
                sessionID: snapshot.sessionID,
                generationID: snapshot.generationID,
                recoveryEntries: ledger.entries(for: key)
            ),
            .retainRecoverySnapshot
        )
        XCTAssertEqual(ledger.entry(recoveryID: snapshot.deliveryID, in: key)?.snapshot, snapshot)
    }

    func testLateDeliveredAckRetainsExpiredAttachmentRecoverySnapshot() {
        let snapshot = recoverySnapshot(
            text: "",
            attachments: ["image-a"],
            pendingEchoID: "echo-image"
        )
        var ledger = ComposerRecoveryScopeLedger()
        XCTAssertEqual(ledger.admitFailure(snapshot, reason: "echo expired"), .retained)
        let key = ComposerRecoveryScopeKey(
            sessionID: snapshot.sessionID,
            generationID: snapshot.generationID
        )
        XCTAssertEqual(
            ComposerSnapshotLifecyclePolicy.deliveredAckDisposition(
                snapshot: snapshot,
                deliveryID: snapshot.deliveryID,
                sessionID: snapshot.sessionID,
                generationID: snapshot.generationID,
                recoveryEntries: ledger.entries(for: key)
            ),
            .retainRecoverySnapshot
        )
        XCTAssertEqual(ledger.entry(recoveryID: snapshot.deliveryID, in: key)?.snapshot, snapshot)
        XCTAssertEqual(ledger.retainedAttachmentIDs, ["image-a"])
    }

    func testDeliveredAckWithWrongSessionOrGenerationIsIgnored() {
        let snapshot = recoverySnapshot()
        var ledger = ComposerRecoveryScopeLedger()
        XCTAssertEqual(ledger.admitFailure(snapshot, reason: "echo expired"), .retained)
        let key = ComposerRecoveryScopeKey(
            sessionID: snapshot.sessionID,
            generationID: snapshot.generationID
        )
        let recoveryEntries = ledger.entries(for: key)
        XCTAssertEqual(
            ComposerSnapshotLifecyclePolicy.deliveredAckDisposition(
                snapshot: snapshot,
                deliveryID: snapshot.deliveryID,
                sessionID: "session-other",
                generationID: snapshot.generationID,
                recoveryEntries: recoveryEntries
            ),
            .ignore
        )
        XCTAssertEqual(
            ComposerSnapshotLifecyclePolicy.deliveredAckDisposition(
                snapshot: snapshot,
                deliveryID: snapshot.deliveryID,
                sessionID: snapshot.sessionID,
                generationID: "generation-other",
                recoveryEntries: recoveryEntries
            ),
            .ignore
        )
    }

    func testDeliveredAckBeforeExpiryRemovesNonRecoverySnapshot() {
        let snapshot = recoverySnapshot()
        XCTAssertEqual(
            ComposerSnapshotLifecyclePolicy.deliveredAckDisposition(
                snapshot: snapshot,
                deliveryID: snapshot.deliveryID,
                sessionID: snapshot.sessionID,
                generationID: snapshot.generationID,
                recoveryEntries: []
            ),
            .removeSnapshot
        )
    }
}
