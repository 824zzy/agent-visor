import XCTest
@testable import AgentVisorCore

final class HistorySliceFingerprintTests: XCTestCase {
    func testInitialIsDistinctFromEmpty() {
        XCTAssertNotEqual(
            HistorySliceFingerprint.initial,
            HistorySliceFingerprint.from(itemCount: 0, lastId: nil)
        )
        // Initial uses count=-1 so the first emission with count>=0
        // is always a change — even on truly empty histories.
        XCTAssertEqual(HistorySliceFingerprint.initial.count, -1)
    }

    func testEmptyIsSelfStable() {
        let a = HistorySliceFingerprint.from(itemCount: 0, lastId: nil)
        let b = HistorySliceFingerprint.from(itemCount: 0, lastId: nil)
        XCTAssertEqual(a, b)
    }

    func testCountChangeFlips() {
        let a = HistorySliceFingerprint.from(itemCount: 5, lastId: "x")
        let b = HistorySliceFingerprint.from(itemCount: 6, lastId: "x")
        XCTAssertNotEqual(a, b)
    }

    func testTailChangeFlipsEvenAtSameCount() {
        // Rebase / clear-and-replace: same item count but the last id
        // changed. The fingerprint MUST flip so the view re-renders.
        let a = HistorySliceFingerprint.from(itemCount: 5, lastId: "x")
        let b = HistorySliceFingerprint.from(itemCount: 5, lastId: "y")
        XCTAssertNotEqual(a, b)
    }

    func testNilTailEqualsEmptyTail() {
        XCTAssertEqual(
            HistorySliceFingerprint.from(itemCount: 0, lastId: nil),
            HistorySliceFingerprint.from(itemCount: 0, lastId: "")
        )
    }

    func testRoundTripThroughInit() {
        let direct = HistorySliceFingerprint(count: 3, lastId: "abc")
        let viaFrom = HistorySliceFingerprint.from(itemCount: 3, lastId: "abc")
        XCTAssertEqual(direct, viaFrom)
    }
}
