import Foundation

public enum PiRestorationSessionFilePolicy {
    public static func isPersistedRegularFile(
        atPath path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard !path.isEmpty,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileType = attributes[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeRegular
    }

    public static func sanitizing(
        _ snapshot: PiRestorationSnapshot,
        fileManager: FileManager = .default
    ) -> PiRestorationSnapshot {
        var sanitized = snapshot
        sanitized.sessionsByID = snapshot.sessionsByID.filter { _, session in
            isPersistedRegularFile(
                atPath: session.sessionFile,
                fileManager: fileManager
            )
        }
        return sanitized
    }
}
