import Foundation

/// Decides whether a composer-height change should be animated.
///
/// The composer's text-height comes from an async re-measure on every
/// keystroke (NSLayoutManager `usedRect`). The empty → 1-char measure
/// can drift by < 1pt from the seeded value because the pre-typed seed
/// uses `defaultLineHeight(for: font)` while the post-typed measure
/// uses `usedRect`. Animating that drift produces visible jitter on
/// every keystroke.
///
/// Rule: animate ONLY when (a) the line count changes, OR (b) the
/// height delta exceeds a sub-line-height threshold. Sub-pixel drift
/// within the same line count is not a user-visible layout change.
///
/// In SwiftUI this is most cleanly expressed as
/// `.animation(_:value: composerLineCount)`: SwiftUI only animates
/// when the bound value changes, and the line count change IS the
/// user-visible event. Sub-pixel `composerTextHeight` drift never
/// reaches the animation system. The `decide(...)` API exists for
/// non-SwiftUI callers and exhaustive truth-table testing.
public enum ComposerHeightAnimationPolicy {
    /// Sub-line jitter threshold. The 1pt seed/measure drift we've
    /// observed is well under this; legitimate single-line layout
    /// changes (e.g. from word-wrap as text fills the box) are well
    /// over.
    public static let subLineJitterThreshold: CGFloat = 8

    public struct Decision: Equatable, Sendable {
        public let shouldAnimate: Bool

        public init(shouldAnimate: Bool) {
            self.shouldAnimate = shouldAnimate
        }
    }

    public static func decide(
        previousHeight: CGFloat,
        newHeight: CGFloat,
        previousLineCount: Int,
        newLineCount: Int
    ) -> Decision {
        // No-op delta → never animate.
        if previousHeight == newHeight && previousLineCount == newLineCount {
            return Decision(shouldAnimate: false)
        }
        // Real layout-row change → animate the slide.
        if previousLineCount != newLineCount {
            return Decision(shouldAnimate: true)
        }
        // Same line count: animate only if the height delta is large
        // enough that it's visible to the user. Sub-pixel drift from
        // re-measure stays still.
        let delta = abs(newHeight - previousHeight)
        return Decision(shouldAnimate: delta >= subLineJitterThreshold)
    }
}
