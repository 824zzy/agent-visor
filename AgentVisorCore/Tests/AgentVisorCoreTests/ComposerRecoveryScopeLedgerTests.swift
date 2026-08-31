import XCTest
@testable import AgentVisorCore

final class ComposerRecoveryScopeLedgerTests: XCTestCase {
    private func snapshot(
        deliveryID: String,
        sessionID: String = "session-a",
        generationID: String = "generation-a",
        text: String = "submitted",
        attachments: [String] = [],
        pendingEchoID: String? = nil
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

    private func key(
        sessionID: String = "session-a",
        generationID: String = "generation-a"
    ) -> ComposerRecoveryScopeKey {
        ComposerRecoveryScopeKey(sessionID: sessionID, generationID: generationID)
    }

    func testScopeSurvivesObserverRecreationAndAwayBackNavigation() {
        var scopes = ComposerRecoveryScopeLedger()
        let a = key()
        XCTAssertTrue(scopes.admitFailure(
            snapshot(deliveryID: "delivery-a", pendingEchoID: "echo-a"),
            reason: "send failed"
        ) == .retained)

        // A second observer sees the same value owned by the app-level scope;
        // it does not create a fresh view-local recovery ledger.
        XCTAssertEqual(scopes.entries(for: a).map(\.recoveryID), ["delivery-a"])
        _ = scopes.ensureScope(key(sessionID: "session-b", generationID: "generation-b"))
        XCTAssertEqual(scopes.entries(for: a).map(\.recoveryID), ["delivery-a"])
        XCTAssertTrue(scopes.containsScope(a))
    }

    func testSessionScopesRemainIsolatedAcrossAtoBtoA() {
        var scopes = ComposerRecoveryScopeLedger()
        let a = key()
        let b = key(sessionID: "session-b", generationID: "generation-b")
        XCTAssertEqual(scopes.admitFailure(
            snapshot(deliveryID: "delivery-a", pendingEchoID: "echo-a"),
            reason: "A failed"
        ), .retained)
        XCTAssertEqual(scopes.admitFailure(
            snapshot(
                deliveryID: "delivery-b",
                sessionID: b.sessionID,
                generationID: b.generationID,
                pendingEchoID: "echo-b"
            ),
            reason: "B failed"
        ), .retained)

        XCTAssertEqual(scopes.entries(for: a).map(\.recoveryID), ["delivery-a"])
        XCTAssertEqual(scopes.entries(for: b).map(\.recoveryID), ["delivery-b"])
    }

    func testGenerationReplacementReturnsOldEntriesWithoutRetryingThem() {
        var scopes = ComposerRecoveryScopeLedger()
        XCTAssertEqual(scopes.admitFailure(
            snapshot(deliveryID: "delivery-old", pendingEchoID: "echo-old"),
            reason: "provider replaced"
        ), .retained)

        let old = scopes.replaceGeneration(
            sessionID: "session-a",
            from: "generation-a",
            to: "generation-new"
        )
        XCTAssertEqual(old.map(\.recoveryID), ["delivery-old"])
        XCTAssertTrue(scopes.entries(for: key(generationID: "generation-a")).isEmpty)
        XCTAssertTrue(scopes.containsScope(key(generationID: "generation-new")))
        XCTAssertFalse(scopes.dismiss(
            recoveryID: "delivery-old",
            in: key(generationID: "generation-new")
        ))
    }

    func testScopeCapRejectsWithoutEvictingActionableData() {
        var scopes = ComposerRecoveryScopeLedger()
        for index in 0..<ComposerRecoveryScopeLedger.maxScopes {
            let session = "session-\(index)"
            XCTAssertEqual(scopes.admitFailure(
                snapshot(
                    deliveryID: "delivery-\(index)",
                    sessionID: session,
                    generationID: "generation-\(index)",
                    pendingEchoID: "echo-\(index)"
                ),
                reason: "failed"
            ), .retained)
        }
        let rejected = scopes.admitFailure(
            snapshot(
                deliveryID: "delivery-over-cap",
                sessionID: "session-over-cap",
                generationID: "generation-over-cap"
            ),
            reason: "failed"
        )
        guard case .rejected = rejected else {
            return XCTFail("a full scope ledger must reject rather than evict")
        }
        XCTAssertEqual(
            scopes.entries(for: key(sessionID: "session-0", generationID: "generation-0"))
                .map(\.recoveryID),
            ["delivery-0"]
        )
    }

    func testCanonicalAndDismissTransitionsReturnOnlyExactCleanupIDs() {
        var scopes = ComposerRecoveryScopeLedger()
        XCTAssertEqual(scopes.admitFailure(
            snapshot(deliveryID: "delivery-a", attachments: ["image-a"], pendingEchoID: "echo-a"),
            reason: "failed"
        ), .retained)
        XCTAssertEqual(scopes.admitFailure(
            snapshot(deliveryID: "delivery-b", attachments: ["image-b"], pendingEchoID: "echo-b"),
            reason: "failed"
        ), .retained)

        XCTAssertEqual(scopes.reconcileCanonical(pendingEchoID: "echo-a", in: key()), ["delivery-a"])
        XCTAssertNil(scopes.entry(recoveryID: "delivery-a", in: key()))
        XCTAssertTrue(scopes.dismiss(recoveryID: "delivery-b", in: key()))
        XCTAssertTrue(scopes.entries(for: key()).isEmpty)
    }

    func testImageOnlyAttachmentRemainsRetainedUntilExactTerminalTransition() {
        var scopes = ComposerRecoveryScopeLedger()
        XCTAssertEqual(scopes.admitFailure(
            snapshot(
                deliveryID: "delivery-image",
                text: "",
                attachments: ["image-only"],
                pendingEchoID: "echo-image"
            ),
            reason: "image failed"
        ), .retained)
        XCTAssertTrue(scopes.retainedAttachmentIDs.contains("image-only"))

        _ = scopes.reconcileCanonical(pendingEchoID: "echo-image", in: key())
        XCTAssertFalse(scopes.retainedAttachmentIDs.contains("image-only"))
    }

    func testLateOriginalCanonicalDoesNotConsumeRetryInAnotherIdentity() {
        var scopes = ComposerRecoveryScopeLedger()
        let original = snapshot(deliveryID: "delivery-original", pendingEchoID: "echo-original")
        XCTAssertEqual(scopes.admitFailure(original, reason: "failed"), .retained)
        let replacement = snapshot(deliveryID: "delivery-retry", pendingEchoID: "echo-retry")
        let retry = scopes.beginRetry(
            recoveryID: original.deliveryID,
            replacement: replacement,
            in: key()
        )
        XCTAssertEqual(retry?.isNew, true)
        XCTAssertTrue(scopes.finishRetry(
            recoveryID: original.deliveryID,
            deliveryID: replacement.deliveryID,
            succeeded: true,
            in: key()
        ))

        XCTAssertTrue(scopes.reconcileCanonical(
            pendingEchoID: original.pendingEchoID!,
            in: key()
        ).isEmpty)
        XCTAssertEqual(scopes.reconcileCanonical(
            pendingEchoID: replacement.pendingEchoID!,
            in: key()
        ), [original.deliveryID])
    }

    func testUncertainRetryRequiresAndForwardsExplicitAuthorization() {
        var scopes = ComposerRecoveryScopeLedger()
        let original = snapshot(deliveryID: "delivery-original", pendingEchoID: "echo-original")
        let replacement = snapshot(deliveryID: "delivery-retry", pendingEchoID: "echo-retry")
        XCTAssertEqual(scopes.recordUncertain(original, reason: "uncertain"), .retained)

        XCTAssertNil(scopes.beginRetry(
            recoveryID: original.deliveryID,
            replacement: replacement,
            in: key()
        ))
        XCTAssertEqual(scopes.beginRetry(
            recoveryID: original.deliveryID,
            replacement: replacement,
            in: key(),
            allowUncertain: true
        )?.isNew, true, "explicit authorization must admit the uncertain retry")
    }

    func testAtomicUncertainRetryReturnsOneRecordAndCleansOnlyTheActiveEcho() {
        var scopes = ComposerRecoveryScopeLedger()
        let original = snapshot(deliveryID: "delivery-original", pendingEchoID: "echo-original")
        let replacement = snapshot(deliveryID: "delivery-retry", pendingEchoID: "echo-retry")
        XCTAssertEqual(scopes.admitFailure(original, reason: "failed"), .retained)
        XCTAssertEqual(scopes.beginRetry(
            recoveryID: original.deliveryID,
            replacement: replacement,
            in: key()
        )?.isNew, true)

        XCTAssertTrue(scopes.finishRetryUncertain(
            recoveryID: original.deliveryID,
            deliveryID: replacement.deliveryID,
            reason: "partial retry",
            in: key()
        ))

        XCTAssertEqual(scopes.allEntries.count, 1)
        let entry = try! XCTUnwrap(scopes.entry(
            recoveryID: original.deliveryID,
            in: key()
        ))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.pendingEchoIDs, ["echo-original", "echo-retry"])
        XCTAssertEqual(
            entry.state,
            ComposerSendRecoveryState.uncertain(reason: "partial retry")
        )
        XCTAssertTrue(scopes.reconcileCanonical(
            pendingEchoID: "echo-original",
            in: key()
        ).isEmpty)
        XCTAssertEqual(scopes.reconcileCanonical(
            pendingEchoID: "echo-retry",
            in: key()
        ), [original.deliveryID])
    }

    func testExpiredReplacementEchoUsesOriginalRecoveryIDAfterFailedRetry() {
        var scopes = ComposerRecoveryScopeLedger()
        let original = snapshot(
            deliveryID: "delivery-original",
            attachments: ["image-original"],
            pendingEchoID: "echo-original"
        )
        let replacement = snapshot(
            deliveryID: "delivery-replacement",
            attachments: ["image-replacement"],
            pendingEchoID: "echo-replacement"
        )
        XCTAssertEqual(scopes.admitFailure(original, reason: "initial failure"), .retained)
        XCTAssertEqual(scopes.beginRetry(
            recoveryID: original.deliveryID,
            replacement: replacement,
            in: key()
        )?.isNew, true)
        XCTAssertTrue(scopes.finishRetry(
            recoveryID: original.deliveryID,
            deliveryID: replacement.deliveryID,
            succeeded: false,
            reason: "retry failed before write",
            in: key()
        ))

        XCTAssertEqual(scopes.recordFailureForPendingEcho(
            replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: "replacement echo expired",
            in: key()
        ), .retained)

        XCTAssertEqual(scopes.entries(for: key()).map(\.recoveryID), [original.deliveryID])
        let entry = try! XCTUnwrap(scopes.entry(recoveryID: original.deliveryID, in: key()))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.state, .failed(reason: "replacement echo expired"))
        XCTAssertNil(scopes.entry(recoveryID: replacement.deliveryID, in: key()))
        XCTAssertEqual(scopes.retainedAttachmentIDs, ["image-replacement"])
    }

    func testExpiredReplacementEchoUsesOriginalRecoveryIDAfterAuthorizedUncertainRetry() {
        var scopes = ComposerRecoveryScopeLedger()
        let original = snapshot(
            deliveryID: "delivery-original",
            attachments: ["image-original"],
            pendingEchoID: "echo-original"
        )
        let replacement = snapshot(
            deliveryID: "delivery-replacement",
            attachments: ["image-replacement"],
            pendingEchoID: "echo-replacement"
        )
        XCTAssertEqual(scopes.recordUncertain(original, reason: "initial uncertain"), .retained)
        XCTAssertEqual(scopes.beginRetry(
            recoveryID: original.deliveryID,
            replacement: replacement,
            in: key(),
            allowUncertain: true
        )?.isNew, true)

        XCTAssertEqual(scopes.recordFailureForPendingEcho(
            replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: "replacement echo expired",
            in: key()
        ), .retained)

        XCTAssertEqual(scopes.entries(for: key()).map(\.recoveryID), [original.deliveryID])
        let entry = try! XCTUnwrap(scopes.entry(recoveryID: original.deliveryID, in: key()))
        XCTAssertEqual(entry.snapshot, replacement)
        guard case .uncertain(let reason) = entry.state else {
            return XCTFail("uncertain recovery must not become ordinary Retry")
        }
        XCTAssertEqual(reason, "replacement echo expired")
        let card = ComposerSendRecoveryPresentationPolicy.presentation(for: entry)
        XCTAssertFalse(card.canRetry)
        XCTAssertTrue(card.canConfirmRiskRetry)
        XCTAssertNil(scopes.entry(recoveryID: replacement.deliveryID, in: key()))
        XCTAssertEqual(scopes.retainedAttachmentIDs, ["image-replacement"])
    }

    func testExpiredReplacementEchoKeepsInFlightRetryRiskConfirmedInOriginalRecoveryID() {
        var scopes = ComposerRecoveryScopeLedger()
        let original = snapshot(
            deliveryID: "delivery-original",
            attachments: ["image-original"],
            pendingEchoID: "echo-original"
        )
        let replacement = snapshot(
            deliveryID: "delivery-replacement",
            attachments: ["image-replacement"],
            pendingEchoID: "echo-replacement"
        )
        XCTAssertEqual(scopes.admitFailure(original, reason: "initial failure"), .retained)
        XCTAssertEqual(scopes.beginRetry(
            recoveryID: original.deliveryID,
            replacement: replacement,
            in: key()
        )?.isNew, true)

        let expiryReason = String(repeating: "界", count: 1_000)
        XCTAssertEqual(scopes.recordFailureForPendingEcho(
            replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: expiryReason,
            in: key()
        ), .retained)

        XCTAssertEqual(scopes.entries(for: key()).map(\.recoveryID), [original.deliveryID])
        let entry = try! XCTUnwrap(scopes.entry(recoveryID: original.deliveryID, in: key()))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.pendingEchoIDs, ["echo-original", "echo-replacement"])
        guard case .uncertain(let reason) = entry.state else {
            return XCTFail("an in-flight retry must not become ordinary Retry after expiry")
        }
        XCTAssertLessThanOrEqual(reason.utf8.count, ComposerSendRecoveryLedger.maxReasonBytes)
        let card = ComposerSendRecoveryPresentationPolicy.presentation(for: entry)
        XCTAssertFalse(card.canRetry)
        XCTAssertTrue(card.canConfirmRiskRetry)
        XCTAssertNil(scopes.entry(recoveryID: replacement.deliveryID, in: key()))
        XCTAssertEqual(scopes.retainedAttachmentIDs, ["image-replacement"])
    }

    func testExpiredReplacementEchoUsesOriginalRecoveryIDAfterAwaitingCanonicalRetry() {
        var scopes = ComposerRecoveryScopeLedger()
        let original = snapshot(
            deliveryID: "delivery-original",
            attachments: ["image-original"],
            pendingEchoID: "echo-original"
        )
        let replacement = snapshot(
            deliveryID: "delivery-replacement",
            attachments: ["image-replacement"],
            pendingEchoID: "echo-replacement"
        )
        XCTAssertEqual(scopes.admitFailure(original, reason: "initial failure"), .retained)
        XCTAssertEqual(scopes.beginRetry(
            recoveryID: original.deliveryID,
            replacement: replacement,
            in: key()
        )?.isNew, true)
        XCTAssertTrue(scopes.finishRetry(
            recoveryID: original.deliveryID,
            deliveryID: replacement.deliveryID,
            succeeded: true,
            in: key()
        ))

        XCTAssertEqual(scopes.recordFailureForPendingEcho(
            replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: "replacement echo expired",
            in: key()
        ), .retained)

        XCTAssertEqual(scopes.entries(for: key()).map(\.recoveryID), [original.deliveryID])
        let entry = try! XCTUnwrap(scopes.entry(
            recoveryID: original.deliveryID,
            in: key()
        ))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.pendingEchoIDs, ["echo-original", "echo-replacement"])
        guard case .uncertain(let reason) = entry.state else {
            return XCTFail("awaiting canonical must remain risk-confirmed after expiry")
        }
        XCTAssertEqual(reason, "replacement echo expired")
        let card = ComposerSendRecoveryPresentationPolicy.presentation(for: entry)
        XCTAssertFalse(card.canRetry)
        XCTAssertTrue(card.canConfirmRiskRetry)
        XCTAssertNil(scopes.entry(recoveryID: replacement.deliveryID, in: key()))
    }

    func testExpiredReplacementEchoRejectsWrongScopeWithoutMutation() {
        var scopes = ComposerRecoveryScopeLedger()
        let original = snapshot(
            deliveryID: "delivery-original",
            pendingEchoID: "echo-original"
        )
        let replacement = snapshot(
            deliveryID: "delivery-replacement",
            pendingEchoID: "echo-replacement"
        )
        XCTAssertEqual(scopes.admitFailure(original, reason: "initial failure"), .retained)
        XCTAssertEqual(scopes.beginRetry(
            recoveryID: original.deliveryID,
            replacement: replacement,
            in: key()
        )?.isNew, true)

        XCTAssertEqual(scopes.recordFailureForPendingEcho(
            replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: "wrong session",
            in: key(sessionID: "session-other")
        ), .rejected(reason: "The pending echo no longer owns this recovery entry."))
        XCTAssertEqual(scopes.recordFailureForPendingEcho(
            replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: "wrong generation",
            in: key(generationID: "generation-other")
        ), .rejected(reason: "The pending echo no longer owns this recovery entry."))
        XCTAssertEqual(scopes.recordFailureForPendingEcho(
            replacement,
            pendingEchoID: "echo-not-owned",
            reason: "wrong echo",
            in: key()
        ), .rejected(reason: "The pending echo no longer owns this recovery entry."))

        XCTAssertEqual(scopes.entries(for: key()).count, 1)
        XCTAssertEqual(
            scopes.entry(recoveryID: original.deliveryID, in: key())?.state,
            .retrying(deliveryID: replacement.deliveryID)
        )
        XCTAssertNil(scopes.entry(recoveryID: replacement.deliveryID, in: key()))
    }

    func testForgetSessionRemovesEveryGenerationAndPreservesOtherSessions() {
        var scopes = ComposerRecoveryScopeLedger()
        let other = key(sessionID: "session-other", generationID: "generation-other")
        XCTAssertEqual(scopes.admitFailure(
            snapshot(deliveryID: "a-old", generationID: "generation-old", pendingEchoID: "echo-old"),
            reason: "old generation"
        ), .retained)
        XCTAssertEqual(scopes.admitFailure(
            snapshot(deliveryID: "a-new", generationID: "generation-new", pendingEchoID: "echo-new"),
            reason: "new generation"
        ), .retained)
        XCTAssertEqual(scopes.admitFailure(
            snapshot(
                deliveryID: "other",
                sessionID: other.sessionID,
                generationID: other.generationID,
                pendingEchoID: "echo-other"
            ),
            reason: "other session"
        ), .retained)

        let removed = scopes.forget(sessionID: "session-a")
        XCTAssertEqual(Set(removed.map(\.snapshot.deliveryID)), ["a-old", "a-new"])
        XCTAssertTrue(scopes.entries(for: key()).isEmpty)
        XCTAssertTrue(scopes.entries(for: key(generationID: "generation-new")).isEmpty)
        XCTAssertEqual(scopes.entries(for: other).map(\.recoveryID), ["other"])
    }

    func testForgetAllowsDeterministicScopeChurnAndSessionIDReuse() {
        var scopes = ComposerRecoveryScopeLedger()
        for index in 0..<ComposerRecoveryScopeLedger.maxScopes {
            XCTAssertTrue(scopes.ensureScope(key(
                sessionID: "churn-\(index)",
                generationID: "generation-\(index)"
            )))
        }
        XCTAssertFalse(scopes.ensureScope(key(sessionID: "churn-over", generationID: "generation-over")))

        _ = scopes.forget(sessionID: "churn-0")
        XCTAssertTrue(scopes.ensureScope(key(sessionID: "churn-over", generationID: "generation-over")))
        _ = scopes.forget(sessionID: "churn-over")
        XCTAssertTrue(scopes.admitFailure(
            snapshot(
                deliveryID: "reused",
                sessionID: "churn-over",
                generationID: "generation-reused"
            ),
            reason: "reused session id"
        ) == .retained)
        XCTAssertEqual(
            scopes.entries(for: key(sessionID: "churn-over", generationID: "generation-reused"))
                .map(\.recoveryID),
            ["reused"]
        )
    }

    func testGenerationReplacementCanBePresentedAsRestorableWithoutStaleEcho() {
        var scopes = ComposerRecoveryScopeLedger()
        let old = snapshot(deliveryID: "old", text: "restore me", pendingEchoID: "old-echo")
        XCTAssertEqual(scopes.admitFailure(old, reason: "provider restarted"), .retained)
        let oldEntries = scopes.replaceGeneration(
            sessionID: old.sessionID,
            from: old.generationID,
            to: "generation-restored"
        )
        XCTAssertEqual(oldEntries.first?.snapshot.pendingEchoID, "old-echo")

        let restored = ComposerRecoveryScopeLedger.restorableSnapshotForGeneration(
            old,
            generationID: "generation-restored"
        )
        XCTAssertEqual(restored?.text, "restore me")
        XCTAssertNil(restored?.pendingEchoID)
        guard let restored else { return XCTFail("replacement must retain a valid snapshot") }
        XCTAssertEqual(scopes.admitFailure(restored, reason: "restore before retry"), .retained)
        let entry = scopes.entry(
            recoveryID: old.deliveryID,
            in: key(generationID: "generation-restored")
        )
        XCTAssertEqual(entry?.snapshot.text, "restore me")
        XCTAssertNil(entry?.pendingEchoIDs.first)
    }

    func testEmptyScopeCanBeForgottenWithoutTouchingOtherSession() {
        var scopes = ComposerRecoveryScopeLedger()
        let empty = key(sessionID: "empty", generationID: "empty-generation")
        let other = key(sessionID: "kept", generationID: "kept-generation")
        XCTAssertTrue(scopes.ensureScope(empty))
        XCTAssertEqual(scopes.admitFailure(
            snapshot(
                deliveryID: "kept-delivery",
                sessionID: other.sessionID,
                generationID: other.generationID
            ),
            reason: "kept"
        ), .retained)
        XCTAssertTrue(scopes.forget(sessionID: "empty").isEmpty)
        XCTAssertFalse(scopes.containsScope(empty))
        XCTAssertTrue(scopes.containsScope(other))
    }
}
