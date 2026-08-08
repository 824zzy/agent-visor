import Foundation
import XCTest
@testable import AgentVisorCore

final class PiRestorationSnapshotStoreTests: XCTestCase {
    private let bootID = "AABBCCDD-EEFF-4011-9234-0123456789AB"
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-restore-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("snapshot.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSavedSnapshotCanBeLoadedExactly() throws {
        let expected = try snapshot()
        let store = PiRestorationSnapshotStore(fileURL: fileURL)

        try store.save(expected)

        XCTAssertEqual(try store.load(), expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSecondSaveAtomicallyReplacesThePriorGeneration() throws {
        let store = PiRestorationSnapshotStore(fileURL: fileURL)
        try store.save(snapshot(generationID: "old"))
        try store.save(snapshot(generationID: "new"))

        XCTAssertEqual(try store.load()?.generationID, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + ".tmp"))
    }

    func testTruncatedOrFutureSnapshotFailsClosed() throws {
        let store = PiRestorationSnapshotStore(fileURL: fileURL)
        try Data("{\"schemaVersion\":".utf8).write(to: fileURL)
        XCTAssertNil(try store.load())

        let future = PiRestorationSnapshot(
            schemaVersion: PiRestorationSnapshot.currentSchemaVersion + 1,
            bootID: bootID,
            generationID: "future"
        )
        try JSONEncoder().encode(future).write(to: fileURL)
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSchemaTwoDecimalSnapshotIsDurablyDiscarded() throws {
        XCTAssertEqual(PiRestorationSnapshot.currentSchemaVersion, 3)
        let legacy = PiRestorationSnapshot(
            schemaVersion: 2,
            bootID: "1785910406.669682",
            generationID: "legacy"
        )
        try JSONEncoder().encode(legacy).write(to: fileURL)

        XCTAssertNil(try PiRestorationSnapshotStore(fileURL: fileURL).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testLowercaseBootUUIDCanonicalizesBeforeSameBootClaim() throws {
        let lowercaseBootID = "aabbccdd-eeff-4011-9234-0123456789ab"
        let canonicalBootID = "AABBCCDD-EEFF-4011-9234-0123456789AB"
        let original = PiRestorationSnapshot(
            bootID: lowercaseBootID,
            generationID: "generation-1"
        )
        try JSONEncoder().encode(original).write(to: fileURL)

        let loaded = try XCTUnwrap(PiRestorationSnapshotStore(fileURL: fileURL).load())
        var coordinator = PiRebootRestorationCoordinator(snapshot: loaded)

        XCTAssertEqual(loaded.bootID, canonicalBootID)
        XCTAssertEqual(
            coordinator.claimRestorePlan(currentBootID: canonicalBootID, liveSessionIDs: []),
            []
        )
        XCTAssertEqual(coordinator.snapshot.generationID, "generation-1")
        XCTAssertEqual(coordinator.snapshot.state, .active)
        let persisted = try JSONDecoder().decode(
            PiRestorationSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(persisted.bootID, canonicalBootID)
    }

    func testMalformedSchemaThreeBootUUIDIsDurablyDiscarded() throws {
        let malformed = PiRestorationSnapshot(
            bootID: "not-a-boot-session-uuid",
            generationID: "unsafe"
        )
        try JSONEncoder().encode(malformed).write(to: fileURL)

        XCTAssertNil(try PiRestorationSnapshotStore(fileURL: fileURL).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testBootUUIDCanonicalizationSaveFailureThrowsAndLeavesOriginal() throws {
        let original = PiRestorationSnapshot(
            bootID: "aabbccdd-eeff-4011-9234-0123456789ab",
            generationID: "generation-1"
        )
        try JSONEncoder().encode(original).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }

        XCTAssertThrowsError(try PiRestorationSnapshotStore(fileURL: fileURL).load())
        let unchanged = try JSONDecoder().decode(
            PiRestorationSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(unchanged, original)
    }

    func testRemoveDeletesExistingSnapshotAndMissingSnapshotIsIdempotent() throws {
        let store = PiRestorationSnapshotStore(fileURL: fileURL)
        try store.save(snapshot())

        try store.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNoThrow(try store.remove())
    }

    func testRemoveReportsDurableCleanupFailure() throws {
        let store = PiRestorationSnapshotStore(fileURL: fileURL)
        try store.save(snapshot())
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }

        XCTAssertThrowsError(try store.remove())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testLoadRemovesOnlyMissingSessionFilesAndPersistsSanitizedSnapshot() throws {
        let validFile = try persistedSessionFile(named: "valid.jsonl")
        let frozenAt = Date(timeIntervalSince1970: 456)
        let original = PiRestorationSnapshot(
            bootID: bootID,
            generationID: "generation",
            state: .frozen,
            sessionsByID: [
                "valid": restorableSession(id: "valid", sessionFile: validFile.path),
                "missing": restorableSession(
                    id: "missing",
                    sessionFile: directory.appendingPathComponent("missing.jsonl").path
                )
            ],
            attemptedSessionIDs: ["already-attempted", "missing"],
            frozenAt: frozenAt
        )
        let store = PiRestorationSnapshotStore(fileURL: fileURL)
        try store.save(original)

        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(Set(loaded.sessionsByID.keys), Set(["valid"]))
        XCTAssertEqual(loaded.state, .frozen)
        XCTAssertEqual(loaded.attemptedSessionIDs, ["already-attempted", "missing"])
        XCTAssertEqual(loaded.frozenAt, frozenAt)
        XCTAssertEqual(loaded.bootID, original.bootID)
        XCTAssertEqual(loaded.generationID, original.generationID)

        let persisted = try JSONDecoder().decode(
            PiRestorationSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(persisted, loaded)
    }

    func testLoadPersistsEmptySessionSetWhenEveryPathIsInvalid() throws {
        let original = PiRestorationSnapshot(
            bootID: bootID,
            generationID: "generation",
            state: .claimed,
            sessionsByID: [
                "missing-a": restorableSession(
                    id: "missing-a",
                    sessionFile: directory.appendingPathComponent("missing-a.jsonl").path
                ),
                "missing-b": restorableSession(
                    id: "missing-b",
                    sessionFile: directory.appendingPathComponent("missing-b.jsonl").path
                )
            ],
            attemptedSessionIDs: ["missing-a", "missing-b"]
        )
        let store = PiRestorationSnapshotStore(fileURL: fileURL)
        try store.save(original)

        let loaded = try XCTUnwrap(store.load())

        XCTAssertTrue(loaded.sessionsByID.isEmpty)
        XCTAssertEqual(loaded.state, .claimed)
        XCTAssertEqual(loaded.attemptedSessionIDs, original.attemptedSessionIDs)
        XCTAssertEqual(try store.load(), loaded)
    }

    func testLoadThrowsWhenSanitizedSnapshotCannotBePersisted() throws {
        let missingFile = directory.appendingPathComponent("missing.jsonl")
        let original = PiRestorationSnapshot(
            bootID: bootID,
            generationID: "generation",
            sessionsByID: [
                "missing": restorableSession(
                    id: "missing",
                    sessionFile: missingFile.path
                )
            ]
        )
        let store = PiRestorationSnapshotStore(fileURL: fileURL)
        try store.save(original)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }

        XCTAssertThrowsError(try store.load())
        let unchanged = try JSONDecoder().decode(
            PiRestorationSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(unchanged, original)
    }

    private func snapshot(generationID: String = "generation") throws -> PiRestorationSnapshot {
        let sessionFile = try persistedSessionFile(named: "\(generationID).jsonl")
        return PiRestorationSnapshot(
            bootID: bootID,
            generationID: generationID,
            sessionsByID: [
                "session": PiRestorableSession(
                    sessionId: "session",
                    sessionFile: sessionFile.path,
                    cwd: "/tmp/project",
                    sessionName: "Session",
                    layout: nil,
                    observedAt: Date(timeIntervalSince1970: 123)
                )
            ]
        )
    }

    private func persistedSessionFile(named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url, options: .atomic)
        return url
    }

    private func restorableSession(id: String, sessionFile: String) -> PiRestorableSession {
        PiRestorableSession(
            sessionId: id,
            sessionFile: sessionFile,
            cwd: "/tmp/project-\(id)",
            sessionName: id,
            layout: nil,
            observedAt: Date(timeIntervalSince1970: 123)
        )
    }
}
