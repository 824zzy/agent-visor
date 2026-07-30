import Foundation
import XCTest
@testable import AgentVisorCore

final class PiRestartReattachmentRegressionTests: XCTestCase {
    func testCapturedResumedSessionsRestoreThroughHeartbeatNotCreationTimeMatching() throws {
        let codes = "/Users/zhengyuanz/Codes"
        let digitalTwin = codes + "/ic-digital-twin"
        let processes = [
            PiProcessCandidate(id: "17818", cwd: digitalTwin, startedAt: try date("2026-07-27T16:41:02.000Z"), tty: "ttys009"),
            PiProcessCandidate(id: "4784", cwd: codes, startedAt: try date("2026-07-29T06:40:12.000Z"), tty: "ttys010"),
            PiProcessCandidate(id: "80290", cwd: codes, startedAt: try date("2026-07-29T06:17:43.000Z"), tty: "ttys011"),
            PiProcessCandidate(id: "61554", cwd: codes, startedAt: try date("2026-07-29T06:05:56.000Z"), tty: "ttys021"),
            PiProcessCandidate(id: "78443", cwd: codes, startedAt: try date("2026-07-29T06:16:51.000Z"), tty: "ttys022"),
        ]
        let sessions = [
            PiSessionCandidate(id: "019f48bc", cwd: digitalTwin, createdAt: try date("2026-07-09T21:15:59.391Z")),
            PiSessionCandidate(id: "019fa67d", cwd: codes, createdAt: try date("2026-07-28T02:11:11.233Z")),
            PiSessionCandidate(id: "019fa505", cwd: codes, createdAt: try date("2026-07-27T19:20:09.023Z")),
            PiSessionCandidate(id: "019faab0", cwd: codes, createdAt: try date("2026-07-28T21:45:36.283Z")),
            PiSessionCandidate(id: "019fa69e", cwd: codes, createdAt: try date("2026-07-28T02:46:41.749Z")),
        ]

        XCTAssertEqual(
            PiProcessSessionMatcher.match(
                processes: processes,
                sessions: sessions,
                tolerance: 5
            ),
            [],
            "Resumed/imported sessions must not be guessed from process start time."
        )

        let restoredIDs = zip(processes, sessions).compactMap { process, session in
            let disposition = PiSessionHeartbeatPolicy.disposition(
                agentID: .pi,
                lifecycleEvent: "SessionHeartbeat",
                hasExistingSession: true,
                existingSessionEnded: true,
                existingPid: nil,
                eventPid: Int(process.id),
                hasDifferentLiveSessionWithEventPid: false
            )
            return disposition == .reattachIdle ? session.id : nil
        }
        XCTAssertEqual(
            restoredIDs,
            ["019f48bc", "019fa67d", "019fa505", "019faab0", "019fa69e"]
        )

        let alreadyVisibleIDs = [
            "019faf9d", "019faaa0", "019f88a3", "019fa985",
            "019faee1", "019f3931", "019faf9c", "019faf21",
        ]
        let now = Date(timeIntervalSince1970: 10_000)
        let active = alreadyVisibleIDs.enumerated().map { index, id in
            PillSurfaceCandidate(
                id: id,
                phase: .working,
                sortDate: now.addingTimeInterval(TimeInterval(-index)),
                navigationDate: nil,
                isHidden: false,
                isTitleless: false
            )
        }
        let restored = restoredIDs.enumerated().map { index, id in
            PillSurfaceCandidate(
                id: id,
                phase: .idle,
                sortDate: now.addingTimeInterval(TimeInterval(-100 - index)),
                navigationDate: now.addingTimeInterval(TimeInterval(-100 - index)),
                isHidden: false,
                isTitleless: false
            )
        }

        let selection = PillSurfacePolicy.select(candidates: active + restored, now: now)
        XCTAssertEqual(selection.orderedVisibleIds.count, 13)
        XCTAssertEqual(Set(selection.orderedVisibleIds), Set(alreadyVisibleIDs + restoredIDs))
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }
}
