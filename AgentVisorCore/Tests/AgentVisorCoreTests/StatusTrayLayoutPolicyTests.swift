import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class StatusTrayLayoutPolicyTests: XCTestCase {
    func testUnavailableObservationKeepsLastReliableEdgeOnSameScreen() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterUnavailableProbe = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: nil,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )

        XCTAssertEqual(afterUnavailableProbe, initial)
    }

    func testUnavailableObservationOnAnotherScreenInvalidatesOldEdge() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterScreenChange = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: nil,
            observedAt: 10,
            targetScreenID: "display-1",
            to: initial
        )

        XCTAssertEqual(
            afterScreenChange,
            StatusTrayLayoutSnapshot(
                targetScreenID: "display-1",
                leftEdge: nil
            )
        )
    }

    func testSafeWidthUsesLastReliableEdge() {
        let snapshot = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )

        XCTAssertEqual(
            StatusTrayLayoutPolicy.safeWidth(
                availableFrom: 1_144,
                snapshot: snapshot,
                margin: 16
            ),
            451
        )
    }

    func testNonPositiveObservationDoesNotReplaceReliableEdge() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterInvalidProbe = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 0,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )

        XCTAssertEqual(afterInvalidProbe, initial)
    }

    func testWiderReliableObservationReplacesStoredEdgeImmediately() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterTrayChanged = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_680,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )

        XCTAssertEqual(afterTrayChanged.leftEdge, 1_680)
    }

    func testUnknownInitialEdgeFailsSafeToZeroWidth() {
        let snapshot = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: nil
        )

        XCTAssertEqual(
            StatusTrayLayoutPolicy.safeWidth(
                availableFrom: 1_144,
                snapshot: snapshot,
                margin: 16
            ),
            0
        )
    }

    func testSingleNarrowerObservationDoesNotCollapseReliableEdge() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterTransientContraction = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_150,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )

        XCTAssertEqual(afterTransientContraction.leftEdge, 1_611)
        XCTAssertEqual(
            StatusTrayLayoutPolicy.safeWidth(
                availableFrom: 1_144,
                snapshot: afterTransientContraction,
                margin: 16
            ),
            451
        )
    }

    func testPersistentNarrowerObservationEventuallyApplies() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterFirstContraction = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_150,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )
        let afterConfirmedContraction = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_150,
            observedAt: 10.8,
            targetScreenID: "display-4",
            to: afterFirstContraction
        )

        XCTAssertEqual(afterConfirmedContraction.leftEdge, 1_150)
        XCTAssertNil(afterConfirmedContraction.pendingContractionSince)
        XCTAssertEqual(
            StatusTrayLayoutPolicy.safeWidth(
                availableFrom: 1_144,
                snapshot: afterConfirmedContraction,
                margin: 16
            ),
            0
        )
    }

    func testUnavailableObservationCancelsPendingContraction() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterContraction = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_150,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )
        let afterUnavailableProbe = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: nil,
            observedAt: 10.4,
            targetScreenID: "display-4",
            to: afterContraction
        )

        XCTAssertEqual(afterUnavailableProbe.leftEdge, 1_611)
        XCTAssertNil(afterUnavailableProbe.pendingContractionSince)
    }

    func testChangedContractionRestartsConfirmationWindow() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterFirstContraction = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_150,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )
        let afterChangedContraction = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_200,
            observedAt: 10.8,
            targetScreenID: "display-4",
            to: afterFirstContraction
        )

        XCTAssertEqual(afterChangedContraction.leftEdge, 1_611)
        XCTAssertEqual(afterChangedContraction.pendingContractionSince, 10.8)
    }

    func testWiderObservationCancelsPendingContraction() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterContraction = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_150,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )
        let afterRecovery = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_680,
            observedAt: 10.4,
            targetScreenID: "display-4",
            to: afterContraction
        )

        XCTAssertEqual(afterRecovery.leftEdge, 1_680)
        XCTAssertNil(afterRecovery.pendingContractionEdge)
        XCTAssertNil(afterRecovery.pendingContractionSince)
    }

    func testScreenChangeDoesNotCarryPendingContraction() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: 1_611
        )
        let afterContraction = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_150,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )
        let afterScreenChange = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_850,
            observedAt: 10.2,
            targetScreenID: "display-1",
            to: afterContraction
        )

        XCTAssertEqual(afterScreenChange.targetScreenID, "display-1")
        XCTAssertEqual(afterScreenChange.leftEdge, 1_850)
        XCTAssertNil(afterScreenChange.pendingContractionEdge)
        XCTAssertNil(afterScreenChange.pendingContractionSince)
    }

    func testFirstReliableObservationPopulatesUnknownSnapshotImmediately() {
        let initial = StatusTrayLayoutPolicy.begin(
            targetScreenID: "display-4",
            observedLeftEdge: nil
        )
        let afterReliableProbe = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: 1_611,
            observedAt: 10,
            targetScreenID: "display-4",
            to: initial
        )

        XCTAssertEqual(afterReliableProbe.leftEdge, 1_611)
        XCTAssertNil(afterReliableProbe.pendingContractionEdge)
        XCTAssertNil(afterReliableProbe.pendingContractionSince)
    }
}
