import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class NotchMenuLayoutPolicyTests: XCTestCase {
    private let margin: CGFloat = 28

    func testLocalOwnerEdgeKeepsLeftPillsAvailableWhenSelfAXCannotProbe() {
        let snapshot = NotchMenuLayoutPolicy.begin(
            generation: 1,
            targetScreenID: "notch",
            ownerBundleID: "com.824zzy.AgentVisor",
            ownerIsResolved: true,
            cachedOwnerEdge: nil,
            localOwnerEdge: 343
        )

        XCTAssertEqual(snapshot.evidence?.source, .ownerLocalMenu)
        XCTAssertEqual(
            NotchMenuLayoutPolicy.safeWidth(
                available: 912,
                snapshot: snapshot,
                margin: margin
            ),
            541
        )
    }

    func testFreshLocalOwnerMeasurementRefinesTheInitialEstimate() {
        let initial = NotchMenuLayoutPolicy.begin(
            generation: 2,
            targetScreenID: "notch",
            ownerBundleID: "com.824zzy.AgentVisor",
            ownerIsResolved: true,
            cachedOwnerEdge: nil,
            localOwnerEdge: 344
        )
        let refined = NotchMenuLayoutPolicy.applying(
            NotchMenuEdgeEvidence(
                generation: 2,
                requestID: 1,
                ownerBundleID: "com.824zzy.AgentVisor",
                edge: 351,
                source: .ownerLocalMenu
            ),
            to: initial
        )

        XCTAssertEqual(NotchMenuLayoutPolicy.renderedEdge(for: refined), 351)
    }

    func testResolvedOwnerCrossScreenMeasurementIgnoresUnrelatedFrontmostCache() {
        let snapshot = NotchMenuLayoutPolicy.begin(
            generation: 1,
            targetScreenID: "notch",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            cachedOwnerEdge: nil
        )
        let measured = NotchMenuLayoutPolicy.applying(
            NotchMenuEdgeEvidence(
                generation: 1,
                ownerBundleID: "com.openai.codex",
                edge: 375,
                source: .ownerAccessibility(onTargetScreen: false)
            ),
            to: snapshot
        )

        XCTAssertEqual(
            NotchMenuLayoutPolicy.safeWidth(
                available: 912,
                snapshot: measured,
                margin: 28
            ),
            509
        )
    }

    func testOwnerEvidenceForAnotherAppIsNeverRendered() {
        let snapshot = NotchMenuLayoutSnapshot(
            generation: 2,
            targetScreenID: "notch",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            evidence: NotchMenuEdgeEvidence(
                generation: 2,
                ownerBundleID: "com.google.Chrome",
                edge: 628,
                source: .ownerCache
            )
        )

        XCTAssertEqual(
            NotchMenuLayoutPolicy.safeWidth(
                available: 912,
                snapshot: snapshot,
                margin: 28
            ),
            0
        )
    }

    func testOlderProbeCannotOverwriteNewerEvidenceInSameGeneration() {
        let initial = NotchMenuLayoutPolicy.begin(
            generation: 3,
            targetScreenID: "notch",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            cachedOwnerEdge: nil
        )
        let newest = NotchMenuLayoutPolicy.applying(
            NotchMenuEdgeEvidence(
                generation: 3,
                requestID: 2,
                ownerBundleID: "com.openai.codex",
                edge: 375,
                source: .ownerAccessibility(onTargetScreen: false)
            ),
            to: initial
        )
        let afterLateOlderProbe = NotchMenuLayoutPolicy.applying(
            NotchMenuEdgeEvidence(
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
        let snapshot = NotchMenuLayoutPolicy.begin(
            generation: 4,
            targetScreenID: "notch",
            ownerBundleID: "com.google.Chrome",
            ownerIsResolved: true,
            cachedOwnerEdge: 628
        )

        XCTAssertEqual(
            NotchMenuLayoutPolicy.safeWidth(
                available: 912,
                snapshot: snapshot,
                margin: margin
            ),
            256
        )
    }

    func testUnresolvedOwnerNeverUsesItsCache() {
        let snapshot = NotchMenuLayoutPolicy.begin(
            generation: 5,
            targetScreenID: "notch",
            ownerBundleID: "com.google.Chrome",
            ownerIsResolved: false,
            cachedOwnerEdge: 628
        )

        XCTAssertEqual(
            NotchMenuLayoutPolicy.safeWidth(
                available: 912,
                snapshot: snapshot,
                margin: margin
            ),
            0
        )
    }

    func testScreenLocalFallbackCanRenderWhenOwnerIsUnresolved() {
        let initial = NotchMenuLayoutPolicy.begin(
            generation: 6,
            targetScreenID: "notch",
            ownerBundleID: nil,
            ownerIsResolved: false,
            cachedOwnerEdge: nil
        )
        let measured = NotchMenuLayoutPolicy.applying(
            NotchMenuEdgeEvidence(
                generation: 6,
                requestID: 1,
                ownerBundleID: nil,
                edge: 400,
                source: .screenWindowList
            ),
            to: initial
        )

        XCTAssertEqual(
            NotchMenuLayoutPolicy.safeWidth(
                available: 912,
                snapshot: measured,
                margin: margin
            ),
            484
        )
    }

    func testPreviousGenerationCannotOverwriteNewOwner() {
        let current = NotchMenuLayoutPolicy.begin(
            generation: 8,
            targetScreenID: "notch",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            cachedOwnerEdge: 375
        )
        let afterStaleChromeProbe = NotchMenuLayoutPolicy.applying(
            NotchMenuEdgeEvidence(
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
        let unknown = NotchMenuLayoutPolicy.begin(
            generation: 9,
            targetScreenID: "notch",
            ownerBundleID: nil,
            ownerIsResolved: false,
            cachedOwnerEdge: nil
        )
        let overfull = NotchMenuLayoutPolicy.applying(
            NotchMenuEdgeEvidence(
                generation: 9,
                requestID: 1,
                ownerBundleID: nil,
                edge: 912,
                source: .screenWindowList
            ),
            to: unknown
        )

        XCTAssertEqual(
            NotchMenuLayoutPolicy.safeWidth(
                available: 912,
                snapshot: unknown,
                margin: margin
            ),
            0
        )
        XCTAssertEqual(
            NotchMenuLayoutPolicy.safeWidth(
                available: 912,
                snapshot: overfull,
                margin: margin
            ),
            0
        )
    }

    func testRepeatedProbeRequestDoesNotChangeRenderedEdge() {
        let initial = NotchMenuLayoutPolicy.begin(
            generation: 10,
            targetScreenID: "notch",
            ownerBundleID: "com.openai.codex",
            ownerIsResolved: true,
            cachedOwnerEdge: nil
        )
        let first = NotchMenuLayoutPolicy.applying(
            NotchMenuEdgeEvidence(
                generation: 10,
                requestID: 1,
                ownerBundleID: "com.openai.codex",
                edge: 375,
                source: .ownerAccessibility(onTargetScreen: false)
            ),
            to: initial
        )
        let second = NotchMenuLayoutPolicy.applying(
            NotchMenuEdgeEvidence(
                generation: 10,
                requestID: 2,
                ownerBundleID: "com.openai.codex",
                edge: 375,
                source: .ownerAccessibility(onTargetScreen: false)
            ),
            to: first
        )

        XCTAssertEqual(
            NotchMenuLayoutPolicy.renderedEdge(for: first),
            NotchMenuLayoutPolicy.renderedEdge(for: second)
        )
    }
}
