import XCTest
@testable import AgentVisorCore

final class TTYNormalizerTests: XCTestCase {

    func testRealTTYPassesThrough() {
        XCTAssertEqual(TTYNormalizer.normalize("ttys001"), "ttys001")
    }

    func testEmptyStringBecomesNil() {
        XCTAssertNil(TTYNormalizer.normalize(""))
    }

    func testDoubleQuestionMarkBecomesNil() {
        XCTAssertNil(TTYNormalizer.normalize("??"))
    }

    func testLeadingTrailingWhitespaceTrimmed() {
        XCTAssertEqual(TTYNormalizer.normalize("  ttys001  "), "ttys001")
    }

    func testWhitespaceOnlyBecomesNil() {
        XCTAssertNil(TTYNormalizer.normalize("   "))
    }

    func testQuestionMarkWithWhitespaceBecomesNil() {
        XCTAssertNil(TTYNormalizer.normalize("  ??  "))
    }

    func testNewlineAlonBecomesNil() {
        XCTAssertNil(TTYNormalizer.normalize("\n"))
    }

    func testTrailingNewlineTrimmed() {
        XCTAssertEqual(TTYNormalizer.normalize("ttys001\n"), "ttys001")
    }

    func testGhosttyStylePTYPassesThrough() {
        // Ghostty / iTerm2 commonly assign ttys012, ttys027, etc.
        XCTAssertEqual(TTYNormalizer.normalize("ttys027"), "ttys027")
    }

    func testTabsAlsoTrimmed() {
        XCTAssertEqual(TTYNormalizer.normalize("\tttys001\t"), "ttys001")
    }
}
