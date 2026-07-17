import XCTest
@testable import AgentVisorCore

final class CodexLiveThreadMatcherTests: XCTestCase {
    func testMatchesRunningCodexProcessToNewestNonArchivedThreadWithSameCwd() {
        let process = CodexProcessCandidate(pid: 42, tty: "ttys020", cwd: "/repo")
        let old = CodexThreadCandidate(
            id: "old",
            rolloutPath: "/old.jsonl",
            cwd: "/repo",
            title: "Old",
            updatedAt: 100,
            archived: false,
            source: "cli"
        )
        let newest = CodexThreadCandidate(
            id: "new",
            rolloutPath: "/new.jsonl",
            cwd: "/repo",
            title: "New",
            updatedAt: 200,
            archived: false,
            source: "cli"
        )
        let archived = CodexThreadCandidate(
            id: "archived",
            rolloutPath: "/archived.jsonl",
            cwd: "/repo",
            title: "Archived",
            updatedAt: 300,
            archived: true,
            source: "cli"
        )

        let matches = CodexLiveThreadMatcher.matchLiveThreads(
            processes: [process],
            threads: [old, newest, archived]
        )

        XCTAssertEqual(matches, [
            CodexLiveThreadMatch(
                thread: newest,
                process: process
            )
        ])
    }

    func testSkipsProcessWhenMultipleEquallyRecentThreadsMatchSameCwd() {
        let process = CodexProcessCandidate(pid: 42, tty: "ttys020", cwd: "/repo")
        let a = CodexThreadCandidate(id: "a", rolloutPath: "/a.jsonl", cwd: "/repo", title: "A", updatedAt: 200, archived: false, source: "cli")
        let b = CodexThreadCandidate(id: "b", rolloutPath: "/b.jsonl", cwd: "/repo", title: "B", updatedAt: 200, archived: false, source: "cli")

        let matches = CodexLiveThreadMatcher.matchLiveThreads(
            processes: [process],
            threads: [a, b]
        )

        XCTAssertEqual(matches, [])
    }

    func testSkipsExecThreadsWhenMatchingLiveTerminalProcess() {
        let process = CodexProcessCandidate(pid: 42, tty: "ttys020", cwd: "/repo")
        let exec = CodexThreadCandidate(
            id: "orko",
            rolloutPath: "/orko.jsonl",
            cwd: "/repo",
            title: "You are orko, a technical assistant",
            updatedAt: 300,
            archived: false,
            source: "exec"
        )
        let cli = CodexThreadCandidate(
            id: "cli",
            rolloutPath: "/cli.jsonl",
            cwd: "/repo",
            title: "Interactive terminal",
            updatedAt: 200,
            archived: false,
            source: "cli"
        )

        let matches = CodexLiveThreadMatcher.matchLiveThreads(
            processes: [process],
            threads: [exec, cli]
        )

        XCTAssertEqual(matches, [
            CodexLiveThreadMatch(
                thread: cli,
                process: process
            )
        ])
    }

    func testSkipsProcessWhenSameCwdHasNoCliThread() {
        let process = CodexProcessCandidate(pid: 42, tty: "ttys020", cwd: "/repo")
        let exec = CodexThreadCandidate(id: "exec", rolloutPath: "/exec.jsonl", cwd: "/repo", title: "Exec", updatedAt: 300, archived: false, source: "exec")
        let gui = CodexThreadCandidate(id: "gui", rolloutPath: "/gui.jsonl", cwd: "/repo", title: "GUI", updatedAt: 200, archived: false, source: "vscode")

        let matches = CodexLiveThreadMatcher.matchLiveThreads(
            processes: [process],
            threads: [exec, gui]
        )

        XCTAssertEqual(matches, [])
    }

    func testSkipsExplicitlyArchivedCliThreadDuringMetadataTransition() {
        let process = CodexProcessCandidate(pid: 42, tty: "ttys020", cwd: "/repo")
        let archived = CodexThreadCandidate(
            id: "archived",
            rolloutPath: "/Users/me/.codex/archived_sessions/rollout-cli.jsonl",
            cwd: "/repo",
            title: "Archived",
            updatedAt: 300,
            archived: false,
            source: "cli"
        )

        let matches = CodexLiveThreadMatcher.matchLiveThreads(
            processes: [process],
            threads: [archived]
        )

        XCTAssertTrue(matches.isEmpty)
    }
}
