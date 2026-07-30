import XCTest
@testable import AgentVisorCore

final class ToolPresentationPolicyTests: XCTestCase {
    func testPiBuiltinsUseCanonicalVerbsAndUsefulTargets() {
        XCTAssertEqual(
            ToolPresentationPolicy.presentation(
                rawName: "read",
                input: ["path": "/tmp/chat-history.png"],
                agent: .pi
            ),
            ToolPresentation(title: "Read", detail: "chat-history.png")
        )
        XCTAssertEqual(
            ToolPresentationPolicy.presentation(
                rawName: "bash",
                input: ["command": "python3 ocr.py\n--all"],
                agent: .pi
            ),
            ToolPresentation(title: "Run", detail: "python3 ocr.py")
        )
        XCTAssertEqual(
            ToolPresentationPolicy.presentation(
                rawName: "edit",
                input: ["path": "/tmp/skill_lib.py", "oldText": "before"],
                agent: .pi
            ),
            ToolPresentation(title: "Edit", detail: "skill_lib.py")
        )
    }
}
