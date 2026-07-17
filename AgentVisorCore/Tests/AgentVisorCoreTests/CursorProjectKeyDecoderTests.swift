import XCTest
@testable import AgentVisorCore

/// Pins the rule for converting a Cursor project-key directory name
/// (under `~/.cursor/projects/<key>/`) back into the absolute CWD it
/// was generated from.
///
/// Bug context: clicking a Cursor IDE Agents Window session ran
/// `open -a Cursor /Users/example/claude` for a session that was
/// actually launched from `/Users/example/.claude`. The encoding
/// `CursorProjectKeyEncoder.projectKey` strips leading dots ("hidden
/// directory" segments collide in the key form), so a naive
/// `"/" + key.replacingOccurrences("-", "/")` decoder lost the dot.
/// LaunchServices then exited 1 ("file does not exist") and the click
/// silently no-op'd.
///
/// Fix: try the naive decoded path first, then if it doesn't exist,
/// probe each path segment with a leading dot and pick whichever
/// candidate exists on disk. We inject the existence predicate so
/// the tests run without touching the real filesystem.
final class CursorProjectKeyDecoderTests: XCTestCase {

    // MARK: - Happy path

    func testDecodesSimpleVisibleDirectory() {
        let cwd = CursorProjectKeyDecoder.decode(
            projectKey: "Users-example-Codes",
            directoryExists: { ["/Users/example/Codes": true][$0] ?? false }
        )
        XCTAssertEqual(cwd, "/Users/example/Codes")
    }

    func testDecodesNestedVisibleDirectory() {
        let cwd = CursorProjectKeyDecoder.decode(
            projectKey: "Users-example-Personal-agent-visor",
            directoryExists: { ["/Users/example/Personal/agent-visor": true][$0] ?? false }
        )
        XCTAssertEqual(cwd, "/Users/example/Personal/agent-visor")
    }

    // MARK: - Hidden-directory recovery

    func testRecoversLeadingDotWhenNaiveDoesNotExist() {
        // /Users/example/claude does NOT exist; /Users/example/.claude does.
        // The decoder must probe with a leading dot at each segment and find
        // the one that resolves on disk.
        let exists: [String: Bool] = [
            "/Users/example/.claude": true,
        ]
        let cwd = CursorProjectKeyDecoder.decode(
            projectKey: "Users-example-claude",
            directoryExists: { exists[$0] ?? false }
        )
        XCTAssertEqual(cwd, "/Users/example/.claude")
    }

    func testRecoversDotInDeeperSegment() {
        // /Users/foo/Library/Application Support/cursor — Cursor would key
        // this as "Users-foo-Library-Application Support-cursor" but that's
        // a different test. Here we test a dot-prefixed mid-segment:
        //   /Users/foo/.config/agent
        let exists: [String: Bool] = [
            "/Users/foo/.config/agent": true,
        ]
        let cwd = CursorProjectKeyDecoder.decode(
            projectKey: "Users-foo-config-agent",
            directoryExists: { exists[$0] ?? false }
        )
        XCTAssertEqual(cwd, "/Users/foo/.config/agent")
    }

    // MARK: - Empty / edge

    func testEmptyKeyReturnsRoot() {
        let cwd = CursorProjectKeyDecoder.decode(
            projectKey: "empty-window",
            directoryExists: { _ in true }
        )
        // The "empty-window" sentinel was written by the encoder for "/" or
        // "" cwd. We can't recover the original; "/" is the safest default
        // and is always a valid directory.
        XCTAssertEqual(cwd, "/")
    }

    func testNoMatchFallsBackToNaiveDecode() {
        // Neither candidate exists. Return the naive decode so the
        // existing chat-history-loading path stays functional even if
        // navigation can't open the workspace.
        let cwd = CursorProjectKeyDecoder.decode(
            projectKey: "Users-foo-bar",
            directoryExists: { _ in false }
        )
        XCTAssertEqual(cwd, "/Users/foo/bar")
    }

    // MARK: - Hyphen preservation (Cursor encodes "/" → "-", so a literal
    //          hyphen in the cwd is indistinguishable from a separator.
    //          The ambiguous candidates are enumerated; we pick the first
    //          one that exists.)

    func testPicksHyphenPreservingCandidateWhenItExists() {
        // /Users/foo/my-project (literal hyphen, no further nesting) and
        // /Users/foo/my/project (separator). Cursor encodes both as
        // "Users-foo-my-project". If the literal-hyphen path exists and
        // the separator one doesn't, the decoder must pick the literal.
        let exists: [String: Bool] = [
            "/Users/foo/my-project": true,
        ]
        let cwd = CursorProjectKeyDecoder.decode(
            projectKey: "Users-foo-my-project",
            directoryExists: { exists[$0] ?? false }
        )
        XCTAssertEqual(cwd, "/Users/foo/my-project")
    }

    // MARK: - Combination: dot + hyphen

    func testRecoversDotInPresenceOfHyphenAmbiguity() {
        // /Users/foo/.local/share — leading dot AND a hyphen-encoded
        // separator deeper in.
        let exists: [String: Bool] = [
            "/Users/foo/.local/share": true,
        ]
        let cwd = CursorProjectKeyDecoder.decode(
            projectKey: "Users-foo-local-share",
            directoryExists: { exists[$0] ?? false }
        )
        XCTAssertEqual(cwd, "/Users/foo/.local/share")
    }
}
