import XCTest

final class ClaudeUsageGlanceWiringAuditTests: XCTestCase {
    func testMonitorIsReadOnlyAndNeverRefreshesTheSharedToken() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let monitor = try source(
            root.appendingPathComponent("AgentVisor/Services/Agents/ClaudeUsageMonitor.swift")
        )

        // Uses Claude Code's usage endpoint + oauth beta, read from Pi's store.
        XCTAssertTrue(monitor.contains("api.anthropic.com/api/oauth/usage"))
        XCTAssertTrue(monitor.contains("oauth-2025-04-20"))
        XCTAssertTrue(monitor.contains(".pi/agent/auth.json"))
        XCTAssertTrue(monitor.contains("ClaudeUsageSnapshotParser.response"))
        XCTAssertTrue(monitor.contains("ClaudeUsageGlancePolicy.availability"))
        XCTAssertTrue(monitor.contains("hasAttemptedRefresh"))

        // SAFETY: Anthropic rotates refresh tokens, so the monitor must never
        // perform a token refresh or write the credential file — doing so
        // would invalidate Pi's stored credential and break Pi's own auth.
        XCTAssertFalse(monitor.contains("grant_type"))
        XCTAssertFalse(monitor.contains("refresh_token"))
        XCTAssertFalse(monitor.contains("platform.claude.com"))
        XCTAssertFalse(monitor.contains("write(to:"))
        XCTAssertFalse(monitor.contains("httpMethod = \"POST\""))
    }

    func testClaudePillSharesTheRightUsageSlotBesideCodex() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try source(
            root.appendingPathComponent("AgentVisor/UI/Components/NotchSideContent.swift")
        )
        let notchView = try source(
            root.appendingPathComponent("AgentVisor/UI/Views/NotchView.swift")
        )

        XCTAssertTrue(sideContent.contains("struct ClaudeUsagePillButton"))
        XCTAssertTrue(sideContent.contains("struct ClaudeUsagePopover"))
        XCTAssertTrue(sideContent.contains("ClaudeUsageGlancePolicy.fixedWidth"))
        XCTAssertTrue(sideContent.contains("MenuBarUsageSlotPolicy.layout"))
        XCTAssertTrue(sideContent.contains("let usageLayout"))
        XCTAssertFalse(sideContent.contains("CodexUsageGlancePolicy.reserveRightSide("))
        XCTAssertFalse(sideContent.contains("ClaudeUsageGlancePolicy.reserveRightSide("))
        XCTAssertFalse(sideContent.contains("static func usageSlotWidth("))
        XCTAssertTrue(sideContent.contains("let showsCodexUsagePill: Bool"))
        XCTAssertTrue(sideContent.contains("let showsClaudeUsagePill: Bool"))

        // Both providers feed the one right-side usage hit region + popover.
        XCTAssertTrue(notchView.contains("includeClaudeUsage: claudeUsageMonitor.showsPill"))
        XCTAssertTrue(notchView.contains("showsClaudeUsage: pack.showsClaudeUsagePill"))
        XCTAssertTrue(notchView.contains("rightUsageWidth"))
        XCTAssertTrue(notchView.contains("pack.usageSlotWidth"))
    }

    func testClaudeUsageIsStartedAndTogglableAndDefaultsOn() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let settings = try source(
            root.appendingPathComponent("AgentVisor/Core/Settings.swift")
        )
        let settingsView = try source(
            root.appendingPathComponent("AgentVisor/UI/Window/SettingsWindowView.swift")
        )
        let appDelegate = try source(
            root.appendingPathComponent("AgentVisor/App/AppDelegate.swift")
        )

        XCTAssertTrue(settings.contains("static var claudeUsageGlanceEnabled"))
        XCTAssertTrue(settingsView.contains("Show Claude usage when available"))
        XCTAssertTrue(appDelegate.contains("ClaudeUsageMonitor.shared.start()"))
    }

    private func source(_ url: URL) throws -> String {
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
