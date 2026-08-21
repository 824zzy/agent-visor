import XCTest
@testable import AgentVisorCore

/// The rule that stopped a bootstrap from forking one `sqlite3` per session.
final class CodexThreadLookupPlanPolicyTests: XCTestCase {
    func testCachedIdsNeedNoRead() {
        let needed = CodexThreadLookupPlanPolicy.idsNeedingQuery(
            requested: ["a", "b"],
            cached: ["a", "b"],
            knownMissing: []
        )
        XCTAssertTrue(needed.isEmpty)
    }

    func testKnownMissingIdsNeedNoRead() {
        // The point of the negative memory: an absent id must not fork again
        // on every later lookup during the same sweep.
        let needed = CodexThreadLookupPlanPolicy.idsNeedingQuery(
            requested: ["gone"],
            cached: [],
            knownMissing: ["gone"]
        )
        XCTAssertTrue(needed.isEmpty)
    }

    func testOnlyUnknownIdsAreQueried() {
        let needed = CodexThreadLookupPlanPolicy.idsNeedingQuery(
            requested: ["cached", "gone", "new"],
            cached: ["cached"],
            knownMissing: ["gone"]
        )
        XCTAssertEqual(needed, ["new"])
    }

    func testRequestOrderIsKeptAndDuplicatesCollapse() {
        let needed = CodexThreadLookupPlanPolicy.idsNeedingQuery(
            requested: ["b", "a", "b", "a"],
            cached: [],
            knownMissing: []
        )
        XCTAssertEqual(needed, ["b", "a"])
    }

    func testEmptyIdsAreIgnored() {
        let needed = CodexThreadLookupPlanPolicy.idsNeedingQuery(
            requested: ["", "a"],
            cached: [],
            knownMissing: []
        )
        XCTAssertEqual(needed, ["a"])
    }

    func testMissingIdsAreTheQueriedMinusTheReturned() {
        let missing = CodexThreadLookupPlanPolicy.missingIDs(
            queried: ["a", "b", "c"],
            returned: ["b"]
        )
        XCTAssertEqual(missing, ["a", "c"])
    }

    func testAnEmptyAnswerProvesNothing() {
        // A read that returns no rows is treated as a failed read, so no id is
        // remembered as absent.
        let missing = CodexThreadLookupPlanPolicy.missingIDs(
            queried: ["a", "b"],
            returned: []
        )
        XCTAssertTrue(missing.isEmpty)
    }

    func testAFullAnswerLeavesNothingMissing() {
        let missing = CodexThreadLookupPlanPolicy.missingIDs(
            queried: ["a"],
            returned: ["a"]
        )
        XCTAssertTrue(missing.isEmpty)
    }
}
