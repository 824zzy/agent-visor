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
        XCTAssertEqual(clicked.opacity, 1)
        XCTAssertEqual(NativeMenuPanelHitTest.resolve(point: CGPoint(x: 50, y: 12),
            orderedSessionIDs: ["a", "b"], sessionFrames: ["a": clicked.frames[a]!, "b": clicked.frames[b]!],
            overflowFrame: nil), .session("a"))
        XCTAssertEqual(update(&state, reordered, pointer: CGPoint(x: 92, y: 12), now: 10).frames, initial)
    }

    func testItWaitsAfterLeavingThenMovesWhileInvisibleAndFinishesOneTransition() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, pointer: CGPoint(x: 50, y: 12), now: 1)
        XCTAssertEqual(update(&state, reordered, now: 2).frames, initial)
        XCTAssertEqual(update(&state, reordered, now: 2.1).frames, initial)
        _ = update(&state, reordered, now: 2.12)
        let fading = update(&state, reordered, now: 2.165)
        XCTAssertEqual(fading.frames, initial)
        XCTAssertEqual(fading.opacity, 0.5, accuracy: 0.001)
        let moved = update(&state, reordered, now: 2.21)
        XCTAssertEqual(moved.frames, reordered)
        XCTAssertEqual(moved.opacity, 0, accuracy: 0.001)
        let done = update(&state, reordered, now: 2.31)
        XCTAssertEqual(done.frames, reordered)
        XCTAssertEqual(done.opacity, 1)
        XCTAssertNil(done.nextUpdateDelay)
    }

    func testReentryRestoresOpacityAndKeepsCurrentTargets() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, now: 1)
        _ = update(&state, reordered, now: 1.12)
        XCTAssertLessThan(update(&state, reordered, now: 1.16).opacity, 1)
        let held = update(&state, reordered, pointer: CGPoint(x: 50, y: 12), now: 1.17)
        XCTAssertEqual(held.frames, initial)
        XCTAssertEqual(held.opacity, 1)
        XCTAssertEqual(update(&state, reordered, pointer: CGPoint(x: 50, y: 12), now: 30).frames, initial)
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

    func testReduceMotionRetainsInteractionHoldButSkipsTheFade() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        XCTAssertEqual(update(&state, reordered, pointer: CGPoint(x: 50, y: 12), reduceMotion: true, now: 1).frames, initial)
        XCTAssertEqual(update(&state, reordered, reduceMotion: true, now: 2).frames, initial)
        let done = update(&state, reordered, reduceMotion: true, now: 2.13)
        XCTAssertEqual(done.frames, reordered)
        XCTAssertEqual(done.opacity, 1)
        XCTAssertNil(done.nextUpdateDelay)
    }

    func testUnsafeGeometryWinsAndRemovedTargetsNeverRemainClickable() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        let replacement = [b: CGRect(x: 250, y: 0, width: 80, height: 24)]
        let safe = update(&state, replacement, pointer: CGPoint(x: 50, y: 12),
            available: [b], areas: [CGRect(x: 200, y: 0, width: 200, height: 24)], now: 1)
        XCTAssertEqual(safe.frames, replacement)
        XCTAssertEqual(safe.opacity, 1)
        XCTAssertNil(safe.frames[a])
    }

    func testLatestLayoutWinsAfterRepeatedUpdatesDuringInteraction() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, pointer: CGPoint(x: 50, y: 12), now: 1)
        _ = update(&state, initial, pointer: CGPoint(x: 50, y: 12), now: 2)
        let done = update(&state, initial, now: 3)
        XCTAssertEqual(done.frames, initial)
        XCTAssertEqual(done.opacity, 1)
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

    func testNewBoundsInvalidateAnUnsafeFadeDestinationBeforeItCanBeShown() {
        var state = NativeMenuLayoutTransition()
        let narrowInitial = [a: initial[a]!]
        _ = update(&state, narrowInitial, now: 0)
        let distant = [a: CGRect(x: 250, y: 0, width: 80, height: 24)]
        _ = update(&state, distant, now: 1)
        _ = update(&state, distant, now: 1.12)
        let safe = update(&state, narrowInitial, areas: [CGRect(x: 0, y: 0, width: 100, height: 24)], now: 1.21)
        XCTAssertEqual(safe.frames, narrowInitial)
        XCTAssertEqual(safe.opacity, 1)
    }

    func testRemovedTaskDisappearsWithoutMovingItsNeighbor() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        let kept = update(&state, [b: initial[b]!], pointer: CGPoint(x: 130, y: 12), available: [b], now: 1)
        XCTAssertNil(kept.frames[a])
        XCTAssertEqual(kept.frames[b], initial[b])
    }

    func testLateTimerStillHandsOffAtZeroOpacity() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, now: 1)
        _ = update(&state, reordered, now: 1.12)
        let moved = update(&state, reordered, now: 1.26)
        XCTAssertEqual(moved.frames, reordered)
        XCTAssertEqual(moved.opacity, 0)
        XCTAssertGreaterThan(update(&state, reordered, now: 1.28).opacity, 0)
    }

    func testReentryDuringFadeInRestoresTheNewLayoutAtFullOpacity() {
        var state = NativeMenuLayoutTransition()
        _ = update(&state, initial, now: 0)
        _ = update(&state, reordered, now: 1)
        _ = update(&state, reordered, now: 1.12)
        _ = update(&state, reordered, now: 1.22)
        let held = update(&state, reordered, pointer: CGPoint(x: 50, y: 12), now: 1.23)
        XCTAssertEqual(held.frames, reordered)
        XCTAssertEqual(held.opacity, 1)
        XCTAssertNil(held.nextUpdateDelay)
    }

    private func update(_ state: inout NativeMenuLayoutTransition,
        _ frames: [NativeMenuPanelTarget: CGRect], pointer: CGPoint? = nil, mouseDown: Bool = false,
        shortcuts: Bool = false, popover: Bool = false, reduceMotion: Bool = false,
        available: Set<NativeMenuPanelTarget>? = nil, areas: [CGRect]? = nil, now: TimeInterval
    ) -> NativeMenuLayoutTransition.Presentation {
        state.update(proposedFrames: frames, availableTargets: available ?? [a, b],
            safeAreas: areas ?? [lane], pointer: pointer, mouseDown: mouseDown,
            shortcutsHeld: shortcuts, popoverOpen: popover, reduceMotion: reduceMotion, now: now)
    }
}
