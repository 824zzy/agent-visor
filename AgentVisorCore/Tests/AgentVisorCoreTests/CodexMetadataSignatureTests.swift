import XCTest
@testable import AgentVisorCore

final class CodexMetadataSignatureTests: XCTestCase {
    func testDifferentFilesCannotCancelEachOtherOutLikeAnAdditiveSignature() {
        let first = CodexMetadataSignature(
            databasePath: "/a/state.sqlite",
            database: .init(modifiedAt: 10, size: 20),
            wal: .init(modifiedAt: 30, size: 40),
            sessionIndex: .init(modifiedAt: 50, size: 60)
        )
        let sameOldSumButDifferentFiles = CodexMetadataSignature(
            databasePath: "/a/state.sqlite",
            database: .init(modifiedAt: 30, size: 40),
            wal: .init(modifiedAt: 10, size: 20),
            sessionIndex: .init(modifiedAt: 50, size: 60)
        )

        XCTAssertNotEqual(first, sameOldSumButDifferentFiles)
    }

    func testDatabaseRelocationInvalidatesTheSnapshot() {
        let stamp = CodexMetadataFileStamp(modifiedAt: 10, size: 20)
        let flat = CodexMetadataSignature(
            databasePath: "/home/.codex/state.sqlite",
            database: stamp,
            wal: .missing,
            sessionIndex: .missing
        )
        let nested = CodexMetadataSignature(
            databasePath: "/home/.codex/sqlite/state.sqlite",
            database: stamp,
            wal: .missing,
            sessionIndex: .missing
        )

        XCTAssertNotEqual(flat, nested)
    }
}
