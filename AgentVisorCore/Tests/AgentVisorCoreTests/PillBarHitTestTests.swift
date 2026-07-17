import XCTest
@testable import AgentVisorCore

final class PillBarHitTestTests: XCTestCase {
    private let spacing: CGFloat = 4

    // MARK: - Empty / Outside

    func testNoPillsReturnsOutside() {
        let result = PillBarHitTest.resolve(
            clickX: 50,
            side: .left,
            sessionPills: [],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 100,
            barWidth: 100
        )
        XCTAssertEqual(result, .outside)
    }

    func testClickOutsideBarBoundsReturnsOutside() {
        // Left bar anchored at 100 with barWidth 100: spans [0, 100].
        // Click at -10 is outside.
        let result = PillBarHitTest.resolve(
            clickX: -10,
            side: .left,
            sessionPills: [.init(id: "a", width: 40)],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 100,
            barWidth: 100
        )
        XCTAssertEqual(result, .outside)
    }

    // MARK: - Left Bar

    // Left bar with one pill: anchor=200, pillWidth=40 → pill spans [160, 200].
    func testLeftBarSinglePillHit() {
        let result = PillBarHitTest.resolve(
            clickX: 180,
            side: .left,
            sessionPills: [.init(id: "a", width: 40)],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 200,
            barWidth: 100
        )
        XCTAssertEqual(result, .session(id: "a"))
    }

    // sessionPills[0] is closest to the notch on the left bar (rightmost
    // visually). sessionPills[1] sits to its left.
    func testLeftBarOrderingNotchClosestFirst() {
        // anchor=200, pill[0] width 40 → [160, 200]
        // spacing 4 → next anchor = 156
        // pill[1] width 40 → [116, 156]
        let result0 = PillBarHitTest.resolve(
            clickX: 180,
            side: .left,
            sessionPills: [.init(id: "near", width: 40), .init(id: "far", width: 40)],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 200,
            barWidth: 200
        )
        XCTAssertEqual(result0, .session(id: "near"))

        let result1 = PillBarHitTest.resolve(
            clickX: 130,
            side: .left,
            sessionPills: [.init(id: "near", width: 40), .init(id: "far", width: 40)],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 200,
            barWidth: 200
        )
        XCTAssertEqual(result1, .session(id: "far"))
    }

    func testLeftBarClickInGapReturnsEmpty() {
        // anchor=200, pill[0] [160,200], spacing 4 → gap [156,160], pill[1] [116,156]
        let result = PillBarHitTest.resolve(
            clickX: 158,
            side: .left,
            sessionPills: [.init(id: "near", width: 40), .init(id: "far", width: 40)],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 200,
            barWidth: 200
        )
        XCTAssertEqual(result, .empty)
    }

    // Left bar with overflow: +N is the OUTERMOST slot, beyond the last pill.
    // anchor=200, pill[0] [160,200], spacing 4, overflow width 30 → [126, 156]
    func testLeftBarOverflowHit() {
        let result = PillBarHitTest.resolve(
            clickX: 140,
            side: .left,
            sessionPills: [.init(id: "near", width: 40)],
            overflowWidth: 30,
            pillSpacing: spacing,
            barAnchorX: 200,
            barWidth: 200
        )
        XCTAssertEqual(result, .overflow)
    }

    // MARK: - Right Bar

    // Right bar: anchor=300, pill[0] width 40 → [300, 340]; sessionPills[0]
    // is closest to the notch (leftmost visually for the right bar).
    func testRightBarSinglePillHit() {
        let result = PillBarHitTest.resolve(
            clickX: 320,
            side: .right,
            sessionPills: [.init(id: "a", width: 40)],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 300,
            barWidth: 100
        )
        XCTAssertEqual(result, .session(id: "a"))
    }

    func testRightBarOrderingNotchClosestFirst() {
        // anchor=300, pill[0] [300,340], spacing 4, pill[1] [344,384]
        let result0 = PillBarHitTest.resolve(
            clickX: 310,
            side: .right,
            sessionPills: [.init(id: "near", width: 40), .init(id: "far", width: 40)],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 300,
            barWidth: 200
        )
        XCTAssertEqual(result0, .session(id: "near"))

        let result1 = PillBarHitTest.resolve(
            clickX: 360,
            side: .right,
            sessionPills: [.init(id: "near", width: 40), .init(id: "far", width: 40)],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 300,
            barWidth: 200
        )
        XCTAssertEqual(result1, .session(id: "far"))
    }

    func testRightBarOverflowHit() {
        // anchor=300, pill[0] [300,340], spacing 4, overflow [344,374]
        let result = PillBarHitTest.resolve(
            clickX: 360,
            side: .right,
            sessionPills: [.init(id: "near", width: 40)],
            overflowWidth: 30,
            pillSpacing: spacing,
            barAnchorX: 300,
            barWidth: 200
        )
        XCTAssertEqual(result, .overflow)
    }

    func testRightBarUsageUtilityIsOutboardOfOverflow() {
        // Session [300,340], overflow [344,374], usage [378,434].
        let result = PillBarHitTest.resolve(
            clickX: 400,
            side: .right,
            sessionPills: [.init(id: "near", width: 40)],
            overflowWidth: 30,
            usageWidth: 56,
            pillSpacing: spacing,
            barAnchorX: 300,
            barWidth: 200
        )

        XCTAssertEqual(result, .usage)
    }

    func testSnapshotCanResolveUsageWithoutSessionPills() {
        let snapshot = PillBarHitTest.PillBarSnapshot(
            leftSlots: [],
            rightSlots: [],
            leftOverflowWidth: nil,
            rightOverflowWidth: nil,
            rightUsageWidth: 56,
            leftAnchorX: 0,
            rightAnchorX: 300,
            leftBarWidth: 0,
            rightBarWidth: 100,
            pillSpacing: spacing
        )

        XCTAssertEqual(
            PillBarHitTest.resolve(clickX: 328, snapshot: snapshot),
            .usage
        )
    }

    func testSnapshotPointOutsideVerticalStripReturnsOutside() {
        let snapshot = PillBarHitTest.PillBarSnapshot(
            leftSlots: [],
            rightSlots: [.init(id: "a", width: 40)],
            leftOverflowWidth: nil,
            rightOverflowWidth: nil,
            leftAnchorX: 0,
            rightAnchorX: 300,
            leftBarWidth: 0,
            rightBarWidth: 100,
            pillSpacing: spacing,
            minY: 1290,
            maxY: 1329
        )

        XCTAssertEqual(
            PillBarHitTest.resolve(click: CGPoint(x: 320, y: 1040), snapshot: snapshot),
            .outside
        )
        XCTAssertEqual(
            PillBarHitTest.resolve(click: CGPoint(x: 320, y: 1310), snapshot: snapshot),
            .session(id: "a")
        )
    }

    // MARK: - Boundary precision

    // Click exactly on a pill's edge counts as a hit. Real bars get a
    // floating-point coordinate from the system, so inclusive bounds are
    // safer than exclusive: a 0.5 px error on an edge slot shouldn't drop
    // the click silently.
    func testClickOnPillEdgeIsHit() {
        let r = PillBarHitTest.resolve(
            clickX: 200, // exactly at anchor → end of pill[0] on left bar
            side: .left,
            sessionPills: [.init(id: "a", width: 40)],
            overflowWidth: nil,
            pillSpacing: spacing,
            barAnchorX: 200,
            barWidth: 100
        )
        XCTAssertEqual(r, .session(id: "a"))
    }

    // MARK: - Snapshot-based resolution
    //
    // The motivating bug ("first click goes to the adjacent pill, second
    // click lands correctly"): SwiftUI body re-evaluation on a
    // `lastActivity` bump can re-sort `sessionMonitor.instances` in the
    // few milliseconds between render and click. The OLD `handleSideClick`
    // recomputed the pack from the *live* array, so a click on the pill
    // the user *saw* resolved to the pill that *replaced* it after the
    // re-sort — the off-by-one symptom.
    //
    // We can't unit-test the SwiftUI race itself (no SwiftUI test target
    // here, and "click queued before relayout" is awful to make
    // deterministic). What we CAN test is the contract one level down:
    //   1. The hit-test API exposes a `PillBarSnapshot` value-type that
    //      callers capture at render time.
    //   2. `resolve(clickX:snapshot:)` returns whatever that captured
    //      snapshot says — never something derived from live state.
    //   3. A rendered snapshot vs. a divergent live-state snapshot at
    //      the same `clickX` produce DIFFERENT hits (this is the whole
    //      point: if they were always equal, snapshot capture would be
    //      vacuous).
    //
    // This makes the regression structurally hard to reintroduce — the
    // only correct caller shape is "build snapshot in body, pass it to
    // resolve at click time," and any code that recomputes a snapshot
    // inside the click handler is visible at review.

    /// The bug, pinned: against a snapshot captured at render time the
    /// click resolves to the pill the user saw; against a divergent
    /// live-state snapshot the same click lands on a different pill.
    /// If this assertion is ever weakened (both equal), snapshot capture
    /// has stopped being load-bearing — investigate.
    func test_resolveAgainstSnapshot_renderedAndLiveDiverge() {
        // Rendered at T0: right bar shows [B, A]. User clicks B.
        let rendered = PillBarHitTest.PillBarSnapshot(
            leftSlots: [],
            rightSlots: [
                .init(id: "B", width: 40),
                .init(id: "A", width: 40),
            ],
            leftOverflowWidth: nil,
            rightOverflowWidth: nil,
            leftAnchorX: 0,
            rightAnchorX: 300,
            leftBarWidth: 0,
            rightBarWidth: 200,
            pillSpacing: spacing
        )
        // Live at T0+5ms: a hook bumped A.lastActivity, re-sort flipped
        // the bar to [A, B] before handleSideClick fires. Same widths,
        // same anchors — only the pill order differs.
        let live = PillBarHitTest.PillBarSnapshot(
            leftSlots: [],
            rightSlots: [
                .init(id: "A", width: 40),
                .init(id: "B", width: 40),
            ],
            leftOverflowWidth: nil,
            rightOverflowWidth: nil,
            leftAnchorX: 0,
            rightAnchorX: 300,
            leftBarWidth: 0,
            rightBarWidth: 200,
            pillSpacing: spacing
        )
        // clickX=320 lands on the rightmost-anchored slot ([300, 340]).
        XCTAssertEqual(
            PillBarHitTest.resolve(clickX: 320, snapshot: rendered),
            .session(id: "B"),
            "snapshot captured at render time must resolve to the pill the user saw"
        )
        XCTAssertEqual(
            PillBarHitTest.resolve(clickX: 320, snapshot: live),
            .session(id: "A"),
            "a divergent live-state snapshot would land on the wrong pill — that's the regression we're guarding against"
        )
    }

    /// Two-bar dispatch: a single resolve call must try the left bar,
    /// then the right, and return the first hit. (Mirrors the old
    /// `handleSideClick` flow, lifted into a pure function so the
    /// dispatch logic is testable in isolation.)
    func test_resolveSnapshot_triesLeftBeforeRight() {
        // Both bars present. clickX=180 lands on the left bar's pill.
        let snapshot = PillBarHitTest.PillBarSnapshot(
            leftSlots: [.init(id: "L", width: 40)],
            rightSlots: [.init(id: "R", width: 40)],
            leftOverflowWidth: nil,
            rightOverflowWidth: nil,
            leftAnchorX: 200,
            rightAnchorX: 300,
            leftBarWidth: 100,
            rightBarWidth: 100,
            pillSpacing: spacing
        )
        XCTAssertEqual(
            PillBarHitTest.resolve(clickX: 180, snapshot: snapshot),
            .session(id: "L")
        )
        XCTAssertEqual(
            PillBarHitTest.resolve(clickX: 320, snapshot: snapshot),
            .session(id: "R")
        )
    }

    /// Snapshot resolution must surface overflow hits and gap misses
    /// the same way the per-bar `resolve` does — the seam is layout
    /// dispatch, not behavior change.
    func test_resolveSnapshot_overflowAndEmptyPropagate() {
        // Left bar with an overflow pill outboard of the session pill.
        // anchor=200, pill[0] [160,200], spacing 4, overflow w=30 → [126,156].
        let snapshot = PillBarHitTest.PillBarSnapshot(
            leftSlots: [.init(id: "near", width: 40)],
            rightSlots: [],
            leftOverflowWidth: 30,
            rightOverflowWidth: nil,
            leftAnchorX: 200,
            rightAnchorX: 300,
            leftBarWidth: 200,
            rightBarWidth: 0,
            pillSpacing: spacing
        )
        XCTAssertEqual(
            PillBarHitTest.resolve(clickX: 140, snapshot: snapshot),
            .overflow
        )
        // Click in the gap between pill and overflow.
        XCTAssertEqual(
            PillBarHitTest.resolve(clickX: 158, snapshot: snapshot),
            .empty
        )
    }
}
