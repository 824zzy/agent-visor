import XCTest
@testable import AgentVisorCore

final class ProjectDisplayNamePolicyTests: XCTestCase {
    func testLegacyRepoFolderDisplaysAsAgentVisor() {
        XCTAssertEqual(
            ProjectDisplayNamePolicy.displayName(forCwd: "/Users/me/Personal/agent-visor"),
            "agent-visor"
        )
    }

    func testOtherProjectNamesAreUnchanged() {
        XCTAssertEqual(
            ProjectDisplayNamePolicy.displayName(forCwd: "/Users/me/Codes/ao-debug-tool"),
            "ao-debug-tool"
        )
    }

    func testLegacyRepoFolderDisplaysAsAgentVisorInsidePath() {
        XCTAssertEqual(
            ProjectDisplayNamePolicy.displayPath(
                forCwd: "/Users/me/Personal/agent-visor",
                homeDirectory: "/Users/me"
            ),
            "~/Personal/agent-visor"
        )
    }

    func testLegacyRepoFolderDisplaysAsAgentVisorInFolderMenus() {
        XCTAssertEqual(
            ProjectDisplayNamePolicy.displayFolderName(forPath: "/Users/me/Personal/agent-visor"),
            "agent-visor"
        )
    }

    func testOtherPathsAreUnchangedExceptHomeTilde() {
        XCTAssertEqual(
            ProjectDisplayNamePolicy.displayPath(
                forCwd: "/Users/me/Codes/ao-debug-tool",
                homeDirectory: "/Users/me"
            ),
            "~/Codes/ao-debug-tool"
        )
    }
}
