import Foundation

public struct PiRestorationSnapshotStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> PiRestorationSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(PiRestorationSnapshot.self, from: data) else {
            return nil
        }
        guard snapshot.schemaVersion == PiRestorationSnapshot.currentSchemaVersion else {
            try remove()
            return nil
        }
        guard let canonicalBootID = MacBootIdentity.canonicalize(snapshot.bootID) else {
            try remove()
            return nil
        }
        let authorized: PiRestorationSnapshot
        if canonicalBootID == snapshot.bootID {
            authorized = snapshot
        } else {
            authorized = PiRestorationSnapshot(
                schemaVersion: snapshot.schemaVersion,
                bootID: canonicalBootID,
                generationID: snapshot.generationID,
                state: snapshot.state,
                sessionsByID: snapshot.sessionsByID,
                attemptedSessionIDs: snapshot.attemptedSessionIDs,
                frozenAt: snapshot.frozenAt
            )
        }
        let sanitized = PiRestorationSessionFilePolicy.sanitizing(authorized)
        if sanitized != snapshot {
            try save(sanitized)
        }
        return sanitized
    }

    public func save(_ snapshot: PiRestorationSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    /// Removes restoration authority. Missing snapshots are already clean.
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
