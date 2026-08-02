import XCTest
@testable import AgentVisorCore

final class ReadySessionEpisodeTrackerTests: XCTestCase {
    func testAttachmentMetadataChangeDoesNotCreateAnotherReadyEpisode() {
        var tracker = ReadySessionEpisodeTracker()

        XCTAssertEqual(
            tracker.update(readySessionIDs: ["session-1"]),
            ["session-1"]
        )
        XCTAssertEqual(
            tracker.update(readySessionIDs: ["session-1"]),
            [],
            "A PID or TTY change is outside durable Ready identity and must not replay attention."
        )
    }

    func testLeavingReadyThenReturningCreatesAnotherEpisode() {
        var tracker = ReadySessionEpisodeTracker()

        XCTAssertEqual(tracker.update(readySessionIDs: ["session-1"]), ["session-1"])
        XCTAssertEqual(tracker.update(readySessionIDs: []), [])
        XCTAssertEqual(tracker.update(readySessionIDs: ["session-1"]), ["session-1"])
    }

    func testOnlyNewlyReadySessionIsReturnedWhenAnotherRemainsReady() {
        var tracker = ReadySessionEpisodeTracker()

        XCTAssertEqual(tracker.update(readySessionIDs: ["session-1"]), ["session-1"])
        XCTAssertEqual(
            tracker.update(readySessionIDs: ["session-1", "session-2"]),
            ["session-2"]
        )
    }
}
