import XCTest
@testable import AgentVisorCore

/// The composer wraps an NSTextView in an NSScrollView. AppKit will
/// auto-scroll the inner clip view on caret movement IF the NSScrollView's
/// outer frame is even slightly smaller than the NSTextView's intrinsic
/// content size. NSTextView's intrinsic content size = `usedRect.height +
/// 2 * textContainerInset.height`. So the outer SwiftUI frame must include
/// the inset padding too — otherwise the NSTextView is taller than the
/// scroll view, the scroll view shows only part of it, and caret movement
/// drifts the text.
///
/// Bug context: dropping the inset from `composerInputHeight` produced
/// the user-reported "text drifts when caret crosses top/bottom line"
/// jitter and "bottom of text is clipped" symptoms.
final class ComposerOuterFrameHeightTests: XCTestCase {
    private typealias Calc = ComposerOuterFrameHeight

    private func make(
        usedRectHeight: CGFloat,
        lineHeight: CGFloat = 16,
        visualLineCount: Int = 1,
        maxLines: Int = 8,
        textContainerInset: CGFloat = 2
    ) -> Calc.Input {
        Calc.Input(
            usedRectHeight: usedRectHeight,
            lineHeight: lineHeight,
            visualLineCount: visualLineCount,
            maxLines: maxLines,
            textContainerInset: textContainerInset
        )
    }

    // MARK: - Single line

    func testSingleLineIncludesInsetPadding() {
        // 1 line of 16pt text + 2pt top + 2pt bottom = 20pt.
        let h = Calc.height(make(usedRectHeight: 16))
        XCTAssertEqual(h, 20)
    }

    func testEmptyContentFloorsAtOneLine() {
        // Empty composer should still be 1 line tall (with inset).
        let h = Calc.height(make(usedRectHeight: 0))
        XCTAssertEqual(h, 20)
    }

    // MARK: - Multiple lines

    func testTwoLinesIncludesInset() {
        let h = Calc.height(make(usedRectHeight: 32, visualLineCount: 2))
        XCTAssertEqual(h, 36)
    }

    func testEightLinesIsAtCap() {
        let h = Calc.height(make(usedRectHeight: 128, visualLineCount: 8))
        XCTAssertEqual(h, 132)
    }

    // MARK: - Cap

    func testNinthLineClampsToEightLineCap() {
        // User pasted 10 lines. Composer must not grow past 8 lines.
        let h = Calc.height(make(usedRectHeight: 160, visualLineCount: 10))
        // cap = 8 * 16 + 2 * 2 = 128 + 4 = 132.
        XCTAssertEqual(h, 132)
    }

    // MARK: - Zero inset

    func testZeroInsetReturnsRawText() {
        let h = Calc.height(
            make(usedRectHeight: 16, textContainerInset: 0)
        )
        XCTAssertEqual(h, 16)
    }

    // MARK: - Minimum bound

    func testMinimumIsOneLineWithInset() {
        // Even with usedRectHeight=4 (sub-line, e.g. just a descender),
        // the composer should be at least one full line tall.
        let h = Calc.height(make(usedRectHeight: 4))
        XCTAssertEqual(h, 20)
    }

    // MARK: - Realistic streaming sequence

    func testGrowsThenShrinksAroundLineCount() {
        let one = Calc.height(make(usedRectHeight: 16, visualLineCount: 1))
        let two = Calc.height(make(usedRectHeight: 32, visualLineCount: 2))
        let three = Calc.height(make(usedRectHeight: 48, visualLineCount: 3))
        XCTAssertEqual(one, 20)
        XCTAssertEqual(two, 36)
        XCTAssertEqual(three, 52)
    }
}
