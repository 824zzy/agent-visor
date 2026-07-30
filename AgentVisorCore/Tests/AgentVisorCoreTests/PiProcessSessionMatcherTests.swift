import XCTest
@testable import AgentVisorCore

final class PiProcessSessionMatcherTests: XCTestCase {
    func testMatchesEachProcessToClosestSessionWithSameWorkingDirectory() {
        let processes = [
            PiProcessCandidate(id: "p1", cwd: "/repo", startedAt: Date(timeIntervalSince1970: 100), tty: "ttys001"),
            PiProcessCandidate(id: "p2", cwd: "/repo", startedAt: Date(timeIntervalSince1970: 200), tty: "ttys002"),
            PiProcessCandidate(id: "other", cwd: "/other", startedAt: Date(timeIntervalSince1970: 100), tty: "ttys003"),
        ]
        let sessions = [
            PiSessionCandidate(id: "stale", cwd: "/repo", createdAt: Date(timeIntervalSince1970: 20)),
            PiSessionCandidate(id: "s2", cwd: "/repo/./", createdAt: Date(timeIntervalSince1970: 201)),
            PiSessionCandidate(id: "s1", cwd: "/repo", createdAt: Date(timeIntervalSince1970: 101)),
            PiSessionCandidate(id: "wrong-cwd", cwd: "/different", createdAt: Date(timeIntervalSince1970: 100)),
        ]

        let matches = PiProcessSessionMatcher.match(
            processes: processes,
            sessions: sessions,
            tolerance: 3
        )

        XCTAssertEqual(matches, [
            PiProcessSessionMatch(process: processes[0], session: sessions[2]),
            PiProcessSessionMatch(process: processes[1], session: sessions[1]),
        ])
    }
}
