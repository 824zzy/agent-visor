import XCTest
@testable import AgentVisorCore

final class ClaudeProjectPathEncoderTests: XCTestCase {
    func testEncodesSimpleAbsolutePath() {
        XCTAssertEqual(
            ClaudeProjectPathEncoder.projectDirName(forCwd: "/Users/me/proj"),
            "-Users-me-proj"
        )
    }

    func testReplacesDotsWithDashes() {
        // Hidden directories and dotfiles must map to dashes so the on-
        // disk projects dir name stays alphanumeric+dash. Mirrors
        // claude-code's own normalization.
        XCTAssertEqual(
            ClaudeProjectPathEncoder.projectDirName(forCwd: "/Users/me/.config/app"),
            "-Users-me--config-app"
        )
    }

    func testReplacesUnderscoresWithDashes() {
        XCTAssertEqual(
            ClaudeProjectPathEncoder.projectDirName(forCwd: "/Users/me/my_project"),
            "-Users-me-my-project"
        )
    }
}
