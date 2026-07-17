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

    func testInstallationCopyExplicitlyTapsTheHomebrewRepository() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"))
        let releaseScript = try String(contentsOf: root.appendingPathComponent("scripts/create-release.sh"))

        for copy in [readme, releaseScript] {
            XCTAssertTrue(copy.contains("brew tap 824zzy/agent-visor"))
            XCTAssertTrue(copy.contains("brew install --cask 824zzy/agent-visor/agent-visor"))
            XCTAssertFalse(copy.contains("\nbrew install --cask agent-visor\n"))
        }
    }

    func testDistributionFeedUsesOnlyAgentVisorReleaseIdentity() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let appcast = try String(contentsOf: root.appendingPathComponent("docs/appcast.xml"))
        let cask = try String(contentsOf: root.appendingPathComponent("Casks/agent-visor.rb"))
        let versionLine = try XCTUnwrap(cask.split(separator: "\n").first {
            $0.contains("version \"")
        })
        let versionFragments = versionLine.split(separator: "\"")
        let version = String(try XCTUnwrap(versionFragments.count > 1 ? versionFragments[1] : nil))

        XCTAssertTrue(appcast.contains("<title>Agent Visor Updates</title>"))
        XCTAssertTrue(appcast.contains("https://824zzy.github.io/agent-visor/appcast.xml"))
        XCTAssertTrue(appcast.contains("<item>"))
        XCTAssertTrue(appcast.contains(
            "<sparkle:shortVersionString>\(version)</sparkle:shortVersionString>"
        ))
        XCTAssertTrue(appcast.contains(
            "https://github.com/824zzy/agent-visor/releases/download/v\(version)/AgentVisor-v\(version).zip"
        ))
        let retiredFragments = ["claude", "visor"]
        let integrationFragments = ["codex", "visor"]
        XCTAssertFalse(appcast.localizedCaseInsensitiveContains(retiredFragments.joined()))
        XCTAssertFalse(appcast.localizedCaseInsensitiveContains(retiredFragments.joined(separator: "-")))
        XCTAssertFalse(appcast.localizedCaseInsensitiveContains(integrationFragments.joined(separator: "-")))
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
