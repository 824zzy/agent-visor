import XCTest
@testable import AgentVisorCore

final class CursorProjectKeyEncoderTests: XCTestCase {
    /// Cursor encodes a CWD as the path with `/` replaced by `-`, leading
    /// `-` stripped. `/Users/example/Codes` → `Users-example-Codes`.
    /// Empty / root paths get `empty-window`.
    ///
    /// Verified empirically against `~/.cursor/projects/` directory names:
    /// - `/Users/example/Codes` → `Users-example-Codes`
    /// - `/Users/example/claude` → `Users-example-claude`
    /// - `/` → `empty-window`
    func testStandardCwdEncodesWithDashes() {
        XCTAssertEqual(
            CursorProjectKeyEncoder.projectKey(forCwd: "/Users/example/Codes"),
            "Users-example-Codes"
        )
    }

    func testNestedPathEncodes() {
        XCTAssertEqual(
            CursorProjectKeyEncoder.projectKey(forCwd: "/Users/example/Personal/agent-visor"),
            "Users-example-Personal-agent-visor"
        )
    }

    func testRootPathYieldsEmptyWindow() {
        XCTAssertEqual(CursorProjectKeyEncoder.projectKey(forCwd: "/"), "empty-window")
    }

    func testEmptyStringYieldsEmptyWindow() {
        XCTAssertEqual(CursorProjectKeyEncoder.projectKey(forCwd: ""), "empty-window")
    }

    func testTrailingSlashIsTrimmed() {
        XCTAssertEqual(
            CursorProjectKeyEncoder.projectKey(forCwd: "/Users/example/Codes/"),
            "Users-example-Codes"
        )
    }

    func testRelativePathStillEncodes() {
        // No leading slash is a degenerate case but should still produce
        // a sensible key without crashing. Treat as the components verbatim.
        XCTAssertEqual(
            CursorProjectKeyEncoder.projectKey(forCwd: "relative/path"),
            "relative-path"
        )
    }
}
