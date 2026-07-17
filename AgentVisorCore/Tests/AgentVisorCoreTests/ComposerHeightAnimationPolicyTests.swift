import XCTest
@testable import AgentVisorCore

/// Tests the policy that decides whether a composer-height change
/// should be animated. Bug context: after typing the first character,
/// the async layout-manager re-measure can return a height differing
/// from the seeded value by < 1pt, and animating that delta produced
/// visible jitter on every keystroke.
///
/// Rule: animate ONLY when the line count changes. Sub-pixel
/// re-measurements within the same line count are not user-visible
/// height changes and must not be animated.
final class ComposerHeightAnimationPolicyTests: XCTestCase {

    private typealias Policy = ComposerHeightAnimationPolicy

    func testNoAnimationWhenLineCountUnchangedAndDeltaSmall() {
        // Empty → 1 char: line count stays 1, height drifts by < 1pt
        // due to layout-manager re-measure. THIS is the jitter bug.
        let decision = Policy.decide(
            previousHeight: 22,
            newHeight: 21,
            previousLineCount: 1,
            newLineCount: 1
        )
        XCTAssertFalse(decision.shouldAnimate)
    }

    func testAnimationWhenLineCountIncreases() {
        // User pressed Enter → line count goes 1 → 2. The height
        // doubles; this is a real layout change that benefits from
        // a smooth slide.
        let decision = Policy.decide(
            previousHeight: 22,
            newHeight: 44,
            previousLineCount: 1,
            newLineCount: 2
        )
        XCTAssertTrue(decision.shouldAnimate)
    }

    func testAnimationWhenLineCountDecreases() {
        // User deleted a line → 2 → 1.
        let decision = Policy.decide(
            previousHeight: 44,
            newHeight: 22,
            previousLineCount: 2,
            newLineCount: 1
        )
        XCTAssertTrue(decision.shouldAnimate)
    }

    func testNoAnimationWhenHeightUnchanged() {
        let decision = Policy.decide(
            previousHeight: 22,
            newHeight: 22,
            previousLineCount: 1,
            newLineCount: 1
        )
        XCTAssertFalse(decision.shouldAnimate)
    }

    func testAnimationWhenLineCountUnchangedButLargeJump() {
        // Programmatic replacement (e.g. slash-command popover insert)
        // can shrink/grow the box by many points within a single
        // logical line via word-wrap. If the line count is the same
        // we still want to animate large deltas — the threshold below
        // prevents jitter, not legitimate animation.
        let decision = Policy.decide(
            previousHeight: 22,
            newHeight: 100,
            previousLineCount: 1,
            newLineCount: 1
        )
        XCTAssertTrue(decision.shouldAnimate)
    }

    func testEmptyToFirstCharIsTheCanonicalNonAnimateCase() {
        // Exact reproduction of the user-reported bug. Seed: 22pt, one
        // line. After first char: NSLayoutManager reports 21pt, still
        // one line. Must not animate.
        let decision = Policy.decide(
            previousHeight: 22.0,
            newHeight: 21.0,
            previousLineCount: 1,
            newLineCount: 1
        )
        XCTAssertFalse(decision.shouldAnimate, "First-char re-measure jitter")
    }
}
