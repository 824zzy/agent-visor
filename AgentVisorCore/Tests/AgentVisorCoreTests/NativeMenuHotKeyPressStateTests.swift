import XCTest
@testable import AgentVisorCore

final class NativeMenuHotKeyPressStateTests: XCTestCase {
    func testHandlesOnePressUntilTheMatchingRelease() {
        var state = NativeMenuHotKeyPressState()

        XCTAssertTrue(state.shouldHandle(id: 10, isPressed: true))
        XCTAssertFalse(state.shouldHandle(id: 10, isPressed: true))
        XCTAssertFalse(state.shouldHandle(id: 10, isPressed: false))
        XCTAssertTrue(state.shouldHandle(id: 10, isPressed: true))
    }
}
