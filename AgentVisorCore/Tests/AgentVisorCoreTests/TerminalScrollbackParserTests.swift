import XCTest
@testable import AgentVisorCore

final class TerminalScrollbackParserTests: XCTestCase {
    // Tracer bullet: one ● block before a □ question marker.
    func testExtractsSingleAssistantBlockBeforeQuestion() {
        let tui = """
        ● Trace done. Here's what I see in the code.

        Some analysis here.

        □ Driver verdict

        Given the trace, does X hold?
        """
        XCTAssertEqual(
            TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: tui),
            "Trace done. Here's what I see in the code.\n\nSome analysis here."
        )
    }

    // No active question form → nil. We only backfill when there is an
    // AskUserQuestion on screen creating the JSONL buffering gap.
    func testReturnsNilWhenNoQuestionMarker() {
        let tui = """
        ● Some assistant text.

        Some output without a question.
        """
        XCTAssertNil(TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: tui))
    }

    // Question marker but no ● before it → nil. Don't fabricate text
    // when there's nothing to pull from.
    func testReturnsNilWhenNoAssistantBlockBeforeQuestion() {
        let tui = """
        Just some tool output.

        □ Driver verdict
        """
        XCTAssertNil(TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: tui))
    }

    func testReturnsNilForEmptyInput() {
        XCTAssertNil(TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: ""))
    }

    // Whitespace-only body between ● and □ should not produce an empty
    // synthetic chat item.
    func testReturnsNilWhenAssistantBlockBodyIsWhitespaceOnly() {
        let tui = """
        ●

        □ Driver verdict
        """
        XCTAssertNil(TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: tui))
    }

    // Earlier ● blocks (e.g. "Doing the trace…" before the tool group)
    // must not leak into the result; only the block immediately before
    // the question's □ counts.
    func testReturnsLastAssistantBlockWhenMultiplePresent() {
        let tui = """
        ● Doing the trace directly so you can see what I'm reading.

          Searched for 2 patterns, read 5 files, listed 1 directory

        ● Trace done. Here's what I see in the code.

        Latest analysis.

        □ Driver verdict
        """
        XCTAssertEqual(
            TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: tui),
            "Trace done. Here's what I see in the code.\n\nLatest analysis."
        )
    }

    // Mirror of the screenshot the user reported: long analysis with
    // numbered list and bulleted insights between the last tool group
    // and the AskUserQuestion. The captured body must include the full
    // analysis through the last paragraph before the □.
    func testExtractsRealisticPlanModeAnalysis() {
        let tui = """
        ● Doing the trace directly so you can see what I'm reading.

          Searched for 2 patterns, read 5 files, listed 1 directory

        ● Trace done. Here's what I see in the code.

          Where A2A actually sits in V2 — three distinct surfaces, easy to conflate.

          1. Client → V2 wire (benchmarks/quality_harness/transport/a2a.py) — sync stdlib A2A client.
          2. V2 internal turn loop — no A2A at all.
          3. V2 → remote agent (agent_platform/agents/a2a_client/) — the production A2A client.

          * Insight

          - The behavioral-testing harness drives V2 over the wire.
          - The in-process Session skips: deployed V2 endpoint, IMS token mint, network roundtrip.

          Revised recommendation for Q5 + driver: In-process via Session, no A2A transport layer at all.

          Layer 4 of TDD reframes: instead of a real A2A round-trip, it becomes a real Bedrock call.

        □ Driver verdict

        Given the trace, does the in-process-without-A2A driver hold, or do you still want the wire path?
        """
        let body = TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: tui)
        XCTAssertNotNil(body)
        XCTAssertTrue(body?.hasPrefix("Trace done.") == true,
                      "Expected body to start with 'Trace done.', got: \(String(describing: body?.prefix(40)))")
        XCTAssertTrue(body?.contains("Where A2A actually sits") == true)
        XCTAssertTrue(body?.contains("Revised recommendation for Q5") == true)
        XCTAssertTrue(body?.contains("Layer 4 of TDD reframes") == true)
        XCTAssertFalse(body?.contains("Doing the trace directly") == true,
                       "Earlier ● block must not leak into the result")
        XCTAssertFalse(body?.contains("Driver verdict") == true,
                       "Content after □ must not leak in")
    }

    // `●` glyph appearing as ordinary content (e.g. a code example or a
    // user-pasted bullet) before a real `\n●` block must not be picked
    // up as a leader. Anchor on line-start.
    func testIgnoresAssistantLeaderInsideContent() {
        let tui = """
        ● Earlier block has a ● glyph inside its body.

        ● Real latest block.

        Body here.

        □ Question
        """
        XCTAssertEqual(
            TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: tui),
            "Real latest block.\n\nBody here."
        )
    }

    // Harder variant: the latest line-start ● has a content-● appearing
    // AFTER it. lastIndex(of: ●) without anchoring would pick the
    // content one and truncate the body. Leader detection must require
    // the glyph to be at the start of a line (preceded by \n or BOF).
    func testAnchorsLeaderOnLineStartEvenWithTrailingContentGlyph() {
        let tui = """
        ● Real block. The file contained a ● glyph in its source.

        Tail of analysis.

        □ Question
        """
        XCTAssertEqual(
            TerminalScrollbackParser.lastAssistantBlockBeforeQuestion(in: tui),
            "Real block. The file contained a ● glyph in its source.\n\nTail of analysis."
        )
    }
}
