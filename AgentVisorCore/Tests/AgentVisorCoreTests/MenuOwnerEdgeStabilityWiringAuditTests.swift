import Foundation
import XCTest

/// Locks the left pill-bar boundary to the stabilized (held) menu-owner edge so
/// it cannot regress to consuming the raw per-probe snapshot, which collapsed
/// `leftSafe` to 0/256 on multi-display transients and flapped pills in and out.
final class MenuOwnerEdgeStabilityWiringAuditTests: XCTestCase {
    func testCoordinatorSafeWidthUsesTheHeldEdgeAndFeedsTheHoldPolicy() throws {
        let source = try String(contentsOf: repoRoot()
            .appendingPathComponent("AgentVisor/Services/MenuBar/NotchMenuLayoutCoordinator.swift"))

        // The hold policy seeds and updates the stabilized edge.
        XCTAssertTrue(source.contains("MenuOwnerEdgeHoldPolicy.begin("))
        XCTAssertTrue(source.contains("MenuOwnerEdgeHoldPolicy.applying("))
        XCTAssertTrue(source.contains("@Published private(set) var stableMenuOwnerEdge"))

        // safeWidth consumes the stabilized edge, not the raw snapshot.
        guard let start = source.range(of: "func safeWidth(available: CGFloat")?.lowerBound,
              let end = source.range(
                of: "func statusTraySafeWidth(",
                range: start..<source.endIndex
              )?.lowerBound else {
            return XCTFail("Could not isolate safeWidth.")
        }
        let safeWidth = String(source[start..<end])
        XCTAssertTrue(
            safeWidth.contains("stableMenuOwnerEdge"),
            "safeWidth must consume the held edge."
        )
        XCTAssertFalse(
            safeWidth.contains("NotchMenuLayoutPolicy.safeWidth("),
            "safeWidth must not read the raw per-probe snapshot edge."
        )

        // The stabilized edge is refreshed on probe ticks and after apply.
        let refreshCalls = source.components(separatedBy: "refreshStableEdge(screenRect:").count - 1
        XCTAssertGreaterThanOrEqual(
            refreshCalls,
            3,
            "refreshStableEdge must be defined and called from both the probe tick and apply."
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
