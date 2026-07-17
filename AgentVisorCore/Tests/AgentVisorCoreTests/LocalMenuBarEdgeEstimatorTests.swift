import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class LocalMenuBarEdgeEstimatorTests: XCTestCase {
    func testEstimatesAgentVisorMenuEdgeFromRenderedTitleWidths() {
        XCTAssertEqual(
            LocalMenuBarEdgeEstimator.estimate(
                titleWidths: [70.3, 23.4, 29.2, 48.4, 28.0]
            ),
            344
        )
    }
}
