//
//  ComposerHeightCalculatorTests.swift
//  AgentVisorCoreTests
//

import XCTest
@testable import AgentVisorCore

final class ComposerHeightCalculatorTests: XCTestCase {
    /// Default test input: 200pt-wide container, 13pt system font,
    /// 0pt line-fragment padding. Mirrors the production composer's
    /// configuration so the empirical values flow through.
    private func make(_ text: String) -> ComposerHeightCalculator.Input {
        ComposerHeightCalculator.Input(text: text, containerWidth: 200)
    }

    /// Helper: round to nearest line so test assertions don't have
    /// to bake in OS-version-specific font metric drift.
    private func lines(_ output: ComposerHeightCalculator.Output) -> Int {
        Int((output.textHeight / output.lineHeight).rounded())
    }

    // MARK: - Empty / single line

    func testEmptyStringIsOneLine() {
        let out = ComposerHeightCalculator.measure(make(""))
        XCTAssertEqual(lines(out), 1)
        XCTAssertEqual(out.textHeight, out.lineHeight)
    }

    func testSingleCharIsOneLine() {
        XCTAssertEqual(lines(ComposerHeightCalculator.measure(make("a"))), 1)
    }

    func testSingleWordIsOneLine() {
        XCTAssertEqual(lines(ComposerHeightCalculator.measure(make("hello"))), 1)
    }

    // MARK: - Hard wraps (Shift+Enter case)

    func testCharThenNewlineIsTwoLines() {
        // Caret on empty line below the first char. The bug we fixed:
        // adding `extraLineFragmentRect.height` to `usedRect.height`
        // double-counted, returning 3 here.
        XCTAssertEqual(lines(ComposerHeightCalculator.measure(make("a\n"))), 2)
    }

    func testTwoLinesNoTrailingNewlineIsTwoLines() {
        XCTAssertEqual(lines(ComposerHeightCalculator.measure(make("a\nb"))), 2)
    }

    func testTwoLinesPlusTrailingNewlineIsThreeLines() {
        // The user just pressed Enter after typing "a\nb"; caret on
        // empty third line.
        XCTAssertEqual(lines(ComposerHeightCalculator.measure(make("a\nb\n"))), 3)
    }

    func testThreeLinesPlusTrailingNewlineIsFourLines() {
        XCTAssertEqual(lines(ComposerHeightCalculator.measure(make("a\nb\nc\n"))), 4)
    }

    // MARK: - The exact user reproduction

    func testItStillHappensTwoLineCase() {
        // The screenshot: "It still happens" + Shift+Enter, then
        // caret on empty second line. Should be exactly 2 lines.
        XCTAssertEqual(
            lines(ComposerHeightCalculator.measure(make("It still happens\n"))),
            2
        )
    }

    func testItStillHappensTypedCharCase() {
        // After the user types `d` on the second line, the count
        // must still be 2 (not 3). This is the parity check between
        // "trailing newline" and "no trailing newline" states that
        // earlier impls broke — the gap appeared in one state and
        // disappeared in the other.
        XCTAssertEqual(
            lines(ComposerHeightCalculator.measure(make("It still happens\nd"))),
            2
        )
    }

    func testTrailingNewlineParityMatchesTypedChar() {
        // Generalized: for every K, the height of K logical lines
        // ending in a trailing newline should equal the height of
        // K+1 logical lines ending in a non-newline character. Both
        // visually occupy K+1 rows.
        for k in 1...6 {
            let prefix = (0..<k).map { "line\($0)" }.joined(separator: "\n")
            let withTrail = ComposerHeightCalculator.measure(make(prefix + "\n"))
            let withChar = ComposerHeightCalculator.measure(make(prefix + "\nx"))
            XCTAssertEqual(
                lines(withTrail),
                lines(withChar),
                "K=\(k): trailing-newline=\(lines(withTrail)) typed-char=\(lines(withChar))"
            )
        }
    }

    // MARK: - Soft wrap (long single line)

    func testLongLineSoftWrapsToTwoLines() {
        // 200pt wide @ 13pt system font fits roughly 30 chars per
        // line. A 50-char string with no newlines must soft-wrap to
        // at least 2 visual lines.
        let long = String(repeating: "x", count: 50) + " " + String(repeating: "y", count: 50)
        let out = ComposerHeightCalculator.measure(make(long))
        XCTAssertGreaterThanOrEqual(lines(out), 2)
    }

    // MARK: - Line height stability

    func testLineHeightIsStableAcrossInputs() {
        // The per-line height depends only on the font, not the
        // string. All measurements with the same font should report
        // the same lineHeight value.
        let h1 = ComposerHeightCalculator.measure(make("")).lineHeight
        let h2 = ComposerHeightCalculator.measure(make("hello")).lineHeight
        let h3 = ComposerHeightCalculator.measure(make("a\nb\nc\n")).lineHeight
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h2, h3)
    }

    func testLineHeightScalesWithFontSize() {
        let small = ComposerHeightCalculator.measure(
            ComposerHeightCalculator.Input(text: "x", containerWidth: 200, fontSize: 10)
        )
        let large = ComposerHeightCalculator.measure(
            ComposerHeightCalculator.Input(text: "x", containerWidth: 200, fontSize: 18)
        )
        XCTAssertGreaterThan(large.lineHeight, small.lineHeight)
    }

    // MARK: - Determinism

    func testRepeatedMeasurementsAreIdentical() {
        // Pure function: identical inputs must produce identical outputs.
        let input = make("a\nb\nc\n")
        let a = ComposerHeightCalculator.measure(input)
        let b = ComposerHeightCalculator.measure(input)
        XCTAssertEqual(a, b)
    }
}
