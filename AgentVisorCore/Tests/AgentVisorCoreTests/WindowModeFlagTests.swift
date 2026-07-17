import XCTest
@testable import AgentVisorCore

final class WindowModeFlagTests: XCTestCase {
    func testDisabledByDefault() {
        XCTAssertFalse(WindowModeFlag.isEnabled(in: [:]))
    }

    func testEnabledWhenSetToOne() {
        XCTAssertTrue(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": "1"]))
    }

    func testEnabledWhenSetToTrue() {
        XCTAssertTrue(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": "true"]))
        XCTAssertTrue(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": "TRUE"]))
        XCTAssertTrue(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": "yes"]))
    }

    func testDisabledWhenSetToZero() {
        XCTAssertFalse(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": "0"]))
        XCTAssertFalse(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": "false"]))
        XCTAssertFalse(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": "no"]))
        XCTAssertFalse(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": ""]))
    }

    func testIgnoresUnrelatedEnvKeys() {
        XCTAssertFalse(WindowModeFlag.isEnabled(in: ["WINDOW_MODE": "1", "OTHER": "yes"]))
    }

    func testWhitespaceTrimmed() {
        XCTAssertTrue(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": "  1  "]))
        XCTAssertTrue(WindowModeFlag.isEnabled(in: ["AV_WINDOW_MODE": "\ttrue\n"]))
    }
}
