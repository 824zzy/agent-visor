import XCTest
@testable import AgentVisorCore

/// Today every child process in the app waits with no deadline, so a child that
/// never exits holds its thread for the life of the app. These tests pin what a
/// deadline means and stop "no deadline" from coming back through the door.
final class SubprocessDeadlinePolicyTests: XCTestCase {
    func testACallerCannotAskForNoDeadline() {
        XCTAssertEqual(
            SubprocessDeadlinePolicy.deadline(requested: nil),
            SubprocessDeadlinePolicy.localRead,
            "A missing choice must fall back to a real deadline, not to waiting forever."
        )
    }

    func testACallerCannotAskForZeroOrLess() {
        // Zero would stop every child before it answered, which looks like the
        // machine is broken. Negative is the same mistake written differently.
        XCTAssertEqual(
            SubprocessDeadlinePolicy.deadline(requested: 0),
            SubprocessDeadlinePolicy.localRead
        )
        XCTAssertEqual(
            SubprocessDeadlinePolicy.deadline(requested: -30),
            SubprocessDeadlinePolicy.localRead
        )
    }

    func testACallerMayAskForLonger() {
        XCTAssertEqual(SubprocessDeadlinePolicy.deadline(requested: 45), 45)
    }

    func testTheFallbackIsTheCallersToChoose() {
        // A command that drives another app waits for a person-sized delay, so
        // its fallback is longer than a read of local state.
        XCTAssertEqual(
            SubprocessDeadlinePolicy.deadline(
                requested: nil,
                fallback: SubprocessDeadlinePolicy.appCommand
            ),
            SubprocessDeadlinePolicy.appCommand
        )
    }

    func testAReadDeadlineIsFarPastAHealthyRead() {
        // A healthy `ps` or sqlite read answers in milliseconds. The deadline is
        // not a performance budget; reaching it means something is wrong.
        XCTAssertGreaterThanOrEqual(SubprocessDeadlinePolicy.localRead, 1)
        XCTAssertLessThanOrEqual(SubprocessDeadlinePolicy.localRead, 10)
        XCTAssertLessThan(SubprocessDeadlinePolicy.localRead, SubprocessDeadlinePolicy.appCommand)
    }

    func testPassingTheDeadlineMeansNoAnswer() {
        XCTAssertEqual(
            SubprocessDeadlinePolicy.outcome(elapsed: 5, deadline: 5),
            .gaveUp
        )
        XCTAssertEqual(
            SubprocessDeadlinePolicy.outcome(elapsed: 4.9, deadline: 5),
            .answered
        )
    }
}
