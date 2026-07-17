import XCTest
@testable import AgentVisorCore

final class SidebarSessionGrouperTests: XCTestCase {
    // MARK: - Fixtures

    private func row(
        id: String,
        title: String = "Session",
        attention: Bool = false,
        active: Bool = true,
        agent: AgentID = .claudeCode,
        last: TimeInterval = 0
    ) -> SidebarSessionRow {
        SidebarSessionRow(
            sessionId: id,
            title: title,
            subtitle: "/tmp",
            agent: agent,
            needsAttention: attention,
            isActive: active,
            lastActivity: Date(timeIntervalSince1970: last)
        )
    }

    // MARK: - Group ordering

    func testEmptyInputProducesNoGroups() {
        XCTAssertTrue(SidebarSessionGrouper.group([]).isEmpty)
    }

    func testAttentionGroupComesFirst() {
        let attn = row(id: "a", attention: true, last: 100)
        let active = row(id: "b", attention: false, active: true, last: 200)
        let groups = SidebarSessionGrouper.group([active, attn])
        XCTAssertEqual(groups.first?.kind, .needsAttention)
        XCTAssertEqual(groups.first?.rows.map(\.sessionId), ["a"])
    }

    func testActiveBeforeRecent() {
        let active = row(id: "act", active: true, last: 50)
        let recent = row(id: "rec", active: false, last: 100)
        let groups = SidebarSessionGrouper.group([recent, active])
        XCTAssertEqual(groups.map(\.kind), [.active, .recent])
    }

    func testFullGroupOrder() {
        let g = SidebarSessionGrouper.group([
            row(id: "rec", active: false, last: 1),
            row(id: "act", active: true, last: 2),
            row(id: "attn", attention: true, last: 3),
        ])
        XCTAssertEqual(g.map(\.kind), [.needsAttention, .active, .recent])
    }

    func testEmptyGroupsAreDropped() {
        let only = row(id: "x", attention: false, active: true)
        let groups = SidebarSessionGrouper.group([only])
        XCTAssertEqual(groups.map(\.kind), [.active])
    }

    // MARK: - Within-group ordering

    func testRowsSortedByLastActivityDescending() {
        let older = row(id: "old", active: true, last: 100)
        let newer = row(id: "new", active: true, last: 200)
        let groups = SidebarSessionGrouper.group([older, newer])
        XCTAssertEqual(groups[0].rows.map(\.sessionId), ["new", "old"])
    }

    func testStableTieBreakerBySessionId() {
        let same = Date(timeIntervalSince1970: 100)
        let a = SidebarSessionRow(sessionId: "a", title: "", subtitle: "", agent: .claudeCode,
                                  needsAttention: false, isActive: true, lastActivity: same)
        let b = SidebarSessionRow(sessionId: "b", title: "", subtitle: "", agent: .claudeCode,
                                  needsAttention: false, isActive: true, lastActivity: same)
        let groups = SidebarSessionGrouper.group([b, a])
        XCTAssertEqual(groups[0].rows.map(\.sessionId), ["a", "b"])
    }

    // MARK: - Attention precedence over active

    func testAttentionWinsOverActive() {
        let r = row(id: "x", attention: true, active: true, last: 1)
        let groups = SidebarSessionGrouper.group([r])
        XCTAssertEqual(groups.map(\.kind), [.needsAttention])
    }
}
