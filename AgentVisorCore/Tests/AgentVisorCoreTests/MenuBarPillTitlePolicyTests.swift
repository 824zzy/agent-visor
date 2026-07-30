import XCTest
@testable import AgentVisorCore

final class MenuBarPillTitlePolicyTests: XCTestCase {
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
