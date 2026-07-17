//
//  TurnCollapsePlannerTests.swift
//  AgentVisorCoreTests
//
//  Pure logic for the window chat's collapsible "Worked for X" turns.
//  A turn-duration parent's intermediate steps (its children) are
//  hidden unless the turn id is in the expanded set — Codex-desktop
//  behavior, collapsed by default.
//

import XCTest
@testable import AgentVisorCore

final class TurnCollapsePlannerTests: XCTestCase {
    private func group(_ parent: String, _ children: [String] = []) -> TurnCollapsePlanner.RowGroup {
        TurnCollapsePlanner.RowGroup(parentId: parent, childIds: children)
    }

    // MARK: - degenerate

    func testEmptyGroupsYieldEmptyPlan() {
        let plan = TurnCollapsePlanner.plan(groups: [], expanded: [])
        XCTAssertTrue(plan.isEmpty)
    }

    func testStandaloneRowsAllDepthZero() {
        let plan = TurnCollapsePlanner.plan(
            groups: [group("a"), group("b"), group("c")],
            expanded: ["a", "b", "c"]  // expansion irrelevant: no children
        )
        XCTAssertEqual(plan, [
            .init(id: "a", depth: 0),
            .init(id: "b", depth: 0),
            .init(id: "c", depth: 0),
        ])
    }

    // MARK: - collapse / expand a turn

    func testCollapsedTurnOmitsChildren() {
        let plan = TurnCollapsePlanner.plan(
            groups: [group("turn", ["s1", "s2", "s3"])],
            expanded: []  // collapsed by default
        )
        XCTAssertEqual(plan, [.init(id: "turn", depth: 0)])
    }

    func testExpandedTurnIncludesChildrenAtDepthOne() {
        let plan = TurnCollapsePlanner.plan(
            groups: [group("turn", ["s1", "s2", "s3"])],
            expanded: ["turn"]
        )
        XCTAssertEqual(plan, [
            .init(id: "turn", depth: 0),
            .init(id: "s1", depth: 1),
            .init(id: "s2", depth: 1),
            .init(id: "s3", depth: 1),
        ])
    }

    // MARK: - mixed timeline, order preserved

    func testMixedTimelinePreservesOrderAndDepths() {
        // user msg, collapsed turn, assistant answer, expanded turn, user msg
        let plan = TurnCollapsePlanner.plan(
            groups: [
                group("u1"),
                group("t1", ["t1s1", "t1s2"]),
                group("a1"),
                group("t2", ["t2s1", "t2s2"]),
                group("u2"),
            ],
            expanded: ["t2"]
        )
        XCTAssertEqual(plan, [
            .init(id: "u1", depth: 0),
            .init(id: "t1", depth: 0),               // collapsed → no children
            .init(id: "a1", depth: 0),
            .init(id: "t2", depth: 0),
            .init(id: "t2s1", depth: 1),
            .init(id: "t2s2", depth: 1),
            .init(id: "u2", depth: 0),
        ])
    }

    // MARK: - robustness

    func testExpandedIdsForUnknownOrChildlessParentsAreNoop() {
        let plan = TurnCollapsePlanner.plan(
            groups: [group("standalone"), group("turn", ["c1"])],
            expanded: ["does-not-exist", "standalone"]  // neither has children
        )
        XCTAssertEqual(plan, [
            .init(id: "standalone", depth: 0),
            .init(id: "turn", depth: 0),  // not in expanded → collapsed
        ])
    }
}
