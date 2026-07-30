import XCTest
@testable import AgentVisorCore

final class PiTurnGrouperTests: XCTestCase {
    private typealias Category = PiTurnGrouper.ItemCategory
    private typealias Item = PiTurnGrouper.ItemDescriptor

    private func item(_ id: String, _ category: Category) -> Item {
        Item(id: id, category: category)
    }

    func testFailedAssistantProseStaysInsideWorkInsteadOfBecomingFinalAnswer() {
        let rows = PiTurnGrouper.group([
            item("prompt", .prompt),
            item("failed-prose", .assistantText),
            item("interrupted", .supportingWork(hasError: true)),
        ], sessionIsProcessing: false)

        XCTAssertEqual(rows.map(\.parentId), [
            "prompt",
            "interrupted" + PiTurnGrouper.headerSuffix,
        ])
        XCTAssertEqual(rows[1].detailIds, ["failed-prose", "interrupted"])
        XCTAssertTrue(rows[1].hasError)
    }

    func testLiveTrailingProseRemainsWorkUntilTurnCompletes() {
        let rows = PiTurnGrouper.group([
            item("prompt", .prompt),
            item("reason", .reasoning),
            item("read", .action(hasError: false)),
            item("progress", .assistantText),
        ], sessionIsProcessing: true)

        XCTAssertEqual(rows.map(\.parentId), [
            "prompt",
            "reason" + PiTurnGrouper.headerSuffix,
        ])
        XCTAssertEqual(rows[1].detailIds, ["read", "progress"])
        XCTAssertEqual(rows[1].reasoningIds, ["reason"])
        XCTAssertTrue(rows[1].isLive)
    }

    func testPromptBoundariesNeverMergeNeighboringTurns() {
        let rows = PiTurnGrouper.group([
            item("prompt-1", .prompt),
            item("tool-1", .action(hasError: false)),
            item("answer-1", .assistantText),
            item("prompt-2", .prompt),
            item("tool-2", .action(hasError: false)),
            item("answer-2", .assistantText),
        ], sessionIsProcessing: false)

        XCTAssertEqual(rows.map(\.parentId), [
            "prompt-1", "tool-1" + PiTurnGrouper.headerSuffix, "answer-1",
            "prompt-2", "tool-2" + PiTurnGrouper.headerSuffix, "answer-2",
        ])
    }

    func testScreenshotTurnBecomesPromptGroupedWorkAndFinalAnswer() {
        let rows = PiTurnGrouper.group([
            item("prompt", .prompt),
            item("reason-1", .reasoning),
            item("read-1", .action(hasError: false)),
            item("reason-2", .reasoning),
            item("bash-1", .action(hasError: false)),
            item("reason-3", .reasoning),
            item("bash-2", .action(hasError: false)),
            item("final", .assistantText),
        ], sessionIsProcessing: false)

        XCTAssertEqual(rows.map(\.parentId), [
            "prompt",
            "reason-1" + PiTurnGrouper.headerSuffix,
            "final",
        ])

        let work = rows[1]
        XCTAssertEqual(work.detailIds, ["read-1", "bash-1", "bash-2"])
        XCTAssertEqual(work.reasoningIds, ["reason-1", "reason-2", "reason-3"])
        XCTAssertEqual(work.actionCount, 3)
        XCTAssertFalse(work.hasError)
        XCTAssertFalse(work.isLive)
    }
}
