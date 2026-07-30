import XCTest
@testable import AgentVisorCore

final class PermissionModeSurfacePolicyTests: XCTestCase {
    func testClaudeTerminalDisplaysCyclesAndProbesPermissionMode() {
        let decision = PermissionModeSurfacePolicy.decision(
            agentID: .claudeCode,
            rawMode: "default",
            hasTTY: true,
            isInTmux: false
        )

        XCTAssertEqual(decision.displayMode, "default")
        XCTAssertTrue(decision.canCycle)
        XCTAssertTrue(decision.shouldProbe)
        XCTAssertTrue(PermissionModeSurfacePolicy.acceptsStateUpdates(for: .claudeCode))
    }

    func testClaudeTerminalCanCycleAndProbeBeforeFirstModeIsKnown() {
        let decision = PermissionModeSurfacePolicy.decision(
            agentID: .claudeCode,
            rawMode: nil,
            hasTTY: true,
            isInTmux: false
        )

        XCTAssertNil(decision.displayMode)
        XCTAssertTrue(decision.canCycle)
        XCTAssertTrue(decision.shouldProbe)
    }

    func testClaudeTmuxModeCyclesWithoutTerminalProbe() {
        let decision = PermissionModeSurfacePolicy.decision(
            agentID: .claudeCode,
            rawMode: "acceptEdits",
            hasTTY: true,
            isInTmux: true
        )

        XCTAssertEqual(decision.displayMode, "acceptEdits")
        XCTAssertTrue(decision.canCycle)
        XCTAssertFalse(decision.shouldProbe)
    }

    func testClaudeEditorModeIsVisibleButReadOnly() {
        let decision = PermissionModeSurfacePolicy.decision(
            agentID: .claudeCode,
            rawMode: "plan",
            hasTTY: false,
            isInTmux: false
        )

        XCTAssertEqual(decision.displayMode, "plan")
        XCTAssertFalse(decision.canCycle)
        XCTAssertFalse(decision.shouldProbe)
    }

    func testCapturedPiSessionRejectsFalseDefaultMode() {
        // Regression fixture from live Pi session 019f88a3: the generic
        // terminal probe inferred `default` from Pi's prompt glyphs.
        let decision = PermissionModeSurfacePolicy.decision(
            agentID: .pi,
            rawMode: "default",
            hasTTY: true,
            isInTmux: false
        )

        XCTAssertNil(decision.displayMode)
        XCTAssertFalse(decision.canCycle)
        XCTAssertFalse(decision.shouldProbe)
        XCTAssertFalse(PermissionModeSurfacePolicy.acceptsStateUpdates(for: .pi))
    }

    func testEveryOtherProviderRejectsClaudePermissionModes() {
        for agentID in AgentID.allCases where agentID != .claudeCode {
            let decision = PermissionModeSurfacePolicy.decision(
                agentID: agentID,
                rawMode: "plan",
                hasTTY: true,
                isInTmux: false
            )

            XCTAssertNil(decision.displayMode, "\(agentID) exposed a Claude mode")
            XCTAssertFalse(decision.canCycle, "\(agentID) enabled Claude mode cycling")
            XCTAssertFalse(decision.shouldProbe, "\(agentID) enabled Claude mode probing")
            XCTAssertFalse(PermissionModeSurfacePolicy.acceptsStateUpdates(for: agentID))
        }
    }
}
