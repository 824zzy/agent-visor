import XCTest

final class ReadyAttentionWiringAuditTests: XCTestCase {
    func testStatusIndicatorsStopPulsingAfterSessionNavigation() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let sources = try [
            "AgentVisor/UI/Components/SessionStatusDot.swift",
            "AgentVisor/UI/Components/SessionStatusStripe.swift"
        ].map { path in
            try String(contentsOf: root.appendingPathComponent(path))
        }

        for source in sources {
            XCTAssertTrue(source.contains("@ObservedObject private var navigationRecencyStore"))
            XCTAssertTrue(source.contains("navigationRecencyStore.readyAcknowledgedAt(for: session)"))
            XCTAssertTrue(source.contains("ReadyAttentionPolicy.shouldPulse"))
        }
    }

    func testReadyNavigationPersistsOnlyTheFirstAcknowledgmentOfATransition() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))

        XCTAssertTrue(source.contains("readyAcknowledgmentDefaultsKey"))
        XCTAssertTrue(source.contains("readyAcknowledgedAt(for: session)"))
        XCTAssertTrue(source.contains("ReadyAttentionPolicy.acknowledgmentDateAfterNavigation"))
        XCTAssertTrue(source.contains("nextReadyAcknowledgment != existingReadyAcknowledgment"))
        XCTAssertTrue(source.contains("scheduleReadyPositionRefresh(for: session)"))
        XCTAssertTrue(source.contains("ReadyAttentionPolicy.defaultPositionHold"))
        XCTAssertTrue(source.contains("DispatchQueue.main.asyncAfter"))
    }

    func testPillOrderingUsesReadyAcknowledgmentSeparatelyFromNavigationRecency() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))

        XCTAssertTrue(source.contains(
            "navigationDate: SessionNavigationRecencyStore.shared.date(for: session)"
        ))
        XCTAssertTrue(source.contains(
            "readyAcknowledgedAt: SessionNavigationRecencyStore.shared.readyAcknowledgedAt(for: session)"
        ))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
