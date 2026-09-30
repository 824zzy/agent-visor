import AppKit
import AgentVisorCore
import XCTest
@testable import AgentVisorNativeHelper

final class NativeMenuLayoutBoundsTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 2_056, height: 1_329)
    private let left = CGRect(x: 0, y: 1_290, width: 918, height: 39)
    private let right = CGRect(x: 1_138, y: 1_290, width: 918, height: 39)

    func testUnknownMenuBoundaryClosesOnlyTheLeftLane() {
        let bounds = NativeMenuController.layoutBounds(
            screenFrame: screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 2_056, height: 1_290),
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right,
            measuredAppMenuEdge: nil,
            measuredTrayEdge: 1_700
        )
        XCTAssertEqual(bounds.leftWidth, 0)
        XCTAssertGreaterThan(bounds.rightWidth, 0)
    }

    func testMeasuredChromeMenuBoundsTheActualLane() {
        let bounds = NativeMenuController.layoutBounds(
            screenFrame: screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 2_056, height: 1_290),
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right,
            measuredAppMenuEdge: 628,
            measuredTrayEdge: 1_700
        )
        let laneStart = bounds.leftInnerEdge - bounds.innerPadding - bounds.leftWidth
        XCTAssertEqual(laneStart, 628)
        XCTAssertEqual(bounds.leftWidth, 282)
        XCTAssertEqual(bounds.y, 1_297.5)
    }
    func testPartialAXReadingCannotOpenTheControllerLeftLane() {
        let edge = NativeMenuApplicationEdgePolicy.rightEdge(
            targetScreen: screen,
            screens: [screen],
            menuItemFrames: [
                CGRect(x: 10, y: 0, width: 34, height: 39),
                CGRect(x: 44, y: 0, width: 271, height: 39),
                CGRect(x: 403, y: 0, width: 225, height: 39),
            ]
        )
        let bounds = NativeMenuController.layoutBounds(
            screenFrame: screen, visibleFrame: screen,
            auxiliaryTopLeftArea: left, auxiliaryTopRightArea: right,
            measuredAppMenuEdge: edge, measuredTrayEdge: 1_700
        )
        XCTAssertEqual(bounds.leftWidth, 0)
        XCTAssertGreaterThan(bounds.rightWidth, 0)
    }

    func testTransferredMenuSetsTheLaneInCocoaCoordinatesWithNegativeOrigin() {
        let externalCG = CGRect(x: -880, y: -1_440, width: 3_440, height: 1_440)
        let edge = NativeMenuApplicationEdgePolicy.rightEdge(
            targetScreen: externalCG, screens: [screen, externalCG],
            menuItemFrames: [
                CGRect(x: 10, y: 0, width: 34, height: 39),
                CGRect(x: 44, y: 0, width: 584, height: 39),
            ]
        )
        let externalCocoa = CGRect(x: -880, y: 1_329, width: 3_440, height: 1_440)
        let bounds = NativeMenuController.layoutBounds(
            screenFrame: externalCocoa, visibleFrame: externalCocoa,
            measuredAppMenuEdge: edge, measuredTrayEdge: 2_200
        )
        XCTAssertEqual(bounds.leftInnerEdge - bounds.innerPadding - bounds.leftWidth, -228)
        XCTAssertGreaterThan(bounds.leftWidth, 0)
    }

    func testUnreadableOrOutOfDisplayEdgesCloseTheLaneBeforePacking() {
        for edge in [CGFloat.nan, .infinity, -1, 3_000] {
            let bounds = NativeMenuController.layoutBounds(
                screenFrame: screen, visibleFrame: screen,
                measuredAppMenuEdge: edge, measuredTrayEdge: 1_700
            )
            XCTAssertEqual(bounds.leftWidth, 0)
        }
    }
    func testFailedLastAXChildInvalidatesTheWholeMeasurement() {
        let child = AXUIElementCreateApplication(getpid())
        var readCount = 0
        let frames = NativeMenuController.menuItemFrames(
            children: [child, child, child],
            readRole: { _ in kAXMenuBarItemRole as String },
            readFrame: { _ in
                readCount += 1
                return readCount == 3 ? nil : CGRect(x: 10, y: 0, width: 34, height: 39)
            }
        )
        XCTAssertNil(frames)
        XCTAssertEqual(readCount, 3)
    }

    func testUnreadableAXRoleInvalidatesTheWholeMeasurement() {
        let child = AXUIElementCreateApplication(getpid())
        XCTAssertNil(NativeMenuController.menuItemFrames(
            children: [child], readRole: { _ in nil },
            readFrame: { _ in XCTFail("unknown roles cannot authorize geometry"); return .zero }
        ))
    }

    func testSystemMenuExtrasAreExcludedFromApplicationMenuGeometry() {
        let child = AXUIElementCreateApplication(getpid())
        let frames = NativeMenuController.menuItemFrames(
            children: [child], readRole: { _ in "AXMenuExtra" },
            readFrame: { _ in XCTFail("status items do not belong to the app menu"); return .zero }
        )
        XCTAssertEqual(frames, [])
    }
}
