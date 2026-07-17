import XCTest
@testable import AgentVisorCore

final class ProjectAwarePillOrderTests: XCTestCase {
    private func candidate(
        _ id: String,
        project: String?,
        surface: String? = nil,
        priority: Int = 2,
        last: TimeInterval
    ) -> ProjectAwarePillOrder.Candidate {
        ProjectAwarePillOrder.Candidate(
            id: id,
            projectKey: project,
            surfaceKey: surface,
            priority: priority,
            sortDate: Date(timeIntervalSince1970: last)
        )
    }

    func testRoundRobinsProjectsWithinSamePriorityTier() {
        let ordered = ProjectAwarePillOrder.orderedIds(for: [
            candidate("a1", project: "alpha", last: 300),
            candidate("a2", project: "alpha", last: 200),
            candidate("a3", project: "alpha", last: 100),
            candidate("b1", project: "beta", last: 150),
        ])

        XCTAssertEqual(ordered, ["a1", "b1", "a2", "a3"])
    }

    func testHigherPrioritySessionsStayAheadOfProjectDiversity() {
        let ordered = ProjectAwarePillOrder.orderedIds(for: [
            candidate("idle-a", project: "alpha", priority: 2, last: 400),
            candidate("blocked-b", project: "beta", priority: 0, last: 100),
            candidate("idle-b", project: "beta", priority: 2, last: 300),
        ])

        XCTAssertEqual(ordered, ["blocked-b", "idle-a", "idle-b"])
    }

    func testDifferentAgentSurfacesDoNotInterruptRecencyWithinSameProject() {
        let ordered = ProjectAwarePillOrder.orderedIds(for: [
            candidate("codex-newest", project: "Codes", surface: "codex:codexApp", last: 400),
            candidate("codex-second", project: "Codes", surface: "codex:codexApp", last: 300),
            candidate("codex-third", project: "Codes", surface: "codex:codexApp", last: 200),
            candidate("cursor-old", project: "Codes", surface: "cursor:cursor", last: 100),
        ])

        XCTAssertEqual(ordered, [
            "codex-newest",
            "codex-second",
            "codex-third",
            "cursor-old",
        ])
    }
}
