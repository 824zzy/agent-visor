import XCTest
@testable import AgentVisorCore

final class NativeHelperWireProtocolTests: XCTestCase {
    func testDecodesEverySupportedRequest() throws {
        let requests = [
            #"{"version":1,"id":"screens","method":"screen_topology"}"#,
            #"{"version":1,"id":"access","method":"accessibility_status"}"#,
            #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[{"id":"session-1","title":"Review migration","phase":"ready","priority":1,"accessibilityLabel":"Review migration, ready"}]}}"#,
            #"{"version":1,"id":"focus","method":"focus","params":{"target":{"pid":42,"bundleIdentifier":"com.mitchellh.ghostty","windowId":7}}}"#,
        ]

        XCTAssertEqual(
            try requests.map { try NativeHelperRequest.decode(Data($0.utf8)).id },
            ["screens", "access", "pills", "focus"]
        )
    }

    func testRejectsUnknownMethodsExtraFieldsAndInexactFocus() {
        assertInvalid(#"{"version":1,"id":"bad","method":"parse_provider"}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"screen_topology","extra":true}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"focus","params":{"target":{"pid":0,"bundleIdentifier":""}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"focus","params":{"target":{"pid":42,"bundleIdentifier":"app","provider":"Pi"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[{"id":"1","title":"A","phase":"ready","priority":1,"accessibilityLabel":"A","provider":"Pi"}]}}"#)
    }

    func testEncodesTypedResponseEnvelope() throws {
        let data = try NativeHelperResponse.accessibilityStatus(
            id: "access",
            trusted: true
        ).encoded()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let result = try XCTUnwrap(object["result"] as? [String: Any])

        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["id"] as? String, "access")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(result["type"] as? String, "accessibility_status")
        XCTAssertEqual(result["trusted"] as? Bool, true)
    }

    func testFramesFragmentedAndAdjacentMessages() throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let framed = try NativeHelperFrameCodec.frame(first) + NativeHelperFrameCodec.frame(second)
        var decoder = NativeHelperFrameDecoder()

        XCTAssertEqual(try decoder.append(framed.prefix(3)), [])
        XCTAssertEqual(try decoder.append(framed.dropFirst(3).prefix(5)), [])
        XCTAssertEqual(try decoder.append(framed.dropFirst(8)), [first, second])
    }

    func testRejectsOversizedFramesBeforeReadingTheirBody() {
        var decoder = NativeHelperFrameDecoder(maxPayloadBytes: 8)
        let oversizedHeader = Data([0, 0, 0, 9])

        XCTAssertThrowsError(try decoder.append(oversizedHeader)) { error in
            XCTAssertEqual(error as? NativeHelperWireError, .frameTooLarge)
        }
    }

    private func assertInvalid(_ json: String) {
        XCTAssertThrowsError(try NativeHelperRequest.decode(Data(json.utf8)))
    }
}
