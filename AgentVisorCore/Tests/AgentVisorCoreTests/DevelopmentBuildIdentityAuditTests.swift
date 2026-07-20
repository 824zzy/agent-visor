import XCTest

final class DevelopmentBuildIdentityAuditTests: XCTestCase {
    func testDebugAndReleaseAppsHaveDistinctVisibleAndPermissionIdentities() throws {
        let project = try source("AgentVisor.xcodeproj/project.pbxproj")
        let info = try source("AgentVisor/Info.plist")
        let debugSettings = try appBuildSettings(named: "Debug", in: project)
        let releaseSettings = try appBuildSettings(named: "Release", in: project)

        XCTAssertTrue(debugSettings.contains("PRODUCT_NAME = \"Agent Visor Dev\";"))
        XCTAssertTrue(
            debugSettings.contains(
                "PRODUCT_BUNDLE_IDENTIFIER = com.824zzy.AgentVisor.Dev;"
            )
        )
        XCTAssertTrue(releaseSettings.contains("PRODUCT_NAME = \"Agent Visor\";"))
        XCTAssertTrue(
            releaseSettings.contains(
                "PRODUCT_BUNDLE_IDENTIFIER = com.824zzy.AgentVisor;"
            )
        )
        XCTAssertTrue(info.contains("<string>$(PRODUCT_NAME)</string>"))
        XCTAssertFalse(
            info.contains("<key>CFBundleDisplayName</key>\n    <string>Agent Visor</string>"),
            "The built app name must follow its configuration instead of making Debug look like Release."
        )
    }

    func testDevBuildScriptTargetsTheDistinctAppBundle() throws {
        let devBuild = try source("scripts/dev-build.sh")
        let releaseBuild = try source("scripts/build.sh")

        XCTAssertTrue(
            devBuild.contains(
                "Build/Products/Debug/Agent Visor Dev.app"
            )
        )
        XCTAssertTrue(
            releaseBuild.contains("APP_NAME=\"Agent Visor.app\""),
            "The public release bundle name must remain unchanged."
        )
    }

    func testDevBuildDeploysAndLaunchesFromAVisibleStableApplicationsPath() throws {
        let devBuild = try source("scripts/dev-build.sh")

        XCTAssertTrue(
            devBuild.contains("INSTALL_DIR=\"${AV_DEV_INSTALL_DIR:-/Applications}\""),
            "The development app must not run from hidden DerivedData or /tmp, where users cannot find it in the Accessibility chooser."
        )
        XCTAssertTrue(
            devBuild.contains("INSTALLED_APP=\"$INSTALL_DIR/Agent Visor Dev.app\"")
        )
        XCTAssertTrue(
            devBuild.contains("open -n \"$INSTALLED_APP\""),
            "The build workflow must launch the stable installed copy, not the transient build product."
        )
    }

    func testDevBuildRegistersOnlyTheStableDevelopmentCopy() throws {
        let devBuild = try source("scripts/dev-build.sh")

        XCTAssertTrue(
            devBuild.contains("\"$LSREGISTER\" -u \"$APP_PATH\""),
            "The hidden intermediate bundle must not remain a competing LaunchServices identity."
        )
        XCTAssertTrue(
            devBuild.contains("\"$LSREGISTER\" -f \"$INSTALLED_APP\"")
        )
    }

    func testDebugAppUsesAnUnmistakableDevelopmentIcon() throws {
        let project = try source("AgentVisor.xcodeproj/project.pbxproj")
        let debugSettings = try appBuildSettings(named: "Debug", in: project)
        let releaseSettings = try appBuildSettings(named: "Release", in: project)
        let devIcon = repoRoot().appendingPathComponent(
            "AgentVisor/Assets.xcassets/AppIconDev.appiconset/Contents.json"
        )

        XCTAssertTrue(
            debugSettings.contains(
                "ASSETCATALOG_COMPILER_APPICON_NAME = AppIconDev;"
            )
        )
        XCTAssertTrue(
            releaseSettings.contains(
                "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: devIcon.path),
            "The Debug identity needs a visibly different icon in System Settings."
        )
    }

    func testBundledDevelopmentRuntimeUsesTheDevelopmentIdentity() throws {
        let project = try source("AgentVisor.xcodeproj/project.pbxproj")
        let serviceManager = try source(
            "AgentVisor/Services/Agents/CodexSharedRuntimeServiceManager.swift"
        )
        let verifier = try source("scripts/test-codex-runtime-bundle.sh")
        let launchAgentPath =
            "AgentVisor/Resources/LaunchAgents/com.824zzy.AgentVisor.Dev.CodexRuntime.plist"
        let launchAgent = try source(launchAgentPath)

        XCTAssertGreaterThanOrEqual(
            project.components(
                separatedBy: "PRODUCT_BUNDLE_IDENTIFIER = com.824zzy.AgentVisor.Dev.CodexRuntime;"
            ).count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            project.components(
                separatedBy: "PRODUCT_NAME = AgentVisorDevCodexRuntime;"
            ).count - 1,
            2
        )
        XCTAssertTrue(
            serviceManager.contains(
                "plistName: \"com.824zzy.AgentVisor.Dev.CodexRuntime.plist\""
            )
        )
        XCTAssertTrue(
            launchAgent.contains(
                "<string>com.824zzy.AgentVisor.Dev.CodexRuntime</string>"
            )
        )
        XCTAssertTrue(
            launchAgent.contains(
                "<string>Contents/Helpers/AgentVisorDevCodexRuntime</string>"
            )
        )
        XCTAssertTrue(
            launchAgent.contains(
                "<string>com.824zzy.AgentVisor.Dev</string>"
            )
        )
        XCTAssertTrue(verifier.contains("Agent Visor Dev.app"))
        XCTAssertTrue(verifier.contains("AgentVisorDevCodexRuntime"))
        XCTAssertTrue(verifier.contains("CFBundleDisplayName"))
        XCTAssertTrue(verifier.contains("com.824zzy.AgentVisor.Dev"))
        XCTAssertTrue(verifier.contains("AppIconDev"))
    }

    func testReleaseAndDevelopmentVariantsCannotOwnTheMenuBarTogether() throws {
        let appDelegate = try source("AgentVisor/App/AppDelegate.swift")

        XCTAssertTrue(
            appDelegate.contains(
                "private static let supportedBundleIdentifiers: Set<String>"
            )
        )
        XCTAssertTrue(appDelegate.contains("\"com.824zzy.AgentVisor\""))
        XCTAssertTrue(appDelegate.contains("\"com.824zzy.AgentVisor.Dev\""))
        XCTAssertTrue(
            appDelegate.contains(
                "Self.supportedBundleIdentifiers.contains($0.bundleIdentifier ?? \"\")"
            )
        )
    }

    private func appBuildSettings(named configuration: String, in project: String) throws -> String {
        let blocks = project.components(separatedBy: "\n\t\t};")
        guard let block = blocks.first(where: {
            $0.contains("/* \(configuration) */ = {")
                && $0.contains("MARKETING_VERSION")
                && $0.contains("PRODUCT_BUNDLE_IDENTIFIER")
        }) else {
            throw TestError.missingAppConfiguration(configuration)
        }
        return block
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private enum TestError: Error {
        case missingAppConfiguration(String)
    }
}
