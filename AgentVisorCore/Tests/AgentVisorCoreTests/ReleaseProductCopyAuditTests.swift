import XCTest

final class ReleaseProductCopyAuditTests: XCTestCase {
    func testReadmeDescribesTheStatusAndNavigationProduct() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"))

        XCTAssertTrue(readme.contains("status and navigation layer"))
        XCTAssertTrue(readme.contains("The owning app remains the authoritative conversation and control surface."))
        XCTAssertTrue(readme.contains("screenshots/session-browser.png"))
        XCTAssertFalse(readme.contains("One window for every coding agent"))
        XCTAssertFalse(readme.contains("Window mode: a dedicated app window"))
    }

    func testNewDistributionFeedDoesNotRewriteHistoricalReleases() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let appcast = try String(contentsOf: root.appendingPathComponent("docs/appcast.xml"))

        XCTAssertTrue(appcast.contains("<title>Agent Visor Updates</title>"))
        XCTAssertTrue(appcast.contains("https://824zzy.github.io/agent-visor/appcast.xml"))
        XCTAssertFalse(appcast.contains("<item>"))
        XCTAssertFalse(appcast.contains("<sparkle:shortVersionString>"))
    }

    func testPublishedScreenshotsComeFromTheSyntheticFixture() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let fixture = try String(contentsOf: root.appendingPathComponent(
            "scripts/screenshot-fixtures/agent-visor-synthetic.html"
        ))
        let screenshots = root.appendingPathComponent("screenshots")

        XCTAssertFalse(fixture.contains("/Users/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: screenshots.appendingPathComponent("menubar-sessions.png").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: screenshots.appendingPathComponent("session-browser.png").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: screenshots.appendingPathComponent("notch-panel.png").path
        ))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
