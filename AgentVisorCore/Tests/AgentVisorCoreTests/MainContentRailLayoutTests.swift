import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class MainContentRailLayoutTests: XCTestCase {
    func testWideWindowCentersTheAccepted980PointRail() {
        let geometry = MainContentRailLayout.resolve(containerWidth: 1_251)

        XCTAssertEqual(geometry.width, 980, accuracy: 0.001)
        XCTAssertEqual(geometry.leading, 135.5, accuracy: 0.001)
    }

    func testDefaultWindowNearlyFillsTheRailWithoutBreakingCentering() {
        let geometry = MainContentRailLayout.resolve(containerWidth: 1_040)

        XCTAssertEqual(geometry.width, 980, accuracy: 0.001)
        XCTAssertEqual(geometry.leading, 30, accuracy: 0.001)
    }

    func testMinimumWindowUsesAllWidthInsideThe28PointInsets() {
        let geometry = MainContentRailLayout.resolve(containerWidth: 960)

        XCTAssertEqual(geometry.width, 904, accuracy: 0.001)
        XCTAssertEqual(geometry.leading, 28, accuracy: 0.001)
    }

    func testContainerNarrowerThanBothInsetsProducesEmptyCenteredRail() {
        let geometry = MainContentRailLayout.resolve(containerWidth: 40)

        XCTAssertEqual(geometry.width, 0, accuracy: 0.001)
        XCTAssertEqual(geometry.leading, 20, accuracy: 0.001)
    }
}
