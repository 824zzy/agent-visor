import Foundation
import XCTest
@testable import AgentVisorCore

final class PiRestorationSnapshotStoreTests: XCTestCase {
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
        let expected = snapshot()
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
            bootID: "boot",
            generationID: "future"
        )
        try JSONEncoder().encode(future).write(to: fileURL)
        XCTAssertNil(try store.load())
    }

    private func snapshot(generationID: String = "generation") -> PiRestorationSnapshot {
        PiRestorationSnapshot(
            bootID: "boot",
            generationID: generationID,
            sessionsByID: [
                "session": PiRestorableSession(
                    sessionId: "session",
                    sessionFile: "/tmp/session.jsonl",
                    cwd: "/tmp/project",
                    sessionName: "Session",
                    layout: nil,
                    observedAt: Date(timeIntervalSince1970: 123)
                )
            ]
        )
    }
}
