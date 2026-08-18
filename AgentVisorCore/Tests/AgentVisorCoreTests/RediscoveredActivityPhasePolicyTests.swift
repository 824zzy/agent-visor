import XCTest
@testable import AgentVisorCore

/// The rule that lets a rediscovered row take a phase from the agent's own
/// busy-or-idle record.
final class RediscoveredActivityPhasePolicyTests: XCTestCase {
    func testBusyRecordLiftsAnIdleRowToWorking() {
        XCTAssertEqual(
            RediscoveredActivityPhasePolicy.phase(for: .working, currentPhase: .idle),
            .processing
        )
    }

    func testBusyRecordLiftsAReadyRowToWorking() {
        XCTAssertEqual(
            RediscoveredActivityPhasePolicy.phase(for: .working, currentPhase: .waitingForInput),
            .processing
        )
    }

    func testIdleRecordSettlesAWorkingRowToReady() {
        XCTAssertEqual(
            RediscoveredActivityPhasePolicy.phase(for: .idle, currentPhase: .processing),
            .waitingForInput
        )
    }

    func testARecordThatAgreesChangesNothing() {
        XCTAssertNil(RediscoveredActivityPhasePolicy.phase(for: .working, currentPhase: .processing))
        XCTAssertNil(RediscoveredActivityPhasePolicy.phase(for: .idle, currentPhase: .idle))
        XCTAssertNil(
            RediscoveredActivityPhasePolicy.phase(for: .idle, currentPhase: .waitingForInput)
        )
    }

    func testNoRecordChangesNothing() {
        // Agents that keep no such record report unknown, and must not move a
        // row at all.
        for phase in [SessionPhase.idle, .processing, .waitingForInput, .ended] {
            XCTAssertNil(
                RediscoveredActivityPhasePolicy.phase(for: .unknown, currentPhase: phase),
                "unknown must never move a row, including from \(phase)"
            )
        }
    }

    func testStrongerPhasesAreNeverOverwritten() {
        // The record reports only busy or idle. It knows nothing about an
        // approval, an end, or a compaction, each of which rests on stronger
        // evidence.
        let pending = SessionPhase.waitingForApproval(
            PermissionContext(
                toolUseId: "t1",
                toolName: "bash",
                toolInput: nil,
                receivedAt: Date()
            )
        )
        for activity in [ClaudeCodeSessionMetadataActivity.working, .idle] {
            XCTAssertNil(RediscoveredActivityPhasePolicy.phase(for: activity, currentPhase: pending))
            XCTAssertNil(RediscoveredActivityPhasePolicy.phase(for: activity, currentPhase: .ended))
            XCTAssertNil(
                RediscoveredActivityPhasePolicy.phase(for: activity, currentPhase: .compacting)
            )
        }
    }

    func testAttachmentDefaultsChangeNothing() {
        let attachment = RediscoveredAttachment()
        XCTAssertFalse(attachment.revivesEndedRow)
        XCTAssertEqual(attachment.pid, .leave)
        XCTAssertFalse(attachment.refreshesActivityFromTranscript)
    }

    func testAttachmentCarriesAClearedPidApartFromAnUnsetOne() {
        // A thread inside a shared app process reports pid 0, which must clear
        // the row's pid rather than leave a stale one behind.
        XCTAssertNotEqual(RediscoveredPidUpdate.clear, .leave)
        XCTAssertNotEqual(RediscoveredPidUpdate.set(0), .clear)
    }
}
