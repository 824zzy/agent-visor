import Foundation

/// Computes the SwiftUI frame height that the composer's enclosing
/// NSScrollView must use, given the NSTextView's measured text height.
///
/// Why this exists as its own helper:
///   - NSTextView's intrinsic content size = `usedRect.height +
///     2 * textContainerInset.height`.
///   - The enclosing NSScrollView's frame must be at least that tall;
///     if it's smaller AppKit's `scrollRangeToVisible:` scrolls the
///     clip view to keep the caret visible, producing visible drift on
///     every caret movement (the user-reported "text moves up/down when
///     I press ↑/↓ in a multi-line query").
///   - If the frame is too tall, the bottom inset goes blank.
///
/// This calculator returns the EXACT outer-frame height that matches
/// the inner intrinsic height — no scroll, no clip.
public enum ComposerOuterFrameHeight {
    public struct Input: Equatable, Sendable {
        public let usedRectHeight: CGFloat   // NSLayoutManager `usedRect.height`
        public let lineHeight: CGFloat       // typesetter default line height
        public let visualLineCount: Int      // visible lines (incl. soft wraps)
        public let maxLines: Int             // cap before scrolling kicks in
        public let textContainerInset: CGFloat  // NSTextView `textContainerInset.height` (top == bottom)

        public init(
            usedRectHeight: CGFloat,
            lineHeight: CGFloat,
            visualLineCount: Int,
            maxLines: Int,
            textContainerInset: CGFloat
        ) {
            self.usedRectHeight = usedRectHeight
            self.lineHeight = lineHeight
            self.visualLineCount = visualLineCount
            self.maxLines = maxLines
            self.textContainerInset = textContainerInset
        }
    }

    /// `lineHeight * min(visualLineCount, maxLines) + 2 * textContainerInset`,
    /// floored at one line + insets so an empty composer still renders.
    public static func height(_ input: Input) -> CGFloat {
        let cappedLines = max(1, min(input.maxLines, input.visualLineCount))
        let textHeight = max(input.lineHeight, CGFloat(cappedLines) * input.lineHeight)
        // We trust line-count × line-height OVER usedRectHeight when
        // they disagree by a pixel or two — usedRect can drift sub-
        // pixel between measure cycles, but line-count is integral.
        // For very small usedRectHeight (just a descender) we still
        // floor at one line.
        let inset2 = input.textContainerInset * 2
        return textHeight + inset2
    }
}
