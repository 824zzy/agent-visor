import XCTest
@testable import AgentVisorCore

final class NativeTerminalCancelPolicyTests: XCTestCase {
    func testInjectedKeyPosterFailureCannotReportSuccessfulCancel() {
        XCTAssertFalse(NativeTerminalCancelPolicy.result(focusSucceeded: true, keyPostSucceeded: false))
    }

    func testFocusFailureCannotReachSuccessPath() {
        XCTAssertFalse(NativeTerminalCancelPolicy.result(focusSucceeded: false, keyPostSucceeded: true))
    }

    func testOnlyFocusedSuccessfullyPostedEscapeSucceeds() {
        XCTAssertTrue(NativeTerminalCancelPolicy.result(focusSucceeded: true, keyPostSucceeded: true))
    }
}
