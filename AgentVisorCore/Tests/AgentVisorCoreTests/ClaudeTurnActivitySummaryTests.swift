//
//  ClaudeTurnActivitySummaryTests.swift
//  AgentVisorCoreTests
//
//  Content-aware "what did this turn do" header label.
//

import XCTest
@testable import AgentVisorCore

final class ClaudeTurnActivitySummaryTests: XCTestCase {
    private func summarize(_ tools: [CanonicalTool]) -> ClaudeTurnActivity {
        ClaudeTurnActivitySummarizer.summarize(tools)
    }

    func testEmptyFallsBackToZeroSteps() {
        XCTAssertEqual(summarize([]).label(), "0 steps")
    }

    func testCategorization() {
        let a = summarize([.read, .glob, .grep, .edit, .write, .bash, .webFetch, .task])
        XCTAssertEqual(a.read, 2)      // read + glob
        XCTAssertEqual(a.searched, 1)  // grep
        XCTAssertEqual(a.edited, 2)    // edit + write
        XCTAssertEqual(a.ran, 1)       // bash
        XCTAssertEqual(a.web, 1)
        XCTAssertEqual(a.delegated, 1)
        XCTAssertEqual(a.total, 8)
    }

    func testEditedAndRanLeadTheLabel() {
        // Reads are most numerous but actions (edit/run) lead; with 3
        // categories and maxClauses 2, the 3 reads roll into "+3 more".
        let a = summarize([.read, .read, .read, .edit, .bash])
        XCTAssertEqual(a.label(maxClauses: 2), "Edited 1 file · Ran 1 command · +3 more")
        // With room for all three, reads appear as their own clause, last.
        XCTAssertEqual(a.label(maxClauses: 3), "Edited 1 file · Ran 1 command · Read 3 files")
    }

    func testSingularPluralization() {
        XCTAssertEqual(summarize([.edit]).label(), "Edited 1 file")
        XCTAssertEqual(summarize([.edit, .edit]).label(), "Edited 2 files")
        XCTAssertEqual(summarize([.bash]).label(), "Ran 1 command")
    }

    func testReadOnlyTurnReadsAsRead() {
        XCTAssertEqual(summarize([.read, .glob, .grep]).label(maxClauses: 3),
                       "Read 2 files · Searched 1 search")
    }

    func testTooManyCategoriesRollIntoMore() {
        // edit, ran, read, searched, web = 5 categories; show top 2 + remainder.
        let a = summarize([.edit, .bash, .read, .grep, .webFetch])
        // edited 1, ran 1 shown (count 2); remainder = 5 - 2 = 3
        XCTAssertEqual(a.label(maxClauses: 2), "Edited 1 file · Ran 1 command · +3 more")
    }

    func testOnlyUncategorizedFallsBackToSteps() {
        // MCP + TodoWrite + AskUserQuestion are all "other" → no clauses.
        let a = summarize([.mcp(server: "github", tool: "x"), .todoWrite])
        XCTAssertEqual(a.label(), "2 steps")
        XCTAssertEqual(a.total, 2)
    }

    func testMixedCategorizedAndOtherCountsOtherInTotalNotClauses() {
        let a = summarize([.edit, .mcp(server: "g", tool: "t")])
        XCTAssertEqual(a.total, 2)
        // single categorized clause shown; other doesn't get its own clause
        XCTAssertEqual(a.label(maxClauses: 2), "Edited 1 file")
    }
}
