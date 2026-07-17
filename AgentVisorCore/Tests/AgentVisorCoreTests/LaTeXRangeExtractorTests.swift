import XCTest
@testable import AgentVisorCore

/// Pins the segmentation contract for converting raw inline text
/// (already stripped of markdown structure by swift-markdown) into a
/// run of literal-text + LaTeX-formula segments. The app-side
/// renderer flattens this run into an AttributedString with image
/// attachments for the formulas.
final class LaTeXRangeExtractorTests: XCTestCase {

    // MARK: - Plain text

    func test_plainText_returnsSingleTextSegment() {
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "no math here"),
            [.text("no math here")]
        )
    }

    func test_emptyString_returnsEmpty() {
        XCTAssertEqual(LaTeXRangeExtractor.segments(in: ""), [])
    }

    // MARK: - Inline math `$...$`

    func test_singleInlineMath() {
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "let $x$ be"),
            [.text("let "), .inlineMath("x"), .text(" be")]
        )
    }

    func test_inlineMath_atStart() {
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "$f(x)$ is the function"),
            [.inlineMath("f(x)"), .text(" is the function")]
        )
    }

    func test_inlineMath_atEnd() {
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "the function is $f(x)$"),
            [.text("the function is "), .inlineMath("f(x)")]
        )
    }

    func test_multipleInlineMath() {
        // Mirrors the screenshot's "$f(x) = 0$" + "$f'$" + "$x_0$" pattern.
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "solve $f(x) = 0$ for $x_0$"),
            [.text("solve "), .inlineMath("f(x) = 0"), .text(" for "), .inlineMath("x_0")]
        )
    }

    func test_inlineMath_withSubscriptBraces() {
        // `$x_{n+1}$` — common in iterative-formula prose.
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "next is $x_{n+1}$ here"),
            [.text("next is "), .inlineMath("x_{n+1}"), .text(" here")]
        )
    }

    // MARK: - Display math `$$...$$`

    func test_displayMath_alone() {
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "$$x_{n+1} = x_n - \\frac{f(x_n)}{f'(x_n)}$$"),
            [.displayMath("x_{n+1} = x_n - \\frac{f(x_n)}{f'(x_n)}")]
        )
    }

    func test_displayMath_inline() {
        // Display math sandwiched in a paragraph — the renderer can
        // promote this to a block; the extractor just labels it.
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "before $$E=mc^2$$ after"),
            [.text("before "), .displayMath("E=mc^2"), .text(" after")]
        )
    }

    func test_displayMath_takesPrecedenceOverInline() {
        // `$$..$$` must be parsed as one display block, not two inline
        // math spans with an empty span between them.
        let result = LaTeXRangeExtractor.segments(in: "$$a$$")
        XCTAssertEqual(result, [.displayMath("a")])
    }

    // MARK: - Escapes and edge cases

    func test_escapedDollar_isLiteral() {
        // `\$5` must not start a math span. Backslash + dollar is the
        // standard markdown escape, expected by users writing prose
        // about money.
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "I lost \\$5 today"),
            [.text("I lost $5 today")]
        )
    }

    func test_unclosedInlineDollar_isLiteral() {
        // A dangling `$` with no closing match — drop the math
        // interpretation, treat as literal text. Avoids "lost $50 in
        // chips" mis-rendering as a giant LaTeX image.
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "I have $50 in chips"),
            [.text("I have $50 in chips")]
        )
    }

    func test_unclosedDisplayDollar_isLiteral() {
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "weird $$ thing"),
            [.text("weird $$ thing")]
        )
    }

    func test_emptyInlineMath_isLiteral() {
        // `$$` adjacent without content — treat as literal so we don't
        // emit a zero-width image.
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "see $$ pair"),
            [.text("see $$ pair")]
        )
    }

    func test_emptySingleDollar_isLiteral() {
        // A literal $$ that is not display math (no body) and is not
        // an empty inline pair (the latter is `$<empty>$` with no body
        // either). Treat the bare `$$` as literal text; behavior pinned
        // by the previous test.
        XCTAssertEqual(
            LaTeXRangeExtractor.segments(in: "$$"),
            [.text("$$")]
        )
    }
}
