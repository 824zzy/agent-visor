import XCTest
@testable import AgentVisorCore

final class TranscriptSyncCoalescerTests: XCTestCase {
    func testRequestsBeforeRunReplaceThePendingRequest() {
        var coalescer = TranscriptSyncCoalescer<String>()

        XCTAssertEqual(coalescer.request("first"), .debounceLatest)
        XCTAssertEqual(coalescer.request("latest"), .debounceLatest)

        XCTAssertEqual(coalescer.beginPendingRun(), "latest")
        XCTAssertNil(coalescer.beginPendingRun())
    }

    func testRequestsDuringRunRetainOnlyOneLatestRerun() {
        var coalescer = TranscriptSyncCoalescer<String>()
        _ = coalescer.request("running")
        XCTAssertEqual(coalescer.beginPendingRun(), "running")

        XCTAssertEqual(coalescer.request("stale-rerun"), .coalescedIntoRunning)
        XCTAssertEqual(coalescer.request("latest-rerun"), .coalescedIntoRunning)

        XCTAssertEqual(coalescer.completeRun(), .debounceLatest)
        XCTAssertEqual(coalescer.beginPendingRun(), "latest-rerun")
        XCTAssertEqual(coalescer.completeRun(), .idle)
    }

    func testCancelPendingKeepsTheCurrentRunButDropsItsRerun() {
        var coalescer = TranscriptSyncCoalescer<String>()
        _ = coalescer.request("running")
        XCTAssertEqual(coalescer.beginPendingRun(), "running")
        _ = coalescer.request("rerun")

        coalescer.cancelPending()

        XCTAssertTrue(coalescer.isRunning)
        XCTAssertEqual(coalescer.completeRun(), .idle)
        XCTAssertNil(coalescer.beginPendingRun())
    }

    func testCancelPendingPreventsADebouncedRunFromStarting() {
        var coalescer = TranscriptSyncCoalescer<String>()
        _ = coalescer.request("pending")

        coalescer.cancelPending()

        XCTAssertFalse(coalescer.isRunning)
        XCTAssertNil(coalescer.beginPendingRun())
    }
}
