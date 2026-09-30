import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class NativeMenuApplicationEdgePolicyTests: XCTestCase {
    private let external = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
    private let builtIn = CGRect(x: 406, y: 1_440, width: 2_056, height: 1_329)

    func testMenuMeasuredOnOtherDisplayMapsToPillDisplay() {
        let items = [
            CGRect(x: 416, y: 1_440, width: 34, height: 30),
            CGRect(x: 450, y: 1_440, width: 80, height: 30),
            CGRect(x: 530, y: 1_440, width: 40, height: 30),
            CGRect(x: 570, y: 1_440, width: 45, height: 30),
        ]

        XCTAssertEqual(
            NativeMenuApplicationEdgePolicy.rightEdge(
                targetScreen: external,
                screens: [external, builtIn],
                menuItemFrames: items
            ),
            233
        )
    }

    func testMenuMeasuredOnPillDisplayKeepsItsActualEdge() {
        let items = [
            CGRect(x: 10, y: 0, width: 34, height: 30),
            CGRect(x: 44, y: 0, width: 80, height: 30),
            CGRect(x: 124, y: 0, width: 40, height: 30),
        ]

        XCTAssertEqual(
            NativeMenuApplicationEdgePolicy.rightEdge(
                targetScreen: external,
                screens: [external, builtIn],
                menuItemFrames: items
            ),
            164
        )
    }

    func testFailedMiddleChildDoesNotShortenTheMenuToItsPrefix() {
        // Chrome reaches x=628; an unreadable Bookmarks child leaves a gap.
        let items = [
            CGRect(x: 10, y: 0, width: 34, height: 39),
            CGRect(x: 44, y: 0, width: 271, height: 39),
            CGRect(x: 403, y: 0, width: 225, height: 39),
        ]
        XCTAssertNil(NativeMenuApplicationEdgePolicy.rightEdge(
            targetScreen: external, screens: [external, builtIn], menuItemFrames: items
        ))
    }

    func testMixedDisplayReadingDoesNotUseJustTheAppleItemOnTheTarget() {
        XCTAssertNil(NativeMenuApplicationEdgePolicy.rightEdge(
            targetScreen: external,
            screens: [external, builtIn],
            menuItemFrames: [
                CGRect(x: 10, y: 0, width: 34, height: 30),
                CGRect(x: 450, y: 1_440, width: 584, height: 30),
            ]
        ))
    }

    func testCompleteMenusTransferAcrossAboveBelowAndLeftDisplays() {
        let laptop = CGRect(x: 0, y: 0, width: 2_056, height: 1_329)
        let others = [
            CGRect(x: -880, y: -1_440, width: 3_440, height: 1_440),
            CGRect(x: -880, y: 1_329, width: 3_440, height: 1_440),
            CGRect(x: -3_440, y: 0, width: 3_440, height: 1_440),
        ]
        for other in others {
            for (source, target) in [(other, laptop), (laptop, other)] {
                let items = [
                    CGRect(x: source.minX + 10, y: source.minY, width: 34, height: 30),
                    CGRect(x: source.minX + 44, y: source.minY, width: 584, height: 30),
                ]
                XCTAssertEqual(NativeMenuApplicationEdgePolicy.rightEdge(
                    targetScreen: target, screens: [laptop, other], menuItemFrames: items
                ), target.minX + 652)
            }
        }
    }

    func testInvalidOrTruncatedReadingsDoNotAuthorizeAnyMenuSpace() {
        let cases = [
            [CGRect(x: 10, y: 0, width: 34, height: 30)],
            [CGRect(x: 10, y: 0, width: 34, height: 30), CGRect(x: 44, y: 0, width: 0, height: 30)],
            [CGRect(x: 10, y: 0, width: 100, height: 30), CGRect(x: 50, y: 0, width: 40, height: 30)],
            [CGRect(x: 100, y: 0, width: 34, height: 30), CGRect(x: 134, y: 0, width: 40, height: 30)],
            [CGRect(x: 10, y: 0, width: 34, height: 30), CGRect(x: 44, y: 0, width: CGFloat.infinity, height: 30)],
        ]
        for items in cases {
            XCTAssertNil(NativeMenuApplicationEdgePolicy.rightEdge(
                targetScreen: external, screens: [external, builtIn], menuItemFrames: items
            ))
        }
    }

    func testCrowdedSourceAndDisconnectedTargetRejectTransfer() {
        let items = [
            CGRect(x: 416, y: 1_440, width: 34, height: 30),
            CGRect(x: 450, y: 1_440, width: 1_950, height: 30),
        ]
        XCTAssertNil(NativeMenuApplicationEdgePolicy.rightEdge(
            targetScreen: external, screens: [external, builtIn], menuItemFrames: items
        ))
        XCTAssertNil(NativeMenuApplicationEdgePolicy.rightEdge(
            targetScreen: external, screens: [builtIn], menuItemFrames: items
        ))
    }

    func testMissingMenuItemsReturnsNoEdge() {
        XCTAssertNil(
            NativeMenuApplicationEdgePolicy.rightEdge(
                targetScreen: external,
                screens: [external, builtIn],
                menuItemFrames: []
            )
        )
    }
}
