import Foundation
import XCTest

final class PiRuntimeOwnershipWiringAuditTests: XCTestCase {
    func testSessionStoreRejectsCompetingPiRuntimeBeforeAnyHookMutation() throws {
        let source = try String(contentsOf: repoRoot()
            .appendingPathComponent("AgentVisor/Services/State/SessionStore.swift"))
        guard let start = source.range(of: "private func processHookEvent")?.lowerBound,
              let end = source.range(of: "private func codexBackedHookEvent")?.lowerBound else {
            return XCTFail("Could not isolate processHookEvent.")
        }
        let hookPath = String(source[start..<end])

        guard let ownership = hookPath.range(
            of: "PiRuntimeOwnershipPolicy.disposition("
        )?.lowerBound,
        let heartbeat = hookPath.range(
            of: "PiSessionHeartbeatPolicy.disposition("
        )?.lowerBound,
        let pidDedup = hookPath.range(
            of: "// Deduplicate: if this PID"
        )?.lowerBound,
        let metadataMerge = hookPath.range(
            of: "HookProcessMetadataPolicy.merge("
        )?.lowerBound,
        let toolEffects = hookPath.range(
            of: "let shouldCreateApprovalPlaceholder"
        )?.lowerBound,
        let genericPhase = hookPath.range(
            of: "let newPhase = event.determinePhase()"
        )?.lowerBound else {
            return XCTFail("The same-session Pi runtime ownership guard is missing from the hook path.")
        }

        for laterMutation in [heartbeat, pidDedup, metadataMerge, toolEffects, genericPhase] {
            XCTAssertLessThan(
                ownership,
                laterMutation,
                "Competing Pi evidence must be rejected before heartbeat or lifecycle state can mutate."
            )
        }
        XCTAssertTrue(hookPath.contains("existingOwnerIsAlive"))
        XCTAssertTrue(hookPath.contains("pid > 0 && kill(Int32(pid), 0) == 0"))
        XCTAssertTrue(hookPath.contains("agentID: event.agentID"))
        XCTAssertTrue(hookPath.contains("hasExistingSession: !isNewSession"))
        XCTAssertTrue(hookPath.contains("existingPid: pidBeforeHookMerge"))
        XCTAssertTrue(hookPath.contains("eventPid: event.pid"))
        XCTAssertTrue(
            hookPath.contains(
                "if runtimeOwnershipDisposition == .ignoreCompetingRuntime"
            )
        )
    }

    func testMenuBarReadyEpisodesUseSessionIdentityInsteadOfAttachmentIdentity() throws {
        let source = try String(contentsOf: repoRoot()
            .appendingPathComponent("AgentVisor/UI/Views/NotchView.swift"))
        guard let start = source.range(
            of: "private func handleWaitingForInputChange"
        )?.lowerBound,
        let end = source.range(
            of: "private func shouldPlayNotificationSound",
            range: start..<source.endIndex
        )?.lowerBound else {
            return XCTFail("Could not isolate menu-bar Ready episode tracking.")
        }
        let readyHandler = String(source[start..<end])

        XCTAssertTrue(
            source.contains(
                "@State private var readyEpisodeTracker = ReadySessionEpisodeTracker()"
            )
        )
        XCTAssertTrue(
            readyHandler.contains(
                "Set(waitingForInputSessions.map { $0.sessionId })"
            )
        )
        XCTAssertTrue(
            readyHandler.contains(
                "readyEpisodeTracker.update(readySessionIDs: currentIds)"
            )
        )
        XCTAssertTrue(readyHandler.contains("newWaitingIds.contains(session.sessionId)"))
        XCTAssertTrue(readyHandler.contains("waitingForInputTimestamps[session.sessionId]"))
        XCTAssertFalse(readyHandler.contains("session.stableId"))
        XCTAssertFalse(source.contains("previousWaitingForInputIds"))

        guard let displayStart = source.range(
            of: "private var hasWaitingForInput"
        )?.lowerBound,
        let displayEnd = source.range(
            of: "// MARK: - Sizing",
            range: displayStart..<source.endIndex
        )?.lowerBound else {
            return XCTFail("Could not isolate the Ready checkmark lookup.")
        }
        let readyDisplay = String(source[displayStart..<displayEnd])
        XCTAssertTrue(
            readyDisplay.contains("waitingForInputTimestamps[session.sessionId]")
        )
        XCTAssertFalse(readyDisplay.contains("session.stableId"))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
