import Foundation
import XCTest

final class TerminalFocusWiringAuditTests: XCTestCase {
    func testITermRequiresForegroundAndExactSessionBeforeReportingSuccess() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("ITermAdapter.swift"))

        XCTAssertTrue(source.contains("TerminalHostActivator.activateAndWait"))
        XCTAssertTrue(source.contains("TerminalFocusVerificationPolicy.isSuccessful"))
        XCTAssertFalse(source.contains("app.activate()"))
    }

    func testGhosttyUsesAHostAdapterThatVerifiesForegroundAndFocusedPane() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let registry = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("TerminalAdapterRegistry.swift"))
        let adapter = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("GhosttyAdapter.swift"))

        XCTAssertTrue(registry.contains("case .ghostty:"))
        XCTAssertTrue(registry.contains("return GhosttyAdapter()"))
        XCTAssertTrue(adapter.contains("TerminalHostActivator.activateAndWait"))
        XCTAssertTrue(adapter.contains("TerminalFocusVerificationPolicy.isSuccessful"))
        XCTAssertTrue(adapter.contains("focused terminal of selected tab of front window"))
    }

    func testTerminalAppUsesExactTTYAdapterAndForegroundVerification() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let registry = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("TerminalAdapterRegistry.swift"))
        let adapter = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("TerminalAppAdapter.swift"))

        XCTAssertTrue(registry.contains("case .terminalApp:"))
        XCTAssertTrue(registry.contains("return TerminalAppAdapter()"))
        XCTAssertTrue(adapter.contains("TerminalAppSessionLocator.focusScript"))
        XCTAssertTrue(adapter.contains("TerminalHostActivator.activateAndWait"))
        XCTAssertTrue(adapter.contains("TerminalFocusVerificationPolicy.isSuccessful"))
    }

    func testFailedExactTerminalFocusDoesNotFallThroughToAnotherHost() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let navigator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Navigation")
            .appendingPathComponent("SessionNavigator.swift"))

        XCTAssertTrue(navigator.contains("reason=exactFocusFailed"))
        XCTAssertFalse(navigator.contains("GhosttyRawActivate"))
        XCTAssertFalse(navigator.contains("ghosttyAllTiersFailed"))
    }

    func testClaudeDesktopNavigationUsesVerifiedForegroundActivation() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let navigator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Navigation")
            .appendingPathComponent("SessionNavigator.swift"))

        XCTAssertTrue(navigator.contains("TerminalHostActivator.activateAndWait"))
        XCTAssertFalse(navigator.contains("app.activate()"))
    }

    func testTerminalAdaptersBuildCleanlyWithCurrentMainActorAndActivationAPIs() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let terminalRoot = root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Terminal")
        let ghostty = try String(contentsOf: terminalRoot
            .appendingPathComponent("GhosttyAdapter.swift"))
        let terminal = try String(contentsOf: terminalRoot
            .appendingPathComponent("TerminalAppAdapter.swift"))
        let activator = try String(contentsOf: terminalRoot
            .appendingPathComponent("TerminalHostActivator.swift"))

        XCTAssertTrue(ghostty.contains("nonisolated init() {}"))
        XCTAssertTrue(terminal.contains("nonisolated init() {}"))
        XCTAssertFalse(activator.contains(".activateIgnoringOtherApps"))
        XCTAssertTrue(activator.contains("app.activate(options: [.activateAllWindows])"))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
