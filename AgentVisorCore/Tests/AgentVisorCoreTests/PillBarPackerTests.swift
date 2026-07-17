import XCTest
@testable import AgentVisorCore

final class PillBarPackerTests: XCTestCase {
    // T1 tracer bullet: empty candidates → empty result.
    func testEmptyCandidatesReturnsEmptyResult() {
        let result = PillBarPacker.pack(
            candidates: [],
            leftMax: 100,
            rightMax: 100,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, [])
        XCTAssertEqual(result.rightVisibleIds, [])
        XCTAssertEqual(result.hiddenCount, 0)
        XCTAssertEqual(result.overflowSide, .right)
    }

    // T2: single pill that fits in leftMax lands on the left bar.
    func testSinglePillFitsLeft() {
        let result = PillBarPacker.pack(
            candidates: [.init(id: "a", pillWidth: 50)],
            leftMax: 100,
            rightMax: 100,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, ["a"])
        XCTAssertEqual(result.rightVisibleIds, [])
        XCTAssertEqual(result.hiddenCount, 0)
    }

    // T3: two pills that both fit are balanced ACROSS the notch (one per
    // side) rather than stacked on the left — the pills should flank the
    // notch. a(40) on the left, b(50) on the right minimizes imbalance.
    func testTwoPillsBalancedAcrossNotch() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 40),
                .init(id: "b", pillWidth: 50),
            ],
            leftMax: 100,
            rightMax: 100,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, ["a"])
        XCTAssertEqual(result.rightVisibleIds, ["b"])
        XCTAssertEqual(result.hiddenCount, 0)
    }

    // T4: three pills with room on both sides split for balance, keeping
    // reading order: a left of the notch, b+c right of it. (Left width 40
    // vs right width 84 is the most balanced feasible contiguous split.)
    func testThreePillsBalancedAcrossNotch() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 40),
                .init(id: "b", pillWidth: 50),
                .init(id: "c", pillWidth: 30),
            ],
            leftMax: 100,
            rightMax: 100,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, ["a"])
        XCTAssertEqual(result.rightVisibleIds, ["b", "c"])
        XCTAssertEqual(result.hiddenCount, 0)
    }

    // T4b: many equal-width pills with ample room split roughly in half so
    // they spread evenly around the notch instead of clustering left.
    func testManyPillsSplitEvenlyAroundNotch() {
        let result = PillBarPacker.pack(
            candidates: (0..<6).map { .init(id: "p\($0)", pillWidth: 40) },
            leftMax: 1000,
            rightMax: 1000,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.hiddenCount, 0)
        // Even split: 3 left, 3 right, reading order preserved.
        XCTAssertEqual(result.leftVisibleIds, ["p0", "p1", "p2"])
        XCTAssertEqual(result.rightVisibleIds, ["p3", "p4", "p5"])
    }

    // T5: right side reserves space for the +N overflow pill while packing.
    // 5 candidates @ width 40. leftMax=84 fits a + 4 + b = 84. rightMax=80
    // fits only c (40 + reserve 4+30 = 74 ≤ 80). Adding d would need
    // 40+4+40+4+30=118 > 80, so d and e remain hidden.
    func testHiddenCountWithRightOverflowReserve() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 40),
                .init(id: "b", pillWidth: 40),
                .init(id: "c", pillWidth: 40),
                .init(id: "d", pillWidth: 40),
                .init(id: "e", pillWidth: 40),
            ],
            leftMax: 84,
            rightMax: 80,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, ["a", "b"])
        XCTAssertEqual(result.rightVisibleIds, ["c"])
        XCTAssertEqual(result.hiddenCount, 2)
        XCTAssertEqual(result.overflowSide, .right)
    }

    func testOverflowExposesExactlyTheHiddenCandidatesInPriorityOrder() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "attention", pillWidth: 40),
                .init(id: "ready", pillWidth: 40),
                .init(id: "working", pillWidth: 40),
                .init(id: "recent-1", pillWidth: 40),
                .init(id: "recent-2", pillWidth: 40),
            ],
            leftMax: 84,
            rightMax: 80,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )

        XCTAssertEqual(result.hiddenIds, ["recent-1", "recent-2"])
        XCTAssertEqual(result.hiddenCount, result.hiddenIds.count)
    }

    // T6: when rightMax can't hold a +N pill, overflow falls back to the
    // left side. The left bar must then reserve room for +N during packing.
    // 3 candidates @ 40. leftMax=80, rightMax=0.
    // overflow side = .left because 0 < overflowPillWidthFor(1)=30.
    // Left packing with reserve: a fits (40+reserve 4+30=34 → 74 ≤ 80),
    // b doesn't (40+4+40+34=118 > 80). Hidden = 2.
    func testRightMaxZeroOverflowFallsBackToLeft() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 40),
                .init(id: "b", pillWidth: 40),
                .init(id: "c", pillWidth: 40),
            ],
            leftMax: 80,
            rightMax: 0,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, ["a"])
        XCTAssertEqual(result.rightVisibleIds, [])
        XCTAssertEqual(result.hiddenCount, 2)
        XCTAssertEqual(result.overflowSide, .left)
    }

    // T7: leftMax=0 (e.g. left AX probe failed) → all pills go to the
    // right bar, in candidate order.
    func testLeftMaxZeroAllPillsGoRight() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 40),
                .init(id: "b", pillWidth: 40),
            ],
            leftMax: 0,
            rightMax: 100,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, [])
        XCTAssertEqual(result.rightVisibleIds, ["a", "b"])
        XCTAssertEqual(result.hiddenCount, 0)
    }

    // T8: both sides fail-safe to 0 (e.g. AX probes failed on both sides).
    // Render nothing rather than risk overlap with menus or tray icons.
    // This deliberately breaks the "always show at least one pill"
    // guarantee from the single-bar design.
    func testBothMaxesZeroRendersNothing() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 40),
                .init(id: "b", pillWidth: 40),
            ],
            leftMax: 0,
            rightMax: 0,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, [])
        XCTAssertEqual(result.rightVisibleIds, [])
        XCTAssertEqual(result.hiddenCount, 2)
    }

    // T9: pillSpacing is added BETWEEN pills, never before the first one
    // on each side. Boundary test: leftMax and rightMax are EXACTLY the
    // pill width, so a leading spacing would push the pill out.
    func testNoSpacingBeforeFirstPillOnEachSide() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 40),
                .init(id: "b", pillWidth: 40),
            ],
            leftMax: 40,
            rightMax: 40,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, ["a"])
        XCTAssertEqual(result.rightVisibleIds, ["b"])
        XCTAssertEqual(result.hiddenCount, 0)
    }

    // T10: left-side overflow reserve, exact boundary. Guards the off-by-one
    // when +N lives on the left. rightMax=0 forces overflowSide=.left.
    // leftMax=74 is exactly a(40) + spacing(4) + overflow(30). a fits with
    // reserve; b would overflow leftMax; b is hidden.
    func testLeftOverflowReserveExactBoundary() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 40),
                .init(id: "b", pillWidth: 40),
            ],
            leftMax: 74,
            rightMax: 0,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, ["a"])
        XCTAssertEqual(result.rightVisibleIds, [])
        XCTAssertEqual(result.hiddenCount, 1)
        XCTAssertEqual(result.overflowSide, .left)
    }

    // T11: no-empty-side rebalance. When the first pass leaves the left
    // empty AND there's overflow, the packer retries with the first
    // candidate's `minimumWidth` (if it fits leftMax) and adopts the
    // retry. Marks the shortened candidate's id in `shortenedIds`.
    //
    // Scenario: 3 pills @ 50. leftMax=30 (no pill fits at width 50).
    // rightMax=84 (fits exactly a + spacing + b = 50+4+50=104? no, 84.
    // So only one pill + reserve fits on right.)
    // First pass: right packs b alone with reserve, hides 2 → left empty.
    // Rebalance: first candidate has minimumWidth=25, which fits leftMax=30.
    // Retried: a (width 25) on left, b on right, c hidden.
    func testNoEmptySideRebalanceShortensFirst() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 50, minimumWidth: 25),
                .init(id: "b", pillWidth: 50),
                .init(id: "c", pillWidth: 50),
            ],
            leftMax: 30,
            rightMax: 84,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, ["a"])
        XCTAssertEqual(result.rightVisibleIds, ["b"])
        XCTAssertEqual(result.hiddenCount, 1)
        XCTAssertEqual(result.shortenedIds, ["a"])
    }

    // T12: rebalance is a no-op when there's no overflow. Standard packing
    // wins, no shortenedIds.
    func testRebalanceSkippedWhenNoOverflow() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 50, minimumWidth: 25),
                .init(id: "b", pillWidth: 50),
            ],
            leftMax: 30,
            rightMax: 200, // plenty of room — no overflow
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, [])
        XCTAssertEqual(result.rightVisibleIds, ["a", "b"])
        XCTAssertEqual(result.hiddenCount, 0)
        XCTAssertEqual(result.shortenedIds, [])
    }

    // T13: rebalance is a no-op when the first candidate has no
    // minimumWidth. Original packing wins (left empty, right starts at a).
    func testRebalanceSkippedWithoutMinimumWidth() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 50),  // no minimumWidth
                .init(id: "b", pillWidth: 50),
                .init(id: "c", pillWidth: 50),
            ],
            leftMax: 30,
            rightMax: 84,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )
        XCTAssertEqual(result.leftVisibleIds, [])
        XCTAssertEqual(result.rightVisibleIds, ["a"])
        XCTAssertEqual(result.hiddenCount, 2)
        XCTAssertEqual(result.shortenedIds, [])
    }

    func testShortensLabelsBeforeOverflowingSessions() {
        let result = PillBarPacker.pack(
            candidates: [
                .init(id: "a", pillWidth: 90, minimumWidth: 50),
                .init(id: "b", pillWidth: 90, minimumWidth: 50),
                .init(id: "c", pillWidth: 90, minimumWidth: 50),
                .init(id: "d", pillWidth: 90, minimumWidth: 50),
            ],
            leftMax: 150,
            rightMax: 150,
            pillSpacing: 4,
            overflowPillWidthFor: { _ in 30 }
        )

        XCTAssertEqual(result.leftVisibleIds, ["a", "b"])
        XCTAssertEqual(result.rightVisibleIds, ["c", "d"])
        XCTAssertEqual(result.hiddenCount, 0)
        XCTAssertEqual(result.shortenedIds, ["b", "c", "d"])
    }
}
