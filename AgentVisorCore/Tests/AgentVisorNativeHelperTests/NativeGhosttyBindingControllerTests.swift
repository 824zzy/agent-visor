import AgentVisorCore
@testable import AgentVisorNativeHelper
import JavaScriptCore
import XCTest

final class NativeGhosttyBindingControllerTests: XCTestCase {
    func testResolvesExactlyOneSurfaceFromItsNonceMarker() throws {
        let nonce = String(repeating: "a", count: 32)
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var focused = [];
        var terminal = {
            id: function() { return 'terminal-1'; },
            name: function() { return 'AVB:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; },
            workingDirectory: function() { return '/Users/me/Codes'; }
        };
        var tab = {
            id: function() { return 'tab-1'; },
            selected: function() { return true; },
            terminals: function() { return [terminal]; },
            focusedTerminal: function() { return terminal; }
        };
        var window = {
            id: function() { return 'window-1'; },
            selectedTab: function() { return tab; },
            tabs: function() { return [tab]; },
            terminals: function() { return [terminal]; }
        };
        function Application() {
            return {
                running: function() { return true; },
                windows: function() { return [window]; },
                terminals: function() { return [terminal]; },
                frontmost: function() { return true; },
                frontWindow: function() { return window; },
                activate: function() {},
                focus: function(surface) { focused.push(surface.id()); }
            };
        }
        """#)

        let controller = NativeGhosttyBindingController(
            resolveApplication: { .init(pid: 701, token: "ghostty-start-1") },
            execute: { context.evaluateScript($0)?.toString() },
            permission: { true },
            isFrontmost: { _ in true }
        )

        let binding = try controller.resolve(nonce: nonce)
        XCTAssertEqual(binding, NativeHelperGhosttyBinding(
            applicationPID: 701,
            processStartToken: "ghostty-start-1",
            windowId: "window-1",
            tabId: "tab-1",
            terminalId: "terminal-1",
            nonce: nonce
        ))
    }

    func testFocusSelectsTheExactTabAndVerifiesTheNativeReadback() throws {
        let nonce = String(repeating: "b", count: 32)
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var targetTerminal = {
            id: function() { return 'terminal-target'; },
            name: function() { return 'AVB:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; }
        };
        var decoyTerminal = {
            id: function() { return 'terminal-decoy'; },
            name: function() { return 'plain'; }
        };
        var targetTab = {
            id: function() { return 'tab-target'; },
            terminals: function() { return [targetTerminal]; },
            focusedTerminal: function() { return focusedTerminalValue; }
        };
        var decoyTab = {
            id: function() { return 'tab-decoy'; },
            terminals: function() { return [decoyTerminal]; },
            focusedTerminal: function() { return focusedTerminalValue; }
        };
        var targetWindow = {
            id: function() { return 'window-target'; },
            tabs: function() { return [decoyTab, targetTab]; },
            selectedTab: function() { return selectedTabValue; }
        };
        var selectedTabValue = decoyTab;
        var focusedTerminalValue = decoyTerminal;
        var frontWindowValue = targetWindow;
        function Application() {
            return {
                running: function() { return true; },
                windows: function() { return [targetWindow]; },
                frontmost: function() { return true; },
                frontWindow: function() { return frontWindowValue; },
                focus: function(value) { focusedTerminalValue = value; },
                selectTab: function(value) { selectedTabValue = value; },
                activateWindow: function(value) { frontWindowValue = value; },
                activate: function() {}
            };
        }
        """#)
        let controller = NativeGhosttyBindingController(
            resolveApplication: { .init(pid: 702, token: "ghostty-start-2") },
            execute: { context.evaluateScript($0)?.toString() },
            permission: { true },
            isFrontmost: { _ in true }
        )
        let target = NativeHelperGhosttyBinding(
            applicationPID: 702,
            processStartToken: "ghostty-start-2",
            windowId: "window-target",
            tabId: "tab-target",
            terminalId: "terminal-target",
            nonce: nonce
        )

        XCTAssertNoThrow(try controller.focus(target))
        XCTAssertEqual(context.evaluateScript("selectedTabValue.id() + '|' + focusedTerminalValue.id()")?.toString(),
                       "tab-target|terminal-target")
    }

    func testDuplicateMarkerIsRejectedAsAmbiguous() throws {
        let nonce = String(repeating: "c", count: 32)
        let controller = NativeGhosttyBindingController(
            resolveApplication: { .init(pid: 703, token: "ghostty-start-3") },
            execute: { _ in
                #"[{"windowId":"window-1","tabId":"tab-1","terminalId":"terminal-1","nonce":"cccccccccccccccccccccccccccccccc"},{"windowId":"window-2","tabId":"tab-2","terminalId":"terminal-2","nonce":"cccccccccccccccccccccccccccccccc"}]"#
            },
            permission: { true },
            isFrontmost: { _ in true }
        )

        XCTAssertThrowsError(try controller.resolve(nonce: nonce)) { error in
            XCTAssertEqual(error as? NativeGhosttyBindingError, .ambiguous)
        }
    }

    func testFocusRejectsAReadbackThatDoesNotMatchTheBoundSurface() throws {
        let target = NativeHelperGhosttyBinding(
            applicationPID: 705,
            processStartToken: "ghostty-start-5",
            windowId: "window-target",
            tabId: "tab-target",
            terminalId: "terminal-target",
            nonce: String(repeating: "f", count: 32)
        )
        let controller = NativeGhosttyBindingController(
            resolveApplication: { .init(pid: 705, token: "ghostty-start-5") },
            execute: { _ in
                #"{"status":"ok","frontmost":true,"windowId":"window-target","tabId":"tab-decoy","terminalId":"terminal-target"}"#
            },
            permission: { true },
            isFrontmost: { _ in true }
        )

        XCTAssertThrowsError(try controller.focus(target)) { error in
            XCTAssertEqual(error as? NativeGhosttyBindingError, .focusFailed)
        }
    }

    func testFocusRejectsProcessReplacementBeforeAcceptingTheReadback() throws {
        let target = NativeHelperGhosttyBinding(
            applicationPID: 706,
            processStartToken: "ghostty-start-6",
            windowId: "window-target",
            tabId: "tab-target",
            terminalId: "terminal-target",
            nonce: String(repeating: "a", count: 32)
        )
        var identityReads = 0
        var executeCount = 0
        let controller = NativeGhosttyBindingController(
            resolveApplication: {
                identityReads += 1
                return identityReads == 1
                    ? .init(pid: 706, token: "ghostty-start-6")
                    : .init(pid: 706, token: "ghostty-start-replaced")
            },
            execute: { _ in executeCount += 1; return "{}" },
            permission: { true },
            isFrontmost: { _ in true }
        )

        XCTAssertThrowsError(try controller.focus(target)) { error in
            XCTAssertEqual(error as? NativeGhosttyBindingError, .applicationChanged)
        }
        XCTAssertEqual(executeCount, 1)
    }

    func testPermissionStatusAndResolutionFailClosedWithoutExecutingScript() throws {
        var executeCount = 0
        let controller = NativeGhosttyBindingController(
            resolveApplication: { .init(pid: 704, token: "ghostty-start-4") },
            execute: { _ in executeCount += 1; return "[]" },
            permission: { false },
            isFrontmost: { _ in true }
        )

        XCTAssertFalse(controller.status())
        XCTAssertThrowsError(try controller.resolve(nonce: String(repeating: "d", count: 32))) { error in
            XCTAssertEqual(error as? NativeGhosttyBindingError, .permissionDenied)
        }
        XCTAssertEqual(executeCount, 0)
    }
}
