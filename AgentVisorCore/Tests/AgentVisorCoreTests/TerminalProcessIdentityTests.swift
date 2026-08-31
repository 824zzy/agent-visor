import XCTest
@testable import AgentVisorCore

final class TerminalProcessIdentityTests: XCTestCase {
    private let expected = TerminalProcessIdentity(
        pid: 42,
        processStartToken: "v1:42:start-a",
        tty: "/dev/ttys012"
    )

    func testExactPidTokenAndTTYAreRequired() {
        XCTAssertTrue(TerminalProcessIdentityPolicy.matches(expected: expected, live: expected))
        XCTAssertFalse(TerminalProcessIdentityPolicy.matches(
            expected: expected,
            live: TerminalProcessIdentity(pid: 43, processStartToken: expected.processStartToken, tty: expected.tty)
        ))
        XCTAssertFalse(TerminalProcessIdentityPolicy.matches(
            expected: expected,
            live: TerminalProcessIdentity(pid: expected.pid, processStartToken: "v1:42:start-b", tty: expected.tty)
        ))
        XCTAssertFalse(TerminalProcessIdentityPolicy.matches(
            expected: expected,
            live: TerminalProcessIdentity(pid: expected.pid, processStartToken: expected.processStartToken, tty: "ttys013")
        ))
    }

    func testMissingIdentityFailsClosed() {
        XCTAssertFalse(TerminalProcessIdentityPolicy.matches(expected: nil, live: expected))
        XCTAssertFalse(TerminalProcessIdentityPolicy.matches(expected: expected, live: nil))
    }

    func testTokenBindsPidAndStartTime() {
        let start = Date(timeIntervalSince1970: 1_787_385_540.123)
        let token = TerminalProcessIdentityToken.make(pid: 42, startTime: start)
        XCTAssertTrue(token.hasPrefix("v1:42:1787385540123:"))
        XCTAssertNotEqual(
            token,
            TerminalProcessIdentityToken.make(pid: 42, startTime: start.addingTimeInterval(1))
        )
    }

    func testProcessProbeParserAcceptsValidFixtureFields() {
        XCTAssertEqual(TerminalProcessProbeParser.pid(from: "  42\n"), 42)
        XCTAssertEqual(TerminalProcessProbeParser.tty(from: " /dev/ttys012\n"), "ttys012")
        XCTAssertEqual(TerminalProcessProbeParser.tty(from: "ttys013"), "ttys013")
        XCTAssertNotNil(
            TerminalProcessProbeParser.startDate(from: "Sat Aug 22 08:00:00 2026")
        )
    }

    func testProcessProbeParserRejectsMissingAndMalformedFixtures() {
        XCTAssertNil(TerminalProcessProbeParser.pid(from: ""))
        XCTAssertNil(TerminalProcessProbeParser.pid(from: "not-a-pid"))
        XCTAssertNil(TerminalProcessProbeParser.tty(from: "?"))
        XCTAssertNil(TerminalProcessProbeParser.tty(from: "??"))
        XCTAssertNil(TerminalProcessProbeParser.tty(from: "-"))
        XCTAssertNil(TerminalProcessProbeParser.startDate(from: "not a ps date"))
    }

    func testSamePidWithDifferentStartFixtureCannotMatch() {
        let expectedStart = TerminalProcessProbeParser.startDate(
            from: "Sat Aug 22 08:00:00 2026"
        )!
        let liveStart = TerminalProcessProbeParser.startDate(
            from: "Sat Aug 22 08:00:01 2026"
        )!
        XCTAssertFalse(TerminalProcessIdentityPolicy.matches(
            expected: TerminalProcessIdentity(
                pid: 42,
                processStartToken: TerminalProcessIdentityToken.make(
                    pid: 42,
                    startTime: expectedStart
                ),
                tty: "ttys012"
            ),
            live: TerminalProcessIdentity(
                pid: 42,
                processStartToken: TerminalProcessIdentityToken.make(
                    pid: 42,
                    startTime: liveStart
                ),
                tty: "ttys012"
            )
        ))
    }
}
