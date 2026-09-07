import XCTest
@testable import AgentVisorCore

final class NativeMenuSessionOrderTests: XCTestCase {
    func testKeepsPositionsAcrossRecencyOnlyReordering() {
        XCTAssertEqual(
            NativeMenuSessionOrder.resolve(
                displayedIDs: ["session-a", "session-b"],
                previousPhases: ["session-a": .ready, "session-b": .ready],
                presentedPills: [pill("session-b", .ready), pill("session-a", .ready)]
            ),
            ["session-a", "session-b"]
        )
    }

    func testWorkingPrecedesUnseenAndSeenCompletionsWithoutDisturbingPeers() {
        XCTAssertEqual(
            NativeMenuSessionOrder.applyingReadyAcknowledgments(
                displayedIDs: ["needs", "ready-a", "ready-b", "working", "history"],
                phases: [
                    "needs": .needsYou,
                    "ready-a": .ready,
                    "ready-b": .ready,
                    "working": .working,
                    "history": .history,
                ],
                acknowledgedReadyIDs: ["ready-a"]
            ),
            ["needs", "working", "ready-b", "ready-a", "history"]
        )
    }

    func testSamePhaseRefreshAppliesAttentionOrderWhileKeepingPeerPositions() {
        let pills = [pill("ready-b", .ready), pill("ready-a", .ready),
                     pill("work-b", .working), pill("work-a", .working)]
        let phases = Dictionary(uniqueKeysWithValues: pills.map { ($0.id, $0.phase) })
        let stableIDs = NativeMenuSessionOrder.resolve(
            displayedIDs: ["ready-a", "ready-b", "work-a", "work-b"],
            previousPhases: phases,
            presentedPills: pills
        )
        let unseen = NativeMenuSessionOrder.applyingReadyAcknowledgments(
            displayedIDs: stableIDs, phases: phases, acknowledgedReadyIDs: []
        )
        XCTAssertEqual(unseen, ["work-a", "work-b", "ready-a", "ready-b"])
        let seen = NativeMenuSessionOrder.applyingReadyAcknowledgments(
            displayedIDs: unseen, phases: phases, acknowledgedReadyIDs: ["ready-a"]
        )
        XCTAssertEqual(seen, ["work-a", "work-b", "ready-b", "ready-a"])
    }

    func testPackingOverflowAndShortcutsShareTheWorkingFirstOrder() {
        let pills = [pill("unseen", .ready), pill("seen", .ready),
                     pill("working", .working), pill("needs", .needsYou), pill("history", .history)]
        let byID = Dictionary(uniqueKeysWithValues: pills.map { ($0.id, $0) })
        let ordered = NativeMenuSessionOrder.applyingReadyAcknowledgments(
            displayedIDs: pills.map(\.id), phases: byID.mapValues(\.phase),
            acknowledgedReadyIDs: ["seen"]
        )
        let packed = PillBarPacker.pack(
            candidates: ordered.map { .init(id: $0, pillWidth: 60) },
            leftMax: 170, rightMax: 0, pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        let visible = packed.leftVisibleIds + packed.rightVisibleIds
        XCTAssertEqual(visible, ["needs", "working"])
        XCTAssertEqual(packed.hiddenIds, ["unseen", "seen", "history"])
        let shortcut = NativeMenuShortcutSnapshot(visibleSessionIDs: visible)
        XCTAssertEqual(shortcut.sessionID(at: 1), "working")
        let overflow = NativeMenuOverflowSnapshot(
            pills: ordered.compactMap { byID[$0] }, visibleSessionIDs: Set(visible)
        )
        XCTAssertEqual(overflow.selection(query: "").orderedSessionIDs, packed.hiddenIds)
        XCTAssertEqual(overflow.overflowSessionIDs.count, packed.hiddenCount)
    }

    func testAdoptsPresentedOrderAfterPhaseOrMembershipChanges() {
        XCTAssertEqual(
            NativeMenuSessionOrder.resolve(
                displayedIDs: ["session-b", "session-a"],
                previousPhases: ["session-a": .ready, "session-b": .ready],
                presentedPills: [pill("session-a", .ready), pill("session-b", .working)]
            ),
            ["session-a", "session-b"]
        )
        XCTAssertEqual(
            NativeMenuSessionOrder.resolve(
                displayedIDs: ["session-a", "session-b"],
                previousPhases: ["session-a": .ready, "session-b": .working],
                presentedPills: [pill("session-c", .ready), pill("session-a", .ready)]
            ),
            ["session-c", "session-a"]
        )
    }

    private func pill(_ id: String, _ phase: NativeHelperPillPhase) -> NativeHelperPill {
        NativeHelperPill(
            id: id,
            title: id,
            phase: phase,
            priority: 0,
            accessibilityLabel: id
        )
    }
}
