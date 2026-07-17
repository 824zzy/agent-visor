import XCTest
@testable import AgentVisorCore

final class SessionNavigatorSearchPolicyTests: XCTestCase {
    func testBlankQueryKeepsTheRenderedOverflowOrder() {
        let selection = SessionNavigatorSearchPolicy.select(
            overflowSessionIDs: ["hidden-ready", "hidden-recent"],
            allCandidates: [
                candidate("visible-working", title: "Visible working"),
                candidate("hidden-ready", title: "Hidden ready"),
                candidate("hidden-recent", title: "Hidden recent"),
            ],
            query: "   "
        )

        XCTAssertFalse(selection.isSearching)
        XCTAssertEqual(selection.orderedSessionIDs, ["hidden-ready", "hidden-recent"])
    }

    func testQuerySearchesAllRecentCandidatesAndRanksTitleBeforeMetadata() {
        let selection = SessionNavigatorSearchPolicy.select(
            overflowSessionIDs: ["hidden-project-match"],
            allCandidates: [
                candidate(
                    "visible-title-match",
                    title: "Agent Visor navigation",
                    project: "Personal",
                    time: 100
                ),
                candidate(
                    "hidden-project-match",
                    title: "Fix session ordering",
                    project: "agent-visor",
                    time: 900
                ),
                candidate(
                    "miss",
                    title: "Investigate service auth",
                    project: "Codes",
                    time: 1_000
                ),
            ],
            query: "agent visor"
        )

        XCTAssertTrue(selection.isSearching)
        XCTAssertEqual(
            selection.orderedSessionIDs,
            ["visible-title-match", "hidden-project-match"]
        )
    }

    func testSearchMatchesSourceOwnerAndPathWithoutTranscriptContent() {
        let selection = SessionNavigatorSearchPolicy.select(
            overflowSessionIDs: [],
            allCandidates: [
                candidate(
                    "source",
                    title: "Review implementation",
                    source: "Claude Code",
                    time: 300
                ),
                candidate(
                    "owner",
                    title: "Fix terminal focus",
                    owner: "iTerm2",
                    time: 200
                ),
                candidate(
                    "path",
                    title: "Inspect navigation",
                    path: "/Users/me/Personal/agent-visor",
                    time: 100
                ),
            ],
            query: "iterm2"
        )

        XCTAssertEqual(selection.orderedSessionIDs, ["owner"])
    }

    private func candidate(
        _ id: String,
        title: String,
        project: String = "Codes",
        source: String = "Codex",
        owner: String = "Codex",
        path: String = "/Users/me/Codes",
        time: TimeInterval = 100
    ) -> SessionNavigatorSearchCandidate {
        SessionNavigatorSearchCandidate(
            sessionID: id,
            title: title,
            project: project,
            source: source,
            owner: owner,
            path: path,
            sortDate: Date(timeIntervalSince1970: time)
        )
    }
}
