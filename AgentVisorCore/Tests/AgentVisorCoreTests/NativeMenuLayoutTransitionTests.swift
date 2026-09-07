import XCTest
@testable import AgentVisorCore

final class NativeMenuLayoutTransitionTests: XCTestCase {
    private let a = NativeMenuPanelTarget.session("a")
    private let b = NativeMenuPanelTarget.session("b")
    private let lane = CGRect(x: 0, y: 0, width: 400, height: 24)
    private var initial: [NativeMenuPanelTarget: CGRect] {
        [a: CGRect(x: 10, y: 0, width: 80, height: 24), b: CGRect(x: 94, y: 0, width: 80, height: 24)]
    }
    private var reordered: [NativeMenuPanelTarget: CGRect] { [a: initial[b]!, b: initial[a]!] }

    func testClickAcknowledgmentKeepsTheClickedTargetAndItsNeighborsInPlace() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        let clicked = update(&state, reordered, pointer: CGPoint(x: 50, y: 12), mouseDown: true, now: 1)
        XCTAssertEqual(clicked.frames, initial)
        XCTAssertEqual(NativeMenuPanelHitTest.resolve(point: CGPoint(x: 50, y: 12),
            orderedSessionIDs: ["a", "b"], sessionFrames: ["a": clicked.frames[a]!, "b": clicked.frames[b]!],
            overflowFrame: nil), .session("a"))
        XCTAssertEqual(update(&state, reordered, pointer: CGPoint(x: 92, y: 12), now: 10).frames, initial)
    }

    func testItWaitsAfterLeavingThenSlidesContinuouslyToTheFinalOrder() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, pointer: CGPoint(x: 50, y: 12), now: 1)
        XCTAssertEqual(update(&state, reordered, now: 2).frames, initial)
        XCTAssertFalse(update(&state, reordered, now: 2.1).isMoving)
        XCTAssertTrue(update(&state, reordered, now: 2.12).isMoving)
        let middle = update(&state, reordered, now: 2.24)
        XCTAssertEqual(middle.frames[a]!.minX, 52, accuracy: 0.001)
        XCTAssertEqual(middle.frames[b]!.minX, 52, accuracy: 0.001)
        XCTAssertEqual(middle.frames[a]!.width, 80)
        XCTAssertEqual(middle.orderedTargets.first, a)
        XCTAssertEqual(middle.overlappingTargets, [a, b])
        let done = update(&state, reordered, now: 2.37)
        XCTAssertEqual(done.frames, reordered)
        XCTAssertFalse(done.isMoving)
        XCTAssertTrue(done.overlappingTargets.isEmpty)
        XCTAssertNil(done.nextUpdateDelay)
    }

    func testReentryPausesTheLastDisplayedFramesAndRetainsForegroundHitRouting() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, now: 1)
        _ = update(&state, reordered, now: 1.12)
        let moving = update(&state, reordered, now: 1.24)
        let held = update(&state, reordered, pointer: CGPoint(x: 80, y: 12), now: 1.25)
        XCTAssertEqual(held.frames, moving.frames)
        XCTAssertFalse(held.isMoving)
        XCTAssertEqual(held.orderedTargets.first, a)
        XCTAssertEqual(update(&state, reordered, pointer: CGPoint(x: 80, y: 12), now: 30).frames, moving.frames)
        XCTAssertEqual(NativeMenuPanelHitTest.resolve(point: CGPoint(x: 80, y: 12),
            orderedSessionIDs: ["b", "a"], sessionFrames: ["a": held.frames[a]!, "b": held.frames[b]!],
            overflowFrame: nil, frontToBack: held.orderedTargets), a)
        _ = update(&state, reordered, now: 31)
        _ = update(&state, reordered, now: 31.12)
        XCTAssertEqual(update(&state, reordered, now: 31.37).frames, reordered)
    }

    func testShortcutsPopoverAndPressDragEachHoldPositions() {
        for reason in 0..<3 {
            var state = NativeMenuLayoutTransition()
            _ = update(&state, initial, pointer: reason == 2 ? CGPoint(x: 50, y: 12) : nil, now: 0)
            let held = update(&state, reordered, mouseDown: reason == 2,
                shortcuts: reason == 0, popover: reason == 1, now: 3)
            XCTAssertEqual(held.frames, initial)
        }
    }

    func testReduceMotionRetainsInteractionHoldButSkipsMovement() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        XCTAssertEqual(update(&state, reordered, pointer: CGPoint(x: 50, y: 12), reduceMotion: true, now: 1).frames, initial)
        XCTAssertEqual(update(&state, reordered, reduceMotion: true, now: 2).frames, initial)
        let done = update(&state, reordered, reduceMotion: true, now: 2.13)
        XCTAssertEqual(done.frames, reordered)
        XCTAssertNil(done.nextUpdateDelay)
    }

    func testUnsafeGeometryWinsAndRemovedTargetsNeverRemainClickable() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        let replacement = [b: CGRect(x: 250, y: 0, width: 80, height: 24)]
        let safe = update(&state, replacement, pointer: CGPoint(x: 50, y: 12),
            available: [b], areas: [CGRect(x: 200, y: 0, width: 200, height: 24)], now: 1)
        XCTAssertEqual(safe.frames, replacement)
        XCTAssertNil(safe.frames[a])
    }

    func testLatestLayoutWinsAfterRepeatedUpdatesDuringInteraction() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, pointer: CGPoint(x: 50, y: 12), now: 1)
        _ = update(&state, initial, pointer: CGPoint(x: 50, y: 12), now: 2)
        let done = update(&state, initial, now: 3)
        XCTAssertEqual(done.frames, initial)
        XCTAssertNil(done.nextUpdateDelay)
    }

    func testClickedPillCanWaitInItsSlotEvenWhenTheNextPlanPutsItInOverflow() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        let lessSpace = [b: initial[a]!]
        let held = update(&state, lessSpace, pointer: CGPoint(x: 50, y: 12), now: 1)
        XCTAssertEqual(held.frames, initial)
        _ = update(&state, lessSpace, reduceMotion: true, now: 2)
        XCTAssertEqual(update(&state, lessSpace, reduceMotion: true, now: 2.13).frames, lessSpace)
    }

    func testPointerInTheNotchDoesNotHoldEitherLane() {
        var state = NativeMenuLayoutTransition()
        let areas = [CGRect(x: 0, y: 0, width: 100, height: 24),
                     CGRect(x: 200, y: 0, width: 100, height: 24)]
        let separated = [a: initial[a]!, b: CGRect(x: 210, y: 0, width: 80, height: 24)]
        _ = update(&state, separated, areas: areas, now: 0)
        let swapped = [a: separated[b]!, b: separated[a]!]
        _ = update(&state, swapped, pointer: CGPoint(x: 150, y: 12), reduceMotion: true, areas: areas, now: 1)
        XCTAssertEqual(update(&state, swapped, pointer: CGPoint(x: 150, y: 12),
            reduceMotion: true, areas: areas, now: 1.13).frames, swapped)
    }

    func testNewBoundsInvalidateAnUnsafeMotionPathBeforeItCanBeShown() {
        var state = NativeMenuLayoutTransition()
        let narrowInitial = [a: initial[a]!]
        _ = update(&state, narrowInitial, now: 0)
        let distant = [a: CGRect(x: 250, y: 0, width: 80, height: 24)]
        _ = update(&state, distant, now: 1)
        _ = update(&state, distant, now: 1.12)
        let safe = update(&state, narrowInitial, areas: [CGRect(x: 0, y: 0, width: 100, height: 24)], now: 1.21)
        XCTAssertEqual(safe.frames, narrowInitial)
    }

    func testRemovedTaskDisappearsWithoutMovingItsNeighbor() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        let kept = update(&state, [b: initial[b]!], pointer: CGPoint(x: 130, y: 12), available: [b], now: 1)
        XCTAssertNil(kept.frames[a])
        XCTAssertEqual(kept.frames[b], initial[b])
    }

    func testLateTimerCompletesWithoutLeavingInvisibleOrIntermediatePills() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, now: 1)
        _ = update(&state, reordered, now: 1.12)
        let done = update(&state, reordered, now: 3)
        XCTAssertEqual(done.frames, reordered)
        XCTAssertFalse(done.isMoving)
        XCTAssertNil(done.nextUpdateDelay)
    }

    func testPillsMovingBetweenLanesNeverDrawThroughTheNotch() {
        var state = NativeMenuLayoutTransition()
        let areas = [CGRect(x: 0, y: 0, width: 100, height: 24),
                     CGRect(x: 200, y: 0, width: 100, height: 24)]
        let before = [a: CGRect(x: 10, y: 0, width: 80, height: 24),
                      b: CGRect(x: 210, y: 0, width: 80, height: 24)]
        let after = [a: before[b]!, b: before[a]!]
        _ = update(&state, before, areas: areas, now: 0)
        _ = update(&state, after, areas: areas, now: 1)
        _ = update(&state, after, areas: areas, now: 1.12)
        for tick in 1...24 {
            let step = update(&state, after, areas: areas, now: 1.12 + Double(tick) / 100)
            for frame in step.frames.values {
                XCTAssertTrue(areas.contains { $0.contains(frame) }, "Unsafe frame: \(frame)")
                XCTAssertFalse(frame.intersects(CGRect(x: 100, y: 0, width: 100, height: 24)))
            }
        }
        XCTAssertEqual(update(&state, after, areas: areas, now: 1.37).frames, after)
    }

    func testOverflowExitClipsTheViewportWithoutCompressingThePillAndCanPause() {
        var state = NativeMenuLayoutTransition()
        let before = [a: CGRect(x: 300, y: 0, width: 80, height: 24), b: initial[b]!]
        let after = [b: initial[b]!]
        _ = update(&state, before, now: 0)
        _ = update(&state, after, now: 1)
        _ = update(&state, after, now: 1.12)
        let middle = update(&state, after, now: 1.24)
        XCTAssertEqual(middle.placements[a]!.contentFrame.width, 80)
        XCTAssertEqual(middle.frames[a]!.width, 50, accuracy: 0.001)
        XCTAssertEqual(middle.frames[a]!.maxX, lane.maxX, accuracy: 0.001)
        let held = update(&state, after, pointer: CGPoint(x: 375, y: 12), now: 1.25)
        XCTAssertEqual(held.frames, middle.frames)
        _ = update(&state, after, now: 2)
        _ = update(&state, after, now: 2.12)
        XCTAssertNil(update(&state, after, now: 2.37).frames[a])
    }

    func testNewlyVisiblePillSlidesInFromItsLaneEdge() {
        var state = NativeMenuLayoutTransition()
        let after = [a: CGRect(x: 300, y: 0, width: 80, height: 24), b: initial[b]!]
        _ = update(&state, [b: initial[b]!], now: 0)
        _ = update(&state, after, now: 1)
        _ = update(&state, after, now: 1.12)
        let middle = update(&state, after, now: 1.24)
        XCTAssertEqual(middle.frames[a]!.minX, 350, accuracy: 0.001)
        XCTAssertEqual(middle.frames[a]!.width, 50, accuracy: 0.001)
        XCTAssertEqual(update(&state, after, now: 1.37).frames, after)
    }

    func testSnapshotsDuringMovementCoalesceAfterTheCurrentMove() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, now: 1)
        _ = update(&state, reordered, now: 1.12)
        let middle = update(&state, initial, now: 1.24)
        XCTAssertEqual(middle.frames[a]!.minX, 52, accuracy: 0.001)
        XCTAssertEqual(update(&state, initial, now: 1.37).frames, reordered)
        _ = update(&state, initial, now: 1.5)
        XCTAssertEqual(update(&state, initial, now: 1.75).frames, initial)
    }

    func testRemovedSessionCannotReappearFromAnActiveMotionTrack() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, now: 1)
        _ = update(&state, reordered, now: 1.12)
        for time in [1.2, 1.3, 1.4, 1.6] {
            XCTAssertNil(update(&state, [b: initial[a]!], available: [b], now: time).frames[a])
        }
    }

    func testTurningOnReduceMotionMidSlideSettlesImmediately() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, now: 1)
        _ = update(&state, reordered, now: 1.12)
        let done = update(&state, reordered, reduceMotion: true, now: 1.2)
        XCTAssertEqual(done.frames, reordered)
        XCTAssertFalse(done.isMoving)
    }

    private func update(_ state: inout NativeMenuLayoutTransition,
        _ frames: [NativeMenuPanelTarget: CGRect], pointer: CGPoint? = nil, mouseDown: Bool = false,
        shortcuts: Bool = false, popover: Bool = false, reduceMotion: Bool = false,
        available: Set<NativeMenuPanelTarget>? = nil, areas: [CGRect]? = nil, now: TimeInterval
    ) -> NativeMenuLayoutTransition.Presentation {
        state.update(proposedFrames: frames, availableTargets: available ?? [a, b],
            safeAreas: areas ?? [lane], pointer: pointer, mouseDown: mouseDown,
            shortcutsHeld: shortcuts, popoverOpen: popover, reduceMotion: reduceMotion, preferredTarget: a, now: now)
    }
}
