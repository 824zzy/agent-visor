import XCTest
@testable import AgentVisorCore

final class AttentionReconcilerTests: XCTestCase {
    func testNewYourTurnFiresOnce() {
        let items = [AttentionItem(sessionId: "a", kind: .yourTurn)]
        let first = AttentionReconciler.reconcile(current: items, previouslyNotified: [])
        XCTAssertEqual(first.newItems, items)
        XCTAssertEqual(first.totalCount, 1)

        // Same turn, already notified — no re-fire, still counts.
        let second = AttentionReconciler.reconcile(
            current: items,
            previouslyNotified: first.currentKeys
        )
        XCTAssertTrue(second.newItems.isEmpty)
        XCTAssertEqual(second.totalCount, 1)
    }

    func testTranscriptHydrationDuringSameReadyEpisodeDoesNotRefire() {
        let settled = [AttentionItem(
            sessionId: "pi",
            kind: .yourTurn
        )]
        let first = AttentionReconciler.reconcile(
            current: settled,
            previouslyNotified: []
        )
        XCTAssertEqual(first.newItems, settled)

        // Captured Pi ordering: agent_settled publishes Ready first, then the
        // debounced transcript replay adds final thinking + text rows.
        let hydrated = [AttentionItem(
            sessionId: "pi",
            kind: .yourTurn
        )]
        let second = AttentionReconciler.reconcile(
            current: hydrated,
            previouslyNotified: first.currentKeys
        )

        XCTAssertTrue(second.newItems.isEmpty)
        XCTAssertTrue(second.resolvedKeys.isEmpty)
        XCTAssertEqual(second.currentKeys, ["pi|turn"])
        XCTAssertEqual(second.totalCount, 1)
    }

    func testLaterReadyEpisodeRefiresAfterWorkingSnapshot() {
        let ready = [AttentionItem(
            sessionId: "pi",
            kind: .yourTurn
        )]
        let first = AttentionReconciler.reconcile(
            current: ready,
            previouslyNotified: []
        )
        let working = AttentionReconciler.reconcile(
            current: [],
            previouslyNotified: first.currentKeys
        )
        XCTAssertEqual(working.resolvedKeys, ["pi|turn"])

        let laterReady = AttentionReconciler.reconcile(
            current: ready,
            previouslyNotified: working.currentKeys
        )

        XCTAssertEqual(laterReady.newItems, ready)
    }

    func testApprovalDedupedByToolUseId() {
        let items = [AttentionItem(sessionId: "a", kind: .approval(toolUseId: "tool-1"))]
        let r1 = AttentionReconciler.reconcile(current: items, previouslyNotified: [])
        XCTAssertEqual(r1.newItems.count, 1)
        let r2 = AttentionReconciler.reconcile(current: items, previouslyNotified: r1.currentKeys)
        XCTAssertTrue(r2.newItems.isEmpty)
    }

    func testResolutionReportsResolvedKeysAndZeroCount() {
        let items = [AttentionItem(sessionId: "a", kind: .approval(toolUseId: "tool-1"))]
        let r1 = AttentionReconciler.reconcile(current: items, previouslyNotified: [])
        // Approval resolved — nothing pending now.
        let r2 = AttentionReconciler.reconcile(current: [], previouslyNotified: r1.currentKeys)
        XCTAssertEqual(r2.resolvedKeys, ["a|approval|tool-1"])
        XCTAssertEqual(r2.totalCount, 0)
        XCTAssertTrue(r2.currentKeys.isEmpty)
    }

    func testMixedAgentsCountedTogether() {
        let items = [
            AttentionItem(sessionId: "claude", kind: .yourTurn),
            AttentionItem(sessionId: "codex", kind: .yourTurn),
            AttentionItem(sessionId: "claude2", kind: .approval(toolUseId: "t")),
        ]
        let r = AttentionReconciler.reconcile(current: items, previouslyNotified: [])
        XCTAssertEqual(r.newItems.count, 3)
        XCTAssertEqual(r.totalCount, 3)
    }

    func testReFireAfterResolutionAndReoccurrence() {
        let item = [AttentionItem(sessionId: "a", kind: .approval(toolUseId: "t"))]
        let r1 = AttentionReconciler.reconcile(current: item, previouslyNotified: [])
        let r2 = AttentionReconciler.reconcile(current: [], previouslyNotified: r1.currentKeys)
        // Same tool id requests again after resolving — should re-fire,
        // because the key was cleared from the notified set.
        let r3 = AttentionReconciler.reconcile(current: item, previouslyNotified: r2.currentKeys)
        XCTAssertEqual(r3.newItems, item)
    }
}
