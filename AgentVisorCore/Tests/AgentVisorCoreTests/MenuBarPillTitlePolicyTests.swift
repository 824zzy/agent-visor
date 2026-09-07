import XCTest
@testable import AgentVisorCore

final class MenuBarPillTitlePolicyTests: XCTestCase {
    func testMultilinePromptUsesItsFirstMeaningfulLine() {
        for separator in ["\n", "\r\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(
                MenuBarPillTitlePolicy.title(
                    sessionName: " \t\(separator) hi\t there \(separator)\(separator)Instruction author: local:profile-test",
                    projectName: "Codes"
                ),
                "hi there"
            )
        }
    }

    func testSourceSessionNameWinsOverProject() {
        XCTAssertEqual(
            MenuBarPillTitlePolicy.title(
                sessionName: "pi-donut",
                projectName: "Codes"
            ),
            "pi-donut"
        )
    }

    func testProjectNameIsTheStableFallback() {
        XCTAssertEqual(
            MenuBarPillTitlePolicy.title(
                sessionName: nil,
                projectName: "Donut"
            ),
            "Donut"
        )
    }

    func testBlankSourceSessionNameFallsBackToProject() {
        XCTAssertEqual(
            MenuBarPillTitlePolicy.title(
                sessionName: "  \n",
                projectName: "PC_POC"
            ),
            "PC_POC"
        )
    }
}
