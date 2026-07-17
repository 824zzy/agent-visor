import XCTest
@testable import AgentVisorCore

final class ToolUseCorrelationBufferTests: XCTestCase {
    func testCompletedAutoApprovedToolCannotSatisfyALaterApproval() {
        var buffer = ToolUseCorrelationBuffer(maxEntries: 16, maxAge: 300)
        buffer.record(
            sessionId: "session",
            correlationKey: "Bash:{command:echo}",
            toolUseId: "auto-approved",
            at: 10
        )
        buffer.complete(toolUseId: "auto-approved", at: 11)
        buffer.record(
            sessionId: "session",
            correlationKey: "Bash:{command:echo}",
            toolUseId: "needs-approval",
            at: 12
        )

        XCTAssertEqual(
            buffer.consume(
                sessionId: "session",
                correlationKey: "Bash:{command:echo}",
                at: 13
            ),
            "needs-approval"
        )
    }

    func testParallelIdenticalToolsRemainFifo() {
        var buffer = ToolUseCorrelationBuffer(maxEntries: 16, maxAge: 300)
        buffer.record(sessionId: "s", correlationKey: "same", toolUseId: "first", at: 1)
        buffer.record(sessionId: "s", correlationKey: "same", toolUseId: "second", at: 2)

        XCTAssertEqual(buffer.consume(sessionId: "s", correlationKey: "same", at: 3), "first")
        XCTAssertEqual(buffer.consume(sessionId: "s", correlationKey: "same", at: 4), "second")
    }

    func testStaleEntriesExpireBeforeConsumption() {
        var buffer = ToolUseCorrelationBuffer(maxEntries: 16, maxAge: 5)
        buffer.record(sessionId: "s", correlationKey: "same", toolUseId: "stale", at: 1)

        XCTAssertNil(buffer.consume(sessionId: "s", correlationKey: "same", at: 7))
        XCTAssertEqual(buffer.count, 0)
    }

    func testBufferEvictsTheOldestEntryAtItsBound() {
        var buffer = ToolUseCorrelationBuffer(maxEntries: 2, maxAge: 300)
        buffer.record(sessionId: "s", correlationKey: "one", toolUseId: "oldest", at: 1)
        buffer.record(sessionId: "s", correlationKey: "two", toolUseId: "middle", at: 2)
        buffer.record(sessionId: "s", correlationKey: "three", toolUseId: "newest", at: 3)

        XCTAssertEqual(buffer.count, 2)
        XCTAssertNil(buffer.consume(sessionId: "s", correlationKey: "one", at: 4))
        XCTAssertEqual(buffer.consume(sessionId: "s", correlationKey: "two", at: 4), "middle")
        XCTAssertEqual(buffer.consume(sessionId: "s", correlationKey: "three", at: 4), "newest")
    }

    func testSessionCleanupDoesNotRemoveOtherSessions() {
        var buffer = ToolUseCorrelationBuffer(maxEntries: 16, maxAge: 300)
        buffer.record(sessionId: "one", correlationKey: "same", toolUseId: "one-id", at: 1)
        buffer.record(sessionId: "two", correlationKey: "same", toolUseId: "two-id", at: 1)

        buffer.removeSession("one", at: 2)

        XCTAssertNil(buffer.consume(sessionId: "one", correlationKey: "same", at: 3))
        XCTAssertEqual(buffer.consume(sessionId: "two", correlationKey: "same", at: 3), "two-id")
    }
}
