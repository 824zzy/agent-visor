import XCTest
@testable import AgentVisorCore

final class ComposerSendRecoveryPolicyTests: XCTestCase {
    private func snapshot(
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
            submittedRevision: 4,
            clearedRevision: 5
        )
    }

    func testFailureRetainsExactTextAttachmentsAndImageOnlySubmission() {
        var ledger = ComposerSendRecoveryLedger()
        let textAndImage = snapshot(attachments: ["image-a"])
        ledger.recordFailure(snapshot: textAndImage, reason: "Terminal unavailable")

        XCTAssertEqual(
            ledger.entry(recoveryID: textAndImage.deliveryID)?.snapshot,
            textAndImage
        )

        let imageOnly = snapshot(
            deliveryID: "delivery-image-only",
            text: "",
            attachments: ["image-only"]
        )
        ledger.recordFailure(snapshot: imageOnly, reason: "Image send failed")
        XCTAssertEqual(
            ledger.entry(recoveryID: imageOnly.deliveryID)?.snapshot.attachmentIDs,
            ["image-only"]
        )
        XCTAssertEqual(
            ledger.entry(recoveryID: imageOnly.deliveryID)?.snapshot.text,
            ""
        )
    }

    func testRetryIsIdempotentAndUsesAReplacementIdentity() {
        var ledger = ComposerSendRecoveryLedger()
        let original = snapshot()
        let replacement = snapshot(
            deliveryID: "delivery-retry",
            pendingEchoID: "echo-retry"
        )
        ledger.recordFailure(snapshot: original, reason: "Send failed")

        let first = ledger.beginRetry(
            recoveryID: original.deliveryID,
            sessionID: original.sessionID,
            generationID: original.generationID,
            replacement: replacement
        )
        XCTAssertEqual(first?.snapshot, replacement)
        XCTAssertEqual(first?.isNew, true)

        let secondReplacement = snapshot(
            deliveryID: "delivery-should-not-send",
            pendingEchoID: "echo-should-not-send"
        )
        let second = ledger.beginRetry(
            recoveryID: original.deliveryID,
            sessionID: original.sessionID,
            generationID: original.generationID,
            replacement: secondReplacement
        )
        XCTAssertEqual(second?.snapshot, replacement)
        XCTAssertEqual(second?.isNew, false)
        XCTAssertEqual(
            ledger.entry(recoveryID: original.deliveryID)?.snapshot.deliveryID,
            "delivery-retry"
        )
    }

    func testRetryFailureRemainsActionableAndDismissTargetsOnlyOneRecord() {
        var ledger = ComposerSendRecoveryLedger()
        let first = snapshot()
        let second = snapshot(deliveryID: "delivery-b")
        ledger.recordFailure(snapshot: first, reason: "first failed")
        ledger.recordFailure(snapshot: second, reason: "second failed")
        let retry = snapshot(deliveryID: "delivery-retry", pendingEchoID: "echo-retry")
        _ = ledger.beginRetry(
            recoveryID: first.deliveryID,
            sessionID: first.sessionID,
            generationID: first.generationID,
            replacement: retry
        )
        XCTAssertTrue(
            ledger.finishRetry(
                recoveryID: first.deliveryID,
                deliveryID: retry.deliveryID,
                succeeded: false,
                reason: "retry failed"
            )
        )
        XCTAssertEqual(
            ledger.entry(recoveryID: first.deliveryID)?.state,
            .failed(reason: "retry failed")
        )
        XCTAssertTrue(
            ledger.dismiss(
                recoveryID: first.deliveryID,
                sessionID: first.sessionID,
                generationID: first.generationID
            )
        )
        XCTAssertNil(ledger.entry(recoveryID: first.deliveryID))
        XCTAssertNotNil(ledger.entry(recoveryID: second.deliveryID))
    }

    func testLateCanonicalArrivalRemovesExactRecoveryOnly() {
        var ledger = ComposerSendRecoveryLedger()
        let first = snapshot()
        let second = snapshot(deliveryID: "delivery-b", pendingEchoID: "echo-b")
        ledger.recordFailure(snapshot: first, reason: "first failed")
        ledger.recordFailure(snapshot: second, reason: "second failed")

        let removed = ledger.reconcileCanonical(
            sessionID: "session-a",
            generationID: "generation-a",
            pendingEchoID: "echo-a"
        )
        XCTAssertEqual(removed, [first.deliveryID])
        XCTAssertNil(ledger.entry(recoveryID: first.deliveryID))
        XCTAssertNotNil(ledger.entry(recoveryID: second.deliveryID))
    }

    func testLateOriginalCanonicalDoesNotConsumeAwaitingRetry() {
        var ledger = ComposerSendRecoveryLedger()
        let original = snapshot(pendingEchoID: "echo-original")
        let retry = snapshot(deliveryID: "delivery-retry", pendingEchoID: "echo-retry")
        XCTAssertTrue(ledger.recordFailure(snapshot: original, reason: "failed"))
        XCTAssertEqual(
            ledger.beginRetry(
                recoveryID: original.deliveryID,
                sessionID: original.sessionID,
                generationID: original.generationID,
                replacement: retry
            )?.isNew,
            true
        )
        XCTAssertTrue(ledger.finishRetry(
            recoveryID: original.deliveryID,
            deliveryID: retry.deliveryID,
            succeeded: true
        ))

        XCTAssertTrue(ledger.entry(recoveryID: original.deliveryID)?.state ==
                      .awaitingCanonical(deliveryID: retry.deliveryID))
        XCTAssertTrue(ledger.reconcileCanonical(
            sessionID: original.sessionID,
            generationID: original.generationID,
            pendingEchoID: "echo-original"
        ).isEmpty)
        XCTAssertNotNil(ledger.entry(recoveryID: original.deliveryID))
        XCTAssertEqual(
            ledger.reconcileCanonical(
                sessionID: original.sessionID,
                generationID: original.generationID,
                pendingEchoID: "echo-retry"
            ),
            [original.deliveryID]
        )
    }

    func testScopeMismatchCannotRestoreOrDismissAcrossSessions() {
        var ledger = ComposerSendRecoveryLedger()
        let original = snapshot()
        ledger.recordFailure(snapshot: original, reason: "failed")
        let replacement = snapshot(deliveryID: "delivery-b", sessionID: "session-b", generationID: "generation-b")

        XCTAssertNil(
            ledger.beginRetry(
                recoveryID: original.deliveryID,
                sessionID: replacement.sessionID,
                generationID: replacement.generationID,
                replacement: replacement
            )
        )
        XCTAssertFalse(
            ledger.dismiss(
                recoveryID: original.deliveryID,
                sessionID: replacement.sessionID,
                generationID: replacement.generationID
            )
        )
        XCTAssertNotNil(ledger.entry(recoveryID: original.deliveryID))
    }

    func testSessionChangeInvalidatesOnlyThatGeneration() {
        var ledger = ComposerSendRecoveryLedger()
        let old = snapshot()
        let other = snapshot(deliveryID: "delivery-b", sessionID: "session-b", generationID: "generation-b")
        ledger.recordFailure(snapshot: old, reason: "old")
        ledger.recordFailure(snapshot: other, reason: "other")

        ledger.invalidate(sessionID: old.sessionID, generationID: old.generationID)
        XCTAssertNil(ledger.entry(recoveryID: old.deliveryID))
        XCTAssertNotNil(ledger.entry(recoveryID: other.deliveryID))
    }

    func testCardPresentationExposesOnlyFailedActionsAndAccessibleIdentity() {
        var ledger = ComposerSendRecoveryLedger()
        let failed = snapshot(attachments: ["image-a"])
        ledger.recordFailure(snapshot: failed, reason: "Transport failed")
        let failedCard = ComposerSendRecoveryPresentationPolicy.presentation(
            for: try! XCTUnwrap(ledger.entry(recoveryID: failed.deliveryID))
        )
        XCTAssertEqual(failedCard.recoveryID, failed.deliveryID)
        XCTAssertEqual(failedCard.title, "Message not sent")
        XCTAssertEqual(failedCard.attachmentCount, 1)
        XCTAssertTrue(failedCard.canRetry)
        XCTAssertTrue(failedCard.canDismiss)
        XCTAssertEqual(failedCard.accessibilityLabel, "Failed message recovery")

        let retry = snapshot(deliveryID: "delivery-retry", pendingEchoID: "echo-retry")
        _ = ledger.beginRetry(
            recoveryID: failed.deliveryID,
            sessionID: failed.sessionID,
            generationID: failed.generationID,
            replacement: retry
        )
        let retryCard = ComposerSendRecoveryPresentationPolicy.presentation(
            for: try! XCTUnwrap(ledger.entry(recoveryID: failed.deliveryID))
        )
        XCTAssertFalse(retryCard.canRetry)
        XCTAssertFalse(retryCard.canDismiss)
        XCTAssertEqual(retryCard.accessibilityLabel, "Retrying failed message")
    }

    func testRetryClearRequiresExactRestoredComposerRevision() {
        let submitted = snapshot()
        XCTAssertTrue(
            ComposerSendRecoveryLedger.shouldClearComposerForRetry(
                snapshot: submitted,
                currentText: submitted.text,
                currentAttachmentIDs: submitted.attachmentIDs,
                currentRevision: submitted.clearedRevision + 1
            )
        )
        XCTAssertFalse(
            ComposerSendRecoveryLedger.shouldClearComposerForRetry(
                snapshot: submitted,
                currentText: submitted.text,
                currentAttachmentIDs: submitted.attachmentIDs,
                currentRevision: submitted.clearedRevision + 2
            )
        )
        XCTAssertFalse(
            ComposerSendRecoveryLedger.shouldClearComposerForRetry(
                snapshot: submitted,
                currentText: "newer text",
                currentAttachmentIDs: submitted.attachmentIDs,
                currentRevision: submitted.clearedRevision + 1
            )
        )
    }

    func testBoundsRejectOversizedSnapshotAndEvictOldestFailedOnly() {
        var ledger = ComposerSendRecoveryLedger()
        let oversized = snapshot(text: String(repeating: "x", count: ComposerSendRecoveryLedger.maxSnapshotBytes))
        XCTAssertFalse(ledger.recordFailure(snapshot: oversized, reason: "too large"))

        for index in 0..<ComposerSendRecoveryLedger.maxRecords {
            let item = snapshot(deliveryID: "delivery-\(index)", pendingEchoID: "echo-\(index)")
            XCTAssertTrue(ledger.recordFailure(snapshot: item, reason: "failed"))
        }
        let newest = snapshot(deliveryID: "delivery-new", pendingEchoID: "echo-new")
        _ = ledger.beginRetry(
            recoveryID: "delivery-255",
            sessionID: newest.sessionID,
            generationID: newest.generationID,
            replacement: newest
        )
        let extra = snapshot(deliveryID: "delivery-extra", pendingEchoID: "echo-extra")
        XCTAssertFalse(ledger.recordFailure(snapshot: extra, reason: "failed"),
                       "Actionable recovery must not be silently evicted at capacity")
        XCTAssertNotNil(ledger.entry(recoveryID: "delivery-0"))
        XCTAssertNotNil(ledger.entry(recoveryID: "delivery-255"))
        XCTAssertNil(ledger.entry(recoveryID: "delivery-extra"))
    }

    func testFailureReasonIsBoundedByUTF8BytesAndSupersededEchoHistoryIsBounded() {
        var ledger = ComposerSendRecoveryLedger()
        let original = snapshot()
        XCTAssertTrue(ledger.recordFailure(
            snapshot: original,
            reason: String(repeating: "界", count: 1000)
        ))
        let entry = try! XCTUnwrap(ledger.entry(recoveryID: original.deliveryID))
        guard case .failed(let reason) = entry.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertLessThanOrEqual(reason.utf8.count, ComposerSendRecoveryLedger.maxReasonBytes)

        var replacement = original
        for index in 0..<(ComposerSendRecoveryLedger.maxPendingEchoIDs + 10) {
            replacement = ComposerSendRecoverySnapshot(
                deliveryID: original.deliveryID,
                sessionID: original.sessionID,
                generationID: original.generationID,
                text: "submitted",
                attachmentIDs: [],
                pendingEchoID: "echo-\(index)",
                submittedRevision: 4,
                clearedRevision: 5
            )
            XCTAssertTrue(ledger.recordFailure(snapshot: replacement, reason: "again"))
        }
        let updated = try! XCTUnwrap(ledger.entry(recoveryID: original.deliveryID))
        XCTAssertLessThanOrEqual(updated.pendingEchoIDs.count,
                                  ComposerSendRecoveryLedger.maxPendingEchoIDs)
    }

    func testAttachmentMetadataCountsFullAndThumbnailBytesForAdmission() {
        let metadata = [ComposerSendRecoveryAttachment(
            id: "image-a",
            path: "/tmp/image-a.png",
            contentBytes: ComposerSendRecoveryLedger.maxSnapshotBytes,
            thumbnailBytes: 128
        )]
        let candidate = ComposerSendRecoverySnapshot(
            deliveryID: "delivery-image",
            sessionID: "session-a",
            generationID: "generation-a",
            text: "",
            attachmentIDs: ["image-a"],
            attachmentMetadata: metadata,
            pendingEchoID: "echo-image",
            submittedRevision: 1,
            clearedRevision: 2
        )
        var ledger = ComposerSendRecoveryLedger()
        XCTAssertFalse(ledger.recordFailure(snapshot: candidate, reason: "image too large"))
        XCTAssertGreaterThan(candidate.estimatedBytes, ComposerSendRecoveryLedger.maxSnapshotBytes)
    }

    func testRejectedAdmissionKeepsEveryActionableAttachmentReference() {
        var ledger = ComposerSendRecoveryLedger()
        for index in 0..<ComposerSendRecoveryLedger.maxRecords {
            let item = snapshot(
                deliveryID: "delivery-\(index)",
                attachments: ["image-\(index)"],
                pendingEchoID: "echo-\(index)"
            )
            XCTAssertEqual(ledger.admitFailure(snapshot: item, reason: "failed"), .retained)
        }
        let rejected = snapshot(
            deliveryID: "delivery-over-cap",
            attachments: ["image-over-cap"],
            pendingEchoID: "echo-over-cap"
        )
        guard case .rejected = ledger.admitFailure(snapshot: rejected, reason: "failed") else {
            return XCTFail("all actionable records must reject a new admission")
        }
        XCTAssertTrue(ledger.retainsAttachment("image-0"))
        XCTAssertFalse(ledger.retainsAttachment("image-over-cap"))
    }

    func testAttachmentReferenceCapRejectsBeforeDroppingActionableRecords() {
        var ledger = ComposerSendRecoveryLedger()
        let existing = snapshot(
            deliveryID: "delivery-existing",
            attachments: (0..<ComposerSendRecoveryLedger.maxRetainedAttachmentReferences)
                .map { "image-\($0)" },
            pendingEchoID: "echo-existing"
        )
        XCTAssertEqual(ledger.admitFailure(snapshot: existing, reason: "failed"), .retained)

        let candidate = snapshot(
            deliveryID: "delivery-candidate",
            attachments: ["image-new"],
            pendingEchoID: "echo-candidate"
        )
        guard case .rejected = ledger.admitFailure(snapshot: candidate, reason: "failed") else {
            return XCTFail("an actionable attachment reference cap must reject atomically")
        }
        XCTAssertNotNil(ledger.entry(recoveryID: existing.deliveryID))
        XCTAssertNil(ledger.entry(recoveryID: candidate.deliveryID))
    }

    func testSharedAttachmentByteBudgetAllowsNormalImageAndRejectsAggregateOverflow() {
        let metadata = [ComposerSendRecoveryAttachment(
            id: "image-a",
            path: "/tmp/image-a.png",
            contentBytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes,
            thumbnailBytes: 80
        )]
        let candidate = ComposerSendRecoverySnapshot(
            deliveryID: "delivery-image",
            sessionID: "session-a",
            generationID: "generation-a",
            text: "",
            attachmentIDs: ["image-a"],
            attachmentMetadata: metadata,
            pendingEchoID: "echo-image",
            submittedRevision: 1,
            clearedRevision: 2
        )
        var ledger = ComposerSendRecoveryLedger()
        XCTAssertTrue(ledger.recordFailure(snapshot: candidate, reason: "image failed"))

        let oversized = snapshot(
            deliveryID: "delivery-oversized",
            text: String(repeating: "x", count: ImageAttachmentAdmissionPolicy.maxAggregateBytes)
        )
        XCTAssertFalse(ledger.recordFailure(snapshot: oversized, reason: "too large"))
        XCTAssertNotNil(ledger.entry(recoveryID: candidate.deliveryID))
    }

    func testLiveSubmissionAdmissionSharesByteAndReferenceBudgets() {
        let existing = snapshot(
            deliveryID: "delivery-existing",
            attachments: (0..<ComposerSendRecoveryLedger.maxRetainedAttachmentReferences)
                .map { "image-\($0)" }
        )
        let candidate = snapshot(
            deliveryID: "delivery-candidate",
            attachments: ["image-new"]
        )
        XCTAssertFalse(
            ComposerSendRecoveryLedger.canAdmitLiveSubmission(
                existing: [existing],
                candidate: candidate
            )
        )

        let oversized = snapshot(
            deliveryID: "delivery-oversized",
            text: String(repeating: "x", count: ComposerSendRecoveryLedger.maxSnapshotBytes)
        )
        XCTAssertFalse(
            ComposerSendRecoveryLedger.canAdmitLiveSubmission(
                existing: [],
                candidate: oversized
            )
        )
    }

    func testUncertainDeliveryRequiresExplicitRiskRetryAndSupportsSafeDismissal() {
        var ledger = ComposerSendRecoveryLedger()
        let submitted = snapshot(attachments: ["image-a"])
        XCTAssertTrue(ledger.recordUncertain(
            snapshot: submitted,
            reason: "An image may already have reached the agent."
        ))
        let entry = try! XCTUnwrap(ledger.entry(recoveryID: submitted.deliveryID))
        let card = ComposerSendRecoveryPresentationPolicy.presentation(for: entry)
        XCTAssertFalse(card.canRetry)
        XCTAssertTrue(card.canDismiss)
        XCTAssertTrue(card.canRestore)
        XCTAssertTrue(card.canConfirmRiskRetry)

        let ordinaryRetry = ledger.beginRetry(
            recoveryID: submitted.deliveryID,
            sessionID: submitted.sessionID,
            generationID: submitted.generationID,
            replacement: snapshot(deliveryID: "retry-ordinary", pendingEchoID: "echo-retry")
        )
        XCTAssertNil(ordinaryRetry)
        XCTAssertEqual(
            ledger.beginRetry(
                recoveryID: submitted.deliveryID,
                sessionID: submitted.sessionID,
                generationID: submitted.generationID,
                replacement: snapshot(deliveryID: "retry-explicit", pendingEchoID: "echo-explicit"),
                allowUncertain: true
            )?.isNew,
            true
        )
        XCTAssertTrue(ledger.dismiss(
            recoveryID: submitted.deliveryID,
            sessionID: submitted.sessionID,
            generationID: submitted.generationID
        ) == false, "an in-flight explicit retry is not dismissible")
    }

    func testRetryPartialFailureKeepsOneUncertainRecordAndTheReplacementIdentity() {
        var ledger = ComposerSendRecoveryLedger()
        let original = snapshot(attachments: ["image-a"], pendingEchoID: "echo-original")
        let replacement = snapshot(
            deliveryID: "delivery-retry",
            attachments: ["image-a"],
            pendingEchoID: "echo-retry"
        )
        XCTAssertTrue(ledger.recordFailure(snapshot: original, reason: "initial failure"))
        XCTAssertEqual(
            ledger.beginRetry(
                recoveryID: original.deliveryID,
                sessionID: original.sessionID,
                generationID: original.generationID,
                replacement: replacement
            )?.isNew,
            true
        )

        XCTAssertTrue(ledger.finishRetryUncertain(
            recoveryID: original.deliveryID,
            deliveryID: replacement.deliveryID,
            reason: "Enter was not confirmed"
        ))

        XCTAssertEqual(ledger.allEntries.count, 1)
        let entry = try! XCTUnwrap(ledger.entry(recoveryID: original.deliveryID))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.pendingEchoIDs, ["echo-original", "echo-retry"])
        XCTAssertEqual(
            entry.state,
            ComposerSendRecoveryState.uncertain(reason: "Enter was not confirmed")
        )
        XCTAssertNil(ledger.entry(recoveryID: replacement.deliveryID))

        // A late canonical row for the superseded attempt must not release
        // the replacement's uncertain snapshot. The active retry identity is
        // the only exact cleanup boundary after an atomic retry transition.
        XCTAssertTrue(ledger.reconcileCanonical(
            sessionID: original.sessionID,
            generationID: original.generationID,
            pendingEchoID: "echo-original"
        ).isEmpty)
        XCTAssertEqual(ledger.reconcileCanonical(
            sessionID: original.sessionID,
            generationID: original.generationID,
            pendingEchoID: "echo-retry"
        ), [original.deliveryID])
        XCTAssertTrue(ledger.retainedAttachmentIDs.isEmpty)
    }

    func testExpiredReplacementEchoKeepsFailedRetryOnOriginalRecoveryID() {
        var ledger = ComposerSendRecoveryLedger()
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
        XCTAssertTrue(ledger.recordFailure(snapshot: original, reason: "initial failure"))
        XCTAssertTrue(ledger.beginRetry(
            recoveryID: original.deliveryID,
            sessionID: original.sessionID,
            generationID: original.generationID,
            replacement: replacement
        )?.isNew == true)
        XCTAssertTrue(ledger.finishRetry(
            recoveryID: original.deliveryID,
            deliveryID: replacement.deliveryID,
            succeeded: false,
            reason: "retry failed before write"
        ))

        XCTAssertTrue(ledger.recordFailureForPendingEcho(
            snapshot: replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: "replacement echo expired"
        ))

        XCTAssertEqual(ledger.allEntries.count, 1)
        let entry = try! XCTUnwrap(ledger.entry(recoveryID: original.deliveryID))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.pendingEchoIDs, ["echo-original", "echo-replacement"])
        XCTAssertEqual(entry.state, .failed(reason: "replacement echo expired"))
        let card = ComposerSendRecoveryPresentationPolicy.presentation(for: entry)
        XCTAssertTrue(card.canRetry)
        XCTAssertTrue(card.canDismiss)
        XCTAssertNil(ledger.entry(recoveryID: replacement.deliveryID))
        XCTAssertEqual(ledger.retainedAttachmentIDs, ["image-replacement"])
    }

    func testExpiredReplacementEchoKeepsUncertainRetryOnOriginalRecoveryID() {
        var ledger = ComposerSendRecoveryLedger()
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
        XCTAssertTrue(ledger.recordUncertain(snapshot: original, reason: "initial uncertain"))
        XCTAssertTrue(ledger.beginRetry(
            recoveryID: original.deliveryID,
            sessionID: original.sessionID,
            generationID: original.generationID,
            replacement: replacement,
            allowUncertain: true
        )?.isNew == true)

        XCTAssertTrue(ledger.recordFailureForPendingEcho(
            snapshot: replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: "replacement echo expired"
        ))

        XCTAssertEqual(ledger.allEntries.count, 1)
        let entry = try! XCTUnwrap(ledger.entry(recoveryID: original.deliveryID))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.pendingEchoIDs, ["echo-original", "echo-replacement"])
        guard case .uncertain(let reason) = entry.state else {
            return XCTFail("an uncertain retry must remain risk-confirmed after echo expiry")
        }
        XCTAssertEqual(reason, "replacement echo expired")
        let card = ComposerSendRecoveryPresentationPolicy.presentation(for: entry)
        XCTAssertFalse(card.canRetry)
        XCTAssertTrue(card.canConfirmRiskRetry)
        XCTAssertNil(ledger.entry(recoveryID: replacement.deliveryID))
        XCTAssertEqual(ledger.retainedAttachmentIDs, ["image-replacement"])
    }

    func testExpiredReplacementEchoTurnsInFlightRetryUncertainOnOriginalRecoveryID() {
        var ledger = ComposerSendRecoveryLedger()
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
        XCTAssertTrue(ledger.recordFailure(snapshot: original, reason: "initial failure"))
        XCTAssertTrue(ledger.beginRetry(
            recoveryID: original.deliveryID,
            sessionID: original.sessionID,
            generationID: original.generationID,
            replacement: replacement
        )?.isNew == true)

        XCTAssertTrue(ledger.recordFailureForPendingEcho(
            snapshot: replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: "retry outcome is unknown"
        ))

        XCTAssertEqual(ledger.allEntries.count, 1)
        let entry = try! XCTUnwrap(ledger.entry(recoveryID: original.deliveryID))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.pendingEchoIDs, ["echo-original", "echo-replacement"])
        XCTAssertEqual(entry.state, .uncertain(reason: "retry outcome is unknown"))
        let card = ComposerSendRecoveryPresentationPolicy.presentation(for: entry)
        XCTAssertFalse(card.canRetry)
        XCTAssertTrue(card.canConfirmRiskRetry)
        XCTAssertNil(ledger.entry(recoveryID: replacement.deliveryID))
        XCTAssertEqual(ledger.retainedAttachmentIDs, ["image-replacement"])
    }

    func testExpiredReplacementEchoKeepsAwaitingCanonicalRetryOnOriginalRecoveryID() {
        var ledger = ComposerSendRecoveryLedger()
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
        XCTAssertTrue(ledger.recordFailure(snapshot: original, reason: "initial failure"))
        XCTAssertTrue(ledger.beginRetry(
            recoveryID: original.deliveryID,
            sessionID: original.sessionID,
            generationID: original.generationID,
            replacement: replacement
        )?.isNew == true)
        XCTAssertTrue(ledger.finishRetry(
            recoveryID: original.deliveryID,
            deliveryID: replacement.deliveryID,
            succeeded: true
        ))
        XCTAssertEqual(
            ledger.entry(recoveryID: original.deliveryID)?.state,
            .awaitingCanonical(deliveryID: replacement.deliveryID)
        )

        XCTAssertTrue(ledger.recordFailureForPendingEcho(
            snapshot: replacement,
            pendingEchoID: replacement.pendingEchoID!,
            reason: "replacement echo expired"
        ))

        XCTAssertEqual(ledger.allEntries.count, 1)
        let entry = try! XCTUnwrap(ledger.entry(recoveryID: original.deliveryID))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.pendingEchoIDs, ["echo-original", "echo-replacement"])
        guard case .uncertain(let reason) = entry.state else {
            return XCTFail("awaiting canonical must become risk-confirmed when its echo expires")
        }
        XCTAssertEqual(reason, "replacement echo expired")
        let card = ComposerSendRecoveryPresentationPolicy.presentation(for: entry)
        XCTAssertFalse(card.canRetry)
        XCTAssertTrue(card.canConfirmRiskRetry)
        XCTAssertNil(ledger.entry(recoveryID: replacement.deliveryID))
        XCTAssertEqual(ledger.retainedAttachmentIDs, ["image-replacement"])
    }

    func testExpiredReplacementEchoRejectsWrongEchoScopeAndSnapshotWithoutMutation() {
        var ledger = ComposerSendRecoveryLedger()
        let original = snapshot(
            deliveryID: "delivery-original",
            pendingEchoID: "echo-original"
        )
        let replacement = snapshot(
            deliveryID: "delivery-replacement",
            pendingEchoID: "echo-replacement"
        )
        XCTAssertTrue(ledger.recordFailure(snapshot: original, reason: "initial failure"))
        XCTAssertTrue(ledger.beginRetry(
            recoveryID: original.deliveryID,
            sessionID: original.sessionID,
            generationID: original.generationID,
            replacement: replacement
        )?.isNew == true)

        XCTAssertFalse(ledger.recordFailureForPendingEcho(
            snapshot: replacement,
            pendingEchoID: "echo-not-owned",
            reason: "wrong echo"
        ))
        XCTAssertFalse(ledger.recordFailureForPendingEcho(
            snapshot: snapshot(
                deliveryID: replacement.deliveryID,
                sessionID: "session-other",
                pendingEchoID: replacement.pendingEchoID
            ),
            pendingEchoID: replacement.pendingEchoID!,
            reason: "wrong session"
        ))
        XCTAssertFalse(ledger.recordFailureForPendingEcho(
            snapshot: snapshot(
                deliveryID: replacement.deliveryID,
                generationID: "generation-other",
                pendingEchoID: replacement.pendingEchoID
            ),
            pendingEchoID: replacement.pendingEchoID!,
            reason: "wrong generation"
        ))
        XCTAssertEqual(ledger.allEntries.count, 1)
        let entry = try! XCTUnwrap(ledger.entry(recoveryID: original.deliveryID))
        XCTAssertEqual(entry.snapshot, replacement)
        XCTAssertEqual(entry.pendingEchoIDs, ["echo-original", "echo-replacement"])
        XCTAssertEqual(entry.state, .retrying(deliveryID: replacement.deliveryID))
        XCTAssertNil(ledger.entry(recoveryID: replacement.deliveryID))
    }
}
