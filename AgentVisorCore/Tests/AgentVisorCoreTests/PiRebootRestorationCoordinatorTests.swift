import Darwin
import XCTest
@testable import AgentVisorCore

final class PiRebootRestorationCoordinatorTests: XCTestCase {
    private let first = PiRestorableSession(
        sessionId: "session-a",
        sessionFile: "/tmp/session-a.jsonl",
        cwd: "/tmp/project-a",
        sessionName: "Project A",
        layout: .init(windowIndex: 1, tabIndex: 1, terminalIndex: 1),
        observedAt: Date(timeIntervalSince1970: 100)
    )

    private let second = PiRestorableSession(
        sessionId: "session-b",
        sessionFile: "/tmp/session-b.jsonl",
        cwd: "/tmp/project-b",
        sessionName: nil,
        layout: .init(windowIndex: 1, tabIndex: 2, terminalIndex: 1),
        observedAt: Date(timeIntervalSince1970: 110)
    )

    func testMissingSessionFileBecomesEligibleAfterItIsPersisted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionFile = directory.appendingPathComponent("session.jsonl")
        XCTAssertFalse(
            PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: sessionFile.path)
        )

        XCTAssertTrue(FileManager.default.createFile(atPath: sessionFile.path, contents: Data()))
        XCTAssertTrue(
            PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: sessionFile.path)
        )
    }

    func testDirectoryIsNotEligibleAsPersistedSessionFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(
            PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: directory.path)
        )
    }

    func testSymbolicLinkToRegularFileIsNotEligibleAsPersistedSessionFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("session.jsonl")
        let symbolicLink = directory.appendingPathComponent("session-link.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: target
        )

        XCTAssertFalse(
            PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: symbolicLink.path)
        )
    }

    func testFIFOIsNotEligibleAsPersistedSessionFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fifo = directory.appendingPathComponent("session.fifo")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertFalse(
            PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: fifo.path)
        )
    }

    func testNewBootRestoresExactlyThePriorLiveSetOnce() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.observe(second)

        let firstPlan = coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: [])
        let duplicatePlan = coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: [])

        XCTAssertEqual(firstPlan, [first, second])
        XCTAssertEqual(duplicatePlan, [])
        XCTAssertEqual(coordinator.snapshot.state, .claimed)
        XCTAssertEqual(coordinator.snapshot.attemptedSessionIDs, ["session-a", "session-b"])
    }

    func testSameBootLaunchNeverRestoresSessions() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)

        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-1", liveSessionIDs: []),
            []
        )
        XCTAssertEqual(coordinator.snapshot.state, .active)
    }

    func testSameBootSessionUUIDPreservesGenerationAndNeverClaims() {
        let bootID = "AABBCCDD-EEFF-4011-9234-0123456789AB"
        var coordinator = PiRebootRestorationCoordinator(
            snapshot: PiRestorationSnapshot(
                bootID: bootID,
                generationID: "generation-1",
                sessionsByID: [first.sessionId: first]
            )
        )

        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: bootID, liveSessionIDs: []),
            []
        )
        XCTAssertEqual(coordinator.snapshot.generationID, "generation-1")
        XCTAssertEqual(coordinator.snapshot.state, .active)
        XCTAssertEqual(coordinator.snapshot.sessionsByID, [first.sessionId: first])
    }

    func testDifferentBootSessionUUIDClaimsGenerationAtMostOnce() {
        let priorBootID = "AABBCCDD-EEFF-4011-9234-0123456789AB"
        let currentBootID = "11111111-2222-4333-8444-555555555555"
        var coordinator = PiRebootRestorationCoordinator(
            snapshot: PiRestorationSnapshot(
                bootID: priorBootID,
                generationID: "generation-1",
                sessionsByID: [first.sessionId: first]
            )
        )

        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: currentBootID, liveSessionIDs: []),
            [first]
        )
        XCTAssertEqual(coordinator.claimRestorePlan(
            currentBootID: currentBootID,
            liveSessionIDs: []
        ), [])
        XCTAssertEqual(coordinator.snapshot.state, .claimed)
        XCTAssertEqual(coordinator.snapshot.bootID, priorBootID)
        XCTAssertEqual(coordinator.snapshot.generationID, "generation-1")
    }

    func testIntentionalEndRemovesSessionBeforeReboot() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.observe(second)
        coordinator.end(sessionID: first.sessionId)

        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: []),
            [second]
        )
    }

    func testInvalidHeartbeatPathRemovesStaleEntryAndLaterRegularFileCanReadd() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionFile = directory.appendingPathComponent("session.jsonl")
        var coordinator = PiRebootRestorationCoordinator(
            bootID: "boot-1",
            generationID: "generation-1"
        )
        coordinator.observe(first)

        XCTAssertFalse(
            PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: sessionFile.path)
        )
        coordinator.end(sessionID: first.sessionId)
        XCTAssertNil(coordinator.snapshot.sessionsByID[first.sessionId])

        try Data().write(to: sessionFile)
        XCTAssertTrue(
            PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: sessionFile.path)
        )
        let restored = PiRestorableSession(
            sessionId: first.sessionId,
            sessionFile: sessionFile.path,
            cwd: first.cwd,
            sessionName: first.sessionName,
            layout: first.layout,
            observedAt: first.observedAt
        )
        coordinator.observe(restored)

        XCTAssertEqual(coordinator.snapshot.sessionsByID[first.sessionId], restored)
    }

    func testPowerOffFreezeIgnoresTeardownEnds() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.freezeForSystemPowerOff(at: Date(timeIntervalSince1970: 120))
        coordinator.end(sessionID: first.sessionId)

        XCTAssertEqual(coordinator.snapshot.state, .frozen)
        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: []),
            [first]
        )
    }

    func testCleanAppTerminationOutsidePowerOffInvalidatesRestore() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.invalidateForCleanAppTermination()

        XCTAssertEqual(coordinator.snapshot.state, .invalidated)
        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: []),
            []
        )
    }

    func testSessionReplacementKeepsOnlyNewExactIdentity() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.replace(sessionID: first.sessionId, with: second)

        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: "boot-2", liveSessionIDs: []),
            [second]
        )
    }

    func testAlreadyLiveSessionIsSuppressedFromRestorePlan() {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)
        coordinator.observe(second)

        XCTAssertEqual(
            coordinator.claimRestorePlan(
                currentBootID: "boot-2",
                liveSessionIDs: [second.sessionId]
            ),
            [first]
        )
        XCTAssertEqual(coordinator.snapshot.attemptedSessionIDs, ["session-a"])
    }

    func testSnapshotRoundTripsWithoutConversationContent() throws {
        var coordinator = PiRebootRestorationCoordinator(bootID: "boot-1", generationID: "generation-1")
        coordinator.observe(first)

        let encoded = try JSONEncoder().encode(coordinator.snapshot)
        let restored = try JSONDecoder().decode(PiRestorationSnapshot.self, from: encoded)

        XCTAssertEqual(restored, coordinator.snapshot)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("prompt"))
        XCTAssertFalse(json.contains("tool"))
        XCTAssertFalse(json.contains("message"))
    }
}
