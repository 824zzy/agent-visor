import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class TransientPopoverHitRegionPolicyTests: XCTestCase {
    func testMatchingEventWindowIsInsideWithoutAFrameMatch() {
        XCTAssertTrue(
            TransientPopoverHitRegionPolicy.isInside(
                eventWindowMatches: true,
                screenPoint: CGPoint(x: 900, y: 900),
                visiblePopoverFrames: []
            )
        )
    }

    func testGlobalEventInsideVisiblePopoverFrameIsInside() {
        XCTAssertTrue(
            TransientPopoverHitRegionPolicy.isInside(
                eventWindowMatches: false,
                screenPoint: CGPoint(x: 140, y: 160),
                visiblePopoverFrames: [CGRect(x: 100, y: 100, width: 200, height: 120)]
            )
        )
    }

    func testGlobalEventOutsideVisiblePopoverFramesIsOutside() {
        XCTAssertFalse(
            TransientPopoverHitRegionPolicy.isInside(
                eventWindowMatches: false,
                screenPoint: CGPoint(x: 40, y: 40),
                visiblePopoverFrames: [CGRect(x: 100, y: 100, width: 200, height: 120)]
            )
        )
    }

    func testNegativeDisplayCoordinatesAreSupported() {
        XCTAssertTrue(
            TransientPopoverHitRegionPolicy.isInside(
                eventWindowMatches: false,
                screenPoint: CGPoint(x: -1_200, y: 300),
                visiblePopoverFrames: [CGRect(x: -1_440, y: 0, width: 1_440, height: 900)]
            )
        )
    }
}
