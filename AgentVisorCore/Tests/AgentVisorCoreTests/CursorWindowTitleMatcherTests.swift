import XCTest
@testable import AgentVisorCore

/// Pins the rule for deciding whether a Cursor IDE Agents Window pill
/// click should fall through to LaunchServices (`open -a Cursor <cwd>`).
///
/// Bug context: clicking a Cursor session whose workspace wasn't
/// currently open in Cursor surprised the user with a fresh new
/// window. `open -a` is "open document" — Cursor's handler dutifully
/// creates a window when none matches, but the user expects "focus
/// the existing one or do nothing." This matcher decides whether
/// any of Cursor's open AX-window titles plausibly hosts the
/// requested workspace; the click handler only invokes
/// LaunchServices when this returns true.
///
/// Match heuristic: the workspace folder's last path component must
/// appear as a comma-separated, em-dash-separated, or substring
/// segment of any Cursor window title. Cursor titles look like
///   "<file> — <workspace folder>"
///   "<workspace folder>"
///   "<file1>, <file2> — <workspace folder>"
///   "<workspace folder>, <peer workspace>"  // multi-root window
final class CursorWindowTitleMatcherTests: XCTestCase {

    // MARK: - Existing workspace window

    func testEmDashSeparatedMatch() {
        XCTAssertTrue(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/Codes",
            cursorWindowTitles: ["main.swift — Codes"]
        ))
    }

    func testWorkspaceOnlyTitle() {
        XCTAssertTrue(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/.claude",
            cursorWindowTitles: [".claude"]
        ))
    }

    func testCommaSeparatedMultiRootMatch() {
        // Multi-root workspace: title lists peers separated by commas.
        XCTAssertTrue(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/.claude",
            cursorWindowTitles: ["issue-tracker.md — Codes, .claude"]
        ))
    }

    func testFileListBeforeEmDashMatch() {
        // "<file1>, <file2> — <workspace>"
        XCTAssertTrue(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/.claude",
            cursorWindowTitles: ["foo.md, bar.md — .claude"]
        ))
    }

    func testMatchesAcrossMultipleWindows() {
        XCTAssertTrue(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/Personal/agent-visor",
            cursorWindowTitles: [
                "issue-tracker.md — Codes",
                "ChatView.swift — agent-visor",
            ]
        ))
    }

    // MARK: - No matching window

    func testNoMatchAcrossUnrelatedWorkspaces() {
        XCTAssertFalse(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/Personal/agent-visor",
            cursorWindowTitles: [
                "issue-tracker.md — Codes",
                ".claude",
            ]
        ))
    }

    func testEmptyTitlesNoMatch() {
        XCTAssertFalse(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/Codes",
            cursorWindowTitles: []
        ))
    }

    func testCursorPlaceholderTitleNoMatch() {
        // Cursor briefly shows just "Cursor" as the title during launch
        // animation. That should NEVER count as a workspace match.
        XCTAssertFalse(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/Codes",
            cursorWindowTitles: ["Cursor"]
        ))
    }

    // MARK: - Boundary discipline

    func testSubstringDoesNotFalseMatch() {
        // "claude" must not match "agent-visor". Token boundaries are
        // ", " and " — " in Cursor titles; a bare-substring check would
        // false-positive here.
        XCTAssertFalse(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/.claude",
            cursorWindowTitles: ["main.swift — agent-visor"]
        ))
    }

    func testCaseInsensitiveMatch() {
        XCTAssertTrue(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/Users/me/Codes",
            cursorWindowTitles: ["main.swift — codes"]
        ))
    }

    // MARK: - Empty workspace folder

    func testEmptyWorkspaceFolderNeverMatches() {
        XCTAssertFalse(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "",
            cursorWindowTitles: ["whatever"]
        ))
    }

    func testRootWorkspaceNeverMatches() {
        // "/" → empty last component; can't sensibly match anything.
        XCTAssertFalse(CursorWindowTitleMatcher.hasMatchingWindow(
            workspaceFolder: "/",
            cursorWindowTitles: ["whatever"]
        ))
    }
}
