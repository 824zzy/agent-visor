//
//  SidebarProjectOrdererTests.swift
//  AgentVisorCoreTests
//
//  The window-mode sidebar lets the user drag project headers to pin a
//  custom group order. SidebarProjectOrderer merges that saved order with
//  the live set of projects (which changes as sessions come and go) and
//  applies individual drag moves.
//

import XCTest
@testable import AgentVisorCore

final class SidebarProjectOrdererTests: XCTestCase {

    // MARK: - order(naturalOrder:manualOrder:)

    func testEmptyManualOrderFallsBackToNatural() {
        let result = SidebarProjectOrderer.order(
            naturalOrder: ["a", "b", "c"],
            manualOrder: []
        )
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testManualOrderTakesPrecedence() {
        let result = SidebarProjectOrderer.order(
            naturalOrder: ["a", "b", "c"],
            manualOrder: ["c", "a", "b"]
        )
        XCTAssertEqual(result, ["c", "a", "b"])
    }

    func testNewProjectNotInManualOrderAppendsInNaturalOrder() {
        // "d" opened since the last drag — it follows the saved keys, in
        // the natural position relative to other un-dragged keys.
        let result = SidebarProjectOrderer.order(
            naturalOrder: ["a", "b", "c", "d"],
            manualOrder: ["c", "a"]
        )
        XCTAssertEqual(result, ["c", "a", "b", "d"])
    }

    func testStaleManualKeyIsDropped() {
        // "z" was dragged once but its project has since closed; it must
        // not appear or leave a hole.
        let result = SidebarProjectOrderer.order(
            naturalOrder: ["a", "b"],
            manualOrder: ["z", "b", "a"]
        )
        XCTAssertEqual(result, ["b", "a"])
    }

    func testDuplicateManualKeysCollapse() {
        let result = SidebarProjectOrderer.order(
            naturalOrder: ["a", "b"],
            manualOrder: ["b", "b", "a"]
        )
        XCTAssertEqual(result, ["b", "a"])
    }

    // MARK: - reordered(currentOrder:movedKey:before:)

    func testReorderMovesBeforeTarget() {
        let result = SidebarProjectOrderer.reordered(
            currentOrder: ["a", "b", "c"],
            movedKey: "c",
            before: "a"
        )
        XCTAssertEqual(result, ["c", "a", "b"])
    }

    func testReorderMovesDownwards() {
        let result = SidebarProjectOrderer.reordered(
            currentOrder: ["a", "b", "c"],
            movedKey: "a",
            before: "c"
        )
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func testReorderNilTargetMovesToEnd() {
        let result = SidebarProjectOrderer.reordered(
            currentOrder: ["a", "b", "c"],
            movedKey: "a",
            before: nil
        )
        XCTAssertEqual(result, ["b", "c", "a"])
    }

    func testReorderOntoSelfIsNoOp() {
        let result = SidebarProjectOrderer.reordered(
            currentOrder: ["a", "b", "c"],
            movedKey: "b",
            before: "b"
        )
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testReorderUnknownMovedKeyIsNoOp() {
        let result = SidebarProjectOrderer.reordered(
            currentOrder: ["a", "b", "c"],
            movedKey: "zzz",
            before: "a"
        )
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testReorderUnknownTargetAppendsToEnd() {
        let result = SidebarProjectOrderer.reordered(
            currentOrder: ["a", "b", "c"],
            movedKey: "a",
            before: "nope"
        )
        XCTAssertEqual(result, ["b", "c", "a"])
    }
}
