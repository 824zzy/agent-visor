import XCTest

final class CodexUsageGlanceWiringAuditTests: XCTestCase {
    func testMonitorReadsStableRPCAndMergesRollingNotifications() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let monitor = try source(
            root.appendingPathComponent("AgentVisor/Services/Agents/CodexUsageMonitor.swift")
        )
        let client = try source(
            root.appendingPathComponent("AgentVisor/Services/Agents/CodexAppServerClient.swift")
        )
        let bridge = try source(
            root.appendingPathComponent("AgentVisor/Services/Agents/CodexAppServerStreamBridge.swift")
        )

        XCTAssertTrue(client.contains("func readAccountRateLimits()"))
        XCTAssertTrue(client.contains("CodexAppServerProtocol.Method.accountRateLimitsRead"))
        XCTAssertTrue(monitor.contains("CodexUsageSnapshotParser.notification"))
        XCTAssertTrue(monitor.contains("snapshot = current.merging(update)"))
        XCTAssertTrue(bridge.contains("NotificationMethod.accountRateLimitsUpdated"))
        XCTAssertTrue(bridge.contains("CodexUsageMonitor.shared.handleNotification"))
    }

    func testUsagePillIsFixedWidthReservedAndUsesRenderSnapshotHitRouting() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try source(
            root.appendingPathComponent("AgentVisor/UI/Components/NotchSideContent.swift")
        )
        let notchView = try source(
            root.appendingPathComponent("AgentVisor/UI/Views/NotchView.swift")
        )

        XCTAssertTrue(sideContent.contains("struct CodexUsagePillButton"))
        XCTAssertTrue(sideContent.contains("CodexUsageGlancePolicy.fixedWidth"))
        XCTAssertTrue(sideContent.contains("struct CodexUsagePopover"))
        XCTAssertTrue(notchView.contains("includeUsage: codexUsageMonitor.showsPill"))
        XCTAssertFalse(notchView.contains("includeUsage: AppSettings.codexUsageGlanceEnabled"))
        XCTAssertFalse(notchView.contains("codexUsageMonitor.enabled"))
        XCTAssertTrue(notchView.contains("rightUsageWidth:"))
        XCTAssertTrue(notchView.contains("case .usage:"))
        XCTAssertTrue(notchView.contains("showCodexUsagePopover = willShowUsagePopover"))
    }

    func testUsagePillShowsBothWindowsWithoutASessionStatusDot() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try source(
            root.appendingPathComponent("AgentVisor/UI/Components/NotchSideContent.swift")
        )
        let start = try XCTUnwrap(sideContent.range(of: "struct CodexUsagePillButton"))
        let end = try XCTUnwrap(sideContent.range(
            of: "struct CodexUsagePopover",
            range: start.upperBound..<sideContent.endIndex
        ))
        let usagePill = String(sideContent[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(usagePill.contains("presentation.fiveHour"))
        XCTAssertTrue(usagePill.contains("presentation.sevenDay"))
        XCTAssertTrue(usagePill.contains("CodexUsagePillValue"))
        XCTAssertTrue(usagePill.contains("switch presentation.tone"))
        XCTAssertFalse(usagePill.contains("Circle()"))
        XCTAssertFalse(usagePill.contains("private var accent"))
    }

    func testUsageGlanceIsReadOnlyAndCanBeHiddenInPillSettings() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let settings = try source(
            root.appendingPathComponent("AgentVisor/Core/Settings.swift")
        )
        let settingsView = try source(
            root.appendingPathComponent("AgentVisor/UI/Window/SettingsWindowView.swift")
        )
        let sideContent = try source(
            root.appendingPathComponent("AgentVisor/UI/Components/NotchSideContent.swift")
        )
        let monitor = try source(
            root.appendingPathComponent("AgentVisor/Services/Agents/CodexUsageMonitor.swift")
        )

        XCTAssertTrue(settings.contains("static var codexUsageGlanceEnabled"))
        XCTAssertTrue(settingsView.contains("Show Codex usage when available"))
        XCTAssertTrue(settingsView.contains("usageAvailabilityDescription"))
        XCTAssertTrue(monitor.contains("CodexUsageGlancePolicy.availability"))
        XCTAssertTrue(monitor.contains("hasAttemptedRefresh"))
        XCTAssertFalse(sideContent.contains("Add credits"))
        XCTAssertFalse(sideContent.contains("consumeAccountRateLimit"))
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
