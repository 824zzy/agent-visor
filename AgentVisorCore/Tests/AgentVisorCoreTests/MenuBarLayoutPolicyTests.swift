import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class MenuBarLayoutPolicyTests: XCTestCase {
    private let margin: CGFloat = 28

    func testLocalOwnerEdgeKeepsLeftPillsAvailableWhenSelfAXCannotProbe() {
        let snapshot = MenuBarLayoutPolicy.begin(
            generation: 1,
            targetScreenID: "target",
            ownerBundleID: "com.824zzy.AgentVisor",
            ownerIsResolved: true,
            cachedOwnerEdge: nil,
            localOwnerEdge: 343
        )

        XCTAssertEqual(snapshot.evidence?.source, .ownerLocalMenu)
        XCTAssertEqual(
            MenuBarLayoutPolicy.safeWidth(
                available: 912,
                snapshot: snapshot,
                margin: margin
            ),
            541
        )
    }

    func testFreshLocalOwnerMeasurementRefinesTheInitialEstimate() {
        let initial = MenuBarLayoutPolicy.begin(
            generation: 2,
            targetScreenID: "target",
            ownerBundleID: "com.824zzy.AgentVisor",
            ownerIsResolved: true,
            cachedOwnerEdge: nil,
            localOwnerEdge: 344
        )
        let refined = MenuBarLayoutPolicy.applying(
            MenuBarEdgeEvidence(
                generation: 2,
                requestID: 1,
                ownerBundleID: "com.824zzy.AgentVisor",
                edge: 351,
                source: .ownerLocalMenu
            ),
            to: initial
        )

        XCTAssertEqual(MenuBarLayoutPolicy.renderedEdge(for: refined), 351)
    }

    func testResolvedOwnerCrossScreenMeasurementIgnoresUnrelatedFrontmostCache() {
        let snapshot = MenuBarLayoutPolicy.begin(
            generation: 1,
            targetScreenID: "target",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            cachedOwnerEdge: nil
        )
        let measured = MenuBarLayoutPolicy.applying(
            MenuBarEdgeEvidence(
                generation: 1,
                ownerBundleID: "com.openai.codex",
                edge: 375,
                source: .ownerAccessibility(onTargetScreen: false)
            ),
            to: snapshot
        )

        XCTAssertEqual(
            MenuBarLayoutPolicy.safeWidth(
                available: 912,
                snapshot: measured,
                margin: 28
            ),
            509
        )
    }

    func testOwnerEvidenceForAnotherAppIsNeverRendered() {
        let snapshot = MenuBarLayoutSnapshot(
            generation: 2,
            targetScreenID: "target",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            evidence: MenuBarEdgeEvidence(
                generation: 2,
                ownerBundleID: "com.google.Chrome",
                edge: 628,
                source: .ownerCache
            )
        )

        XCTAssertEqual(
            MenuBarLayoutPolicy.safeWidth(
                available: 912,
                snapshot: snapshot,
                margin: 28
            ),
            0
        )
    }

    func testOlderProbeCannotOverwriteNewerEvidenceInSameGeneration() {
        let initial = MenuBarLayoutPolicy.begin(
            generation: 3,
            targetScreenID: "target",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            cachedOwnerEdge: nil
        )
        let newest = MenuBarLayoutPolicy.applying(
            MenuBarEdgeEvidence(
                generation: 3,
                requestID: 2,
                ownerBundleID: "com.openai.codex",
                edge: 375,
                source: .ownerAccessibility(onTargetScreen: false)
            ),
            to: initial
        )
        let afterLateOlderProbe = MenuBarLayoutPolicy.applying(
            MenuBarEdgeEvidence(
                generation: 3,
                requestID: 1,
                ownerBundleID: "com.openai.codex",
                edge: 628,
                source: .ownerAccessibility(onTargetScreen: false)
            ),
            to: newest
        )

        XCTAssertEqual(afterLateOlderProbe, newest)
    }

    func testResolvedOwnerCacheIsUsedWhileFreshProbeIsPending() {
        let snapshot = MenuBarLayoutPolicy.begin(
            generation: 4,
            targetScreenID: "target",
            ownerBundleID: "com.google.Chrome",
            ownerIsResolved: true,
            cachedOwnerEdge: 628
        )

        XCTAssertEqual(
            MenuBarLayoutPolicy.safeWidth(
                available: 912,
                snapshot: snapshot,
                margin: margin
            ),
            256
        )
    }

    func testUnresolvedOwnerNeverUsesItsCache() {
        let snapshot = MenuBarLayoutPolicy.begin(
            generation: 5,
            targetScreenID: "target",
            ownerBundleID: "com.google.Chrome",
            ownerIsResolved: false,
            cachedOwnerEdge: 628
        )

        XCTAssertEqual(
            MenuBarLayoutPolicy.safeWidth(
                available: 912,
                snapshot: snapshot,
                margin: margin
            ),
            0
        )
    }

    func testScreenLocalFallbackCanRenderWhenOwnerIsUnresolved() {
        let initial = MenuBarLayoutPolicy.begin(
            generation: 6,
            targetScreenID: "target",
            ownerBundleID: nil,
            ownerIsResolved: false,
            cachedOwnerEdge: nil
        )
        let measured = MenuBarLayoutPolicy.applying(
            MenuBarEdgeEvidence(
                generation: 6,
                requestID: 1,
                ownerBundleID: nil,
                edge: 400,
                source: .screenWindowList
            ),
            to: initial
        )

        XCTAssertEqual(
            MenuBarLayoutPolicy.safeWidth(
                available: 912,
                snapshot: measured,
                margin: margin
            ),
            484
        )
    }

    func testPreviousGenerationCannotOverwriteNewOwner() {
        let current = MenuBarLayoutPolicy.begin(
            generation: 8,
            targetScreenID: "target",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            cachedOwnerEdge: 375
        )
        let afterStaleChromeProbe = MenuBarLayoutPolicy.applying(
            MenuBarEdgeEvidence(
                generation: 7,
                requestID: 99,
                ownerBundleID: "com.google.Chrome",
                edge: 628,
                source: .ownerAccessibility(onTargetScreen: true)
            ),
            to: current
        )

        XCTAssertEqual(afterStaleChromeProbe, current)
    }

    func testUnknownOrOverfullEdgesHideInsteadOfOverlapping() {
        let unknown = MenuBarLayoutPolicy.begin(
            generation: 9,
            targetScreenID: "target",
            ownerBundleID: nil,
            ownerIsResolved: false,
            cachedOwnerEdge: nil
        )
        let overfull = MenuBarLayoutPolicy.applying(
            MenuBarEdgeEvidence(
                generation: 9,
                requestID: 1,
                ownerBundleID: nil,
                edge: 912,
                source: .screenWindowList
            ),
            to: unknown
        )

        XCTAssertEqual(
            MenuBarLayoutPolicy.safeWidth(
                available: 912,
                snapshot: unknown,
                margin: margin
            ),
            0
        )
        XCTAssertEqual(
            MenuBarLayoutPolicy.safeWidth(
                available: 912,
                snapshot: overfull,
                margin: margin
            ),
            0
        )
    }

    func testRepeatedProbeRequestDoesNotChangeRenderedEdge() {
        let initial = MenuBarLayoutPolicy.begin(
            generation: 10,
            targetScreenID: "target",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            cachedOwnerEdge: nil
        )
        let first = MenuBarLayoutPolicy.applying(
            MenuBarEdgeEvidence(
                generation: 10,
                requestID: 1,
                ownerBundleID: "com.openai.codex",
                edge: 375,
                source: .ownerAccessibility(onTargetScreen: false)
            ),
            to: initial
        )
        let second = MenuBarLayoutPolicy.applying(
            MenuBarEdgeEvidence(
                generation: 10,
                requestID: 2,
                ownerBundleID: "com.openai.codex",
                edge: 375,
                source: .ownerAccessibility(onTargetScreen: false)
            ),
            to: first
        )

        XCTAssertEqual(
            MenuBarLayoutPolicy.renderedEdge(for: first),
            MenuBarLayoutPolicy.renderedEdge(for: second)
        )
    }
}
