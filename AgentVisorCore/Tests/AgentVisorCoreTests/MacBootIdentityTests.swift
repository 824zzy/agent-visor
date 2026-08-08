import XCTest
@testable import AgentVisorCore

final class MacBootIdentityTests: XCTestCase {
    func testValidBootSessionUUIDIsCanonicalized() {
        XCTAssertEqual(
            MacBootIdentity.current {
                "aabbccdd-eeff-4011-9234-0123456789ab"
            },
            "AABBCCDD-EEFF-4011-9234-0123456789AB"
        )
    }

    func testRepeatedReadsOfSameUUIDAreStable() {
        let raw = "AABBCCDD-EEFF-4011-9234-0123456789AB"
        XCTAssertEqual(MacBootIdentity.current { raw }, MacBootIdentity.current { raw })
    }

    func testMalformedAndMissingValuesFailClosed() {
        XCTAssertNil(MacBootIdentity.current { nil })
        XCTAssertNil(MacBootIdentity.current { "" })
        XCTAssertNil(MacBootIdentity.current { "1785910406.669682" })
        XCTAssertNil(MacBootIdentity.current { "not-a-uuid" })
    }
}
