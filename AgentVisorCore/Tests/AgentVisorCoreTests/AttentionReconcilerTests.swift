import XCTest
@testable import AgentVisorCore

final class AttentionReconcilerTests: XCTestCase {
    func testNewYourTurnFiresOnce() {
        let items = [AttentionItem(sessionId: "a", kind: .yourTurn(turnToken: "3"))]
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

    func testNewTurnReFiresAfterTokenChange() {
        let turn1 = [AttentionItem(sessionId: "a", kind: .yourTurn(turnToken: "3"))]
        let r1 = AttentionReconciler.reconcile(current: turn1, previouslyNotified: [])
        // User replied, agent finished again → token advances.
        let turn2 = [AttentionItem(sessionId: "a", kind: .yourTurn(turnToken: "5"))]
        let r2 = AttentionReconciler.reconcile(current: turn2, previouslyNotified: r1.currentKeys)
        XCTAssertEqual(r2.newItems, turn2)
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
            AttentionItem(sessionId: "claude", kind: .yourTurn(turnToken: "2")),
            AttentionItem(sessionId: "codex", kind: .yourTurn(turnToken: "8")),
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
