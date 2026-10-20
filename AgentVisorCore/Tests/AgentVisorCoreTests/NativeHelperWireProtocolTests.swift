import XCTest
@testable import AgentVisorCore

final class NativeHelperWireProtocolTests: XCTestCase {
    func testPillActivationCarriesItsNativeTimestamp() throws {
        let data = try NativeHelperEvent.activatePill(sessionId: "session", activatedAt: 1_792_518_000_123).encoded()
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(value["activatedAt"] as? Double, 1_792_518_000_123)
    }
    func testRecoveredGhosttyViewEvidenceSurvivesTheActualFocusRequestDecoder() throws {
        for titleEnabled in [true, false] {
            let target = NativeHelperGhosttyTerminalView(applicationPID: 7, processStartToken: "instance",
                terminalId: "manual", title: "ccx-thinking-block-sneha", cwd: "/Users/me/Codes",
                titleUpdatesEnabled: titleEnabled ? true : nil, viewMode: .conversation)
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any])
            func request() throws -> Data {
                try JSONSerialization.data(withJSONObject: ["version": 1, "id": "focus", "method": "focus_ghostty_terminal",
                    "params": ["target": fields]])
            }
            XCTAssertEqual(try NativeHelperRequest.decode(request()), .focusGhosttyTerminal(id: "focus", target: target))
            fields["unexpected"] = true
            XCTAssertThrowsError(try NativeHelperRequest.decode(request()))
        }
    }

    func testGhosttyFooterScopeIsOptionalBoundedAndStrict() throws {
        func request(_ params: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 1, "id": "views",
                "method": "ghostty_terminal_views", "params": params])
        }
        XCTAssertEqual(try NativeHelperRequest.decode(request(["conversationTitles": ["ccx-thinking-block-sneha"]])),
                       .ghosttyTerminalViews(id: "views", conversationTitles: ["ccx-thinking-block-sneha"]))
        XCTAssertThrowsError(try NativeHelperRequest.decode(request(["conversationTitles": Array(repeating: "name", count: 65)])))
        XCTAssertThrowsError(try NativeHelperRequest.decode(request(["conversationTitles": [""]])))
        XCTAssertThrowsError(try NativeHelperRequest.decode(request(["conversationTitles": ["name"], "unexpected": true])))
    }

    func testPillPresentationAcceptsDurableAttention() throws {
        XCTAssertNoThrow(try NativeHelperRequest.decode(Data(#"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[{"id":"test","title":"Test","phase":"ready","attentionTier":"ready","completionUnseen":true,"priority":0,"accessibilityLabel":"Test, unopened"}]}}"#.utf8)))
    }

    func testFocusFailureCarriesOnlyAReasonAndSystemCodeAlongsideTheMessage() throws {
        let data = try NativeHelperResponse.error(
            id: "click", code: .failed, message: "Codex could not select the thread.",
            reason: "deep_link_rejected", systemCode: -1743
        ).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["reason"] as? String, "deep_link_rejected")
        XCTAssertEqual(error["systemCode"] as? Int, -1743)
        XCTAssertEqual(error.count, 4)
    }

    func testGhosttyViewFocusAndReadShareTheWireIdentity() throws {
        let target = NativeHelperGhosttyTerminalView(
            applicationPID: 7, processStartToken: "instance", terminalId: "surface-a",
            title: "✳ ccx-cleanup", cwd: "/Users/me/Codes"
        )
        XCTAssertEqual(try NativeHelperRequest.decode(Data(#"{"version":1,"id":"views","method":"ghostty_terminal_views"}"#.utf8)), .ghosttyTerminalViews(id: "views"))
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "id": "focus-view", "method": "focus_ghostty_terminal",
            "params": ["target": try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))],
        ])
        XCTAssertEqual(try NativeHelperRequest.decode(data), .focusGhosttyTerminal(id: "focus-view", target: target))
        let result = try NativeHelperResponse.ghosttyTerminalViews(id: "views", views: [target]).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let body = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "ghostty_terminal_views")
        XCTAssertEqual((body["views"] as? [[String: Any]])?.first?["terminalId"] as? String, "surface-a")
    }

    func testNonceBoundGhosttyBindingRequestsAndResponsesAreStrict() throws {
        let nonce = String(repeating: "e", count: 32)
        let target = NativeHelperGhosttyBinding(
            applicationPID: 701,
            processStartToken: "ghostty-start-1",
            windowId: "window-1",
            tabId: "tab-1",
            terminalId: "terminal-1",
            nonce: nonce
        )
        let resolve = try JSONSerialization.data(withJSONObject: [
            "version": 1, "id": "resolve", "method": "resolve_ghostty_binding",
            "params": ["nonce": nonce],
        ])
        XCTAssertEqual(
            try NativeHelperRequest.decode(resolve),
            .resolveGhosttyBinding(id: "resolve", nonce: nonce)
        )
        let focus = try JSONSerialization.data(withJSONObject: [
            "version": 1, "id": "focus", "method": "focus_ghostty_binding",
            "params": ["target": try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))],
        ])
        XCTAssertEqual(
            try NativeHelperRequest.decode(focus),
            .focusGhosttyBinding(id: "focus", target: target)
        )
        XCTAssertThrowsError(try NativeHelperRequest.decode(Data(#"{"version":1,"id":"bad","method":"resolve_ghostty_binding","params":{"nonce":"EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"}}"#.utf8)))

        let status = try NativeHelperResponse.ghosttyBindingStatus(id: "status", available: true).encoded()
        let statusObject = try XCTUnwrap(JSONSerialization.jsonObject(with: status) as? [String: Any])
        let statusResult = try XCTUnwrap(statusObject["result"] as? [String: Any])
        XCTAssertEqual(statusResult["type"] as? String, "ghostty_binding_status")
        XCTAssertEqual(statusResult["available"] as? Bool, true)

        let resolved = try NativeHelperResponse.ghosttyBinding(id: "resolved", binding: target).encoded()
        let resolvedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: resolved) as? [String: Any])
        let resolvedResult = try XCTUnwrap(resolvedObject["result"] as? [String: Any])
        XCTAssertEqual(resolvedResult["type"] as? String, "ghostty_binding")
        XCTAssertEqual((resolvedResult["binding"] as? [String: Any])?["terminalId"] as? String, "terminal-1")
    }

    func testParsesWireTimestampsWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(NativeHelperTimestamp.parse("2026-08-24T12:00:00.000Z"))
        XCTAssertNotNil(NativeHelperTimestamp.parse("2026-08-24T12:00:00Z"))
        XCTAssertNil(NativeHelperTimestamp.parse("August 24, 2026"))
    }

    func testNativeHelperLimitsUseTheSharedWireContract() {
        XCTAssertEqual(NativeHelperWireLimits.maxTerminalTextBytes, 65_536)
        XCTAssertEqual(NativeHelperWireLimits.maxFramePayloadBytes, 1_048_576)
        XCTAssertEqual(nativeHelperMaximumTerminalTextBytes, NativeHelperWireLimits.maxTerminalTextBytes)
        XCTAssertEqual(nativeHelperMaximumPayloadBytes, NativeHelperWireLimits.maxFramePayloadBytes)
    }

    func testTerminalTextLimitIsMeasuredInUTF8Bytes() throws {
        let boundary = String(repeating: "😀", count: NativeHelperWireLimits.maxTerminalTextBytes / 4)
        XCTAssertEqual(boundary.utf8.count, NativeHelperWireLimits.maxTerminalTextBytes)
        XCTAssertNoThrow(try NativeHelperRequest.decode(terminalRequestData(id: "boundary", text: boundary)))

        XCTAssertThrowsError(try NativeHelperRequest.decode(terminalRequestData(id: "overflow", text: boundary + "x"))) { error in
            XCTAssertEqual(error as? NativeHelperWireError, .invalidRequest)
        }
    }

    private func terminalRequestData(id: String, text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "id": id,
            "method": "send_terminal",
            "params": [
                "target": ["application": "Ghostty", "pid": 42, "processStartToken": "2026-08-22T08:00:00Z", "tty": "ttys012", "cwd": "/tmp/project"],
                "text": text,
                "submit": true,
            ],
        ])
    }

    func testDecodesEverySupportedRequest() throws {
        let requests = [
            #"{"version":1,"id":"screens","method":"screen_topology"}"#,
            #"{"version":1,"id":"access","method":"accessibility_status"}"#,
            #"{"version":1,"id":"notifications","method":"notification_status"}"#,
            #"{"version":1,"id":"request-notifications","method":"request_notifications"}"#,
            #"{"version":1,"id":"request-access","method":"request_accessibility"}"#,
            #"{"version":1,"id":"open-access","method":"open_accessibility_settings"}"#,
            #"{"version":1,"id":"pi-restoration","method":"reconcile_pi_restoration","params":{"candidates":[],"liveSessionIds":[],"removeCandidateSessionIds":[],"cleanTermination":false}}"#,
            #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[{"id":"session-1","title":"Review migration","subtitle":"Ready to continue","source":"Pi","project":"agent-visor","owner":"Ghostty","phase":"ready","attentionTier":"acknowledged_ready","priority":1,"accessibilityLabel":"Review migration, ready"},{"id":"session-2","title":"Recent migration","phase":"history","priority":2,"accessibilityLabel":"Recent migration, recent session"}],"shortcutModifierFamily":"controlCommand","hotkeyTrigger":"custom","customHotkeyCombo":"49:8","usageGlances":[{"id":"codex","label":"5h 82% | 7d 61%","detail":"Codex usage","tone":"normal","priority":100,"accessibilityLabel":"Codex usage"}]}}"#,
            #"{"version":1,"id":"legacy-pills","method":"present_pills","params":{"pills":[{"id":"legacy","title":"Legacy","phase":"working","priority":2,"accessibilityLabel":"Legacy, in progress"}]}}"#,
            #"{"version":1,"id":"focus","method":"focus","params":{"target":{"pid":42,"bundleIdentifier":"com.mitchellh.ghostty","windowId":7}}}"#,
            #"{"version":1,"id":"focus-terminal","method":"focus_terminal","params":{"target":{"application":"Ghostty","pid":42,"processStartToken":"2026-08-22T08:00:00Z","tty":"ttys012","cwd":"/tmp/project"}}}"#,
            #"{"version":1,"id":"open-codex-thread","method":"open_codex_thread","params":{"target":{"pid":70220,"home":"/Users/me/.codex-copilot","threadId":"019f3931-ec11-7f31-8400-1c8624aa9e4d"}}}"#,
            #"{"version":1,"id":"send-terminal","method":"send_terminal","params":{"target":{"application":"Ghostty","pid":42,"processStartToken":"2026-08-22T08:00:00Z","tty":"/dev/ttys012","cwd":"/tmp/project"},"text":"Continue","submit":true}}"#,
            #"{"version":1,"id":"cancel-terminal","method":"cancel_terminal","params":{"target":{"application":"Ghostty","pid":42,"processStartToken":"2026-08-22T08:00:00Z","tty":"/dev/ttys012","cwd":"/tmp/project"}}}"#,
            #"{"version":1,"id":"cycle-permission","method":"cycle_permission_mode","params":{"target":{"application":"Ghostty","pid":42,"processStartToken":"2026-08-22T08:00:00Z","tty":"/dev/ttys012","cwd":"/tmp/project"}}}"#,
        ]

        XCTAssertEqual(
            try requests.map { try NativeHelperRequest.decode(Data($0.utf8)).id },
            [
                "screens", "access", "notifications", "request-notifications",
                "request-access", "open-access", "pi-restoration",
                "pills", "legacy-pills", "focus", "focus-terminal", "open-codex-thread", "send-terminal", "cancel-terminal", "cycle-permission",
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

    func testDecodesBoundedPiRestorationCandidates() throws {
        let json = #"{"version":1,"id":"pi-restoration","method":"reconcile_pi_restoration","params":{"candidates":[{"sessionId":"pi-1","sessionFile":"/Users/me/.pi/agent/sessions/pi-1.jsonl","cwd":"/Users/me/Codes/agent-visor","sessionName":"Restore Pi sessions","pid":43,"tty":"ttys001"}],"liveSessionIds":["pi-1"],"removeCandidateSessionIds":[],"cleanTermination":false}}"#

        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .reconcilePiRestoration(_, let update) = request else {
            return XCTFail("Expected Pi restoration candidates")
        }
        XCTAssertFalse(update.cleanTermination)
        XCTAssertEqual(update.liveSessionIds, ["pi-1"])
        XCTAssertEqual(update.removeCandidateSessionIds, [])
        XCTAssertEqual(update.candidates.first?.sessionId, "pi-1")
        XCTAssertEqual(update.candidates.first?.pid, 43)
        XCTAssertEqual(update.candidates.first?.tty, "ttys001")
    }

    func testDecodesSeparateNavigatorCatalog() throws {
        let json = #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[{"id":"visible","title":"Visible","phase":"working","priority":0,"accessibilityLabel":"Visible, in progress"}],"navigatorPills":[{"id":"visible","title":"Visible","phase":"working","priority":0,"accessibilityLabel":"Visible, in progress"},{"id":"chat-history","title":"Chat history","phase":"history","priority":1,"defaultOverflowEligible":true,"accessibilityLabel":"Chat history, recent session"}]}}"#

        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .presentPills(_, let pills, let navigatorPills, _, _, _, _, _, _) = request else {
            return XCTFail("Expected pills")
        }
        XCTAssertEqual(pills.map(\.id), ["visible"])
        XCTAssertEqual(navigatorPills.map(\.id), ["visible", "chat-history"])
        XCTAssertNil(navigatorPills.first?.defaultOverflowEligible)
        XCTAssertEqual(navigatorPills.last?.defaultOverflowEligible, true)
    }

    func testDecodesOptionalFailureAlertWithoutChangingLegacyPills() throws {
        let json = #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[{"id":"failure","title":"Failed turn","phase":"needs_you","failureAlert":true,"priority":0,"accessibilityLabel":"Failed turn, needs you"},{"id":"blocked","title":"Approval needed","phase":"needs_you","priority":1,"accessibilityLabel":"Approval needed, needs you"}]}}"#

        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .presentPills(_, let pills, _, _, _, _, _, _, _) = request else {
            return XCTFail("Expected pills")
        }
        XCTAssertEqual(pills.first?.failureAlert, true)
        XCTAssertNil(pills.last?.failureAlert)
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

    func testDecodesDisplayUUIDInSpecificPillScreen() throws {
        let uuid = "1A108786-48D9-48F8-9611-48282BDABE1F"
        let json = #"{"version":1,"id":"pills","method":"present_pills","params":{"pills":[],"pillScreen":{"mode":"specific","displayId":5,"name":"DELL P3424WEB","displayUuid":"\#(uuid)"}}}"#

        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .presentPills(_, _, _, _, _, let screen, _, _, _) = request else {
            return XCTFail("Expected pills")
        }
        XCTAssertEqual(screen, .specific(displayId: 5, name: "DELL P3424WEB", displayUuid: uuid))
    }

    func testRejectsMalformedOrAutomaticDisplayUUID() {
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[],"pillScreen":{"mode":"specific","displayId":5,"name":"DELL","displayUuid":"not-a-uuid"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[],"pillScreen":{"mode":"automatic","displayUuid":"1A108786-48D9-48F8-9611-48282BDABE1F"}}}"#)
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

    func testDecodesCopilotCreditsAndRejectsAnUnsafeUsageLink() throws {
        let json = #"{"version":1,"id":"cp","method":"present_pills","params":{"pills":[],"usageGlances":[{"id":"copilot","heading":"GitHub Copilot","width":64,"label":"CP 92%","detail":"GitHub Copilot credits","summary":"128,807 of 140,000 AI credits remaining","usageURL":"https://github.com/settings/copilot","tone":"normal","priority":110,"accessibilityLabel":"GitHub Copilot credits"}]}}"#
        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .presentPills(_, _, _, let glances, _, _, _, _, _) = request else {
            return XCTFail("Expected pills")
        }
        let glance = try XCTUnwrap(glances.first)
        XCTAssertEqual(glance.id, "copilot")
        XCTAssertEqual(glance.label, "CP 92%")
        XCTAssertEqual(glance.summary, "128,807 of 140,000 AI credits remaining")
        XCTAssertEqual(glance.usageURL, "https://github.com/settings/copilot")
        assertInvalid(json.replacingOccurrences(of: "https://github.com/settings/copilot", with: "file:///etc/passwd"))
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
        assertInvalid(#"{"version":1,"id":"bad","method":"open_codex_thread","params":{"target":{"pid":42,"home":"relative","threadId":"019f3931-ec11-7f31-8400-1c8624aa9e4d"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"open_codex_thread","params":{"target":{"pid":42,"home":"/tmp","threadId":"019f3931-ec11-7f31-8400-1c8624aa9e4d","url":"file:///tmp"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"focus_terminal","params":{"target":{"application":"Ghostty","tty":"/dev/null","cwd":"/"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"cancel_terminal","params":{"target":{"application":"Ghostty","pid":42,"tty":"ttys012","cwd":"/","extra":true}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[{"id":"1","title":"A","subtitle":"Ready","source":"Pi","project":"agent-visor","owner":"Ghostty","phase":"ready","priority":1,"accessibilityLabel":"A","provider":"Pi"}],"usageGlances":[]}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[{"id":"1","title":"A","phase":"ready","priority":1,"accessibilityLabel":"A","inspector":{"status":"Ready","runtimeItems":["Pi"],"detailRows":[],"projectPath":"/tmp","activityAt":"2026-08-22T21:02:18.000Z","provider":"Pi"}}]}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[],"usageGlances":[{"id":"codex","label":"5h 0%","detail":"Codex usage","tone":"critical","priority":100,"accessibilityLabel":"Codex usage","windows":[{"title":"5 hour limit","remainingPercent":101}]}]}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[],"usageGlances":[{"id":"codex","label":"5h 82%","detail":"Codex usage","tone":"normal","priority":100,"accessibilityLabel":"Codex usage","windows":[{"remainingPercent":82}]}]}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"present_pills","params":{"pills":[],"pillScreen":{"mode":"automatic","name":"Injected"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"reconcile_pi_restoration","params":{"candidates":[{"sessionId":"pi-1","sessionFile":"/session.jsonl","cwd":"/project","pid":43,"tty":"ttys001","provider":"Pi"}],"liveSessionIds":["pi-1"],"removeCandidateSessionIds":[],"cleanTermination":false}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"reconcile_pi_restoration","params":{"candidates":[{"sessionId":"pi-1","sessionFile":"relative.jsonl","cwd":"/project","pid":43,"tty":"ttys001"}],"liveSessionIds":["pi-1"],"removeCandidateSessionIds":[],"cleanTermination":false}}"#)
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
        let dismiss = try NativeHelperEvent.activatePill(
            sessionId: "failed-session",
            intent: .dismiss
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
        let dismissed = try XCTUnwrap(JSONSerialization.jsonObject(with: dismiss) as? [String: Any])
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
        XCTAssertEqual(dismissed["event"] as? String, "activate_pill")
        XCTAssertEqual(dismissed["sessionId"] as? String, "failed-session")
        XCTAssertEqual(dismissed["intent"] as? String, "dismiss")
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

    func testDecodesClaudeAttachAndRejectsUnsafeTargets() throws {
        XCTAssertEqual(
            try NativeHelperRequest.decode(Data(#"{"version":1,"id":"attach","method":"open_claude_attach","params":{"target":{"cwd":"/tmp/project","executable":"/Users/me/.local/bin/claude","jobId":"62c740e7"}}}"#.utf8)),
            .openClaudeAttach(id: "attach", target: NativeHelperClaudeAttachTarget(
                cwd: "/tmp/project", executable: "/Users/me/.local/bin/claude", jobId: "62c740e7"
            ))
        )
        assertInvalid(#"{"version":1,"id":"bad","method":"open_claude_attach","params":{"target":{"cwd":"relative","executable":"/bin/claude","jobId":"62c740e7"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"open_claude_attach","params":{"target":{"cwd":"/tmp","executable":"claude","jobId":"62c740e7"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"open_claude_attach","params":{"target":{"cwd":"/tmp","executable":"/bin/claude","jobId":"62c740e7; rm"}}}"#)
        assertInvalid(#"{"version":1,"id":"bad","method":"open_claude_attach","params":{"target":{"cwd":"/tmp","executable":"/bin/claude","jobId":"62c740e7","command":"sh"}}}"#)
    }
}
