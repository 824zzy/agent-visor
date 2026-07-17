import XCTest
@testable import AgentVisorCore

final class CodexActiveThreadSelectorTests: XCTestCase {
    private func thread(
        _ id: String,
        updatedAt: Int,
        archived: Bool = false,
        source: String = "vscode",
        cwd: String? = nil,
        rolloutModifiedAt: Int? = nil,
        rolloutPath: String? = nil
    ) -> CodexThreadCandidate {
        CodexThreadCandidate(
            id: id,
            rolloutPath: rolloutPath ?? "/tmp/\(id).jsonl",
            cwd: cwd ?? "/tmp/\(id)",
            title: id,
            updatedAt: updatedAt,
            archived: archived,
            source: source,
            rolloutModifiedAt: rolloutModifiedAt
        )
    }

    // Visibility is governed by the recency window alone — NOT by whether
    // Codex.app is running. A recent GUI thread is surfaced even when the app
    // is closed (read-only; original-host navigation launches Codex.app).
    func testKeepsRecentThreadRegardlessOfAppState() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("a", updatedAt: now - 60, rolloutModifiedAt: now - 60)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testDropsThreadOlderThanWindow() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("stale", updatedAt: now - 1000, rolloutModifiedAt: now - 60)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testDropsNonArchivedGUIThreadWithoutRolloutFile() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("metadataOnly", updatedAt: now - 10, rolloutModifiedAt: nil)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testDropsArchivedAndSubagentThreads() {
        let now = 100_000
        let candidates = [
            thread("live", updatedAt: now - 10, rolloutModifiedAt: now - 10),
            thread("archived", updatedAt: now - 10, archived: true),
            thread("guardian", updatedAt: now - 10, source: "{\"subagent\":{\"other\":\"guardian\"}}"),
        ]
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: candidates,
            now: now,
            windowSeconds: 900
        )
        XCTAssertEqual(result.map(\.id), ["live"])
    }

    func testBoundaryInclusiveAtCutoff() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("edge", updatedAt: now - 900, rolloutModifiedAt: now - 60)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertEqual(result.map(\.id), ["edge"])
    }

    // Only interactive GUI ("vscode") threads belong in the observed-GUI
    // set — those are what show in Codex.app's sidebar. Programmatic
    // `exec` runs and terminal `cli` sessions are dropped here (cli is
    // surfaced separately by the process/tty discovery path).
    func testKeepsOnlyInteractiveGUISource() {
        let now = 100_000
        let candidates = [
            thread("gui", updatedAt: now - 10, source: "vscode", rolloutModifiedAt: now - 10),
            thread("cli", updatedAt: now - 10, source: "cli", rolloutModifiedAt: now - 10),
            thread("exec", updatedAt: now - 10, source: "exec", rolloutModifiedAt: now - 10),
        ]
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: candidates,
            now: now,
            windowSeconds: 900
        )
        XCTAssertEqual(result.map(\.id), ["gui"])
    }

    func testDropsObserverSessionCwds() {
        let now = 100_000
        let candidates = [
            thread("visible", updatedAt: now - 10, cwd: "/Users/me/project", rolloutModifiedAt: now - 10),
            thread("claudeMem", updatedAt: now - 10, cwd: "/Users/me/.claude-mem/observer-sessions", rolloutModifiedAt: now - 10),
            thread("observer", updatedAt: now - 10, cwd: "/Users/me/observer-sessions", rolloutModifiedAt: now - 10),
        ]
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: candidates,
            now: now,
            windowSeconds: 900
        )
        XCTAssertEqual(result.map(\.id), ["visible"])
    }

    // MARK: - Running-archived GUI threads
    //
    // Codex flips background-research GUI threads to archived=1 the instant
    // they start, yet keeps appending turns to their rollout JSONL. Such a
    // thread is still running, so it should be surfaced — but ONLY while its
    // rollout is freshly written, since archived=1 also marks the dozens of
    // genuinely-closed threads.

    func testIncludesArchivedGUIThreadWithFreshRollout() {
        let now = 100_000
        // updatedAt is old (sqlite stopped bumping when it archived), but the
        // rollout was written 60s ago — within the running window.
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("running", updatedAt: now - 9999, archived: true, rolloutModifiedAt: now - 60)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertEqual(result.map(\.id), ["running"])
    }

    func testExplicitlyArchivedGUIThreadIsExcludedEvenWithFreshRollout() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread(
                "closed",
                updatedAt: now - 1,
                archived: true,
                rolloutModifiedAt: now - 1,
                rolloutPath: "/Users/me/.codex/archived_sessions/rollout-closed.jsonl"
            )],
            now: now,
            windowSeconds: 900
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testExcludesArchivedGUIThreadWithStaleRollout() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("closed", updatedAt: now - 10, archived: true, rolloutModifiedAt: now - 180)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testExcludesArchivedGUIThreadWithNilRollout() {
        let now = 100_000
        // No rollout mtime → can't confirm it's running → exclude (conservative).
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("unknown", updatedAt: now - 10, archived: true, rolloutModifiedAt: nil)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testExcludesArchivedExecThreadEvenWithFreshRollout() {
        let now = 100_000
        // Source gate still applies: a fresh-rollout archived `exec` run is
        // automation noise, not a GUI conversation.
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("exec", updatedAt: now - 10, archived: true, source: "exec", rolloutModifiedAt: now - 30)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testExcludesArchivedSubagentThreadEvenWithFreshRollout() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("guardian", updatedAt: now - 10, archived: true, source: "{\"subagent\":{\"other\":\"guardian\"}}", rolloutModifiedAt: now - 30)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testExcludesArchivedGUIThreadInObserverCwdEvenWithFreshRollout() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("obs", updatedAt: now - 10, archived: true, cwd: "/Users/me/observer-sessions", rolloutModifiedAt: now - 30)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testArchivedRolloutBoundaryAtExactWindowIncluded() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("edge", updatedAt: now - 10, archived: true, rolloutModifiedAt: now - CodexActiveThreadSelector.runningArchivedWindowSeconds)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertEqual(result.map(\.id), ["edge"])
    }

    func testArchivedRolloutBoundaryOneSecondStaleExcluded() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("past", updatedAt: now - 10, archived: true, rolloutModifiedAt: now - CodexActiveThreadSelector.runningArchivedWindowSeconds - 1)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testArchivedRolloutInFutureExcluded() {
        let now = 100_000
        // Clock skew / future mtime → negative age → don't trust it.
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("future", updatedAt: now - 10, archived: true, rolloutModifiedAt: now + 60)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }

    // A non-archived thread's fresh rollout doesn't rescue it past the
    // recency window — the running-archived path is archived-only; the
    // non-archived branch is governed by `updatedAt` as before.
    func testNonArchivedStaleThreadNotRescuedByFreshRollout() {
        let now = 100_000
        let result = CodexActiveThreadSelector.activeThreads(
            candidates: [thread("stale", updatedAt: now - 1000, archived: false, rolloutModifiedAt: now - 5)],
            now: now,
            windowSeconds: 900
        )
        XCTAssertTrue(result.isEmpty)
    }
}
