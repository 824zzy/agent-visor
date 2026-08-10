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

    func testActivationPersistsOnlyTheFirstAcknowledgmentOfACompletion() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))

        XCTAssertTrue(source.contains("readyAcknowledgmentDefaultsKey"))
        XCTAssertTrue(source.contains("readyAcknowledgedAt(for: session)"))
        XCTAssertTrue(source.contains("PillCompletionAttentionPolicy.acknowledgmentDateAfterActivation"))
        XCTAssertTrue(source.contains("nextReadyAcknowledgment != existingReadyAcknowledgment"))
        XCTAssertTrue(source.contains("scheduleCompletionPositionRefresh()"))
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

    func testPublishedReadySessionsPersistCompletionIdentityForPills() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))
        let monitor = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/ClaudeSessionMonitor.swift"
        ))

        XCTAssertTrue(sideContent.contains("completionDefaultsKey"))
        XCTAssertTrue(sideContent.contains("func observe(_ sessions: [SessionState])"))
        XCTAssertTrue(sideContent.contains("PillCompletionObservationPolicy.completionDateAfterObservation"))
        XCTAssertTrue(monitor.contains("SessionNavigationRecencyStore.shared.observe(sessions)"))
        XCTAssertTrue(sideContent.contains(
            "completedAt: SessionNavigationRecencyStore.shared.completionDate(for: session)"
        ))
    }

    func testMenuBarDotUsesCompletionAttentionWithoutChangingBrowserDots() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let dot = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/SessionStatusDot.swift"
        ))
        let sideContent = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))

        XCTAssertTrue(dot.contains("enum SessionStatusSurface"))
        XCTAssertTrue(dot.contains("case menuBarPill"))
        XCTAssertTrue(dot.contains("PillCompletionAttentionPolicy.shouldPulse"))
        XCTAssertTrue(dot.contains("PillCompletionAttentionPolicy.state"))
        XCTAssertTrue(sideContent.contains("surface: .menuBarPill"))
        XCTAssertTrue(dot.contains("var surface: SessionStatusSurface = .standard"))
    }

    func testOverflowPillSignalsHiddenUnseenCompletionWithoutUsingMoreWidth() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))
        let notchView = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/NotchView.swift"
        ))

        XCTAssertTrue(sideContent.contains("let overflowContainsUnseenCompletion: Bool"))
        XCTAssertTrue(sideContent.contains("completionAttention(for: session) == .unseen"))
        XCTAssertTrue(sideContent.contains("let hasUnseenCompletion: Bool"))
        XCTAssertTrue(sideContent.contains(".overlay(alignment: .topTrailing)"))
        XCTAssertTrue(notchView.contains(
            "overflowContainsUnseenCompletion: pack.overflowContainsUnseenCompletion"
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
