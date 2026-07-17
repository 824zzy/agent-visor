import XCTest
@testable import AgentVisorCore

final class EditorWindowMatcherTests: XCTestCase {
    // T1 tracer: empty titles → nil.
    func testEmptyTitlesReturnsNil() {
        XCTAssertNil(EditorWindowMatcher.bestMatch(titles: [], projectName: "anything"))
    }

    // T2: title equal to projectName matches.
    func testSingleTitleEqualsProjectNameMatches() {
        let result = EditorWindowMatcher.bestMatch(
            titles: ["agent-visor"],
            projectName: "agent-visor"
        )
        XCTAssertEqual(result, 0)
    }

    // T3: VS Code's "filename — workspace" format. The workspace name
    // appears as the second em-dash-separated segment.
    func testTitleWithFilenamePrefixMatchesByLastSegment() {
        let result = EditorWindowMatcher.bestMatch(
            titles: ["NotchView.swift — agent-visor"],
            projectName: "agent-visor"
        )
        XCTAssertEqual(result, 0)
    }

    // T4: matching is case-insensitive.
    func testMatchIsCaseInsensitive() {
        let result = EditorWindowMatcher.bestMatch(
            titles: ["Agent-Visor"],
            projectName: "agent-visor"
        )
        XCTAssertEqual(result, 0)
    }

    // T5: multiple titles, picks the first match in order.
    func testMultipleTitlesReturnsFirstMatch() {
        let result = EditorWindowMatcher.bestMatch(
            titles: ["other-project", "agent-visor", "agent-visor"],
            projectName: "agent-visor"
        )
        XCTAssertEqual(result, 1)
    }

    // T6: no title contains the project name → nil.
    func testNoMatchReturnsNil() {
        let result = EditorWindowMatcher.bestMatch(
            titles: ["other-project", "third-project"],
            projectName: "agent-visor"
        )
        XCTAssertNil(result)
    }

    // T7: substring should NOT match — "foobar" is not "foo".
    // Protects against the obvious mistake of using .contains() instead
    // of segment exact-match.
    func testSubstringDoesNotMatch() {
        let result = EditorWindowMatcher.bestMatch(
            titles: ["foobar"],
            projectName: "foo"
        )
        XCTAssertNil(result)
    }

    // T8: ".code-workspace" titles append "[Workspace]" segment. The
    // middle segment is still the workspace name and should match.
    func testCodeWorkspaceSuffixMatches() {
        let result = EditorWindowMatcher.bestMatch(
            titles: ["NotchView.swift — agent-visor — [Workspace]"],
            projectName: "agent-visor"
        )
        XCTAssertEqual(result, 0)
    }

    // T9: empty projectName never matches — would otherwise match an
    // empty title (`bestMatch(titles: [""], projectName: "") == 0`).
    func testEmptyProjectNameReturnsNil() {
        XCTAssertNil(EditorWindowMatcher.bestMatch(titles: [""], projectName: ""))
        XCTAssertNil(EditorWindowMatcher.bestMatch(titles: ["some-title"], projectName: ""))
    }
}
