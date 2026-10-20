import AgentVisorCore
import AppKit
import Carbon
import Foundation

/// Errors from the nonce-bound Ghostty surface path. The controller fails
/// closed: it never falls back to a title, cwd, generic application, or input.
public enum NativeGhosttyBindingError: Error, Equatable {
    case invalidNonce
    case unavailable
    case permissionDenied
    case unreadable
    case malformedResponse
    case missing
    case ambiguous
    case applicationChanged
    case stale
    case focusFailed
}

/// Resolves and focuses one Ghostty surface using an exact, short-lived title
/// marker. All environment-dependent operations are injected so the behavior
/// can be exercised against a JavaScriptCore fixture without touching a live
/// terminal or native window during tests.
public final class NativeGhosttyBindingController {
    private struct SurfaceRow: Codable, Equatable {
        let windowId: String
        let tabId: String
        let terminalId: String
        let nonce: String
    }

    private struct FocusResult: Codable, Equatable {
        let status: String
        let frontmost: Bool
        let windowId: String?
        let tabId: String?
        let terminalId: String?
    }

    private let resolveApplication: () -> NativeGhosttyTerminalController.ApplicationIdentity?
    private let execute: (String) -> String?
    private let permission: () -> Bool
    private let isFrontmost: (Int32) -> Bool

    public init(
        resolveApplication: @escaping () -> NativeGhosttyTerminalController.ApplicationIdentity? =
            NativeGhosttyTerminalController.liveApplication,
        execute: @escaping (String) -> String? = NativeGhosttyTerminalController.liveScript,
        permission: @escaping () -> Bool = NativeGhosttyBindingController.liveAutomationPermission,
        isFrontmost: @escaping (Int32) -> Bool = NativeGhosttyBindingController.liveIsFrontmost
    ) {
        self.resolveApplication = resolveApplication
        self.execute = execute
        self.permission = permission
        self.isFrontmost = isFrontmost
    }

    /// Returns true only when exactly one live Ghostty process is resolvable
    /// and Automation is already granted. This check never prompts.
    public func status() -> Bool {
        permission() && resolveApplication() != nil
    }

    public func resolve(nonce: String) throws -> NativeHelperGhosttyBinding {
        guard Self.isValidNonce(nonce) else { throw NativeGhosttyBindingError.invalidNonce }
        guard permission() else { throw NativeGhosttyBindingError.permissionDenied }
        guard let identity = resolveApplication() else { throw NativeGhosttyBindingError.unavailable }
        guard let output = execute(Self.resolveScript(nonce: nonce)) else {
            throw NativeGhosttyBindingError.unreadable
        }
        guard resolveApplication() == identity else {
            throw NativeGhosttyBindingError.applicationChanged
        }
        guard let data = output.data(using: .utf8), data.count <= 64 * 1_024,
              let rows = try? JSONDecoder().decode([SurfaceRow].self, from: data),
              rows.count <= 128, rows.allSatisfy(Self.isValidSurfaceRow) else {
            throw NativeGhosttyBindingError.malformedResponse
        }
        let matches = rows.filter { $0.nonce == nonce }
        guard !matches.isEmpty else { throw NativeGhosttyBindingError.missing }
        guard matches.count == 1, let match = matches.first else {
            throw NativeGhosttyBindingError.ambiguous
        }
        let binding = NativeHelperGhosttyBinding(
            applicationPID: identity.pid,
            processStartToken: identity.token,
            windowId: match.windowId,
            tabId: match.tabId,
            terminalId: match.terminalId,
            nonce: nonce
        )
        guard binding.isValid else { throw NativeGhosttyBindingError.malformedResponse }
        guard resolveApplication() == identity else {
            throw NativeGhosttyBindingError.applicationChanged
        }
        return binding
    }

    public func focus(_ target: NativeHelperGhosttyBinding) throws {
        guard target.isValid, Self.isValidNonce(target.nonce) else {
            throw NativeGhosttyBindingError.stale
        }
        guard permission() else { throw NativeGhosttyBindingError.permissionDenied }
        guard let identity = resolveApplication(),
              identity.pid == target.applicationPID,
              identity.token == target.processStartToken else {
            throw NativeGhosttyBindingError.stale
        }
        guard let output = execute(Self.focusScript(target: target)) else {
            throw NativeGhosttyBindingError.unreadable
        }
        guard resolveApplication() == identity else {
            throw NativeGhosttyBindingError.applicationChanged
        }
        guard let data = output.data(using: .utf8), data.count <= 8 * 1_024,
              let result = try? JSONDecoder().decode(FocusResult.self, from: data),
              result.status == "ok",
              result.frontmost,
              result.windowId == target.windowId,
              result.tabId == target.tabId,
              result.terminalId == target.terminalId,
              isFrontmost(identity.pid) else {
            throw NativeGhosttyBindingError.focusFailed
        }
        guard resolveApplication() == identity else {
            throw NativeGhosttyBindingError.applicationChanged
        }
    }

    private static func isValidSurfaceRow(_ row: SurfaceRow) -> Bool {
        validIdentity(row.windowId) && validIdentity(row.tabId)
            && validIdentity(row.terminalId) && isValidNonce(row.nonce)
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 128 && !value.contains("\0")
    }

    private static func isValidNonce(_ nonce: String) -> Bool {
        nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
    }

    private static func resolveScript(nonce: String) -> String {
        let encodedNonce = jsString(nonce)
        return """
        (function () {
            var expected = \(encodedNonce);
            var app = Application('com.mitchellh.ghostty');
            if (!app.running()) return '[]';
            var rows = [];
            var windows = app.windows();
            if (!windows || windows.length > 64) return '[]';
            for (var wi = 0; wi < windows.length; wi++) {
                var window = windows[wi];
                var windowId = window.id();
                if (typeof windowId !== 'string' || !windowId || windowId.length > 128) continue;
                var tabs = window.tabs();
                if (!tabs || tabs.length > 128) continue;
                for (var ti = 0; ti < tabs.length; ti++) {
                    var tab = tabs[ti];
                    var tabId = tab.id();
                    if (typeof tabId !== 'string' || !tabId || tabId.length > 128) continue;
                    var terminals = tab.terminals();
                    if (!terminals || terminals.length > 128) continue;
                    for (var si = 0; si < terminals.length; si++) {
                        var terminal = terminals[si];
                        var terminalId = terminal.id(), name = terminal.name();
                        if (typeof terminalId !== 'string' || !terminalId || terminalId.length > 128) continue;
                        if (name === 'AVB:' + expected) {
                            rows.push({windowId: windowId, tabId: tabId, terminalId: terminalId, nonce: expected});
                        }
                    }
                }
            }
            return JSON.stringify(rows);
        })()
        """
    }

    private static func focusScript(target: NativeHelperGhosttyBinding) -> String {
        let encodedTarget = String(data: try! JSONEncoder().encode(target), encoding: .utf8)!
        return """
        (function () {
            var expected = \(encodedTarget);
            var app = Application('com.mitchellh.ghostty');
            if (!app.running()) return JSON.stringify({status: 'missing', frontmost: false});
            var foundWindow = null, foundTab = null, foundTerminal = null;
            var windows = app.windows();
            for (var wi = 0; wi < windows.length; wi++) {
                var window = windows[wi];
                if (window.id() !== expected.windowId) continue;
                foundWindow = window;
                var tabs = window.tabs();
                for (var ti = 0; ti < tabs.length; ti++) {
                    var tab = tabs[ti];
                    if (tab.id() !== expected.tabId) continue;
                    foundTab = tab;
                    var terminals = tab.terminals();
                    for (var si = 0; si < terminals.length; si++) {
                        var terminal = terminals[si];
                        if (terminal.id() === expected.terminalId &&
                            terminal.name() === 'AVB:' + expected.nonce) {
                            foundTerminal = terminal;
                            break;
                        }
                    }
                    break;
                }
                break;
            }
            if (!foundWindow || !foundTab || !foundTerminal) {
                return JSON.stringify({status: 'stale', frontmost: false});
            }
            app.focus(foundTerminal);
            app.selectTab(foundTab);
            app.activateWindow(foundWindow);
            app.activate();
            if (foundTerminal.name() !== 'AVB:' + expected.nonce) {
                return JSON.stringify({status: 'stale', frontmost: false});
            }
            var frontWindow = app.frontWindow();
            var selectedTab = frontWindow && frontWindow.selectedTab();
            var focusedTerminal = selectedTab && selectedTab.focusedTerminal();
            var result = {
                status: app.frontmost() && frontWindow && selectedTab && focusedTerminal ? 'ok' : 'not-frontmost',
                frontmost: app.frontmost() === true,
                windowId: frontWindow ? frontWindow.id() : null,
                tabId: selectedTab ? selectedTab.id() : null,
                terminalId: focusedTerminal ? focusedTerminal.id() : null
            };
            return JSON.stringify(result);
        })()
        """
    }

    private static func jsString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }

    public static func liveIsFrontmost(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isActive == true
    }

    public static func liveAutomationPermission() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.mitchellh.ghostty")
        return AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false
        ) == noErr
    }
}
