import XCTest
@testable import AgentVisorCore

final class ComposerCancellationCapabilityPolicyTests: XCTestCase {
    func testCompactionIsExplicitlyFailClosed() {
        let availability = ComposerCancellationCapabilityPolicy.availability(
            phase: .compacting
        )

        XCTAssertFalse(availability.canCancel)
        XCTAssertEqual(availability.reason, "Context compaction cannot be stopped from the composer.")
        XCTAssertEqual(availability.accessibilityLabel, "Stopping unavailable while context is compacting")
    }

    func testProcessingIsCancellableButIdleAndEndedAreNot() {
        XCTAssertTrue(ComposerCancellationCapabilityPolicy.availability(phase: .processing).canCancel)
        XCTAssertFalse(ComposerCancellationCapabilityPolicy.availability(phase: .idle).canCancel)
        XCTAssertFalse(ComposerCancellationCapabilityPolicy.availability(phase: .ended).canCancel)
    }

    func testEscapeRoutingConsumesCompactionWithoutClearingDraft() {
        XCTAssertEqual(
            ComposerCancellationCapabilityPolicy.escapeAction(phase: .processing),
            .cancel
        )
        XCTAssertEqual(
            ComposerCancellationCapabilityPolicy.escapeAction(phase: .compacting),
            .consumeCompaction
        )
        XCTAssertEqual(
            ComposerCancellationCapabilityPolicy.escapeAction(phase: .idle),
            .clearDraft
        )
    }

    func testProcessingStopRequiresVerifiedSupportedTerminalRoute() {
        XCTAssertTrue(
            ComposerCancellationCapabilityPolicy.availability(
                phase: .processing,
                terminalHost: .terminalApp,
                hasVerifiedTarget: true
            ).canCancel
        )
        XCTAssertFalse(
            ComposerCancellationCapabilityPolicy.availability(
                phase: .processing,
                terminalHost: .terminalApp,
                hasVerifiedTarget: false
            ).canCancel
        )
        XCTAssertFalse(
            ComposerCancellationCapabilityPolicy.availability(
                phase: .processing,
                terminalHost: .codexApp,
                hasVerifiedTarget: true
            ).canCancel
        )
    }

    func testTerminalAppRouteIsNotGhosttyFallback() {
        let availability = ComposerCancellationCapabilityPolicy.availability(
            phase: .processing,
            terminalHost: .terminalApp,
            hasVerifiedTarget: true
        )
        XCTAssertEqual(availability.accessibilityLabel, "Stop the working turn")
    }
}
