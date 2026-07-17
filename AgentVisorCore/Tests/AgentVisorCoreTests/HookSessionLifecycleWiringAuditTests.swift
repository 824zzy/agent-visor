import Foundation
import XCTest

final class HookSessionLifecycleWiringAuditTests: XCTestCase {
    func testHookBridgeAndBundledScriptTreatSessionStartAsIdle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Hooks/HookSocketServer.swift"
        ))
        let script = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Resources/agent-visor-state.py"
        ))

        XCTAssertTrue(bridge.contains("HookSessionLifecyclePolicy.phase("))
        XCTAssertTrue(script.contains(
            "\n    elif event == \"SessionStart\":\n"
                + "        # A live process with no turn is idle, not a completed result.\n"
                + "        state[\"status\"] = \"idle\""
        ))
    }

    func testPeriodicReconciliationExpiresStaleHookReadySessions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))

        XCTAssertTrue(store.contains("HookReadyExpirationPolicy.shouldExpire("))
        XCTAssertTrue(store.contains("await self?.reconcileHookReadyFreshness()"))
    }

    func testBundledClaudeHookCoversFailureAndCompactionBoundaries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let provider = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/ClaudeCodeAgentProvider.swift"
        ))
        let script = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Resources/agent-visor-state.py"
        ))

        XCTAssertTrue(provider.contains("ClaudeHookSubscriptionPolicy.subscriptions"))
        XCTAssertTrue(script.contains("elif event in (\"PostToolUse\", \"PostToolUseFailure\")"))
        XCTAssertTrue(script.contains("elif event == \"StopFailure\":"))
        XCTAssertTrue(script.contains("elif event == \"PostCompact\":"))
        XCTAssertTrue(script.contains(
            "elif event == \"SubagentStop\":\n"
                + "        # The parent turn continues after a subagent returns its result.\n"
                + "        state[\"status\"] = \"processing\""
        ))
    }

    func testToolUseCorrelationIsClearedByBothCompletionEvents() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let socketServer = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Hooks/HookSocketServer.swift"
        ))

        XCTAssertTrue(socketServer.contains("private var toolUseCorrelations = ToolUseCorrelationBuffer()"))
        XCTAssertTrue(socketServer.contains(
            "event.event == \"PostToolUse\" || event.event == \"PostToolUseFailure\""
        ))
        XCTAssertTrue(socketServer.contains("completeCachedToolUseId(toolUseId)"))
    }
}
