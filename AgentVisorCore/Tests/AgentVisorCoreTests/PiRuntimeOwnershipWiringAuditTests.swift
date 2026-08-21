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

    func testBootstrapRejectsPiDiscoveryWhosePidIsOwnedByAnotherLiveSession() throws {
        let source = try String(contentsOf: repoRoot()
            .appendingPathComponent("AgentVisor/Services/State/SessionStore.swift"))
        guard let start = source.range(of: "func bootstrapSessions(_ discovered:")?.lowerBound,
              let end = source.range(
                of: "private func applyBootstrapConversationInfo",
                range: start..<source.endIndex
              )?.lowerBound else {
            return XCTFail("Could not isolate bootstrapSessions.")
        }
        let bootstrap = String(source[start..<end])

        guard let hiddenSkip = bootstrap.range(
                of: "if hiddenSessionIds.contains(info.sessionId)"
              )?.lowerBound,
              let admits = bootstrap.range(
                of: "PiRuntimeOwnershipPolicy.admitsDiscoveredSession("
              )?.lowerBound,
              let existingMerge = bootstrap.range(
                of: "if let existing = sessions[info.sessionId]"
              )?.lowerBound,
              let insert = bootstrap.range(
                of: "sessions[info.sessionId] = session"
              )?.lowerBound else {
            return XCTFail("The fallback Pi discovery ownership guard is missing from bootstrapSessions.")
        }

        XCTAssertLessThan(
            hiddenSkip,
            admits,
            "Hidden rows are filtered before the discovery ownership guard runs."
        )
        XCTAssertLessThan(
            admits,
            existingMerge,
            "Discovery ownership must be resolved before the existing-row merge."
        )
        XCTAssertLessThan(
            admits,
            insert,
            "Discovery ownership must be resolved before a new discovery row is inserted."
        )
        XCTAssertTrue(bootstrap.contains("pidOwnedByOtherLiveSession"))
        XCTAssertTrue(bootstrap.contains("agentID: info.agentID"))
        XCTAssertTrue(bootstrap.contains("== .ignoreCompetingRuntime"))
    }

    func testMenuBarReadyEpisodesUseSessionIdentityInsteadOfAttachmentIdentity() throws {
        let source = try String(contentsOf: repoRoot()
            .appendingPathComponent("AgentVisor/UI/Views/PillStripView.swift"))
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
        XCTAssertTrue(readyHandler.contains("newWaitingIds.contains($0.sessionId)"))
        XCTAssertTrue(readyHandler.contains("isBouncing = true"))
        XCTAssertTrue(readyHandler.contains("shouldPlayNotificationSound"))
        XCTAssertFalse(readyHandler.contains("session.stableId"))
        XCTAssertFalse(source.contains("previousWaitingForInputIds"))
        XCTAssertFalse(
            source.contains("waitingForInputTimestamps"),
            "The retired panel's 30-second visibility timer must not return."
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
