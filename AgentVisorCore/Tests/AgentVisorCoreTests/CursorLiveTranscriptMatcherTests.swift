import XCTest
@testable import AgentVisorCore

final class CursorLiveTranscriptMatcherTests: XCTestCase {
    func testProcessesInSameProjectConsumeDistinctTranscripts() {
        let matches = CursorLiveTranscriptMatcher.match(
            processes: [
                .init(id: "p1", cwd: "/Users/me/project"),
                .init(id: "p2", cwd: "/Users/me/project"),
            ],
            transcripts: [
                .init(sessionId: "newest", projectKey: "Users-me-project", mtime: 200),
                .init(sessionId: "older", projectKey: "Users-me-project", mtime: 100),
            ]
        )

        XCTAssertEqual(matches.map(\.transcript.sessionId), ["newest", "older"])
    }

    func testSingleTranscriptIsNotReusedForMultipleProcesses() {
        let matches = CursorLiveTranscriptMatcher.match(
            processes: [
                .init(id: "p1", cwd: "/Users/me/project"),
                .init(id: "p2", cwd: "/Users/me/project"),
            ],
            transcripts: [
                .init(sessionId: "only", projectKey: "Users-me-project", mtime: 200),
            ]
        )

        XCTAssertEqual(matches.map(\.transcript.sessionId), ["only"])
    }

    func testSkipsProcessesWithoutMatchingProjectTranscript() {
        let matches = CursorLiveTranscriptMatcher.match(
            processes: [
                .init(id: "p1", cwd: "/Users/me/project"),
                .init(id: "p2", cwd: "/Users/me/other"),
            ],
            transcripts: [
                .init(sessionId: "only", projectKey: "Users-me-project", mtime: 200),
            ]
        )

        XCTAssertEqual(matches.map(\.process.id), ["p1"])
        XCTAssertEqual(matches.map(\.transcript.sessionId), ["only"])
    }
}
