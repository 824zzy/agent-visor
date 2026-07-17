import XCTest
@testable import AgentVisorCore

final class CodexRolloutFileSignatureTests: XCTestCase {
    func testSamePathAndByteCountAreEqual() {
        XCTAssertEqual(
            CodexRolloutFileSignature(path: "/tmp/rollout.jsonl", byteCount: 123),
            CodexRolloutFileSignature(path: "/tmp/rollout.jsonl", byteCount: 123)
        )
    }

    func testByteCountChangeInvalidatesSignature() {
        XCTAssertNotEqual(
            CodexRolloutFileSignature(path: "/tmp/rollout.jsonl", byteCount: 123),
            CodexRolloutFileSignature(path: "/tmp/rollout.jsonl", byteCount: 124)
        )
    }

    func testPathChangeInvalidatesSignature() {
        XCTAssertNotEqual(
            CodexRolloutFileSignature(path: "/tmp/a.jsonl", byteCount: 123),
            CodexRolloutFileSignature(path: "/tmp/b.jsonl", byteCount: 123)
        )
    }
}
