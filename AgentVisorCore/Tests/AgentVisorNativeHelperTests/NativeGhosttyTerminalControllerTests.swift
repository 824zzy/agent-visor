import AgentVisorCore
@testable import AgentVisorNativeHelper
import XCTest
import JavaScriptCore

final class NativeGhosttyTerminalControllerTests: XCTestCase {
    func testReadsOnlyTheFocusedSurfaceAndRejectsAReplacedApplication() {
        var identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "instance-one")
        var replaced = false
        let controller = NativeGhosttyTerminalController(resolveApplication: { identity }, execute: { _ in
            if replaced { identity = .init(pid: 7, token: "instance-two") }
            return #"{"terminalId":"surface-a","title":"✳ Cleanup","cwd":"/project"}"#
        })
        XCTAssertEqual(controller.focusedView()?.terminalId, "surface-a")
        replaced = true
        XCTAssertNil(controller.focusedView())
    }

    func testScriptingSelectsOnlyTheStableSurfaceAndRejectsAChangedTitle() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var focused = [];
        var rows = [
            {id: function(){return 'surface-a'}, name: function(){return '✳ ccx-cleanup'}, workingDirectory: function(){return '/Users/me/Codes'}},
            {id: function(){return 'surface-b'}, name: function(){return '✳ ccx-cleanup'}, workingDirectory: function(){return '/Users/me/Codes'}}
        ];
        function Application() { return {
            running: function(){return true}, terminals: function(){return rows},
            focus: function(t){focused.push(t.id())}, activate: function(){}
        }; }
        """#)
        let target = NativeHelperGhosttyTerminalView(
            applicationPID: 7, processStartToken: "instance", terminalId: "surface-b",
            title: "✳ ccx-cleanup", cwd: "/Users/me/Codes"
        )
        XCTAssertEqual(context.evaluateScript(GhosttyTerminalViewScript.focus(target))?.toString(), "ok")
        XCTAssertEqual(context.evaluateScript("JSON.stringify(focused)")?.toString(), #"["surface-b"]"#)
        // Claude animates the title indicator without changing conversation.
        context.evaluateScript("rows[1].name = function(){return '◐ ccx-cleanup'}")
        XCTAssertEqual(context.evaluateScript(GhosttyTerminalViewScript.focus(target))?.toString(), "ok")
        XCTAssertEqual(context.evaluateScript("focused.length")?.toInt32(), 2)
        context.evaluateScript("rows[1].name = function(){return 'claude agents'}")
        XCTAssertEqual(context.evaluateScript(GhosttyTerminalViewScript.focus(target))?.toString(), "changed")
        XCTAssertEqual(context.evaluateScript("focused.length")?.toInt32(), 2)
        let titles = try XCTUnwrap(context.evaluateScript(GhosttyTerminalViewScript.list)?.toString())
        XCTAssertTrue(titles.contains("claude agents"))
        XCTAssertNil(context.exception)
    }
    func testFocusRejectsReusedPIDAndReportsAChangedSurface() {
        let target = NativeHelperGhosttyTerminalView(
            applicationPID: 7, processStartToken: "instance-one", terminalId: "surface-a",
            title: "✳ ccx-cleanup", cwd: "/Users/me/Codes"
        )
        var identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "instance-one")
        var outcome = "ok"
        var attempts = 0
        let controller = NativeGhosttyTerminalController(resolveApplication: { identity }, execute: { _ in
            attempts += 1
            return outcome
        })
        XCTAssertTrue(controller.focus(target))
        outcome = "changed"
        XCTAssertFalse(controller.focus(target))
        XCTAssertEqual(attempts, 2)
        identity = .init(pid: 7, token: "instance-two")
        XCTAssertFalse(controller.focus(target))
        XCTAssertEqual(attempts, 2)
    }
    func testReadsCurrentTitlesAndRejectsAnApplicationReplacementDuringRead() {
        var identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "instance-one")
        var replace = false
        let controller = NativeGhosttyTerminalController(resolveApplication: { identity }, execute: { _ in
            if replace { identity = .init(pid: 7, token: "instance-two") }
            return #"[{"terminalId":"surface-a","title":"✳ ccx-cleanup","cwd":"/Users/me/Codes"}]"#
        })
        XCTAssertEqual(controller.views(), [.init(
            applicationPID: 7, processStartToken: "instance-one", terminalId: "surface-a",
            title: "✳ ccx-cleanup", cwd: "/Users/me/Codes"
        )])
        replace = true
        XCTAssertEqual(controller.views(), [])
    }
}
