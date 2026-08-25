import XCTest
@testable import AgentVisorCore

final class NativeHelperWireProtocolTests: XCTestCase {
    func testDecodesEverySupportedRequest() throws {
        let requests = [
            #"{"version":1,"id":"screens","method":"screen_topology"}"#,
            #"{"version":1,"id":"access","method":"accessibility_status"}"#,
            #"{"version":1,"id":"notifications","method":"notification_status"}"#,
            #"{"version":1,"id":"request-notifications","method":"request_notifications"}"#,
            #"{"version":1,"id":"request-access","method":"request_accessibility"}"#,
            #"{"version":1,"id":"open-access","method":"open_accessibility_settings"}"#,
            #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[{"id":"session-1","title":"Review migration","subtitle":"Ready to continue","source":"Pi","project":"agent-visor","owner":"Ghostty","phase":"ready","priority":1,"accessibilityLabel":"Review migration, ready"},{"id":"session-2","title":"Recent migration","phase":"history","priority":2,"accessibilityLabel":"Recent migration, recent session"}],"shortcutModifierFamily":"controlCommand","hotkeyTrigger":"custom","customHotkeyCombo":"49:8","usageGlances":[{"id":"codex","label":"5h 82% | 7d 61%","detail":"Codex usage","tone":"normal","priority":100,"accessibilityLabel":"Codex usage"}]}}"#,
            #"{"version":1,"id":"legacy-pills","method":"present_pills","params":{"pills":[{"id":"legacy","title":"Legacy","phase":"working","priority":2,"accessibilityLabel":"Legacy, in progress"}]}}"#,
            #"{"version":1,"id":"focus","method":"focus","params":{"target":{"pid":42,"bundleIdentifier":"com.mitchellh.ghostty","windowId":7}}}"#,
            #"{"version":1,"id":"focus-terminal","method":"focus_terminal","params":{"target":{"application":"Ghostty","tty":"ttys012","cwd":"/tmp/project"}}}"#,
            #"{"version":1,"id":"send-terminal","method":"send_terminal","params":{"target":{"application":"Ghostty","tty":"/dev/ttys012","cwd":"/tmp/project"},"text":"Continue","submit":true}}"#,
        ]

        XCTAssertEqual(
            try requests.map { try NativeHelperRequest.decode(Data($0.utf8)).id },
            [
                "screens", "access", "notifications", "request-notifications",
                "request-access", "open-access",
                "pills", "legacy-pills", "focus", "focus-terminal", "send-terminal",
            ]
        )
    }

    func testDecodesBoundedNotifications() throws {
        let json = #"{"version":1,"id":"notifications","method":"reconcile_notifications","params":{"presentNew":true,"notifications":[{"id":"attention-1","sessionId":"session-1","title":"Bash needs approval","subtitle":"Review migration","body":"{\"command\":\"npm test\"}","toolUseId":"tool-7","sound":"Pop"}]}}"#

        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .reconcileNotifications(_, let notifications, let presentNew) = request else {
            return XCTFail("Expected notifications")
        }
        XCTAssertTrue(presentNew)
        XCTAssertEqual(notifications.first?.sessionId, "session-1")
        XCTAssertEqual(notifications.first?.toolUseId, "tool-7")
        XCTAssertEqual(notifications.first?.sound, .pop)
    }

    func testDecodesSeparateNavigatorCatalog() throws {
        let json = #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[{"id":"visible","title":"Visible","phase":"working","priority":0,"accessibilityLabel":"Visible, in progress"}],"navigatorPills":[{"id":"visible","title":"Visible","phase":"working","priority":0,"accessibilityLabel":"Visible, in progress"},{"id":"chat-history","title":"Chat history","phase":"history","priority":1,"accessibilityLabel":"Chat history, recent session"}]}}"#

        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .presentPills(_, let pills, let navigatorPills, _, _, _, _, _, _) = request else {
            return XCTFail("Expected pills")
        }
        XCTAssertEqual(pills.map(\.id), ["visible"])
        XCTAssertEqual(navigatorPills.map(\.id), ["visible", "chat-history"])
    }

    func testDecodesDisplayAndFullScreenPreferences() throws {
        let json = #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[],"pillScreen":{"mode":"specific","displayId":5,"name":"XZ322QU V3"},"fullScreenPolicy":"alwaysHide"}}"#

        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .presentPills(_, _, _, _, _, let screen, let policy, _, _) = request else {
            return XCTFail("Expected pills")
        }
        XCTAssertEqual(screen, .specific(displayId: 5, name: "XZ322QU V3"))
        XCTAssertEqual(policy, .alwaysHide)
    }

    func testDecodesAuthoritativeUsagePopoverDetails() throws {
        let json = #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[],"usageGlances":[{"id":"codex","heading":"Codex Usage","width":114,"label":"5h 82% | 7d 61%","detail":"Codex usage","tone":"normal","priority":100,"accessibilityLabel":"Codex usage","observedAt":"2026-08-24T12:00:00.000Z","windows":[{"title":"5 hour limit","remainingPercent":82,"tone":"normal","resetsAt":"2026-08-24T13:00:00.000Z"},{"title":"Weekly limit","remainingPercent":61,"tone":"normal"}],"resetCreditsAvailable":3,"stale":true}]}}"#

        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .presentPills(_, _, _, let glances, _, _, _, _, _) = request else {
            return XCTFail("Expected pills")
        }
        let glance = try XCTUnwrap(glances.first)
        XCTAssertEqual(glance.heading, "Codex Usage")
        XCTAssertEqual(glance.width, 114)
        XCTAssertEqual(glance.observedAt, "2026-08-24T12:00:00.000Z")
        XCTAssertEqual(glance.windows?.map(\.title), ["5 hour limit", "Weekly limit"])
        XCTAssertEqual(glance.windows?.map(\.remainingPercent), [82, 61])
        XCTAssertEqual(glance.windows?.map(\.tone), [.normal, .normal])
        XCTAssertEqual(glance.windows?.first?.resetsAt, "2026-08-24T13:00:00.000Z")
        XCTAssertEqual(glance.resetCreditsAvailable, 3)
        XCTAssertEqual(glance.stale, true)
    }

    func testDecodesBoundedSessionInspector() throws {
        let json = #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[{"id":"session-1","title":"Review migration","phase":"ready","priority":1,"accessibilityLabel":"Review migration, ready","inspector":{"status":"Ready","runtimeItems":["Pi · Ghostty","Claude Sonnet 4"],"detailRows":[{"label":"Reasoning","value":"High"}],"projectPath":"~/Codes/agent-visor","activityAt":"2026-08-22T21:02:18.000Z","context":{"usedLabel":"84k","windowLabel":"200k","percentage":42}}}],"hotkeyTrigger":"custom","customHotkeyCombo":"49:8"}}"#

        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .presentPills(_, let pills, _, _, _, _, _, let trigger, let combo) = request else {
            return XCTFail("Expected pills")
        }
        let inspector = try XCTUnwrap(pills.first?.inspector)
        XCTAssertEqual(inspector.status, "Ready")
        XCTAssertEqual(inspector.runtimeItems, ["Pi · Ghostty", "Claude Sonnet 4"])
        XCTAssertEqual(inspector.detailRows.first?.label, "Reasoning")
        XCTAssertEqual(inspector.projectPath, "~/Codes/agent-visor")
        XCTAssertEqual(inspector.activityAt, "2026-08-22T21:02:18.000Z")
        XCTAssertEqual(inspector.context?.percentage, 42)
        XCTAssertEqual(trigger, .custom)
        XCTAssertEqual(combo, KeyCombo(keyCode: 49, modifiers: .command))
    }

    func testRejectsUnknownMethodsExtraFieldsAndInexactFocus() {
        assertInvalid(#"{"version":1,"id":"bad","method":"parse_provider"}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"screen_topology","extra":true}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"focus","params":{"target":{"pid":0,"bundleIdentifier":""}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"focus","params":{"target":{"pid":42,"bundleIdentifier":"app","provider":"Pi"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"focus_terminal","params":{"target":{"application":"Ghostty","tty":"/dev/null","cwd":"/"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[{"id":"1","title":"A","subtitle":"Ready","source":"Pi","project":"agent-visor","owner":"Ghostty","phase":"ready","priority":1,"accessibilityLabel":"A","provider":"Pi"}],"usageGlances":[]}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[{"id":"1","title":"A","phase":"ready","priority":1,"accessibilityLabel":"A","inspector":{"status":"Ready","runtimeItems":["Pi"],"detailRows":[],"projectPath":"/tmp","activityAt":"2026-08-22T21:02:18.000Z","provider":"Pi"}}]}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[],"usageGlances":[{"id":"codex","label":"5h 0%","detail":"Codex usage","tone":"critical","priority":100,"accessibilityLabel":"Codex usage","windows":[{"title":"5 hour limit","remainingPercent":101}]}]}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[],"usageGlances":[{"id":"codex","label":"5h 82%","detail":"Codex usage","tone":"normal","priority":100,"accessibilityLabel":"Codex usage","windows":[{"remainingPercent":82}]}]}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[],"pillScreen":{"mode":"automatic","name":"Injected"}}}"#)
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

        let notificationData = try NativeHelperResponse.notificationStatus(
            id: "notifications",
            status: .authorized
        ).encoded()
        let notificationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: notificationData) as? [String: Any]
        )
        let notificationResult = try XCTUnwrap(
            notificationObject["result"] as? [String: Any]
        )
        XCTAssertEqual(notificationResult["type"] as? String, "notification_status")
        XCTAssertEqual(notificationResult["status"] as? String, "authorized")
    }

    func testEncodesActivationEvents() throws {
        let activation = try NativeHelperEvent.activatePill(
            sessionId: "session-1",
            intent: .chat
        ).encoded()
        let open = try NativeHelperEvent.openSessions.encoded()
        let toggle = try NativeHelperEvent.toggleSessions.encoded()
        let settings = try NativeHelperEvent.openSettings.encoded()
        let refresh = try NativeHelperEvent.refreshUsage.encoded()
        let permission = try NativeHelperEvent.notificationPermission(.authorized).encoded()
        let approve = try NativeHelperEvent.notificationAction(
            sessionId: "session-1",
            toolUseId: "tool-7",
            action: .approve
        ).encoded()
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: activation) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: open) as? [String: Any])
        let third = try XCTUnwrap(JSONSerialization.jsonObject(with: toggle) as? [String: Any])
        let fourth = try XCTUnwrap(JSONSerialization.jsonObject(with: settings) as? [String: Any])
        let fifth = try XCTUnwrap(JSONSerialization.jsonObject(with: refresh) as? [String: Any])
        let sixth = try XCTUnwrap(JSONSerialization.jsonObject(with: permission) as? [String: Any])
        let seventh = try XCTUnwrap(JSONSerialization.jsonObject(with: approve) as? [String: Any])

        XCTAssertEqual(first["type"] as? String, "event")
        XCTAssertEqual(first["event"] as? String, "activate_pill")
        XCTAssertEqual(first["sessionId"] as? String, "session-1")
        XCTAssertEqual(first["intent"] as? String, "chat")
        XCTAssertEqual(second["event"] as? String, "open_sessions")
        XCTAssertEqual(third["event"] as? String, "toggle_sessions")
        XCTAssertEqual(fourth["event"] as? String, "open_settings")
        XCTAssertEqual(fifth["event"] as? String, "refresh_usage")
        XCTAssertEqual(sixth["event"] as? String, "notification_permission")
        XCTAssertEqual(sixth["status"] as? String, "authorized")
        XCTAssertEqual(seventh["event"] as? String, "notification_action")
        XCTAssertEqual(seventh["sessionId"] as? String, "session-1")
        XCTAssertEqual(seventh["toolUseId"] as? String, "tool-7")
        XCTAssertEqual(seventh["action"] as? String, "approve")
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
