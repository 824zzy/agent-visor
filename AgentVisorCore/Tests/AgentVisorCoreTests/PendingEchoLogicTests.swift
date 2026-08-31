//
//  PendingEchoLogicTests.swift
//  AgentVisorCoreTests
//
//  Tests the pure dictionary-mutation logic that PendingEchoStore (in
//  the main app target) delegates to. The store itself owns
//  @Published state + Combine; this Core type owns the WHAT-changes
//  decisions so they can be unit-tested without mocking SwiftUI.
//

import XCTest
@testable import AgentVisorCore

final class PendingEchoLogicTests: XCTestCase {
    // MARK: - push

    func test_push_appendsToSession() {
        var state: [String: [PendingEchoItem]] = [:]
        state = PendingEchoLogic.push(into: state, sessionId: "S1", id: "echo:1", text: "hello")
        XCTAssertEqual(state["S1"]?.count, 1)
        XCTAssertEqual(state["S1"]?.first?.id, "echo:1")
        XCTAssertEqual(state["S1"]?.first?.text, "hello")
    }

    func test_push_preservesExistingItems() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "first")]
        ]
        state = PendingEchoLogic.push(into: state, sessionId: "S1", id: "echo:2", text: "second")
        XCTAssertEqual(state["S1"]?.count, 2)
        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:1", "echo:2"])
    }

    func test_push_emptyText_isNoOp() {
        var state: [String: [PendingEchoItem]] = [:]
        state = PendingEchoLogic.push(into: state, sessionId: "S1", id: "echo:1", text: "")
        XCTAssertNil(state["S1"])
    }

    func test_push_whitespaceOnlyText_isNoOp() {
        var state: [String: [PendingEchoItem]] = [:]
        state = PendingEchoLogic.push(into: state, sessionId: "S1", id: "echo:1", text: "   \n\t")
        XCTAssertNil(state["S1"])
    }

    func test_push_imageOnlySubmission_createsRecoverableEcho() {
        var state: [String: [PendingEchoItem]] = [:]
        let submittedAt = Date(timeIntervalSince1970: 100)
        state = PendingEchoLogic.push(
            into: state,
            sessionId: "S1",
            id: "echo:image-only",
            text: "",
            imageReferences: ["/tmp/image.png"],
            submittedAt: submittedAt,
            deliveryID: "delivery:image-only"
        )

        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:image-only"])
        XCTAssertEqual(state["S1"]?.first?.imageReferences, ["/tmp/image.png"])
        XCTAssertEqual(state["S1"]?.first?.submittedAt, submittedAt)
        XCTAssertEqual(state["S1"]?.first?.deliveryID, "delivery:image-only")
    }

    // MARK: - evictById

    func test_evictById_removesOneAndKeepsRest() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "first"),
                PendingEchoItem(id: "echo:2", text: "second"),
            ]
        ]
        state = PendingEchoLogic.evict(from: state, sessionId: "S1", id: "echo:1")
        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:2"])
    }

    func test_evictById_lastItem_removesEntireSessionEntry() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "only")]
        ]
        state = PendingEchoLogic.evict(from: state, sessionId: "S1", id: "echo:1")
        XCTAssertNil(state["S1"])
    }

    func test_evictById_cancelTarget_preservesOtherDeliveriesAndSessions() {
        let initial: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "delivery:1", text: "first"),
                PendingEchoItem(id: "delivery:2", text: "second"),
            ],
            "S2": [PendingEchoItem(id: "delivery:1", text: "other session")]
        ]

        let result = PendingEchoLogic.evict(
            from: initial,
            sessionId: "S1",
            id: "delivery:1"
        )

        XCTAssertEqual(result["S1"]?.map(\.id), ["delivery:2"])
        XCTAssertEqual(result["S2"]?.map(\.id), ["delivery:1"])
    }

    // MARK: - reconcile (text-match against real JSONL turns)

    func test_reconcile_removesEchoMatchedByText() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "hello world")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["hello world"]
        )
        XCTAssertNil(result["S1"], "matched echo should evict; empty list collapses to nil entry")
    }

    func test_reconcile_keepsEchoNotInRealTexts() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "still pending"),
                PendingEchoItem(id: "echo:2", text: "already landed"),
            ]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["already landed"]
        )
        XCTAssertEqual(result["S1"]?.count, 1)
        XCTAssertEqual(result["S1"]?.first?.id, "echo:1")
    }

    func test_reconcile_trimsWhitespaceOnBothSides() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "  hello  ")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["hello"]
        )
        XCTAssertNil(result["S1"], "trimmed text comparison should match")
    }

    // MARK: - reconcile: image-paste prefix tolerance
    //
    // Claude Code's TUI rewrites the user turn in JSONL as
    // "[Image #N] <typed text>" when images are attached. The optimistic
    // echo carries only the typed text, so strict equality misses the
    // match. Reconcile should strip leading [Image]/[Image #N] tokens
    // from both sides before comparing.

    func test_reconcile_realTextWithImageNumberPrefix_matchesPlainEcho() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "No, you misunderstood")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #61] No, you misunderstood"]
        )
        XCTAssertNil(result["S1"], "[Image #N] prefix on real text should not block reconcile")
    }

    func test_reconcile_multipleImagePrefixes_matchPlainEcho() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "compare these")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #1] [Image #2] compare these"]
        )
        XCTAssertNil(result["S1"])
    }

    func test_reconcile_echoWithPlainImagePrefix_matchesNumberedReal() {
        // Chat's optimistic echo decorates with [Image] without a number.
        // Be tolerant on both sides.
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "[Image] hello")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #5] hello"]
        )
        XCTAssertNil(result["S1"])
    }

    func test_reconcile_imagePrefixOnUnrelatedText_doesNotFalseMatch() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "hello world")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #1] something else entirely"]
        )
        XCTAssertEqual(result["S1"]?.count, 1, "different post-prefix text must not match")
    }

    func test_reconcile_midStringImageMention_isNotStripped() {
        // Only LEADING [Image #N] tokens are placeholder injections.
        // Mid-string mentions are real content; matching stays exact.
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "see [Image #1]?")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["see [Image #1]?"]
        )
        XCTAssertNil(result["S1"], "exact-string mid-mention still matches")
    }

    func test_reconcile_imagePrefixOnly_doesNotEvictPlainEcho() {
        // An image-only canonical row has no text and must not match a
        // plain-text echo merely because its display placeholder is similar.
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "hello")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #1]"]
        )
        XCTAssertEqual(result["S1"]?.count, 1)
    }

    func test_reconcileIdentified_imageOnlyCanonicalConsumesExactlyOneNewImageEcho() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(
                    id: "echo:image-1",
                    text: "[Image]",
                    imageReferences: ["/tmp/image-a.png"]
                ),
                PendingEchoItem(
                    id: "echo:image-2",
                    text: "[Image]",
                    imageReferences: ["/tmp/image-a.png"]
                )
            ]
        ]
        var seen: [String] = ["canonical:old-image"]

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [
                PendingEchoCanonicalItem(
                    id: "canonical:new-image",
                    text: "",
                    imageReferences: ["/tmp/image-a.png"]
                )
            ],
            seenCanonicalIDs: &seen
        )

        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:image-2"])
    }

    func test_reconcileIdentified_imageOnlyReplayAndOldBaselineDoNotConsumeNewEcho() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(
                id: "echo:new",
                text: "[Image]",
                imageReferences: ["/tmp/image-a.png"]
            )]
        ]
        var seen: [String] = ["canonical:old-image"]
        let old = [PendingEchoCanonicalItem(
            id: "canonical:old-image",
            text: "",
            imageReferences: ["/tmp/image-a.png"]
        )]

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: old,
            seenCanonicalIDs: &seen
        )
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: old,
            seenCanonicalIDs: &seen
        )

        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:new"])
    }

    func test_reconcileIdentified_imageReferencesMustMatchWhenCanonicalCarriesThem() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(
                id: "echo:image",
                text: "[Image]",
                imageReferences: ["/tmp/image-a.png"]
            )]
        ]
        var seen: [String] = []

        let result = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:wrong-image",
                text: "",
                imageReferences: ["/tmp/image-b.png"]
            )],
            seenCanonicalIDs: &seen
        )

        XCTAssertEqual(result["S1"]?.map(\.id), ["echo:image"])
    }

    func test_reconcile_oneCanonicalTurn_consumesOnlyOneIdenticalEcho() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "same"),
                PendingEchoItem(id: "echo:2", text: "same"),
            ]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["same"]
        )
        XCTAssertEqual(result["S1"]?.map(\.id), ["echo:2"])
    }

    func test_reconcile_twoCanonicalTurns_consumesTwoIdenticalEchoes() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "same"),
                PendingEchoItem(id: "echo:2", text: "same"),
            ]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["same", "same"]
        )
        XCTAssertNil(result["S1"])
    }

    func test_reconcile_identifiedCanonicalReplay_consumesOnlyOnce() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "same"),
                PendingEchoItem(id: "echo:2", text: "same"),
            ]
        ]
        var seenCanonicalIDs: Set<String> = []
        let canonical = [PendingEchoCanonicalItem(id: "real:1", text: "same")]

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: canonical,
            seenCanonicalIDs: &seenCanonicalIDs
        )
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: canonical,
            seenCanonicalIDs: &seenCanonicalIDs
        )

        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:2"])
    }

    func test_reconcile_identifiedDuplicateRowsInOnePageConsumeOnlyOnce() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "same"),
                PendingEchoItem(id: "echo:2", text: "same"),
            ]
        ]
        var seenCanonicalIDs: [String] = []
        let duplicatePage = [
            PendingEchoCanonicalItem(id: "real:1", text: "same"),
            PendingEchoCanonicalItem(id: "real:1", text: "same"),
        ]

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: duplicatePage,
            seenCanonicalIDs: &seenCanonicalIDs
        )

        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:2"])
        XCTAssertEqual(seenCanonicalIDs, ["real:1"])
    }

    func test_reconcile_identified_orderedHistorySurvivesPageReplay() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "same"),
                PendingEchoItem(id: "echo:2", text: "same"),
            ]
        ]
        var seenCanonicalIDs: [String] = []

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(id: "real:a", text: "same")],
            seenCanonicalIDs: &seenCanonicalIDs
        )
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(id: "real:b", text: "unrelated")],
            seenCanonicalIDs: &seenCanonicalIDs
        )
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(id: "real:a", text: "same")],
            seenCanonicalIDs: &seenCanonicalIDs
        )

        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:2"])
        XCTAssertEqual(seenCanonicalIDs, ["real:a", "real:b"])
    }

    func test_rememberCanonicalIDsSeedsBaselineWithoutConsumingEchoes() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:new", text: "same")]
        ]
        var seenCanonicalIDs: [String] = []
        let oldHistory = [PendingEchoCanonicalItem(id: "real:old", text: "same")]

        PendingEchoLogic.rememberCanonicalIDs(
            oldHistory,
            seenCanonicalIDs: &seenCanonicalIDs
        )
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: oldHistory,
            seenCanonicalIDs: &seenCanonicalIDs
        )

        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:new"])
        XCTAssertEqual(seenCanonicalIDs, ["real:old"])
    }

    func test_reconcile_identified_seenHistoryIsInsertionOrderedAndBounded() {
        var state: [String: [PendingEchoItem]] = [:]
        var seenCanonicalIDs: [String] = []
        let firstPage = (0..<512).map {
            PendingEchoCanonicalItem(id: "real:\($0)", text: "turn \($0)")
        }
        let secondPage = [
            PendingEchoCanonicalItem(id: "real:511", text: "duplicate"),
            PendingEchoCanonicalItem(id: "real:512", text: "new"),
            PendingEchoCanonicalItem(id: "real:513", text: "new"),
        ]

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: firstPage,
            seenCanonicalIDs: &seenCanonicalIDs
        )
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: secondPage,
            seenCanonicalIDs: &seenCanonicalIDs
        )

        XCTAssertEqual(seenCanonicalIDs.count, 512)
        XCTAssertEqual(seenCanonicalIDs.first, "real:2")
        XCTAssertEqual(seenCanonicalIDs.suffix(2), ["real:512", "real:513"])
        XCTAssertEqual(state, [:], "canonical turns are still independent of the history cap")
    }

    func test_reconcile_identified_orderedHistoryIsSessionIsolated() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:s1:1", text: "same"),
                PendingEchoItem(id: "echo:s1:2", text: "same"),
            ],
            "S2": [
                PendingEchoItem(id: "echo:s2:1", text: "same"),
                PendingEchoItem(id: "echo:s2:2", text: "same"),
            ],
        ]
        var seenCanonicalIDsBySession: [String: [String]] = [:]
        let pageA = [PendingEchoCanonicalItem(id: "real:a", text: "same")]
        let pageB = [PendingEchoCanonicalItem(id: "real:b", text: "unrelated")]

        for sessionId in ["S1", "S2"] {
            state = PendingEchoLogic.reconcileIdentified(
                state,
                sessionId: sessionId,
                realUserItems: pageA,
                seenCanonicalIDs: &seenCanonicalIDsBySession[sessionId, default: []]
            )
        }
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: pageB,
            seenCanonicalIDs: &seenCanonicalIDsBySession["S1", default: []]
        )
        for sessionId in ["S1", "S2"] {
            state = PendingEchoLogic.reconcileIdentified(
                state,
                sessionId: sessionId,
                realUserItems: pageA,
                seenCanonicalIDs: &seenCanonicalIDsBySession[sessionId, default: []]
            )
        }

        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:s1:2"])
        XCTAssertEqual(state["S2"]?.map(\.id), ["echo:s2:2"])
        XCTAssertEqual(seenCanonicalIDsBySession["S1"], ["real:a", "real:b"])
        XCTAssertEqual(seenCanonicalIDsBySession["S2"], ["real:a"])
    }

    func test_reconcileIdentified_contentFallbackRequiresAuthoritativePostSubmitOccurrence() {
        let submittedAt = Date(timeIntervalSince1970: 100)
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(
                id: "echo:text",
                text: "same",
                submittedAt: submittedAt
            )]
        ]
        var seen: [String] = []

        let oldHistory = [PendingEchoCanonicalItem(
            id: "canonical:old",
            text: "same",
            occurredAt: Date(timeIntervalSince1970: 99)
        )]
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: oldHistory,
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: true)
        )
        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:text"])

        let missingTimestamp = [PendingEchoCanonicalItem(id: "canonical:missing", text: "same")]
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: missingTimestamp,
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: true)
        )
        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:text"])

        let incompleteBaseline = [PendingEchoCanonicalItem(
            id: "canonical:incomplete",
            text: "same",
            occurredAt: Date(timeIntervalSince1970: 101)
        )]
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: incompleteBaseline,
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: false)
        )
        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:text"])

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:new",
                text: "same",
                occurredAt: Date(timeIntervalSince1970: 101)
            )],
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: true)
        )
        XCTAssertNil(state["S1"])
    }

    func test_reconcileIdentified_exactDeliveryIdentityCanMatchWithoutTimestamp() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(
                id: "echo:exact",
                text: "same",
                submittedAt: Date(timeIntervalSince1970: 100),
                deliveryID: "delivery:exact"
            )]
        ]
        var seen: [String] = []

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:exact",
                text: "same",
                deliveryID: "delivery:exact"
            )],
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: false, baselineComplete: false)
        )

        XCTAssertNil(state["S1"], "exact delivery identity is sufficient even when provider time is absent")
    }

    func test_reconcileIdentified_imageFallbackUsesTheSameOccurrenceBoundary() {
        let submittedAt = Date(timeIntervalSince1970: 100)
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(
                id: "echo:image",
                text: "",
                imageReferences: ["/tmp/image-a.png"],
                submittedAt: submittedAt
            )]
        ]
        var seen: [String] = []

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:old-image",
                text: "",
                imageReferences: ["/tmp/image-a.png"],
                occurredAt: Date(timeIntervalSince1970: 99)
            )],
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: true)
        )
        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:image"])

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:new-image",
                text: "",
                imageReferences: ["/tmp/image-a.png"],
                occurredAt: Date(timeIntervalSince1970: 101)
            )],
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: true)
        )
        XCTAssertNil(state["S1"])
    }

    func test_reconcileIdentified_authoritativeEmptyBaselineStillRejectsOldRow() {
        let submittedAt = Date(timeIntervalSince1970: 100)
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(
                id: "echo:empty-baseline",
                text: "same",
                submittedAt: submittedAt
            )]
        ]
        var seen: [String] = []
        let context = PendingEchoReconciliationContext(
            authoritativeLatest: true,
            baselineComplete: true
        )

        // A genuinely empty, fully loaded transcript is a complete baseline;
        // a later replayed row must still prove it occurred after submission.
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [],
            seenCanonicalIDs: &seen,
            context: context
        )
        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:old-after-empty",
                text: "same",
                occurredAt: Date(timeIntervalSince1970: 99)
            )],
            seenCanonicalIDs: &seen,
            context: context
        )
        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:empty-baseline"])

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:new-after-empty",
                text: "same",
                occurredAt: Date(timeIntervalSince1970: 101)
            )],
            seenCanonicalIDs: &seen,
            context: context
        )
        XCTAssertNil(state["S1"])
    }

    func test_reconcileIdentified_explicitDeliveryMismatchNeverFallsBackToContent() {
        let submittedAt = Date(timeIntervalSince1970: 100)
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(
                    id: "echo:text",
                    text: "same",
                    submittedAt: submittedAt,
                    deliveryID: "delivery:expected"
                ),
                PendingEchoItem(
                    id: "echo:image",
                    text: "",
                    imageReferences: ["/tmp/image.png"],
                    submittedAt: submittedAt,
                    deliveryID: "delivery:expected"
                )
            ]
        ]
        var seen: [String] = []

        state = PendingEchoLogic.reconcileIdentified(
            state,
            sessionId: "S1",
            realUserItems: [
                PendingEchoCanonicalItem(
                    id: "canonical:text-mismatch",
                    text: "same",
                    occurredAt: Date(timeIntervalSince1970: 101),
                    deliveryID: "delivery:other"
                ),
                PendingEchoCanonicalItem(
                    id: "canonical:image-mismatch",
                    text: "",
                    imageReferences: ["/tmp/image.png"],
                    occurredAt: Date(timeIntervalSince1970: 101),
                    deliveryID: "delivery:other"
                )
            ],
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: true)
        )

        XCTAssertEqual(
            state["S1"]?.map(\.id),
            ["echo:text", "echo:image"],
            "an explicit provider identity must block content/image fallback"
        )
    }

    func test_reconcileAuthoritativeLatest_matchesDetachedPostSubmitTextBeforeRememberingIt() {
        let submittedAt = Date(timeIntervalSince1970: 100)
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:detached", text: "same", submittedAt: submittedAt)]
        ]
        var seen: [String] = []

        state = PendingEchoLogic.reconcileAuthoritativeLatest(
            state,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:detached",
                text: "same",
                occurredAt: Date(timeIntervalSince1970: 101)
            )],
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: true)
        )

        XCTAssertNil(state["S1"])
        XCTAssertEqual(seen, ["canonical:detached"])
    }

    func test_reconcileAuthoritativeLatest_imageOnlyDetachedRowIsOneToOneAndReplaySafe() {
        let submittedAt = Date(timeIntervalSince1970: 100)
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(
                    id: "echo:image-1",
                    text: "",
                    imageReferences: ["/tmp/image.png"],
                    submittedAt: submittedAt
                ),
                PendingEchoItem(
                    id: "echo:image-2",
                    text: "",
                    imageReferences: ["/tmp/image.png"],
                    submittedAt: submittedAt
                )
            ]
        ]
        var seen: [String] = []
        let canonical = PendingEchoCanonicalItem(
            id: "canonical:image",
            text: "",
            imageReferences: ["/tmp/image.png"],
            occurredAt: Date(timeIntervalSince1970: 101)
        )

        state = PendingEchoLogic.reconcileAuthoritativeLatest(
            state,
            sessionId: "S1",
            realUserItems: [canonical],
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: true)
        )
        state = PendingEchoLogic.reconcileAuthoritativeLatest(
            state,
            sessionId: "S1",
            realUserItems: [canonical],
            seenCanonicalIDs: &seen,
            context: .init(authoritativeLatest: true, baselineComplete: true)
        )

        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:image-2"],
                       "one canonical row consumes one image echo and replay cannot consume another")
    }

    func test_reconcileAuthoritativeLatest_exactIdentityWorksWithoutTimestampAndEarlierContextDoesNotUseText() {
        var exactState: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(
                id: "echo:exact",
                text: "same",
                submittedAt: Date(timeIntervalSince1970: 100),
                deliveryID: "delivery:exact"
            )]
        ]
        var exactSeen: [String] = []
        exactState = PendingEchoLogic.reconcileAuthoritativeLatest(
            exactState,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:exact",
                text: "same",
                deliveryID: "delivery:exact"
            )],
            seenCanonicalIDs: &exactSeen,
            context: .init(authoritativeLatest: true, baselineComplete: false)
        )
        XCTAssertNil(exactState["S1"])

        var earlierState: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(
                id: "echo:earlier",
                text: "same",
                submittedAt: Date(timeIntervalSince1970: 100)
            )]
        ]
        var earlierSeen: [String] = []
        earlierState = PendingEchoLogic.reconcileAuthoritativeLatest(
            earlierState,
            sessionId: "S1",
            realUserItems: [PendingEchoCanonicalItem(
                id: "canonical:earlier",
                text: "same",
                occurredAt: Date(timeIntervalSince1970: 101)
            )],
            seenCanonicalIDs: &earlierSeen,
            context: .init(authoritativeLatest: false, baselineComplete: false)
        )
        XCTAssertEqual(earlierState["S1"]?.map(\.id), ["echo:earlier"])
    }
}
