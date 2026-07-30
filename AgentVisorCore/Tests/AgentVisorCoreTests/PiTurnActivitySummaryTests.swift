import XCTest
@testable import AgentVisorCore

final class PiTurnActivitySummaryTests: XCTestCase {
    func testScreenshotToolsBecomeTenActionsWithCanonicalSummary() {
        let summary = PiTurnActivitySummarizer.summarize(rawToolNames: [
            "read", "read", "read", "read",
            "bash", "bash", "bash", "bash", "bash", "bash",
        ])

        XCTAssertEqual(summary.actionCount, 10)
        XCTAssertEqual(summary.countLabel, "10 actions")
        XCTAssertEqual(summary.activityLabel, "Ran 6 commands · Read 4 files")
    }
}
