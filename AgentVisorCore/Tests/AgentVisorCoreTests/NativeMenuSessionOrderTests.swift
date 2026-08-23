import XCTest
@testable import AgentVisorCore

final class NativeMenuSessionOrderTests: XCTestCase {
    func testKeepsPositionsAcrossRecencyOnlyReordering() {
        XCTAssertEqual(
            NativeMenuSessionOrder.resolve(
                displayedIDs: ["session-a", "session-b"],
                previousPhases: ["session-a": .ready, "session-b": .ready],
                presentedPills: [pill("session-b", .ready), pill("session-a", .ready)]
            ),
            ["session-a", "session-b"]
        )
    }

    func testAdoptsPresentedOrderAfterPhaseOrMembershipChanges() {
        XCTAssertEqual(
            NativeMenuSessionOrder.resolve(
                displayedIDs: ["session-b", "session-a"],
                previousPhases: ["session-a": .ready, "session-b": .ready],
                presentedPills: [pill("session-a", .ready), pill("session-b", .working)]
            ),
            ["session-a", "session-b"]
        )
        XCTAssertEqual(
            NativeMenuSessionOrder.resolve(
                displayedIDs: ["session-a", "session-b"],
                previousPhases: ["session-a": .ready, "session-b": .working],
                presentedPills: [pill("session-c", .ready), pill("session-a", .ready)]
            ),
            ["session-c", "session-a"]
        )
    }

    private func pill(_ id: String, _ phase: NativeHelperPillPhase) -> NativeHelperPill {
        NativeHelperPill(
            id: id,
            title: id,
            phase: phase,
            priority: 0,
            accessibilityLabel: id
        )
    }
}
