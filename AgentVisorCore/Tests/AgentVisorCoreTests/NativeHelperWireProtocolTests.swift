import XCTest
@testable import AgentVisorCore

final class NativeHelperWireProtocolTests: XCTestCase {
    func testDecodesEverySupportedRequest() throws {
        let requests = [
            #"{"version":1,"id":"screens","method":"screen_topology"}"#,
            #"{"version":1,"id":"access","method":"accessibility_status"}"#,
            #"{"version":1,"id":"request-access","method":"request_accessibility"}"#,
            #"{"version":1,"id":"open-access","method":"open_accessibility_settings"}"#,
            #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[{"id":"session-1","title":"Review migration","subtitle":"Ready to continue","source":"Pi","project":"agent-visor","owner":"Ghostty","phase":"ready","priority":1,"accessibilityLabel":"Review migration, ready"}],"shortcutModifierFamily":"controlCommand","usageGlances":[{"id":"codex","label":"5h 82% | 7d 61%","detail":"Codex usage","tone":"normal","priority":100,"accessibilityLabel":"Codex usage"}]}}"#,
            #"{"version":1,"id":"legacy-pills","method":"present_pills","params":{"pills":[{"id":"legacy","title":"Legacy","phase":"working","priority":2,"accessibilityLabel":"Legacy, in progress"}]}}"#,
            #"{"version":1,"id":"focus","method":"focus","params":{"target":{"pid":42,"bundleIdentifier":"com.mitchellh.ghostty","windowId":7}}}"#,
            #"{"version":1,"id":"focus-terminal","method":"focus_terminal","params":{"target":{"application":"Ghostty","tty":"ttys012","cwd":"/tmp/project"}}}"#,
            #"{"version":1,"id":"send-terminal","method":"send_terminal","params":{"target":{"application":"Ghostty","tty":"/dev/ttys012","cwd":"/tmp/project"},"text":"Continue","submit":true}}"#,
        ]

        XCTAssertEqual(
            try requests.map { try NativeHelperRequest.decode(Data($0.utf8)).id },
            [
                "screens", "access", "request-access", "open-access",
                "pills", "legacy-pills", "focus", "focus-terminal", "send-terminal",
            ]
        )
    }

    func testRejectsUnknownMethodsExtraFieldsAndInexactFocus() {
        assertInvalid(#"{"version":1,"id":"bad","method":"parse_provider"}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"screen_topology","extra":true}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"focus","params":{"target":{"pid":0,"bundleIdentifier":""}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"focus","params":{"target":{"pid":42,"bundleIdentifier":"app","provider":"Pi"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"focus_terminal","params":{"target":{"application":"Ghostty","tty":"/dev/null","cwd":"/"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[{"id":"1","title":"A","subtitle":"Ready","source":"Pi","project":"agent-visor","owner":"Ghostty","phase":"ready","priority":1,"accessibilityLabel":"A","provider":"Pi"}],"usageGlances":[]}}"#)
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

    func testEncodesActivationEvents() throws {
        let activation = try NativeHelperEvent.activatePill(sessionId: "session-1").encoded()
        let open = try NativeHelperEvent.openSessions.encoded()
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: activation) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: open) as? [String: Any])

        XCTAssertEqual(first["type"] as? String, "event")
        XCTAssertEqual(first["event"] as? String, "activate_pill")
        XCTAssertEqual(first["sessionId"] as? String, "session-1")
        XCTAssertEqual(second["event"] as? String, "open_sessions")
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
