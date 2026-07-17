import XCTest
@testable import AgentVisorCore

final class SidebarStateSectionPolicyTests: XCTestCase {
    private func candidate(
        _ id: String,
        section: SidebarStateSectionKind,
        last: TimeInterval
    ) -> SidebarStateSectionCandidate {
        SidebarStateSectionCandidate(
            sessionId: id,
            section: section,
            sortDate: Date(timeIntervalSince1970: last)
        )
    }

    func testSectionOrderIsStateFirst() {
        let groups = SidebarStateSectionPolicy.group([
            candidate("recent", section: .recent, last: 400),
            candidate("ready", section: .ready, last: 300),
            candidate("working", section: .working, last: 200),
            candidate("attention", section: .needsAttention, last: 100),
        ])

        XCTAssertEqual(groups.map(\.kind), [
            .needsAttention,
            .ready,
            .working,
            .recent,
        ])
    }

    func testRecencySortsWithinEachSection() {
        let groups = SidebarStateSectionPolicy.group([
            candidate("older", section: .working, last: 100),
            candidate("newer", section: .working, last: 200),
        ])

        XCTAssertEqual(groups.first?.rows.map(\.sessionId), ["newer", "older"])
    }

    func testOlderReadyStillAppearsAboveNewerWorking() {
        let groups = SidebarStateSectionPolicy.group([
            candidate("work-new", section: .working, last: 1_000),
            candidate("ready-old", section: .ready, last: 1),
        ])

        XCTAssertEqual(SidebarStateSectionPolicy.visibleIds(from: groups), [
            "ready-old",
            "work-new",
        ])
    }

    func testNewerIdleDoesNotJumpAboveReadyOrWorking() {
        let groups = SidebarStateSectionPolicy.group([
            candidate("idle-new", section: .recent, last: 1_000),
            candidate("ready-old", section: .ready, last: 2),
            candidate("work-old", section: .working, last: 1),
        ])

        XCTAssertEqual(SidebarStateSectionPolicy.visibleIds(from: groups), [
            "ready-old",
            "work-old",
            "idle-new",
        ])
    }

    func testHotkeyOrderFollowsVisibleStateSectionOrder() {
        let groups = SidebarStateSectionPolicy.group([
            candidate("recent-a", section: .recent, last: 30),
            candidate("ready-a", section: .ready, last: 10),
            candidate("working-a", section: .working, last: 20),
            candidate("attention-a", section: .needsAttention, last: 5),
        ])

        XCTAssertEqual(SidebarStateSectionPolicy.visibleIds(from: groups), [
            "attention-a",
            "ready-a",
            "working-a",
            "recent-a",
        ])
    }

    func testStableTieBreakerBySessionId() {
        let groups = SidebarStateSectionPolicy.group([
            candidate("b", section: .ready, last: 100),
            candidate("a", section: .ready, last: 100),
        ])

        XCTAssertEqual(groups.first?.rows.map(\.sessionId), ["a", "b"])
    }
}
