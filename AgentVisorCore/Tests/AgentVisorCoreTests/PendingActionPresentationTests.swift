import XCTest
@testable import AgentVisorCore

final class PendingActionPresentationTests: XCTestCase {
    func testMissingToolUsesGenericActionWithoutContextLabel() {
        XCTAssertEqual(
            PendingActionPresentation.storedToolName(nil),
            "Needs your input"
        )
        XCTAssertNil(PendingActionPresentation.contextualToolName("unknown"))
        XCTAssertNil(PendingActionPresentation.contextualToolName("Needs your input"))
    }

    func testCodexUserInputWireNamesNormalizeToQuestionTool() {
        XCTAssertEqual(
            PendingActionPresentation.contextualToolName("request_user_input"),
            "AskUserQuestion"
        )
        XCTAssertEqual(
            PendingActionPresentation.contextualToolName("requestUserInput"),
            "AskUserQuestion"
        )
    }
}
