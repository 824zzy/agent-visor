//
//  SessionHotkeyMatcherTests.swift
//  AgentVisorCoreTests
//

import XCTest
@testable import AgentVisorCore

final class SessionHotkeyMatcherTests: XCTestCase {
    func testDigit1Maps0() {
        XCTAssertEqual(SessionHotkeyMatcher.position(forKeyCharacter: "1"), 0)
    }

    func testDigit9Maps8() {
        XCTAssertEqual(SessionHotkeyMatcher.position(forKeyCharacter: "9"), 8)
    }

    func testDigit5Maps4() {
        XCTAssertEqual(SessionHotkeyMatcher.position(forKeyCharacter: "5"), 4)
    }

    func testZeroIsRejected() {
        // Cmd+0 is reserved for chat font reset; matcher must NOT
        // claim it for session navigation.
        XCTAssertNil(SessionHotkeyMatcher.position(forKeyCharacter: "0"))
    }

    func testLetterIsRejected() {
        XCTAssertNil(SessionHotkeyMatcher.position(forKeyCharacter: "a"))
        XCTAssertNil(SessionHotkeyMatcher.position(forKeyCharacter: "A"))
    }

    func testEmptyStringIsRejected() {
        XCTAssertNil(SessionHotkeyMatcher.position(forKeyCharacter: ""))
    }

    func testMultiCharIsRejected() {
        // "10" parses as Int but it's two characters — reject so
        // composed key sequences don't accidentally navigate.
        XCTAssertNil(SessionHotkeyMatcher.position(forKeyCharacter: "10"))
    }

    func testUnicodeDigitIsRejected() {
        // Superscript 2 ("²") parses as Int via NumberFormatter in
        // some paths; we want strictly ASCII 1–9.
        XCTAssertNil(SessionHotkeyMatcher.position(forKeyCharacter: "²"))
        // Arabic-Indic digit
        XCTAssertNil(SessionHotkeyMatcher.position(forKeyCharacter: "٤"))
    }

    func testWhitespaceIsRejected() {
        XCTAssertNil(SessionHotkeyMatcher.position(forKeyCharacter: " "))
        XCTAssertNil(SessionHotkeyMatcher.position(forKeyCharacter: "\t"))
    }

    func testFullDigitRange() {
        for digit in 1...9 {
            XCTAssertEqual(
                SessionHotkeyMatcher.position(forKeyCharacter: String(digit)),
                digit - 1,
                "digit \(digit) should map to position \(digit - 1)"
            )
        }
    }
}
