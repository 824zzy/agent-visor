import XCTest
@testable import AgentVisorCore

final class RelativeTimestampFormatterTests: XCTestCase {

    // MARK: - Below floor

    func testReturnsNilForJustNow() {
        XCTAssertNil(RelativeTimestampFormatter.format(elapsed: 0))
    }

    func testReturnsNilFor30Seconds() {
        XCTAssertNil(RelativeTimestampFormatter.format(elapsed: 30))
    }

    func testReturnsNilForNegativeInterval() {
        // Clock skew or forward-dated JSONL line; treat as below floor.
        XCTAssertNil(RelativeTimestampFormatter.format(elapsed: -300))
    }

    // MARK: - Minutes

    func testOneMinute() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 60), "1m")
    }

    func testFiveMinutes() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 5 * 60), "5m")
    }

    func testFiftyNineMinutes() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 59 * 60), "59m")
    }

    // MARK: - Hours

    func testOneHour() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 60 * 60), "1h")
    }

    func testTwentyThreeHours() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 23 * 3600), "23h")
    }

    // MARK: - Days

    func testOneDay() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 24 * 3600), "1d")
    }

    func testSixDays() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 6 * 24 * 3600), "6d")
    }

    // MARK: - Weeks

    func testOneWeek() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 7 * 24 * 3600), "1w")
    }

    func testFourWeeks() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 28 * 24 * 3600), "4w")
    }

    // MARK: - Months

    func testOneMonth() {
        // 35 days → 5 weeks → bucket flips to months.
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 35 * 24 * 3600), "1mo")
    }

    func testElevenMonths() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 330 * 24 * 3600), "11mo")
    }

    // MARK: - Years

    func testOneYear() {
        XCTAssertEqual(RelativeTimestampFormatter.format(elapsed: 365 * 24 * 3600), "1y")
    }

    // MARK: - Date convenience

    func testFormatSinceDate() {
        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        XCTAssertEqual(
            RelativeTimestampFormatter.format(since: twoHoursAgo, now: now),
            "2h"
        )
    }

    func testFormatSinceFutureDate() {
        let now = Date()
        let inFiveMinutes = now.addingTimeInterval(5 * 60)
        XCTAssertNil(RelativeTimestampFormatter.format(since: inFiveMinutes, now: now))
    }
}
