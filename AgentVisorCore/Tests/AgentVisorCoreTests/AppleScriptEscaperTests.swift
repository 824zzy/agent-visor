import XCTest
@testable import AgentVisorCore

final class AppleScriptEscaperTests: XCTestCase {
    func testEscapesBackslashByDoubling() {
        XCTAssertEqual(AppleScriptEscaper.escape("a\\b"), "a\\\\b")
    }

    func testEscapesDoubleQuoteWithBackslash() {
        XCTAssertEqual(AppleScriptEscaper.escape("a\"b"), "a\\\"b")
    }
}
