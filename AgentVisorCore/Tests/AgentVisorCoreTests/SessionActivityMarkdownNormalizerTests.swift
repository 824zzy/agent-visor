import AgentVisorCore
import Foundation
import XCTest

final class SessionActivityMarkdownNormalizerTests: XCTestCase {
    func testAbsoluteFileLinkRendersAsItsLabel() throws {
        let source = "Recently migrate [perception-action-agi](/Users/example/Codes/perception-action-agi) under Codes."

        let normalized = SessionActivityMarkdownNormalizer.normalize(source)
        let rendered = try AttributedString(markdown: normalized)

        XCTAssertEqual(
            String(rendered.characters),
            "Recently migrate perception-action-agi under Codes."
        )
        XCTAssertTrue(normalized.contains("file:///Users/example/Codes/perception-action-agi"))
    }

    func testWebLinksAndPlainTextRemainUnchanged() {
        let source = "Read [the docs](https://example.com/docs) before continuing."

        XCTAssertEqual(SessionActivityMarkdownNormalizer.normalize(source), source)
    }

    func testAbsoluteFileLinkWithSpacesIsEncoded() throws {
        let source = "Open [the report](/Users/example/My Reports/report.md)."

        let normalized = SessionActivityMarkdownNormalizer.normalize(source)
        let rendered = try AttributedString(markdown: normalized)

        XCTAssertEqual(String(rendered.characters), "Open the report.")
        XCTAssertTrue(normalized.contains("My%20Reports"))
    }
}
