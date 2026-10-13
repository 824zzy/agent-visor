import AgentVisorCore
@testable import AgentVisorNativeHelper
import XCTest
import JavaScriptCore
import Darwin

final class NativeGhosttyTerminalControllerTests: XCTestCase {
    func testAgentCountsDoNotHideTheDisplayedConversation() throws {
        // Claude Code 2.1.296 replaces "for agents" with counts while jobs exist.
        for hint in ["← 1 agent", "← 3 agents", "← 2 done", "← 99+ agents"] {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript(#"""
            var focused = [];
            function Application(){return {
                running: function(){return true}, terminals: function(){return [{
                    id: function(){return 'manual'}, name: function(){return 'ccx-thinking-block-sneha'},
                    workingDirectory: function(){return '/Users/me/Codes'}
                }]}, focus: function(t){focused.push(t.id())}, activate: function(){}
            };}
            """#)
            let controller = NativeGhosttyTerminalController(readViewText: { _, _ in
                // Layout independently confirmed by the user's current footer screenshot.
                "──────────────── ccx-thinking-block-sneha —\n❯\n────────────────\nOpus 5.5 | high | 34% | thinking-block-simplify\naccept edits on (shift+tab to cycle) · \(hint)"
            }, resolveApplication: { .init(pid: 7, token: "same-instance") },
                execute: { context.evaluateScript($0)?.toString() })
            let view = try XCTUnwrap(controller.views(conversationTitles: ["ccx-thinking-block-sneha"]).first)
            XCTAssertEqual(view.viewMode, .conversation, hint)
            XCTAssertTrue(controller.focus(view), hint)
            XCTAssertEqual(context.evaluateScript("JSON.stringify(focused)")?.toString(), #"["manual"]"#)
        }
    }

    func testAgentCountsInOverviewHistoryDoNotRestoreAPhantomPill() throws {
        var footer = "ccx-thinking-block-sneha —\naccept edits on · ← 3 agents"
        let rows = #"[{"terminalId":"manual","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"}]"#
        let controller = NativeGhosttyTerminalController(readViewText: { _, _ in footer },
            resolveApplication: { .init(pid: 7, token: "same-instance") }, execute: { _ in rows })
        let current = try XCTUnwrap(controller.views().first)
        XCTAssertEqual(current.viewMode, .conversation)
        footer += "\nNeeds input\nCompleted\n❯ describe a task for a new session\naccept edits · enter to return · space to reply · ctrl+x to delete · ? for shortcuts"
        XCTAssertEqual(try controller.views().first?.viewMode, .overview)
        XCTAssertFalse(controller.focus(current))
        footer = "another-conversation —\naccept edits on · ← 3 agents"
        XCTAssertNil(try controller.views().first?.viewMode)
    }

    func testApplicationReplacementDuringFooterReadCannotPublishConversationEvidence() {
        var identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "original")
        let controller = NativeGhosttyTerminalController(readViewText: { _, _ in
            identity = .init(pid: 7, token: "replacement")
            return "ccx-thinking-block-sneha —\naccept edits on · ← for agents"
        }, resolveApplication: { identity }, execute: { _ in
            #"[{"terminalId":"manual","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"}]"#
        })
        XCTAssertThrowsError(try controller.views())
    }

    func testFooterInspectionIsScopedToClaudeConversationTitles() throws {
        var inspected: [String] = []
        let controller = NativeGhosttyTerminalController(readViewText: { _, title in
            inspected.append(title)
            return nil
        }, resolveApplication: { .init(pid: 7, token: "same-instance") }, execute: { _ in
            #"[{"terminalId":"claude","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"},{"terminalId":"shell","title":"private-shell","cwd":"/Users/me/Other"}]"#
        })
        _ = try controller.views(conversationTitles: ["ccx-thinking-block-sneha"])
        XCTAssertEqual(inspected, ["ccx-thinking-block-sneha"])
        inspected = []
        _ = try controller.views(conversationTitles: [])
        XCTAssertEqual(inspected, [])
    }

    func testPersistedEvidenceIsRevokedForChangedProcessDirectoryAndClosedSurface() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("terminal-evidence.json")
        var identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "original")
        var cwd = "/Users/me/Codes"
        var closed = false
        func controller() -> NativeGhosttyTerminalController {
            NativeGhosttyTerminalController(storageURL: file, resolveApplication: { identity }, execute: { _ in
                closed ? "[]" : "[{\"terminalId\":\"saved\",\"title\":\"ccx-thinking-block-sneha\",\"cwd\":\"\(cwd)\"}]"
            }, openAttach: { _ in "saved" })
        }
        XCTAssertTrue(controller().openClaudeAttach(.init(
            cwd: cwd, executable: "/Users/me/.local/bin/claude", jobId: "9dd37798"
        )))
        let saved = try Data(contentsOf: file)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        identity = .init(pid: 7, token: "replacement")
        XCTAssertNil(try controller().views()[0].titleUpdatesEnabled)
        identity = .init(pid: 7, token: "original")
        try saved.write(to: file)
        cwd = "/Users/me/Other"
        XCTAssertNil(try controller().views()[0].titleUpdatesEnabled)
        cwd = "/Users/me/Codes"
        try saved.write(to: file)
        closed = true
        XCTAssertEqual(try controller().views(), [])
        closed = false
        XCTAssertNil(try controller().views()[0].titleUpdatesEnabled)
    }

    func testUnknownQuotedAndDuplicateSurfaceContentCannotConfirmAConversation() throws {
        var rows = #"[{"terminalId":"a","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"}]"#
        var footer: String? = "An example: ccx-thinking-block-sneha —\naccept edits on · ← for agents\n❯ user prompt"
        let controller = NativeGhosttyTerminalController(readViewText: { _, _ in footer },
            resolveApplication: { .init(pid: 7, token: "same-instance") }, execute: { _ in rows })
        XCTAssertNil(try controller.views()[0].viewMode)
        footer = nil
        XCTAssertNil(try controller.views()[0].viewMode)
        footer = "ccx-thinking-block-sneha —\naccept edits on · ← for agents"
        rows = #"[{"terminalId":"a","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"},{"terminalId":"b","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"}]"#
        XCTAssertTrue(try controller.views().allSatisfy { $0.viewMode == nil })
    }

    func testFooterDoesNotUseAnEarlierMentionAsTheCurrentConversation() throws {
        let controller = NativeGhosttyTerminalController(readViewText: { _, _ in
            "ccx-thinking-block-sneha —\nMentioned above in the transcript\nanother-conversation —\nOpus 5.5 | Codes\naccept edits on · ← for agents"
        }, resolveApplication: { .init(pid: 7, token: "same-instance") },
            execute: { _ in #"[{"terminalId":"manual","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"}]"# })
        XCTAssertNil(try controller.views()[0].viewMode)
    }

    func testInvalidViewResponseDoesNotEraseVerifiedTerminalEvidence() throws {
        var rows = #"[{"terminalId":"saved","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"}]"#
        let valid = rows
        let controller = NativeGhosttyTerminalController(resolveApplication: { .init(pid: 7, token: "same-instance") },
            execute: { _ in rows }, openAttach: { _ in "saved" })
        XCTAssertTrue(controller.openClaudeAttach(.init(
            cwd: "/Users/me/Codes", executable: "/Users/me/.local/bin/claude", jobId: "9dd37798"
        )))
        rows = #"[{"terminalId":"saved","title":"ccx-thinking-block-sneha","cwd":"invalid"}]"#
        XCTAssertThrowsError(try controller.views())
        rows = valid
        XCTAssertEqual(try controller.views()[0].titleUpdatesEnabled, true)
    }

    func testRecoveredFocusRejectsAConversationChangeDuringActivation() throws {
        var name = "ccx-thinking-block-sneha"
        let controller = NativeGhosttyTerminalController(readViewText: { _, _ in
            name + " —\naccept edits on · ← for agents"
        }, resolveApplication: { .init(pid: 7, token: "same-instance") }, execute: { source in
            if source == GhosttyTerminalViewScript.list {
                return "[{\"terminalId\":\"manual\",\"title\":\"\(name)\",\"cwd\":\"/Users/me/Codes\"}]"
            }
            name = "another-conversation"
            return "ok"
        })
        let view = try XCTUnwrap(controller.views().first)
        XCTAssertFalse(controller.focus(view))
    }

    func testTrackedPlainTitleIsNotFocusedWhenFreshEvidenceShowsOverview() throws {
        var footer: String?
        var focuses = 0
        let rows = #"[{"terminalId":"saved","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"}]"#
        let controller = NativeGhosttyTerminalController(readViewText: { _, _ in footer },
            resolveApplication: { .init(pid: 7, token: "same-instance") },
            execute: { source in
                if source == GhosttyTerminalViewScript.list { return rows }
                focuses += 1
                return "ok"
            }, openAttach: { _ in "saved" })
        XCTAssertTrue(controller.openClaudeAttach(.init(
            cwd: "/Users/me/Codes", executable: "/Users/me/.local/bin/claude", jobId: "9dd37798"
        )))
        let target = try XCTUnwrap(controller.views().first)
        footer = "accept edits · enter to return · space to reply · ctrl+x to delete · ? for shortcuts"
        XCTAssertFalse(controller.focus(target))
        XCTAssertEqual(focuses, 0)
    }

    func testRecoveredPlainTitleClickUsesExactSurfaceAndRejectsOverviewBeforeFocusing() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var focused = [];
        function Application(){return {
            running: function(){return true}, terminals: function(){return [{
                id: function(){return 'manual'}, name: function(){return 'ccx-thinking-block-sneha'},
                workingDirectory: function(){return '/Users/me/Codes'}
            }]}, focus: function(t){focused.push(t.id())}, activate: function(){}
        };}
        """#)
        var footer = "ccx-thinking-block-sneha —\naccept edits on · ← for agents"
        let controller = NativeGhosttyTerminalController(readViewText: { _, _ in footer },
            resolveApplication: { .init(pid: 7, token: "same-instance") },
            execute: { context.evaluateScript($0)?.toString() })
        let view = try XCTUnwrap(controller.views().first)
        XCTAssertTrue(controller.focus(view))
        XCTAssertEqual(context.evaluateScript("JSON.stringify(focused)")?.toString(), #"["manual"]"#)
        footer = "accept edits · enter to return · space to reply · ctrl+x to delete · ? for shortcuts"
        XCTAssertFalse(controller.focus(view))
        XCTAssertEqual(context.evaluateScript("focused.length")?.toInt32(), 1)
        XCTAssertNil(context.exception)
    }

    func testPlainTitleConversationIsRecoveredFromCurrentFooterWithoutAttachmentTrust() throws {
        var footer = "ccx-thinking-block-sneha —\nOpus 5.5 | Codes\naccept edits on · ← for agents"
        let identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "same-instance")
        func controller() -> NativeGhosttyTerminalController {
            NativeGhosttyTerminalController(readViewText: { _, _ in footer }, resolveApplication: { identity },
                execute: { _ in #"[{"terminalId":"manual","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"}]"# })
        }
        XCTAssertEqual(try controller().views()[0].viewMode, .conversation)
        // A suppressed title stays unchanged when the UI enters overview.
        footer = "Needs input\nCompleted\n❯ describe a task for a new session\naccept edits · enter to return · space to reply · ctrl+x to delete · ? for shortcuts"
        XCTAssertEqual(try controller().views()[0].viewMode, .overview)
        footer = "ccx-thinking-block-sneha —\naccept edits on · ← for agents"
        XCTAssertEqual(try controller().views()[0].viewMode, .conversation)
    }

    func testCreatedTerminalEvidenceSurvivesHelperRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("terminal-evidence.json")
        let identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 7, token: "same-instance")
        let rows = #"[{"terminalId":"saved","title":"ccx-thinking-block-sneha","cwd":"/Users/me/Codes"}]"#
        func controller() -> NativeGhosttyTerminalController {
            NativeGhosttyTerminalController(storageURL: file, resolveApplication: { identity },
                execute: { $0 == GhosttyTerminalViewScript.list ? rows : "ok" }, openAttach: { _ in "saved" })
        }
        let first = controller()
        XCTAssertTrue(first.openClaudeAttach(.init(
            cwd: "/Users/me/Codes", executable: "/Users/me/.local/bin/claude", jobId: "9dd37798"
        )))
        XCTAssertEqual(try first.views()[0].titleUpdatesEnabled, true)
        let restarted = controller()
        let view = try restarted.views()[0]
        XCTAssertEqual(view.titleUpdatesEnabled, true)
        XCTAssertTrue(restarted.focus(view))
    }

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
