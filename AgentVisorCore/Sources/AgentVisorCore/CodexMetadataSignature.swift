import Foundation

public struct CodexMetadataFileStamp: Equatable, Sendable {
    public let modifiedAt: TimeInterval
    public let size: UInt64

    public init(modifiedAt: TimeInterval, size: UInt64) {
        self.modifiedAt = modifiedAt
        self.size = size
    }

    public static let missing = CodexMetadataFileStamp(modifiedAt: 0, size: 0)
}

public struct CodexMetadataSignature: Equatable, Sendable {
    public let databasePath: String
    public let database: CodexMetadataFileStamp
    public let wal: CodexMetadataFileStamp
    public let sessionIndex: CodexMetadataFileStamp

    public init(
        databasePath: String,
        database: CodexMetadataFileStamp,
        wal: CodexMetadataFileStamp,
        sessionIndex: CodexMetadataFileStamp
    ) {
        self.databasePath = databasePath
        self.database = database
        self.wal = wal
        self.sessionIndex = sessionIndex
    }
}
