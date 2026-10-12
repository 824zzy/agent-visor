import AgentVisorCore
@testable import AgentVisorNativeHelper
import XCTest
import JavaScriptCore
import Darwin

final class NativeGhosttyTerminalControllerTests: XCTestCase {
    func testTrackedAttachmentCanLaunchGhosttyWhenItWasNotRunning() throws {
        var identity: NativeGhosttyTerminalController.ApplicationIdentity?
        let controller = NativeGhosttyTerminalController(
            resolveApplication: { identity },
            execute: { _ in #"[{"terminalId":"launched","title":"ccx-plg-manifest","cwd":"/Users/me/Codes"}]"# },
            openAttach: { _ in identity = .init(pid: 7, token: "new-instance"); return "launched" }
        )
        XCTAssertTrue(controller.openClaudeAttach(.init(
            cwd: "/Users/me/Codes", executable: "/Users/me/.local/bin/claude", jobId: "8e45ed2c"
        )))
        XCTAssertEqual(try controller.views().first?.titleUpdatesEnabled, true)
    }

    func testOnlyCreatedTerminalsReceiveTitleTrustAndReplacementClearsIt() throws {
        var identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "instance")
        var rows = #"[{"terminalId":"owned","title":"ccx-plg-manifest","cwd":"/Users/me/Codes"},{"terminalId":"other","title":"ccx-plg-manifest","cwd":"/Users/me/Codes"}]"#
        let controller = NativeGhosttyTerminalController(
            resolveApplication: { identity },
            execute: { $0 == GhosttyTerminalViewScript.list ? rows : "ok" },
            openAttach: { _ in "owned" }
        )
        XCTAssertTrue(controller.openClaudeAttach(.init(
            cwd: "/Users/me/Codes", executable: "/Users/me/.local/bin/claude", jobId: "8e45ed2c"
        )))
        let views = try controller.views()
        XCTAssertEqual(views[0].titleUpdatesEnabled, true)
        XCTAssertNil(views[1].titleUpdatesEnabled)
        XCTAssertTrue(controller.focus(views[0]))
        rows = "[]"
        XCTAssertEqual(try controller.views(), [])
        XCTAssertFalse(controller.focus(views[0]))
        identity = .init(pid: 7, token: "replacement")
        rows = #"[{"terminalId":"owned","title":"ccx-plg-manifest","cwd":"/Users/me/Codes"}]"#
        XCTAssertNil(try controller.views()[0].titleUpdatesEnabled)
        XCTAssertFalse(controller.focus(views[0]))
    }

    func testFocusRejectsClaimedTitleTrustForAnUnownedTerminal() {
        let controller = NativeGhosttyTerminalController(
            resolveApplication: { .init(pid: 7, token: "instance") }, execute: { _ in "ok" }
        )
        let target = NativeHelperGhosttyTerminalView(
            applicationPID: 7, processStartToken: "instance", terminalId: "unowned",
            title: "ccx-plg-manifest", cwd: "/Users/me/Codes", titleUpdatesEnabled: true
        )
        XCTAssertFalse(controller.focus(target))
    }

    func testPlainTitleFocusKeepsExactSurfaceAndRejectsOverview() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var title = 'ccx-plg-manifest', focused = [];
        function Application() { return {
            running: function(){return true},
            terminals: function(){return [{
                id: function(){return 'owned-surface'}, name: function(){return title},
                workingDirectory: function(){return '/Users/me/Codes'}
            }]},
            focus: function(t){focused.push(t.id())}, activate: function(){}
        }; }
        """#)
        let target = NativeHelperGhosttyTerminalView(
            applicationPID: 7, processStartToken: "instance", terminalId: "owned-surface",
            title: "ccx-plg-manifest", cwd: "/Users/me/Codes", titleUpdatesEnabled: true
        )
        XCTAssertEqual(context.evaluateScript(GhosttyTerminalViewScript.focus(target))?.toString(), "ok")
        context.evaluateScript("title = '◐ ccx-plg-manifest'")
        XCTAssertEqual(context.evaluateScript(GhosttyTerminalViewScript.focus(target))?.toString(), "ok")
        context.evaluateScript("title = '1 awaiting input · claude agents'")
        XCTAssertEqual(context.evaluateScript(GhosttyTerminalViewScript.focus(target))?.toString(), "changed")
        XCTAssertEqual(context.evaluateScript("focused.length")?.toInt32(), 2)
        XCTAssertNil(context.exception)
    }

    func testRepeatedViewIdentityChecksReleaseProcessPipes() throws {
        // Use our own process and fixture views: no Ghostty automation or UI input.
        let pid = getpid()
        let controller = NativeGhosttyTerminalController(resolveApplication: {
            NativeTerminalController.processStartToken(pid: pid).map {
                .init(pid: pid, token: $0)
            }
        }, execute: { _ in "[]" })
        XCTAssertEqual(try controller.views(), [])
        let before = openDescriptorCount()
        for _ in 0..<64 {
            XCTAssertNotNil(NativeTerminalController.processStartToken(pid: pid))
            XCTAssertEqual(try controller.views(), [])
        }
        XCTAssertLessThanOrEqual(openDescriptorCount(), before + 4,
                                 "Periodic view discovery must not exhaust the helper's descriptors")
    }

    private func openDescriptorCount() -> Int {
        var limit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &limit), 0)
        return (0..<Int32(min(limit.rlim_cur, 8_192))).reduce(0) { count, fd in
            count + (fcntl(fd, F_GETFD) >= 0 ? 1 : 0)
        }
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
    func testReadsCurrentTitlesAndRejectsAnApplicationReplacementDuringRead() throws {
        var identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "instance-one")
        var replace = false
        let controller = NativeGhosttyTerminalController(resolveApplication: { identity }, execute: { _ in
            if replace { identity = .init(pid: 7, token: "instance-two") }
            return #"[{"terminalId":"surface-a","title":"✳ ccx-cleanup","cwd":"/Users/me/Codes"}]"#
        })
        XCTAssertEqual(try controller.views(), [.init(
            applicationPID: 7, processStartToken: "instance-one", terminalId: "surface-a",
            title: "✳ ccx-cleanup", cwd: "/Users/me/Codes"
        )])
        replace = true
        XCTAssertThrowsError(try controller.views())
    }
    func testFailedViewReadIsNotReportedAsAnEmptyTerminalList() throws {
        let identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "instance")
        var output: String? = nil
        let controller = NativeGhosttyTerminalController(resolveApplication: { identity }, execute: { _ in output })
        XCTAssertThrowsError(try controller.views())
        output = "not JSON"
        XCTAssertThrowsError(try controller.views())
        output = "[]"
        XCTAssertEqual(try controller.views(), [])
    }
}
