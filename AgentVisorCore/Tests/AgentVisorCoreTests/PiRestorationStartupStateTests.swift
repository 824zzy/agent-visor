import XCTest
@testable import AgentVisorCore

final class PiRestorationStartupStateTests: XCTestCase {
    private enum SaveFailure: Error {
        case unavailable
    }

    func testInitialBaselineSaveFailureDisablesAndRevokesCoordinatorAuthority() {
        var saveAttempts = 0
        var state = PiRestorationStartupState(
            coordinator: PiRebootRestorationCoordinator(
                bootID: "AABBCCDD-EEFF-4011-9234-0123456789AB",
                generationID: "generation"
            ),
            needsInitialSnapshotPersistence: true
        )

        XCTAssertThrowsError(
            try state.persistInitialSnapshotIfNeeded { _ in
                saveAttempts += 1
                throw SaveFailure.unavailable
            }
        )

        XCTAssertEqual(saveAttempts, 1)
        XCTAssertTrue(state.isDisabled)
        XCTAssertNil(state.coordinator)
        XCTAssertTrue(state.needsInitialSnapshotPersistence)
    }

    func testInitialBaselineRequirementClearsOnlyAfterSuccessfulSave() throws {
        var persistedSnapshot: PiRestorationSnapshot?
        var state = PiRestorationStartupState(
            coordinator: PiRebootRestorationCoordinator(
                bootID: "AABBCCDD-EEFF-4011-9234-0123456789AB",
                generationID: "generation"
            ),
            needsInitialSnapshotPersistence: true
        )

        try state.persistInitialSnapshotIfNeeded { snapshot in
            persistedSnapshot = snapshot
        }

        XCTAssertEqual(persistedSnapshot?.generationID, "generation")
        XCTAssertFalse(state.isDisabled)
        XCTAssertNotNil(state.coordinator)
        XCTAssertFalse(state.needsInitialSnapshotPersistence)
    }
}
