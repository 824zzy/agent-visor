import XCTest

final class ReleaseBuildHardeningAuditTests: XCTestCase {
    func testReleaseBuildDisablesDebugEntitlementInjection() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let project = try source(
            at: root.appendingPathComponent("AgentVisor.xcodeproj/project.pbxproj")
        )
        let buildScript = try source(
            at: root.appendingPathComponent("scripts/build.sh")
        )

        let releaseSettings = project.components(
            separatedBy: "name = Release;"
        )
        XCTAssertGreaterThanOrEqual(releaseSettings.count - 1, 3)
        XCTAssertGreaterThanOrEqual(
            project.components(
                separatedBy: "CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;"
            ).count - 1,
            2,
            "Both the Release app and helper configurations must reject injected debug entitlements."
        )
        XCTAssertTrue(
            buildScript.contains("CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"),
            "Release packaging must enforce the hardening setting even if project defaults drift."
        )
    }

    func testReleaseBuildVerifiesTheDistributedBundle() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let buildScript = try source(
            at: root.appendingPathComponent("scripts/build.sh")
        )
        let verifierURL = root.appendingPathComponent("scripts/test-release-bundle.sh")
        guard FileManager.default.fileExists(atPath: verifierURL.path) else {
            XCTFail("Release packaging needs a final-artifact verifier.")
            return
        }
        let verifier = try source(at: verifierURL)

        XCTAssertTrue(buildScript.contains("test-release-bundle.sh"))
        XCTAssertTrue(verifier.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(verifier.contains("com.apple.security.get-task-allow"))
        XCTAssertTrue(verifier.contains("Contents/Helpers/AgentVisorCodexRuntime"))
        XCTAssertTrue(verifier.contains("Contents/Library/LaunchAgents"))
    }

    func testReleasePublicationReverifiesTheAppBeforeArchiving() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let releaseScript = try source(
            at: root.appendingPathComponent("scripts/create-release.sh")
        )

        XCTAssertTrue(
            releaseScript.contains("\"$SCRIPT_DIR/test-release-bundle.sh\" \"$APP_PATH\""),
            "Publishing must reject an app that changed after scripts/build.sh completed."
        )
        XCTAssertTrue(
            releaseScript.contains("\"$SCRIPT_DIR/test-homebrew-resign.sh\" \"$APP_PATH\""),
            "Publishing must recheck the installation signature path used by the casks."
        )
        XCTAssertTrue(
            releaseScript.contains("\"$SCRIPT_DIR/test-release-archive.sh\" \"$ZIP_PATH\""),
            "Publishing must verify the exact archive that users will download."
        )
    }

    func testReleaseArchiveVerifierRejectsMetadataJunkAndChecksTheExtractedApp() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let verifierURL = root.appendingPathComponent("scripts/test-release-archive.sh")
        guard FileManager.default.fileExists(atPath: verifierURL.path) else {
            XCTFail("Release publication needs a final archive verifier.")
            return
        }
        let verifier = try source(at: verifierURL)

        XCTAssertTrue(verifier.contains("__MACOSX"))
        XCTAssertTrue(verifier.contains(".DS_Store"))
        XCTAssertTrue(verifier.contains("test-release-bundle.sh"))
        XCTAssertTrue(verifier.contains("test-homebrew-resign.sh"))
    }

    func testCIRunsCoreTestsAndReleasePackaging() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let workflowURL = root.appendingPathComponent(".github/workflows/ci.yml")
        guard FileManager.default.fileExists(atPath: workflowURL.path) else {
            XCTFail("The release snapshot needs a repeatable CI gate.")
            return
        }
        let workflow = try source(at: workflowURL)

        XCTAssertTrue(workflow.contains("runs-on: macos-15"))
        XCTAssertTrue(
            workflow.contains(
                "DEVELOPER_DIR: /Applications/Xcode_26.2.app/Contents/Developer"
            ),
            "CI must use the same Xcode release toolchain as the validated local build."
        )
        XCTAssertTrue(workflow.contains("swift test --package-path AgentVisorCore"))
        XCTAssertTrue(workflow.contains("brew style Casks/agent-visor.rb"))
        XCTAssertTrue(
            workflow.contains(
                "AV_RELEASE_DERIVED=\"$RUNNER_TEMP/av-release-build\" scripts/build.sh"
            ),
            "Runner-specific paths must be resolved inside a step, where RUNNER_TEMP is available."
        )
        XCTAssertFalse(
            workflow.contains("${{ runner.temp }}"),
            "The runner context is unavailable in job-level env and invalidates the workflow."
        )
    }

    func testReleaseSigningUsesTheReleaseBuildDerivedData() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let releaseScript = try source(
            at: root.appendingPathComponent("scripts/create-release.sh")
        )

        XCTAssertTrue(
            releaseScript.contains(
                "RELEASE_DERIVED=\"${AV_RELEASE_DERIVED:-/tmp/av-release-build}\""
            )
        )
        XCTAssertTrue(
            releaseScript.contains(
                "\"$RELEASE_DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin\""
            ),
            "A fresh machine that only ran scripts/build.sh must still find Sparkle's sign_update tool."
        )
    }

    func testReleaseDependencyResolutionIsCommittedAndEnforced() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let ignoreRules = try source(at: root.appendingPathComponent(".gitignore"))
        let buildScript = try source(at: root.appendingPathComponent("scripts/build.sh"))
        let devBuildScript = try source(at: root.appendingPathComponent("scripts/dev-build.sh"))
        let resolvedPath = "AgentVisor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        let resolvedURL = root.appendingPathComponent(resolvedPath)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resolvedURL.path),
            "The application dependency graph must be committed for reproducible release builds."
        )
        XCTAssertTrue(
            ignoreRules.contains("!\(resolvedPath)"),
            "The shared Xcode Package.resolved file must not be hidden by broad SPM ignore rules."
        )
        XCTAssertTrue(
            buildScript.contains("-onlyUsePackageVersionsFromResolvedFile"),
            "Release packaging must fail instead of silently selecting newer package versions."
        )
        XCTAssertTrue(
            devBuildScript.components(separatedBy: "-onlyUsePackageVersionsFromResolvedFile").count == 3,
            "Both signed and fallback Debug builds must preserve the committed package graph."
        )
    }

    func testIncrementalDevBuildResealsTheAppWithoutDroppingEntitlements() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let devBuildScript = try source(at: root.appendingPathComponent("scripts/dev-build.sh"))

        XCTAssertTrue(
            devBuildScript.contains("--preserve-metadata=identifier,entitlements,requirements,flags,runtime"),
            "Repairing an incremental resource-bundle signature must preserve the app's identity and entitlements."
        )
        XCTAssertTrue(
            devBuildScript.contains("codesign --force --sign \"$SIGN_IDENTITY\""),
            "An incremental build must reseal the outer app after Swift package resources change."
        )
        XCTAssertGreaterThanOrEqual(
            devBuildScript.components(separatedBy: "test-codex-runtime-bundle.sh").count - 1,
            2,
            "The repaired bundle must be verified again before the build is accepted."
        )
    }

    func testReleaseDependenciesDoNotFollowMovingBranches() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let project = try source(
            at: root.appendingPathComponent("AgentVisor.xcodeproj/project.pbxproj")
        )
        let resolved = try source(
            at: root.appendingPathComponent(
                "AgentVisor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            )
        )

        XCTAssertFalse(
            project.contains("kind = branch;"),
            "Release dependencies must not follow mutable branches."
        )
        XCTAssertFalse(
            resolved.contains("\"branch\""),
            "The committed resolver must record immutable package selections."
        )
    }

    func testHomebrewMetadataDescribesTheNavigationProduct() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        for name in ["agent-visor.rb"] {
            let cask = try source(at: root.appendingPathComponent("Casks/\(name)"))
            XCTAssertTrue(
                cask.contains(
                    "desc \"Monitor and return to coding-agent sessions from the menu bar\""
                )
            )
            XCTAssertFalse(
                cask.contains("One window for every coding agent"),
                "Release metadata must not promise the retired chat-first product."
            )
            XCTAssertTrue(
                cask.contains("depends_on arch: :arm64"),
                "Homebrew must not offer the arm64-only app to Intel Macs."
            )
            XCTAssertTrue(
                cask.contains("--preserve-metadata=entitlements,flags"),
                "Homebrew's ad-hoc re-sign must preserve the app's hardened-runtime entitlements."
            )
        }
    }

    func testReleaseBuildExercisesTheHomebrewResignPath() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let buildScript = try source(at: root.appendingPathComponent("scripts/build.sh"))
        let verifierURL = root.appendingPathComponent("scripts/test-homebrew-resign.sh")
        guard FileManager.default.fileExists(atPath: verifierURL.path) else {
            XCTFail("Release verification must cover the Homebrew postflight signature.")
            return
        }
        let verifier = try source(at: verifierURL)

        XCTAssertTrue(buildScript.contains("test-homebrew-resign.sh"))
        XCTAssertTrue(verifier.contains("--preserve-metadata=entitlements,flags"))
        XCTAssertTrue(verifier.contains("com.apple.security.cs.disable-library-validation"))
        XCTAssertTrue(verifier.contains("com.apple.security.get-task-allow"))
    }

    func testReleaseVerifierChecksSupportedPlatformAndRuntime() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let verifier = try source(
            at: root.appendingPathComponent("scripts/test-release-bundle.sh")
        )

        XCTAssertTrue(verifier.contains("LSMinimumSystemVersion"))
        XCTAssertTrue(verifier.contains("14.0"))
        XCTAssertTrue(verifier.contains("file \"$EXECUTABLE\""))
        XCTAssertTrue(verifier.contains("Mach-O 64-bit executable arm64"))
        XCTAssertTrue(verifier.contains("flags=.*runtime"))
    }

    func testAutomationPermissionCopyMatchesOriginalFirstNavigation() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let info = try source(at: root.appendingPathComponent("AgentVisor/Info.plist"))

        XCTAssertTrue(
            info.contains(
                "Agent Visor uses automation to focus and control the terminal session you choose."
            )
        )
        XCTAssertFalse(info.contains("when you click a session in the sidebar"))
    }

    func testReleaseSigningRejectsExposedPrivateKeys() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let releaseScript = try source(
            at: root.appendingPathComponent("scripts/create-release.sh")
        )

        XCTAssertTrue(releaseScript.contains("require_private_key_security"))
        XCTAssertTrue(releaseScript.contains("stat -f '%Lp'"))
        XCTAssertTrue(releaseScript.contains("key_mode_value & 077"))
        XCTAssertTrue(releaseScript.contains("chmod 600"))
    }

    func testSparkleKeyGenerationUsesTheAgentVisorAccount() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let keyScript = try source(
            at: root.appendingPathComponent("scripts/generate-keys.sh")
        )
        let info = try source(
            at: root.appendingPathComponent("AgentVisor/Info.plist")
        )

        XCTAssertTrue(
            keyScript.contains("KEY_ACCOUNT=\"com.824zzy.AgentVisor\""),
            "The clean app identity must not reuse another product's default Sparkle key."
        )
        XCTAssertGreaterThanOrEqual(
            keyScript.components(separatedBy: "--account \"$KEY_ACCOUNT\"").count - 1,
            2,
            "Both key generation and private-key export must use the app-specific account."
        )
        XCTAssertTrue(
            keyScript.contains("/tmp/av-debug-build"),
            "Local key generation must discover Sparkle in the isolated Agent Visor build."
        )
        XCTAssertTrue(
            info.contains("qgVbB+rSiMGsCFha7UmnjyfkOm9f0lnlq7aQHC8WuEs="),
            "The app must embed the public half of the Agent Visor-specific update key."
        )
        XCTAssertTrue(
            keyScript.contains("chmod 600 \"$KEYS_DIR/eddsa_private_key\""),
            "Exported update keys must be private before any release tooling reads them."
        )
    }

    func testDebugSigningKeyIsScopedToCodeSigning() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let setupScript = try source(
            at: root.appendingPathComponent("scripts/dev-sign-setup.sh")
        )

        XCTAssertFalse(
            setupScript.contains("\n    -A \\"),
            "The debug private key must not be available to every application."
        )
        XCTAssertTrue(setupScript.contains("-T /usr/bin/codesign"))
        XCTAssertTrue(
            setupScript.contains(
                "security add-trusted-cert -r trustRoot -p codeSign"
            ),
            "The self-signed certificate trust must be constrained to code signing."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url)
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
