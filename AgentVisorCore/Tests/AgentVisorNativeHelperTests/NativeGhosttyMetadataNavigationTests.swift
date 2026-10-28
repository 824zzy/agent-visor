import AgentVisorCore
import AgentVisorNativeHelper
import Carbon
import XCTest

final class NativeGhosttyMetadataNavigationTests: XCTestCase {
    private let claudeProcessToken = TerminalProcessIdentityToken.make(pid: 42, startTime: Date(timeIntervalSince1970: 1_700_000_000))
    func testNavigationWireRetainsTheExactClaudeSessionIdentity() throws {
        let data = Data(#"{"version":1,"id":"focus","method":"focus_terminal","params":{"conversationOnly":true,"target":{"application":"Ghostty","pid":42,"processStartToken":"start-one","tty":"ttys001","cwd":"/project","claudeSessionId":"11111111-2222-4333-8444-555555555555"}}}"#.utf8)
        let request = try NativeHelperRequest.decode(data)
        guard case .focusTerminal(_, let target, _) = request else { return XCTFail("Wrong navigation request") }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any]
        XCTAssertEqual(encoded?["claudeSessionId"] as? String, "11111111-2222-4333-8444-555555555555")
    }

    func testNavigationWireRejectsMalformedClaudeIdentities() throws {
        for method in ["focus_terminal", "prepare_terminal"] {
            for invalid: Any in ["", "not-a-session", "../session.json", NSNull(), 42] {
                let object: [String: Any] = ["version": 1, "id": "invalid", "method": method,
                    "params": ["conversationOnly": true, "target": ["application": "Ghostty", "pid": 42,
                        "processStartToken": "start-one", "tty": "ttys001", "cwd": "/project", "claudeSessionId": invalid]]]
                XCTAssertThrowsError(try NativeHelperRequest.decode(JSONSerialization.data(withJSONObject: object)))
            }
        }
    }

    func testExplicitClaudeIdentityCannotOmitItsConversationGuard() throws {
        let data = Data(#"{"version":1,"id":"focus","method":"focus_terminal","params":{"target":{"application":"Ghostty","pid":42,"processStartToken":"start-one","tty":"ttys001","cwd":"/project","claudeSessionId":"11111111-2222-4333-8444-555555555555"}}}"#.utf8)
        guard case .focusTerminal(_, _, let policy) = try NativeHelperRequest.decode(data) else {
            return XCTFail("Wrong navigation request")
        }
        XCTAssertEqual(policy, true, "An explicit expected identity must not enter the legacy focus branch")
    }

    func testNavigationIdentityDoesNotChangeTerminalInputRequestDecoding() throws {
        for method in ["send_terminal", "cancel_terminal", "cycle_permission_mode"] {
            let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
                processStartToken: "start-one", tty: "ttys001", cwd: "/project",
                claudeSessionId: "11111111-2222-4333-8444-555555555555")
            var params: [String: Any] = ["target": try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))]
            if method == "send_terminal" { params["text"] = "fixture"; params["submit"] = true }
            let request = try NativeHelperRequest.decode(JSONSerialization.data(withJSONObject: [
                "version": 1, "id": "input", "method": method, "params": params]))
            switch request {
            case .sendTerminal(_, let actual, let text, let submit):
                XCTAssertEqual(actual, target); XCTAssertEqual(text, "fixture"); XCTAssertTrue(submit)
            case .cancelTerminal(_, let actual), .cyclePermissionMode(_, let actual): XCTAssertEqual(actual, target)
            default: XCTFail("Unexpected terminal input request")
            }
        }
    }
    private final class Wire {
        var rows: [NativeGhosttyAppleEvents.Surface]
        var missingCWD = false
        var selected: String?
        var active = false
        init(_ rows: [NativeGhosttyAppleEvents.Surface]) { self.rows = rows }
        lazy var sdk = NativeGhosttyAppleEvents(pid: 7, transmit: { [unowned self] event in
            guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return nil }
            if event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue == NativeGhosttyAppleEvents.code("Fcus") {
                self.selected = direct.forKeyword(AEKeyword(keyAEKeyData))?.stringValue
                return .null()
            }
            if direct.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == NativeGhosttyAppleEvents.code("Gtrm") {
                let list = NSAppleEventDescriptor.list()
                for (index, row) in self.rows.enumerated() {
                    let reference = NSAppleEventDescriptor.record()
                    reference.setDescriptor(.init(typeCode: NativeGhosttyAppleEvents.code("Gtrm")), forKeyword: AEKeyword(keyAEDesiredClass))
                    reference.setDescriptor(.init(enumCode: UInt32(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
                    reference.setDescriptor(.init(string: row.id), forKeyword: AEKeyword(keyAEKeyData))
                    reference.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
                    list.insert(reference.coerce(toDescriptorType: typeObjectSpecifier)!, at: index + 1)
                }
                return list
            }
            let key = direct.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue
            let id = direct.forKeyword(AEKeyword(keyAEContainer))?.forKeyword(AEKeyword(keyAEKeyData))?.stringValue
            if key == NativeGhosttyAppleEvents.code("pisf") { return .init(boolean: self.active) }
            if key == NativeGhosttyAppleEvents.code("ID  "), id == nil { return .init(string: self.selected ?? "other") }
            guard let row = self.rows.first(where: { $0.id == id }) else { return nil }
            switch key {
            case NativeGhosttyAppleEvents.code("ID  "): return .init(string: row.id)
            case NativeGhosttyAppleEvents.code("pnam"): return .init(string: row.title)
            case NativeGhosttyAppleEvents.code("Gwdr"): return self.missingCWD ? nil : .init(string: row.cwd)
            default: return nil
            }
        }, activate: { [unowned self] in self.active = true; return true })
    }

    func testHerdrBindingWithEmptyDirectoryKeepsExactProcessAndNonceGuards() throws {
        let nonce = String(repeating: "a", count: 32)
        let wire = Wire([.init(id: "herdr", title: "AVB:" + nonce, cwd: ""),
                         .init(id: "other", title: "Other tab", cwd: "/other")])
        let target = NativeHelperGhosttyBinding(applicationPID: 7, processStartToken: "app-one",
            windowId: "window", tabId: "tab", terminalId: "herdr", nonce: nonce)
        var processIdentity = "client-one"
        let controller = NativeGhosttyBindingController(resolveApplication: { .init(pid: 7, token: "app-one") },
            execute: { _ in XCTFail("Unexpected fallback"); return nil }, permission: { true },
            isFrontmost: { _ in wire.active }, surface: { wire.sdk.surface(id: $0) },
            focusSurface: { wire.sdk.focus(terminalID: $0, expectedTitle: nil, expectedCWD: nil) },
            processIdentity: { _ in processIdentity })
        let processes = [NativeHelperProcessIdentity(pid: 42, processStartToken: "client-one")]
        XCTAssertTrue(controller.prepare(target, processes: processes))
        wire.rows[0] = .init(id: "herdr", title: "Herdr", cwd: "")
        wire.selected = "other"
        try controller.focus(target)
        XCTAssertEqual(wire.selected, "herdr")
        processIdentity = "replaced-client"; wire.selected = nil
        XCTAssertThrowsError(try controller.focus(target)); XCTAssertNil(wire.selected)
        XCTAssertFalse(controller.prepare(target, processes: processes), "Released nonce cannot mint a new capability")
    }

    func testMixedInventoryDoesNotLoseExactTerminalPreparation() {
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: "process-one", tty: "ttys001", cwd: "/project")
        let wire = Wire([.init(id: "herdr", title: "Herdr", cwd: ""),
                         .init(id: "conversation", title: "Conversation", cwd: "/project")])
        XCTAssertEqual(wire.sdk.surfaces()?.map(\.id), ["herdr", "conversation"])
        let routes = NativeGhosttyPreparedRoutes(environment: .init(
            application: { .init(pid: 7, token: "app-one") }, verify: { $0 == target },
            surfaces: { wire.sdk.surfaces() }, surface: { wire.sdk.surface(id: $0) },
            focus: { wire.sdk.focus(terminalID: $0, expectedTitle: $1, expectedCWD: $2) },
            viewMode: { _, _ in .conversation }, writeMetadata: { cwd, actual in
                guard actual == target else { return false }
                wire.rows[1] = .init(id: "conversation", title: "Conversation", cwd: cwd); return true
            }, pause: {}))
        XCTAssertTrue(routes.prepare(target)); XCTAssertNil(wire.selected)
        XCTAssertEqual(routes.focus(target), true); XCTAssertEqual(wire.selected, "conversation")
    }

    func testMissingDirectoryCannotSatisfyAnExplicitDirectoryGuard() {
        let wire = Wire([.init(id: "exact", title: "Conversation", cwd: "")])
        XCTAssertFalse(wire.sdk.focus(terminalID: "exact", expectedTitle: "Conversation", expectedCWD: "/project"))
        XCTAssertNil(wire.selected)
    }

    // Diagnostic reproduction of unavailable pre-selection AX evidence. The
    // terminal still exists in the scripting inventory; its footer is exposed
    // only after selection. This models the visibility boundary, not a live UI.
    func testDirectGhosttyCanReturnWhenFooterIsUnavailableUntilSelection() throws {
        try assertDirectClaudeFocus(initiallySelected: false, prepareWhileSelected: false)
    }

    func testDirectGhosttySelectedClaudeTabIsNavigable() throws {
        try assertDirectClaudeFocus(initiallySelected: true, prepareWhileSelected: false)
    }

    func testDirectGhosttyUnselectedCodexTabIsNavigable() throws {
        try assertDirectClaudeFocus(initiallySelected: false, prepareWhileSelected: false, conversationOnly: false)
    }

    func testDirectGhosttyWarmRouteCanReturnAfterAnotherTabIsSelected() throws {
        try assertDirectClaudeFocus(initiallySelected: true, prepareWhileSelected: true)
    }

    func testExplicitClaudeIdentityCannotFocusAKnownOverview() throws {
        try assertDirectClaudeFocus(initiallySelected: false, prepareWhileSelected: false,
            mode: .overview, expectSuccess: false)
    }

    func testOverviewRevealedAfterExactFocusIsNotReportedAsSuccessfulNavigation() throws {
        try assertDirectClaudeFocus(initiallySelected: false, prepareWhileSelected: false,
            overviewAfterFocus: true, expectSuccess: false)
    }

    func testChangedClaudeSessionCannotReuseAPreparedRouteWithGenericPolicy() throws {
        let sessionId = "11111111-2222-4333-8444-555555555555"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("av-claude-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = directory.appendingPathComponent("42.json")
        func write(_ id: String) throws {
            try JSONSerialization.data(withJSONObject: ["sessionId": id, "cwd": "/project", "kind": "interactive"])
                .write(to: file)
        }
        try write(sessionId)
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: claudeProcessToken, tty: "ttys001", cwd: "/project", claudeSessionId: sessionId)
        let wire = Wire([.init(id: "conversation", title: "Conversation", cwd: "/project")])
        let routes = NativeGhosttyPreparedRoutes(environment: .init(
            application: { .init(pid: 7, token: "app-one") }, verify: { $0 == target },
            surfaces: { wire.sdk.surfaces() }, surface: { wire.sdk.surface(id: $0) },
            focus: { wire.sdk.focus(terminalID: $0, expectedTitle: $1, expectedCWD: $2) },
            viewMode: { _, _ in .conversation }, writeMetadata: { cwd, _ in
                wire.rows[0] = .init(id: "conversation", title: "Conversation", cwd: cwd); return true
            }, pause: {}, verifyClaudeSession: NativeClaudeSessionVerifier(homeDirectory: home).verify))
        XCTAssertTrue(routes.prepare(target, conversationOnly: false))
        try write("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        XCTAssertEqual(routes.focus(target, conversationOnly: false), false)
        XCTAssertNil(wire.selected, "A retained caption cannot authorize a different conversation")
    }

    func testOverviewTransitionDuringFocusIsNotReportedAsSuccessfulNavigation() throws {
        let sessionId = "11111111-2222-4333-8444-555555555555"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("av-claude-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = directory.appendingPathComponent("42.json")
        var record: [String: Any] = ["sessionId": sessionId, "cwd": "/project", "kind": "interactive"]
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: claudeProcessToken, tty: "ttys001", cwd: "/project", claudeSessionId: sessionId)
        let wire = Wire([.init(id: "conversation", title: "Conversation", cwd: "/project")])
        let routes = NativeGhosttyPreparedRoutes(environment: .init(
            application: { .init(pid: 7, token: "app-one") }, verify: { $0 == target },
            surfaces: { wire.sdk.surfaces() }, surface: { wire.sdk.surface(id: $0) },
            focus: { id, title, cwd in
                record["parkedJobId"] = "aabbccdd"
                do { try JSONSerialization.data(withJSONObject: record).write(to: file) }
                catch { XCTFail("Could not update fixture"); return false }
                return wire.sdk.focus(terminalID: id, expectedTitle: title, expectedCWD: cwd)
            }, viewMode: { _, _ in .conversation }, writeMetadata: { cwd, _ in
                wire.rows[0] = .init(id: "conversation", title: "Conversation", cwd: cwd); return true
            }, pause: {}, verifyClaudeSession: NativeClaudeSessionVerifier(homeDirectory: home).verify))
        XCTAssertFalse(routes.focusOrPrepare(target, conversationOnly: true))
        XCTAssertEqual(wire.selected, "conversation", "The transition occurs during the fixture focus")
        XCTAssertNil(routes.focus(target), "The rejected capability must be evicted")
    }

    private func assertDirectClaudeFocus(initiallySelected: Bool, prepareWhileSelected: Bool,
                                         conversationOnly: Bool = true,
                                         mode: NativeHelperGhosttyViewMode? = nil,
                                         overviewAfterFocus: Bool = false, expectSuccess: Bool = true,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let sessionId = "11111111-2222-4333-8444-555555555555"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("av-claude-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "cwd": "/project",
            "kind": "interactive", "status": "idle"]).write(to: directory.appendingPathComponent("42.json"))
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: claudeProcessToken, tty: "ttys001", cwd: "/project",
            claudeSessionId: conversationOnly ? sessionId : nil)
        let wire = Wire([.init(id: "other", title: "Other tab", cwd: "/other"),
                         .init(id: "conversation", title: "Conversation", cwd: "/project")])
        wire.selected = initiallySelected ? "conversation" : "other"
        let routes = NativeGhosttyPreparedRoutes(environment: .init(
            application: { .init(pid: 7, token: "app-one") }, verify: { $0 == target },
            surfaces: { wire.sdk.surfaces() }, surface: { wire.sdk.surface(id: $0) },
            focus: { wire.sdk.focus(terminalID: $0, expectedTitle: $1, expectedCWD: $2) },
            viewMode: { _, _ in overviewAfterFocus && wire.selected == "conversation" ? .overview : mode },
            writeMetadata: { cwd, actual in
                guard actual == target else { return false }
                wire.rows[1] = .init(id: "conversation", title: "Conversation", cwd: cwd)
                return true
            }, pause: {}, verifyClaudeSession: NativeClaudeSessionVerifier(homeDirectory: home).verify))
        if prepareWhileSelected {
            XCTAssertTrue(routes.prepare(target, conversationOnly: conversationOnly), file: file, line: line)
            wire.selected = "other"
        }
        XCTAssertEqual(routes.focusOrPrepare(target, conversationOnly: conversationOnly), expectSuccess,
                       "An unknown footer must not block exact navigation; a known overview must reject it", file: file, line: line)
        XCTAssertEqual(wire.selected, expectSuccess || overviewAfterFocus ? "conversation" : "other", file: file, line: line)
        XCTAssertEqual(wire.rows[1].cwd, target.cwd, "Metadata must be restored", file: file, line: line)
    }

    func testUnreadableOrMalformedDirectoryRemainsRejected() {
        let wire = Wire([.init(id: "exact", title: "Conversation", cwd: "/project")])
        wire.missingCWD = true; XCTAssertNil(wire.sdk.surface(id: "exact"))
        wire.missingCWD = false
        for cwd in ["relative", String(repeating: "/", count: 4097)] {
            wire.rows[0] = .init(id: "exact", title: "Conversation", cwd: cwd)
            XCTAssertNil(wire.sdk.surface(id: "exact"))
        }
    }
}
