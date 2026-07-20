import XCTest
@testable import AgentVisorCore

final class SessionBrowserPolicyTests: XCTestCase {
    func testBrowserSectionsUseActionOrientedLabels() {
        XCTAssertEqual(SessionBrowserSection.needsAttention.displayTitle, "Needs you")
        XCTAssertEqual(SessionBrowserSection.ready.displayTitle, "Ready to continue")
        XCTAssertEqual(SessionBrowserSection.working.displayTitle, "In progress")
        XCTAssertEqual(SessionBrowserSection.recent.displayTitle, "History")
    }

    func testBlankQueryOrdersSectionsByActionabilityAndRowsByRecency() {
        let selection = SessionBrowserPolicy.select(
            candidates: [
                candidate("recent-new", section: .recent, time: 900),
                candidate("ready-old", section: .ready, time: 200),
                candidate("working", section: .working, time: 800),
                candidate("attention", section: .needsAttention, time: 100),
                candidate("ready-new", section: .ready, time: 700),
            ],
            query: ""
        )

        XCTAssertFalse(selection.isSearching)
        XCTAssertEqual(
            selection.groups.map(\.section),
            [.needsAttention, .ready, .working, .recent]
        )
        XCTAssertEqual(
            selection.orderedSessionIds,
            ["attention", "ready-new", "ready-old", "working", "recent-new"]
        )
    }

    func testSearchMatchesAcrossMetadataAndRanksTitleMatchesFirst() {
        let selection = SessionBrowserPolicy.select(
            candidates: [
                candidate(
                    "title-match",
                    title: "Agent Visor navigation",
                    project: "Personal",
                    path: "/Users/me/Personal/agent-visor",
                    time: 100
                ),
                candidate(
                    "project-match",
                    title: "Fix session ordering",
                    project: "agent-visor",
                    path: "/Users/me/Personal/agent-visor",
                    time: 900
                ),
                candidate(
                    "miss",
                    title: "Investigate service auth",
                    project: "Codes",
                    path: "/Users/me/Codes",
                    time: 1_000
                ),
            ],
            query: "agent visor"
        )

        XCTAssertTrue(selection.isSearching)
        XCTAssertTrue(selection.groups.isEmpty)
        XCTAssertEqual(selection.orderedSessionIds, ["title-match", "project-match"])
    }

    func testHiddenArchivedAndTitlelessRowsNeverReachTheBrowser() {
        let selection = SessionBrowserPolicy.select(
            candidates: [
                candidate("visible", time: 10),
                candidate("hidden", time: 30, isHidden: true),
                candidate("archived", time: 20, isArchived: true),
                candidate("titleless", title: "   ", time: 40),
            ],
            query: ""
        )

        XCTAssertEqual(selection.orderedSessionIds, ["visible"])
    }

    private func candidate(
        _ id: String,
        title: String? = nil,
        project: String = "Codes",
        path: String = "/Users/me/Codes",
        section: SessionBrowserSection = .recent,
        time: TimeInterval,
        isHidden: Bool = false,
        isArchived: Bool = false
    ) -> SessionBrowserCandidate {
        SessionBrowserCandidate(
            sessionId: id,
            title: title ?? id,
            preview: "",
            project: project,
            source: "Codex",
            owner: "Codex",
            path: path,
            section: section,
            sortDate: Date(timeIntervalSince1970: time),
            isHidden: isHidden,
            isArchived: isArchived
        )
    }
}
