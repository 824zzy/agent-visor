import XCTest
@testable import AgentVisorCore

/// Pins the rule for picking which workspace folder to hand to
/// LaunchServices when a sidebar pill is clicked for a Cursor- or
/// claude-code-in-Cursor session.
///
/// Bug context: clicking a Cursor IDE Agents Window session
/// (`agentID == .cursor`) routed through `findIDEWorkspaceFolder`,
/// which reads `~/.claude/ide/*.lock` — but those lock files are
/// written by the claude-code Cursor extension only. IDE Agents
/// Window sessions have no lock, so resolution returned nil and the
/// click fell through to AppleScript title-matching, which lands on
/// the wrong window when the user's current Cursor workspace is
/// different from the session's cwd. Fix: for `agentID == .cursor`,
/// use `sessionCwd` directly and skip the lock-file lookup.
final class CursorWorkspaceResolverTests: XCTestCase {

    // MARK: - Cursor agent (skip locks)

    func testCursorAgentReturnsSessionCwdWithEmptyLocks() {
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/agent-visor",
            agentID: .cursor,
            candidateFolders: []
        )
        XCTAssertEqual(folder, "/Users/me/Projects/agent-visor")
    }

    func testCursorAgentIgnoresAvailableLocks() {
        // Even if a claude-code lock happens to be present in the same
        // workspace, a cursor-agent session must not route through it.
        // Skipping the lock-file lookup keeps the cursor-agent path
        // independent of whether the claude-code extension is installed.
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/agent-visor/sub",
            agentID: .cursor,
            candidateFolders: ["/Users/me/Projects/agent-visor"]
        )
        XCTAssertEqual(folder, "/Users/me/Projects/agent-visor/sub")
    }

    // MARK: - claude-code agent (longest-prefix lock match)

    func testClaudeCodeReturnsExactMatch() {
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/foo",
            agentID: .claudeCode,
            candidateFolders: ["/Users/me/Projects/foo"]
        )
        XCTAssertEqual(folder, "/Users/me/Projects/foo")
    }

    func testClaudeCodeReturnsPrefixMatch() {
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/foo/src/parser",
            agentID: .claudeCode,
            candidateFolders: ["/Users/me/Projects/foo"]
        )
        XCTAssertEqual(folder, "/Users/me/Projects/foo")
    }

    func testClaudeCodeReturnsLongestPrefix() {
        // Two lock files exposing nested workspace folders; the deeper
        // one wins so the request lands on the most specific extension
        // host that owns the session.
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/foo/sub/leaf",
            agentID: .claudeCode,
            candidateFolders: [
                "/Users/me/Projects/foo",
                "/Users/me/Projects/foo/sub",
            ]
        )
        XCTAssertEqual(folder, "/Users/me/Projects/foo/sub")
    }

    func testClaudeCodeReturnsNilOnNoMatch() {
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/foo",
            agentID: .claudeCode,
            candidateFolders: ["/Users/me/Projects/bar"]
        )
        XCTAssertNil(folder)
    }

    func testClaudeCodeReturnsNilOnEmptyCandidates() {
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/foo",
            agentID: .claudeCode,
            candidateFolders: []
        )
        XCTAssertNil(folder)
    }

    func testClaudeCodeRespectsPathBoundary() {
        // `/Users/me/Projects/foobar` must NOT match folder
        // `/Users/me/Projects/foo` — without the path-separator guard,
        // a string-prefix check would incorrectly route the session to
        // an unrelated workspace.
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/foobar",
            agentID: .claudeCode,
            candidateFolders: ["/Users/me/Projects/foo"]
        )
        XCTAssertNil(folder)
    }

    // MARK: - Other agents (defensive)

    func testCodexAgentReturnsNil() {
        // codex sessions have a tty and don't reach EditorAdapter in
        // practice, but if one ever did, returning nil keeps the
        // caller on its existing AppleScript fallback path.
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/foo",
            agentID: .codex,
            candidateFolders: []
        )
        XCTAssertNil(folder)
    }

    func testAuggieAgentReturnsNil() {
        let folder = CursorWorkspaceResolver.resolveWorkspaceFolder(
            sessionCwd: "/Users/me/Projects/foo",
            agentID: .auggie,
            candidateFolders: ["/Users/me/Projects/foo"]
        )
        XCTAssertNil(folder)
    }
}
