import XCTest

final class PillClickNavigationWiringAuditTests: XCTestCase {
    func testPillDispatchUsesNavigationPolicy() throws {
        let source = try String(contentsOf: repoRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("NotchView.swift"))

        XCTAssertTrue(
            source.contains("PillClickNavigationPolicy.action"),
            "Pill clicks must go through the tested navigation policy instead of directly focusing the original host."
        )
        XCTAssertTrue(
            source.contains("event.modifierFlags.contains(.option) ? .forceAgentVisor : .standard"),
            "Option-click should remain the low-risk escape hatch for opening the Agent Visor mirror."
        )
    }

    func testRightClickMenuUsesSameSnapshotResolverAndOnlyOffersPillSettings() throws {
        let source = try String(contentsOf: repoRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("NotchView.swift"))

        XCTAssertTrue(
            source.contains("EventMonitor(mask: [.leftMouseDown, .rightMouseDown])"),
            "The pill event monitor should observe right-clicks through the same path as left-clicks."
        )
        XCTAssertTrue(
            source.contains("PillBarHitTest.resolve(click: CGPoint(x: clickX, y: clickY), snapshot: snapshot)"),
            "Right-click must resolve against the rendered snapshot, not live session order."
        )
        XCTAssertTrue(
            source.contains("showPillContextMenu"),
            "Resolved right-clicks should open the pill context menu."
        )
        XCTAssertTrue(
            source.contains("actionItem(\"Pill Settings...\")"),
            "A session pill's context menu should retain the contextual settings shortcut."
        )
        XCTAssertFalse(source.contains("PillClickMenuModel.session"))
        XCTAssertFalse(source.contains("sourceDefaultsMenuItem"))
    }

    func testMainWindowCanOpenSpecificSession() throws {
        let appDelegate = try String(contentsOf: repoRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("App")
            .appendingPathComponent("AppDelegate.swift"))
        let controller = try String(contentsOf: repoRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Window")
            .appendingPathComponent("MainWindowController.swift"))

        XCTAssertTrue(appDelegate.contains("openSessionInMainWindow"))
        XCTAssertTrue(controller.contains("showSession(_ sessionId: String)"))
        XCTAssertTrue(controller.contains("viewModel.selectSession(sessionId)"))
    }

    func testPillSettingsDoNotOfferClickRoutingOverrides() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let settings = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Window")
            .appendingPathComponent("SettingsWindowView.swift"))
        let appSettings = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Core")
            .appendingPathComponent("Settings.swift"))
        let notch = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("NotchView.swift"))

        XCTAssertFalse(settings.contains("SettingsSubheading(\"Click behavior\")"))
        XCTAssertFalse(settings.contains("title: \"Pill click action\""))
        XCTAssertFalse(settings.contains("AppSettings.pillClickBehavior"))
        XCTAssertFalse(appSettings.contains("pillClickBehavior"))
        XCTAssertFalse(appSettings.contains("pillClickSourceOverrides"))
        XCTAssertFalse(notch.contains("pillClickPreferences"))
    }

    func testCodexOriginalNavigationUsesThreadDeepLinks() throws {
        let provider = try String(contentsOf: repoRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("CodexAgentProvider.swift"))
        let navigator = try String(contentsOf: repoRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Navigation")
            .appendingPathComponent("SessionNavigator.swift"))

        XCTAssertTrue(
            provider.contains("codex://threads/"),
            "Codex Desktop original-host navigation should use Codex's per-thread URL route."
        )
        XCTAssertTrue(
            navigator.contains("nav codex open-thread"),
            "Original-host navigation for observed Codex Desktop sessions should be logged as per-thread deep-link navigation."
        )
        XCTAssertTrue(
            provider.contains("NSWorkspace.OpenConfiguration()"),
            "Codex Desktop original-host navigation should use NSWorkspace OpenConfiguration so the deep link activates Codex."
        )
        XCTAssertTrue(
            provider.contains("NSWorkspace.shared.open([deepLink], withApplicationAt: appURL, configuration: configuration)"),
            "Codex Desktop original-host navigation should open the thread URL with Codex.app as the target application."
        )
        XCTAssertTrue(
            provider.contains("configuration.activates = true"),
            "Codex Desktop original-host navigation must request app activation when opening the running app."
        )
        XCTAssertFalse(
            provider.contains("activate(options: [.activateIgnoringOtherApps])"),
            "NSRunningApplication.activate(options:) can report success without making Codex frontmost on current macOS."
        )
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
