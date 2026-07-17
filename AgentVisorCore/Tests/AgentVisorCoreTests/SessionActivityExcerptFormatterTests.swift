import XCTest
@testable import AgentVisorCore

final class SessionActivityExcerptFormatterTests: XCTestCase {
    func testBlockMarkdownPreservesReadableBoundaries() {
        let source = """
        ## Slack Smoke Result

        The session completed successfully.

        - Fresh session passed
        - Resume passed
        """

        XCTAssertEqual(
            SessionActivityExcerptFormatter.plainText(source),
            "Slack Smoke Result\nThe session completed successfully.\n• Fresh session passed\n• Resume passed"
        )
    }

    func testSingleLineExcerptRemovesMarkdownWithoutRunningBlocksTogether() {
        XCTAssertEqual(
            SessionActivityExcerptFormatter.singleLine("**Result**\n\n- Build passed\n- Smoke passed"),
            "Result · Build passed · Smoke passed"
        )
    }

    func testAttributedExcerptPreservesLinks() {
        let excerpt = SessionActivityExcerptFormatter.attributedText(
            "Read [the report](https://example.com/report)."
        )

        XCTAssertEqual(String(excerpt.characters), "Read the report.")
        XCTAssertTrue(excerpt.runs.contains { $0.link != nil })
    }

    func testOuterMarkdownFenceIsRenderedAsDocumentContent() {
        let source = """
        ```markdown
        ## Summary

        **Build passed.**
        ```
        """

        XCTAssertEqual(
            SessionActivityExcerptFormatter.plainText(source),
            "Summary\nBuild passed."
        )
    }

    func testHeadingAfterPlainLabelDoesNotLeakMarkdownMarker() {
        let source = """
        PR Description
        ## Summary

        This change fixes the session inspector.
        """

        XCTAssertEqual(
            SessionActivityExcerptFormatter.plainText(source),
            "PR Description\nSummary\nThis change fixes the session inspector."
        )
    }

    func testEmbeddedMarkdownDocumentFenceRendersItsContents() {
        let source = """
        **PR Description**

        ```md
        ## Summary

        This change fixes the session inspector.
        ```
        """

        XCTAssertEqual(
            SessionActivityExcerptFormatter.plainText(source),
            "PR Description\nSummary\nThis change fixes the session inspector."
        )
    }
}
