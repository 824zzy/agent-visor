import XCTest
@testable import AgentVisorCore

final class PiConnectionStatePolicyTests: XCTestCase {
    func testConnectionStateRequiresDetectionBeforeHeartbeat() {
        XCTAssertEqual(PiConnectionStatePolicy.state(isDetected: false, hasHeartbeat: false), .notDetected)
        XCTAssertEqual(PiConnectionStatePolicy.state(isDetected: false, hasHeartbeat: true), .notDetected)
        XCTAssertEqual(PiConnectionStatePolicy.state(isDetected: true, hasHeartbeat: false), .observing)
        XCTAssertEqual(PiConnectionStatePolicy.state(isDetected: true, hasHeartbeat: true), .connected)
    }
}
