import XCTest
@testable import AgentVisorCore

final class SidebarPathGrouperTests: XCTestCase {
    private let home = "/Users/test"

    private func row(
        id: String,
        cwd: String,
        attention: Bool = false,
        active: Bool = true,
        last: TimeInterval = 0
    ) -> SidebarPathRow {
        SidebarPathRow(
            sessionId: id,
            title: id,
            subtitle: "",
            agent: .claudeCode,
            needsAttention: attention,
            isActive: active,
            lastActivity: Date(timeIntervalSince1970: last),
            cwd: cwd
        )
    }

    // MARK: - projectKey helper

    func testEmptyCwdHasNoProjectKey() {
        XCTAssertNil(SidebarPathGrouper.projectKey(forCwd: "", homeDirectory: home))
    }

    func testRootCwdHasNoProjectKey() {
        XCTAssertNil(SidebarPathGrouper.projectKey(forCwd: "/", homeDirectory: home))
    }

    func testHomeDirCwdHasNoProjectKey() {
        XCTAssertNil(SidebarPathGrouper.projectKey(forCwd: home, homeDirectory: home))
        // Trailing slash variant standardizes to same.
        XCTAssertNil(SidebarPathGrouper.projectKey(forCwd: home + "/", homeDirectory: home))
    }

    func testCwdLastComponentIsProjectKey() {
        XCTAssertEqual(
            SidebarPathGrouper.projectKey(forCwd: "\(home)/Personal/agent-visor", homeDirectory: home),
            "agent-visor"
        )
        XCTAssertEqual(
            SidebarPathGrouper.projectKey(forCwd: "\(home)/Codes/ao-debug-tool", homeDirectory: home),
            "ao-debug-tool"
        )
    }

    // MARK: - empty input

    func testEmptyInputProducesNoGroups() {
        XCTAssertTrue(SidebarPathGrouper.group([], homeDirectory: home).isEmpty)
    }

    // MARK: - basic project grouping

    func testSingleSessionFormsProjectGroup() {
        let r = row(id: "a", cwd: "\(home)/Codes/foo", last: 100)
        let g = SidebarPathGrouper.group([r], homeDirectory: home)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].kind, .project(name: "foo"))
        XCTAssertEqual(g[0].rows.map(\.sessionId), ["a"])
    }

    func testTwoSessionsSamePathOneGroup() {
        let a = row(id: "a", cwd: "\(home)/Codes/foo", last: 100)
        let b = row(id: "b", cwd: "\(home)/Codes/foo", last: 200)
        let g = SidebarPathGrouper.group([a, b], homeDirectory: home)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].kind, .project(name: "foo"))
        // Newer first.
        XCTAssertEqual(g[0].rows.map(\.sessionId), ["b", "a"])
    }

    func testTwoProjectsTwoGroups() {
        let a = row(id: "a", cwd: "\(home)/Codes/foo", last: 100)
        let b = row(id: "b", cwd: "\(home)/Codes/bar", last: 200)
        let g = SidebarPathGrouper.group([a, b], homeDirectory: home)
        XCTAssertEqual(g.count, 2)
        // Project ordering: most-recent activity first.
        XCTAssertEqual(g[0].kind, .project(name: "bar"))
        XCTAssertEqual(g[1].kind, .project(name: "foo"))
    }

    // MARK: - within-group ordering

    func testRowsWithinGroupSortedByLastActivityDescending() {
        let older = row(id: "old", cwd: "\(home)/p", last: 100)
        let newer = row(id: "new", cwd: "\(home)/p", last: 200)
        let g = SidebarPathGrouper.group([older, newer], homeDirectory: home)
        XCTAssertEqual(g[0].rows.map(\.sessionId), ["new", "old"])
    }

    func testWithinGroupTieBreaksBySessionId() {
        let same = TimeInterval(100)
        let a = row(id: "a", cwd: "\(home)/p", last: same)
        let b = row(id: "b", cwd: "\(home)/p", last: same)
        let g = SidebarPathGrouper.group([b, a], homeDirectory: home)
        XCTAssertEqual(g[0].rows.map(\.sessionId), ["a", "b"])
    }

    // MARK: - 'Other' bucket

    func testHomeDirSessionGoesToOther() {
        let a = row(id: "a", cwd: home, last: 100)
        let g = SidebarPathGrouper.group([a], homeDirectory: home)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].kind, .other)
    }

    func testOtherIsAlwaysLast() {
        let other = row(id: "o", cwd: home, last: 999)
        let proj = row(id: "p", cwd: "\(home)/Codes/foo", last: 1)
        let g = SidebarPathGrouper.group([other, proj], homeDirectory: home)
        XCTAssertEqual(g.last?.kind, .other,
                       "Other should be pinned to bottom even when its rows are most recent")
        XCTAssertEqual(g[0].kind, .project(name: "foo"))
    }

    // MARK: - Needs attention overlay

    func testNeedsAttentionPinnedAtTop() {
        let attn = row(id: "a", cwd: "\(home)/Codes/foo", attention: true, last: 100)
        let calm = row(id: "c", cwd: "\(home)/Codes/bar", last: 200)
        let g = SidebarPathGrouper.group([calm, attn], homeDirectory: home)
        XCTAssertEqual(g.first?.kind, .needsAttention)
        XCTAssertEqual(g.first?.rows.map(\.sessionId), ["a"])
    }

    func testAttentionRowAbsentFromProjectGroup() {
        let attn = row(id: "a", cwd: "\(home)/Codes/foo", attention: true, last: 100)
        let calm = row(id: "c", cwd: "\(home)/Codes/foo", last: 50)
        let g = SidebarPathGrouper.group([attn, calm], homeDirectory: home)
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].kind, .needsAttention)
        XCTAssertEqual(g[0].rows.map(\.sessionId), ["a"])
        // Calm row remains under its project; attention row does NOT
        // appear under the project group.
        XCTAssertEqual(g[1].kind, .project(name: "foo"))
        XCTAssertEqual(g[1].rows.map(\.sessionId), ["c"])
    }

    func testAttentionGroupOmittedWhenEmpty() {
        let r = row(id: "a", cwd: "\(home)/Codes/foo", attention: false)
        let g = SidebarPathGrouper.group([r], homeDirectory: home)
        XCTAssertFalse(g.contains { $0.kind == .needsAttention })
    }

    // MARK: - Full ordering

    func testFullOrdering() {
        let attn = row(id: "attn", cwd: "\(home)/Codes/foo", attention: true, last: 50)
        let bar = row(id: "bar1",  cwd: "\(home)/Codes/bar", last: 200)
        let foo = row(id: "foo1",  cwd: "\(home)/Codes/foo", last: 100)
        let other = row(id: "o",   cwd: home, last: 999)
        let g = SidebarPathGrouper.group([other, foo, attn, bar], homeDirectory: home)
        XCTAssertEqual(g.map(\.kind), [
            .needsAttention,
            .project(name: "bar"),  // last:200, most-recent project
            .project(name: "foo"),  // last:100
            .other,                 // pinned bottom regardless of its rows
        ])
    }

    // MARK: - Display title

    func testGroupDisplayTitles() {
        XCTAssertEqual(SidebarPathGroup(kind: .needsAttention, rows: []).displayTitle,
                       "Needs attention")
        XCTAssertEqual(SidebarPathGroup(kind: .project(name: "agent-visor"), rows: []).displayTitle,
                       "agent-visor")
        XCTAssertEqual(SidebarPathGroup(kind: .other, rows: []).displayTitle,
                       "Other")
    }
}
