import XCTest
@testable import AgentVisorCore

final class NativeMenuShortcutSnapshotTests: XCTestCase {
    func testFreezesTheFirstNineVisibleSessionPositions() {
        let ids = (1...12).map { "session-\($0)" }
        let snapshot = NativeMenuShortcutSnapshot(visibleSessionIDs: ids)

        XCTAssertEqual(snapshot.positions["session-1"], 1)
        XCTAssertEqual(snapshot.positions["session-9"], 9)
        XCTAssertNil(snapshot.positions["session-10"])
        XCTAssertEqual(snapshot.sessionID(at: 0), "session-1")
        XCTAssertEqual(snapshot.sessionID(at: 8), "session-9")
        XCTAssertNil(snapshot.sessionID(at: 9))
    }
}
