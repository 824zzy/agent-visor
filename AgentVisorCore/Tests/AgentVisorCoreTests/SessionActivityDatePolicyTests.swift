import XCTest
@testable import AgentVisorCore

final class SessionActivityDatePolicyTests: XCTestCase {
    func testKeepsCurrentDateWhenTranscriptDatesAreMissing() {
        let current = Date(timeIntervalSince1970: 100)

        let merged = SessionActivityDatePolicy.merged(
            current: current,
            candidates: [nil, nil]
        )

        XCTAssertEqual(merged, current)
    }

    func testKeepsCurrentDateWhenTranscriptDatesAreOlder() {
        let current = Date(timeIntervalSince1970: 100)
        let older = Date(timeIntervalSince1970: 90)

        let merged = SessionActivityDatePolicy.merged(
            current: current,
            candidates: [older]
        )

        XCTAssertEqual(merged, current)
    }

    func testAdvancesToNewestTranscriptDate() {
        let current = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 120)
        let newest = Date(timeIntervalSince1970: 130)

        let merged = SessionActivityDatePolicy.merged(
            current: current,
            candidates: [newer, newest]
        )

        XCTAssertEqual(merged, newest)
    }
}
