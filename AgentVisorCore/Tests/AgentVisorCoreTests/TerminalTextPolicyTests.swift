import XCTest
@testable import AgentVisorCore

final class TerminalTextPolicyTests: XCTestCase {
    func testAcceptsASCIIAtTheUTF8ByteBoundary() {
        let text = String(repeating: "x", count: TerminalTextPolicy.maximumUTF8Bytes)

        XCTAssertEqual(TerminalTextPolicy.validation(for: text), .valid)
    }

    func testRejectsOneASCIIByteOverTheBoundary() {
        let text = String(repeating: "x", count: TerminalTextPolicy.maximumUTF8Bytes + 1)

        XCTAssertEqual(
            TerminalTextPolicy.validation(for: text),
            .exceedsUTF8ByteLimit(
                actual: TerminalTextPolicy.maximumUTF8Bytes + 1,
                maximum: TerminalTextPolicy.maximumUTF8Bytes
            )
        )
    }

    func testMeasuresMultibyteTextInUTF8Bytes() {
        let boundary = String(repeating: "é", count: TerminalTextPolicy.maximumUTF8Bytes / 2)
        let over = boundary + "é"

        XCTAssertEqual(boundary.utf8.count, TerminalTextPolicy.maximumUTF8Bytes)
        XCTAssertTrue(TerminalTextPolicy.canSend(boundary))
        XCTAssertFalse(TerminalTextPolicy.canSend(over))
    }
}
