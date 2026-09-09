import XCTest
@testable import AgentVisorCore

final class NativeMenuSessionOrderTests: XCTestCase {
    func testAdoptsPresentedRecencyOrderWithoutAPhaseChange() {
        let before = [pill("old", .ready, 0), pill("agi-poc", .ready, 1)]
        let after = [pill("old", .ready, 1), pill("agi-poc", .ready, 0)]
        XCTAssertEqual(NativeMenuSessionOrder.orderedPills(before).map(\.id), ["old", "agi-poc"])
        XCTAssertEqual(NativeMenuSessionOrder.orderedPills(after).map(\.id), ["agi-poc", "old"])
    }

    func testAcknowledgmentStopsThePulseWithoutDemotingTheCompletedPill() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let pills = [pill("old-unseen", .ready, 1), pill("new", .ready, 0)]
        var attention = NativeMenuReadyAttention()
        attention.present(previousPhases: ["new": .working, "old-unseen": .ready], pills: pills, now: now)
        XCTAssertTrue(attention.hasActivePulse(pills: pills, now: now))
        attention.acknowledgeReady(id: "new")
        XCTAssertFalse(attention.hasActivePulse(pills: pills, now: now))
        let acknowledged = [pills[0], pill("new", .ready, 0, acknowledged: true)]
        XCTAssertEqual(NativeMenuSessionOrder.orderedPills(acknowledged).map(\.id), ["new", "old-unseen"])
    }

    func testRecencyUpdatePreservesTheClickedTargetUntilTheSlideSettles() {
        let before = [pill("old", .ready, 0), pill("agi-poc", .ready, 1, acknowledged: true)]
        let after = [pill("old", .ready, 1), pill("agi-poc", .ready, 0, acknowledged: true)]
        let lane = CGRect(x: 0, y: 0, width: 200, height: 24)
        let pointer = CGPoint(x: 30, y: 12)
        var transition = NativeMenuLayoutTransition()
        func update(_ pills: [NativeHelperPill], pointer: CGPoint? = nil, now: TimeInterval)
            -> NativeMenuLayoutTransition.Presentation {
            let frames = Dictionary(uniqueKeysWithValues: NativeMenuSessionOrder.orderedPills(pills)
                .enumerated().map { index, pill in
                    (NativeMenuPanelTarget.session(pill.id), CGRect(x: index * 84, y: 0, width: 80, height: 24))
                })
            return transition.update(proposedFrames: frames, availableTargets: Set(frames.keys),
                safeAreas: [lane], pointer: pointer, mouseDown: false, shortcutsHeld: false,
                popoverOpen: false, reduceMotion: false, preferredTarget: .session("old"), now: now)
        }
        let initial = update(before, now: 0)
        let held = update(after, pointer: pointer, now: 1)
        XCTAssertEqual(held.frames, initial.frames)
        XCTAssertEqual(held.frames[.session("old")]?.minX, 0)
        _ = update(after, now: 2)
        _ = update(after, now: 2.12)
        XCTAssertTrue(update(after, now: 2.24).isMoving)
        let settled = update(after, now: 2.37)
        XCTAssertEqual(settled.frames[.session("agi-poc")]?.minX, 0)
        XCTAssertEqual(settled.frames[.session("old")]?.minX, 84)
        XCTAssertFalse(settled.isMoving)
    }

    func testPackingOverflowAndShortcutsShareThePresentedPriority() {
        let pills = [pill("old-unseen", .ready, 3), pill("agi-poc", .ready, 2, acknowledged: true),
                     pill("working", .working, 1), pill("needs", .needsYou, 0), pill("history", .history, 4)]
        let ordered = NativeMenuSessionOrder.orderedPills(pills)
        let packed = PillBarPacker.pack(
            candidates: ordered.map { .init(id: $0.id, pillWidth: 60) },
            leftMax: 234, rightMax: 0, pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        let visible = packed.leftVisibleIds + packed.rightVisibleIds
        XCTAssertEqual(visible, ["needs", "working", "agi-poc"])
        XCTAssertEqual(packed.hiddenIds, ["old-unseen", "history"])
        let shortcut = NativeMenuShortcutSnapshot(visibleSessionIDs: visible)
        XCTAssertEqual(shortcut.sessionID(at: 2), "agi-poc")
        let overflow = NativeMenuOverflowSnapshot(pills: ordered, visibleSessionIDs: Set(visible))
        XCTAssertEqual(overflow.selection(query: "").orderedSessionIDs, ["old-unseen", "history"])
        XCTAssertEqual(overflow.overflowSessionIDs.count, packed.hiddenCount)
    }

    func testEqualPrioritiesHaveDeterministicIDsAndDuplicateTargetsAreRemoved() {
        let pills = [pill("b", .ready, 1), pill("a", .ready, 1), pill("a", .ready, 2)]
        XCTAssertEqual(NativeMenuSessionOrder.orderedPills(pills).map(\.id), ["a", "b"])
        XCTAssertEqual(NativeMenuSessionOrder.orderedPills(pills.reversed()).map(\.id), ["a", "b"])
    }

    private func pill(_ id: String, _ phase: NativeHelperPillPhase, _ priority: Int,
                      acknowledged: Bool = false) -> NativeHelperPill {
        NativeHelperPill(id: id, title: id, phase: phase,
            attentionTier: acknowledged ? .acknowledgedReady : nil,
            priority: priority, accessibilityLabel: id)
    }
}
