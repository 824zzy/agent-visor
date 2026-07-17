//
//  SidebarRecencyTests.swift
//  AgentVisorCoreTests
//
//  The sidebar's recency sort must reflect TRUE conversational
//  recency. `lastUserMessageDate` is brittle on big/compacted
//  transcripts: the head+tail summary parser only matches
//  string-content user turns, so a session whose recent human turns
//  are array-shaped (image/tool_result wrappers) resolves its
//  "last user message" to an ancient head-of-file turn and sinks to
//  the bottom even though it's the most recently active. `lastActivityDate`
//  (last message of ANY role, both content shapes) is the correct key.
//

import XCTest
@testable import AgentVisorCore

final class SidebarRecencyTests: XCTestCase {
    private let recent = Date(timeIntervalSince1970: 1_780_942_000)  // Jun 2026
    private let ancient = Date(timeIntervalSince1970: 1_775_872_000)  // Apr 2026
    private let mtime = Date(timeIntervalSince1970: 1_780_900_000)

    // MARK: - preference order

    func testPrefersLastActivityDateOverEverything() {
        let d = SidebarRecency.sortDate(
            lastActivityDate: recent,
            lastUserMessageDate: ancient,
            lastActivity: mtime
        )
        XCTAssertEqual(d, recent)
    }

    func testUsesNewestSignalWhenNoActivityDate() {
        let d = SidebarRecency.sortDate(
            lastActivityDate: nil,
            lastUserMessageDate: ancient,
            lastActivity: mtime
        )
        XCTAssertEqual(d, mtime)
    }

    func testFallsBackToLastActivityWhenNoDates() {
        let d = SidebarRecency.sortDate(
            lastActivityDate: nil,
            lastUserMessageDate: nil,
            lastActivity: mtime
        )
        XCTAssertEqual(d, mtime)
    }

    // MARK: - the regression this fixes

    func testRecentArrayTurnSessionOutranksStaleUserDate() {
        // Session A: recent activity (assistant/tool turn today) but its
        // last STRING user message is ancient — the bug case.
        let a = SidebarRecency.sortDate(
            lastActivityDate: recent, lastUserMessageDate: ancient, lastActivity: mtime
        )
        // Session B: genuinely older across the board.
        let older = Date(timeIntervalSince1970: 1_779_863_000)
        let b = SidebarRecency.sortDate(
            lastActivityDate: older, lastUserMessageDate: older, lastActivity: older
        )
        XCTAssertGreaterThan(a, b, "recent-activity session must sort newer than an older one")
    }

    func testFileActivityCanOutrankStaleParsedActivityDate() {
        let staleParsedActivity = Date(timeIntervalSince1970: 1_781_389_597)
        let freshRolloutMTime = Date(timeIntervalSince1970: 1_781_390_176)

        let d = SidebarRecency.sortDate(
            lastActivityDate: staleParsedActivity,
            lastUserMessageDate: staleParsedActivity,
            lastActivity: freshRolloutMTime
        )

        XCTAssertEqual(d, freshRolloutMTime)
    }

    func testRecencyBeatsPhasePriorityForNormalRows() {
        XCTAssertTrue(SidebarRecency.precedes(
            lhsDate: recent,
            rhsDate: ancient,
            lhsPhasePriority: 2,
            rhsPhasePriority: 0,
            lhsID: "newer-idle",
            rhsID: "older-processing"
        ))
    }

    func testPhasePriorityBreaksTiesOnly() {
        XCTAssertTrue(SidebarRecency.precedes(
            lhsDate: recent,
            rhsDate: recent,
            lhsPhasePriority: 0,
            rhsPhasePriority: 2,
            lhsID: "processing",
            rhsID: "idle"
        ))
    }
}
