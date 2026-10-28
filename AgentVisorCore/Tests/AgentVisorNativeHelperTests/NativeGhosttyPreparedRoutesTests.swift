import AgentVisorCore
import AgentVisorNativeHelper
import XCTest

final class NativeGhosttyPreparedRoutesTests: XCTestCase {
    func testFocusesExactTerminalWhenDirectoryBasedTitleRestoresAsynchronously() {
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: "process-one", tty: "ttys001", cwd: "/project")
        let app = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "ghostty-one")
        var cwd = target.cwd
        var title = target.cwd
        var restoring = false
        var restorationReads = 0
        var focused: String?
        let routes = NativeGhosttyPreparedRoutes(environment: .init(application: { app }, verify: { $0 == target },
            surfaces: { [.init(id: "exact", title: title, cwd: cwd)] },
            surface: { _ in
                if restoring {
                    restorationReads += 1
                    if restorationReads > 1 { title = target.cwd }
                }
                return .init(id: "exact", title: title, cwd: cwd)
            }, focus: { id, expectedTitle, expectedCWD in
                guard expectedTitle == target.cwd, expectedCWD == target.cwd else { return false }
                focused = id
                return true
            }, viewMode: { _, _ in XCTFail("Generic terminal must not read a Claude footer"); return nil },
            writeMetadata: { value, _ in
                cwd = value
                if value == target.cwd { restoring = true }
                else { title = value }
                return true
            }, pause: {}))

        XCTAssertTrue(routes.focusOrPrepare(target, conversationOnly: false))
        XCTAssertEqual(focused, "exact")
        XCTAssertEqual(cwd, target.cwd)
    }

    func testGenericTerminalPreparationDoesNotRequireAClaudeFooter() {
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: "process-one", tty: "ttys001", cwd: "/project")
        let app = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "ghostty-one")
        var cwd = target.cwd
        var selected: String?
        let routes = NativeGhosttyPreparedRoutes(environment: .init(application: { app }, verify: { _ in true },
            surfaces: { [.init(id: "codex", title: "Codex", cwd: cwd)] },
            surface: { _ in .init(id: "codex", title: "Codex", cwd: cwd) },
            focus: { id, _, _ in selected = id; return true },
            viewMode: { _, _ in XCTFail("Generic terminal must not read a Claude footer"); return nil },
            writeMetadata: { value, _ in cwd = value; return true }, pause: {}))
        XCTAssertTrue(routes.prepare(target, conversationOnly: false))
        XCTAssertEqual(routes.focus(target, conversationOnly: false), true)
        XCTAssertEqual(selected, "codex")
        XCTAssertEqual(routes.focus(target, conversationOnly: true), false, "Cannot reuse a generic capability as a Claude proof")
    }
    func testDecodesBackgroundPreparationWithExactTerminalIdentity() throws {
        let request = Data(#"{"version":1,"id":"prepare","method":"prepare_terminal","params":{"target":{"application":"Ghostty","pid":42,"processStartToken":"start-a","tty":"ttys001","cwd":"/project"}}}"#.utf8)
        XCTAssertEqual(try NativeHelperRequest.decode(request).id, "prepare")
    }
    func testExactTerminalPolicySurvivesTheWireAndRejectsOtherApplications() throws {
        for method in ["prepare_terminal", "focus_terminal"] {
            for policy in [true, false] {
                let value: [String: Any] = ["version": 1, "id": "policy", "method": method,
                    "params": ["conversationOnly": policy, "target": ["application": "Ghostty", "pid": 42,
                        "processStartToken": "start-a", "tty": "ttys001", "cwd": "/project"]]]
                switch try NativeHelperRequest.decode(JSONSerialization.data(withJSONObject: value)) {
                case .focusTerminal(_, _, let actual): XCTAssertEqual(actual, policy)
                case .prepareTerminal(_, _, let actual): XCTAssertEqual(actual, policy)
                default: XCTFail("Unexpected request")
                }
                let wrongApplication: [String: Any] = ["version": 1, "id": "policy", "method": method,
                    "params": ["conversationOnly": policy, "target": ["application": "Terminal", "pid": 42,
                        "processStartToken": "start-a", "tty": "ttys001", "cwd": "/project"]]]
                XCTAssertThrowsError(try NativeHelperRequest.decode(JSONSerialization.data(withJSONObject: wrongApplication)))
            }
        }
    }
    func testPreparationWireRejectsMissingProcessIdentity() {
        for target in [#"{"application":"Ghostty","tty":"ttys001","cwd":"/project"}"#,
                       #"{"application":"Ghostty","pid":42,"tty":"ttys001","cwd":"/project"}"#] {
            let data = Data((#"{"version":1,"id":"prepare","method":"prepare_terminal","params":{"target":"#
                + target + "}}" ).utf8)
            XCTAssertThrowsError(try NativeHelperRequest.decode(data))
        }
    }
    func testPreparationDoesNotFocusAndWarmClickDoesNotWriteTerminalMetadata() {
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: "process-one", tty: "ttys001", cwd: "/project")
        let app = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "ghostty-one")
        var cwd = target.cwd
        var metadataWrites: [String] = []
        var selected: String?
        let routes = NativeGhosttyPreparedRoutes(environment: .init(
            application: { app }, verify: { $0 == target },
            surfaces: { [NativeGhosttyAppleEvents.Surface(id: "exact-surface", title: "✳ conversation", cwd: cwd)] },
            surface: { _ in .init(id: "exact-surface", title: "◐ conversation", cwd: cwd) },
            focus: { id, _, _ in selected = id; return true },
            viewMode: { _, _ in .conversation },
            writeMetadata: { value, _ in metadataWrites.append(value); cwd = value; return true }, pause: {}))

        XCTAssertTrue(routes.prepare(target))
        XCTAssertNil(selected)
        XCTAssertEqual(cwd, target.cwd)
        let beforeClick = metadataWrites
        XCTAssertEqual(routes.focus(target), true)
        XCTAssertEqual(selected, "exact-surface")
        XCTAssertEqual(metadataWrites, beforeClick)
    }

    func testChangedProcessApplicationSurfaceOrOverviewNeverFocusesAPreparedRoute() {
        for change in ["process", "application", "surface", "title", "cwd", "overview", "unknown"] {
            let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
                processStartToken: "process-one", tty: "ttys001", cwd: "/project")
            let app = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "ghostty-one")
            var changed = false
            var cwd = target.cwd
            var focused = false
            let routes = NativeGhosttyPreparedRoutes(environment: .init(
                application: { changed && change == "application" ? nil : app },
                verify: { _ in !(changed && change == "process") },
                surfaces: { [.init(id: "exact", title: "conversation", cwd: cwd)] },
                surface: { _ in
                    if changed && change == "surface" { return nil }
                    return .init(id: "exact", title: changed && change == "title" ? "other" : "conversation",
                        cwd: changed && change == "cwd" ? "/other" : cwd)
                }, focus: { _, _, _ in focused = true; return true },
                viewMode: { _, _ in
                    if changed && change == "overview" { return .overview }
                    if changed && change == "unknown" { return nil }
                    return .conversation
                }, writeMetadata: { value, _ in cwd = value; return true }, pause: {}))
            XCTAssertTrue(routes.prepare(target), change)
            changed = true
            XCTAssertEqual(routes.focus(target), false, change)
            XCTAssertFalse(focused, change)
            XCTAssertNil(routes.focus(target), "Rejected capability must be evicted: " + change)
        }
    }

    func testAmbiguousLocatorRestoresMetadataAndCannotMintAFocusRoute() {
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: "process-one", tty: "ttys001", cwd: "/project")
        let app = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "ghostty-one")
        var cwd = target.cwd
        let routes = NativeGhosttyPreparedRoutes(environment: .init(application: { app }, verify: { _ in true },
            surfaces: { [.init(id: "one", title: "conversation", cwd: cwd), .init(id: "two", title: "conversation", cwd: cwd)] },
            surface: { _ in nil }, focus: { _, _, _ in XCTFail("Ambiguous surface focused"); return true },
            viewMode: { _, _ in .conversation }, writeMetadata: { value, _ in cwd = value; return true }, pause: {}))
        XCTAssertFalse(routes.prepare(target))
        XCTAssertEqual(cwd, target.cwd)
        XCTAssertNil(routes.focus(target))
    }

    func testColdConversationFocusFailsClosedForOverviewOrUnreadableFooter() {
        for mode: NativeHelperGhosttyViewMode? in [.overview, nil] {
            let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
                processStartToken: "process-one", tty: "ttys001", cwd: "/project")
            let app = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "ghostty-one")
            var cwd = target.cwd
            let routes = NativeGhosttyPreparedRoutes(environment: .init(application: { app }, verify: { _ in true },
                surfaces: { [.init(id: "exact", title: "conversation", cwd: cwd)] },
                surface: { _ in .init(id: "exact", title: "conversation", cwd: cwd) },
                focus: { _, _, _ in XCTFail("Unverified conversation focused"); return true },
                viewMode: { _, _ in mode }, writeMetadata: { value, _ in cwd = value; return true }, pause: {}))
            XCTAssertFalse(routes.focusOrPrepare(target, conversationOnly: true))
            XCTAssertEqual(cwd, target.cwd)
        }
    }

    func testFailedRestorationReadbackRetriesCleanupWithoutPublishingARoute() {
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: "process-one", tty: "ttys001", cwd: "/project")
        let app = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "ghostty-one")
        var cwd = target.cwd
        var restorationWrites = 0
        let routes = NativeGhosttyPreparedRoutes(environment: .init(application: { app }, verify: { _ in true },
            surfaces: { [.init(id: "exact", title: "conversation", cwd: cwd)] },
            surface: { _ in .init(id: "exact", title: "conversation", cwd: cwd) },
            focus: { _, _, _ in XCTFail("Unrestored metadata cannot publish a route"); return true },
            viewMode: { _, _ in .conversation }, writeMetadata: { value, _ in
                if value == target.cwd {
                    restorationWrites += 1
                    if restorationWrites == 1 { return true } // Write accepted; terminal has not applied it.
                }
                cwd = value; return true
            }, pause: {}))
        XCTAssertFalse(routes.prepare(target))
        XCTAssertEqual(cwd, target.cwd)
        XCTAssertEqual(restorationWrites, 2)
        XCTAssertNil(routes.focus(target))
    }
}
