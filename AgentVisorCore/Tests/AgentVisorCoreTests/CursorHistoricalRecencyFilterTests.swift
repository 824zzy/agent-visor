import XCTest
@testable import AgentVisorCore

/// Pins the rule for which Cursor IDE Agents Window transcripts are
/// allowed into the agent-visor sidebar.
///
/// Bug context: ClaudeSessionMonitor was sorting all `~/.cursor/projects/
/// */agent-transcripts/*` by mtime and keeping the top 30 — no age cap.
/// A user with only a handful of historical Cursor transcripts saw a
/// 5-week-old "How do you know about chrome-devtools..." row stuck in
/// the live sidebar, with click going nowhere because the workspace
/// window was already frontmost (visual no-op of `app.activate()`).
///
/// The fix: drop transcripts older than `cutoff` BEFORE the count cap.
/// Pure logic; no I/O.
final class CursorHistoricalRecencyFilterTests: XCTestCase {

    private struct Hit: Equatable {
        let sessionId: String
        let mtime: TimeInterval
    }

    func testRetainsHitsNewerThanCutoff() {
        let now: TimeInterval = 1_000_000_000
        let cutoff: TimeInterval = 7 * 24 * 60 * 60
        let hits = [
            Hit(sessionId: "fresh", mtime: now - 3600),
            Hit(sessionId: "borderline-young", mtime: now - cutoff + 1),
        ]
        let kept = CursorHistoricalRecencyFilter.filter(
            hits: hits,
            now: now,
            maxAge: cutoff,
            mtime: { $0.mtime }
        )
        XCTAssertEqual(kept, hits)
    }

    func testDropsHitsOlderThanCutoff() {
        let now: TimeInterval = 1_000_000_000
        let cutoff: TimeInterval = 7 * 24 * 60 * 60
        let hits = [
            Hit(sessionId: "fresh", mtime: now - 60),
            Hit(sessionId: "stale", mtime: now - cutoff - 1),
            Hit(sessionId: "ancient", mtime: now - 100 * 24 * 60 * 60),
        ]
        let kept = CursorHistoricalRecencyFilter.filter(
            hits: hits,
            now: now,
            maxAge: cutoff,
            mtime: { $0.mtime }
        )
        XCTAssertEqual(kept.map(\.sessionId), ["fresh"])
    }

    func testCutoffBoundaryIsInclusive() {
        // A transcript whose age is EXACTLY at the cutoff stays. The
        // intent of "last 7 days" is "≤ 7 days old"; equality should
        // not be the difference between visible and hidden.
        let now: TimeInterval = 1_000_000_000
        let cutoff: TimeInterval = 7 * 24 * 60 * 60
        let hits = [
            Hit(sessionId: "exact", mtime: now - cutoff),
        ]
        let kept = CursorHistoricalRecencyFilter.filter(
            hits: hits,
            now: now,
            maxAge: cutoff,
            mtime: { $0.mtime }
        )
        XCTAssertEqual(kept, hits)
    }

    func testFutureMtimesAreKept() {
        // Clock-skew defense. A transcript stamped slightly in the future
        // (NTP drift, file copied from another machine) shouldn't get
        // dropped — that would silently hide the user's freshest data.
        let now: TimeInterval = 1_000_000_000
        let cutoff: TimeInterval = 7 * 24 * 60 * 60
        let hits = [
            Hit(sessionId: "future", mtime: now + 60),
        ]
        let kept = CursorHistoricalRecencyFilter.filter(
            hits: hits,
            now: now,
            maxAge: cutoff,
            mtime: { $0.mtime }
        )
        XCTAssertEqual(kept, hits)
    }

    func testEmptyInputReturnsEmpty() {
        let kept = CursorHistoricalRecencyFilter.filter(
            hits: [Hit](),
            now: 1_000_000_000,
            maxAge: 7 * 24 * 60 * 60,
            mtime: { $0.mtime }
        )
        XCTAssertTrue(kept.isEmpty)
    }

    func testPreservesInputOrder() {
        // The caller is responsible for sort order; the filter must
        // not reorder. `prefix(N)` after the filter relies on the
        // caller's mtime-desc ordering being preserved.
        let now: TimeInterval = 1_000_000_000
        let cutoff: TimeInterval = 7 * 24 * 60 * 60
        let hits = [
            Hit(sessionId: "second-newest", mtime: now - 3600),
            Hit(sessionId: "newest",        mtime: now - 60),
            Hit(sessionId: "third-newest",  mtime: now - 7200),
        ]
        let kept = CursorHistoricalRecencyFilter.filter(
            hits: hits,
            now: now,
            maxAge: cutoff,
            mtime: { $0.mtime }
        )
        XCTAssertEqual(kept.map(\.sessionId), ["second-newest", "newest", "third-newest"])
    }
}
