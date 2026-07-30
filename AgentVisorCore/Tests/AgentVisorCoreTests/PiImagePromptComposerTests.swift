import XCTest
@testable import AgentVisorCore

final class PiImagePromptComposerTests: XCTestCase {
    func testImageOnlyPromptIsTheImagePath() {
        XCTAssertEqual(
            PiImagePromptComposer.compose(
                text: "",
                imagePaths: ["/tmp/av-first.png"]
            ),
            "/tmp/av-first.png"
        )
    }

    func testPathsStayOrderedBeforeOptionalTextWithSingleSpaceSeparators() {
        XCTAssertEqual(
            PiImagePromptComposer.compose(
                text: "Compare these screenshots",
                imagePaths: [
                    "/tmp/av-first.png",
                    "/tmp/av-second.png",
                ]
            ),
            "/tmp/av-first.png /tmp/av-second.png Compare these screenshots"
        )
    }

    func testTextOnlyPromptRemainsAvailableToTheSharedSender() {
        XCTAssertEqual(
            PiImagePromptComposer.compose(
                text: "Explain this behavior",
                imagePaths: []
            ),
            "Explain this behavior"
        )
    }

    func testBlankPathsAndOuterTextWhitespaceAreDiscarded() {
        XCTAssertEqual(
            PiImagePromptComposer.compose(
                text: "  Inspect this  ",
                imagePaths: ["", "   ", "/tmp/av-image.png"]
            ),
            "/tmp/av-image.png Inspect this"
        )
    }

    func testEmptyInputDoesNotProduceASubmission() {
        XCTAssertNil(
            PiImagePromptComposer.compose(
                text: " \n ",
                imagePaths: ["", "  "]
            )
        )
    }

    func testInternalPromptNewlinesArePreserved() {
        XCTAssertEqual(
            PiImagePromptComposer.compose(
                text: "Compare both\nand explain the difference",
                imagePaths: ["/tmp/av-image.png"]
            ),
            "/tmp/av-image.png Compare both\nand explain the difference"
        )
    }
}
