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
            209
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
