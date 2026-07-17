//
//  CodexMemoryCitationStripperTests.swift
//  AgentVisorCoreTests
//
//  Codex appends an internal `<oai-mem-citation>…</oai-mem-citation>`
//  memory-citation trailer to its final answers. Codex's own UI strips
//  it before display; agent-visor must do the same so the markup
//  doesn't leak into the rendered chat.
//

import XCTest
@testable import AgentVisorCore

final class CodexMemoryCitationStripperTests: XCTestCase {
    private func strip(_ s: String) -> String {
        CodexMemoryCitationStripper.strip(s)
    }

    func testStripsTrailingCitationBlock() {
        let input = """
        Here is the real answer.

        Sources: [docs](https://example.com).

        <oai-mem-citation>
        <citation_entries>
        MEMORY.md:33-62|note=[prior context]
        </citation_entries>
        <rollout_ids>
        9526647a-f7d0-42f4-8ba3-a1391c5789cf
        </rollout_ids>
        </oai-mem-citation>
        """
        XCTAssertEqual(
            strip(input),
            "Here is the real answer.\n\nSources: [docs](https://example.com)."
        )
    }

    func testNoCitationBlockIsUnchanged() {
        let input = "A normal answer with no citation trailer."
        XCTAssertEqual(strip(input), input)
    }

    func testEmptyCitationSectionsStillStripped() {
        let input = """
        Final answer body.

        <oai-mem-citation>
        <citation_entries>
        </citation_entries>
        <rollout_ids>
        </rollout_ids>
        </oai-mem-citation>
        """
        XCTAssertEqual(strip(input), "Final answer body.")
    }

    func testStripsEvenWithTrailingWhitespaceAfterBlock() {
        let input = "Body text.\n\n<oai-mem-citation>\n<rollout_ids>\nabc\n</rollout_ids>\n</oai-mem-citation>\n  \n"
        XCTAssertEqual(strip(input), "Body text.")
    }

    func testStripsBlockEvenIfNotAtVeryEnd() {
        // Defensive: strip the block wherever it sits, not only as a suffix.
        let input = "Before.\n<oai-mem-citation>\n<rollout_ids>\nx\n</rollout_ids>\n</oai-mem-citation>\nAfter."
        XCTAssertEqual(strip(input), "Before.\nAfter.")
    }

    func testPreservesInteriorAngleBracketContent() {
        // A generic-looking `<foo>` in the body must not be touched.
        let input = "Use `Vec<String>` here. No citation."
        XCTAssertEqual(strip(input), input)
    }
}
