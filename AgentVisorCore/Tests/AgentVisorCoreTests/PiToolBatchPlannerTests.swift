import XCTest
@testable import AgentVisorCore

final class PiToolBatchPlannerTests: XCTestCase {
    func testAdjacentSameKindActionsBatchWithoutLosingOriginalIds() {
        let groups = PiToolBatchPlanner.groups([
            .init(id: "read-1", tool: .read, isBatchable: true),
            .init(id: "bash-1", tool: .bash, isBatchable: true),
            .init(id: "bash-2", tool: .bash, isBatchable: true),
            .init(id: "bash-error", tool: .bash, isBatchable: false),
            .init(id: "read-2", tool: .read, isBatchable: true),
            .init(id: "read-3", tool: .read, isBatchable: true),
        ])

        XCTAssertEqual(groups.map(\.ids), [
            ["read-1"],
            ["bash-1", "bash-2"],
            ["bash-error"],
            ["read-2", "read-3"],
        ])
    }
}
