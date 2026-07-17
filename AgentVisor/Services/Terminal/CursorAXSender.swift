//
//  CursorAXSender.swift
//  AgentVisor
//
//  Silent text-send into Cursor's claude-code extension chat input.
//
//  Full pipeline (verified 2026-05-20):
//    1. Dispatch `cursor://anthropic.claude-code/open?session=<id>`
//       via `NSWorkspace.open(_:configuration:)` with
//       `activates = false, hides = true`. The URL is the
//       extension's primary-editor.open command; with activates=false
//       LaunchServices delivers the GURL Apple Event to Cursor's
//       process WITHOUT raising the app. Cursor's URL handler then
//       switches the primary editor tab to the target session in
//       the matching workspace window. Focus stays where it was.
//    2. Wait ~800 ms for the webview to mount the new tab's chat
//       input. Empirically the AXTextArea is in the AX tree within
//       ~500 ms; we use 800 ms for headroom on slower machines.
//    3. Walk Cursor's AX tree, find the AXTextArea with
//       AXDescription="Message input" in the workspace window.
//    4. Set AXFocusedAttribute = true on the textarea.
//    5. Set AXValueAttribute to the user's message.
//    6. Post Return via `CGEventPostToPid` to Cursor's pid — this
//       delivers a keystroke to a specific process without requiring
//       the app to be frontmost, so agent-visor stays in focus.
//
//  Why this works where prior attempts failed:
//    - `osascript tell process X to keystroke` routes through System
//      Events to whatever's frontmost; verified empty no-op.
//    - URL via `open cursor://…` raises Cursor via LaunchServices.
//      The `NSWorkspace.OpenConfiguration.activates = false` flag
//      changes that behavior — the URL Apple Event is delivered but
//      the app is NOT brought to foreground.
//    - AX-only tab switching (`AXPress`, `AXSelected=true`,
//      `AXValue=1`, `AXSelectedChildren` on the AXTabGroup) all
//      either no-op or return AttributeUnsupported; Cursor's
//      Chromium webview ignores AX writes for selection state.
//    - AX write WITHOUT a follow-up Enter doesn't submit — Cursor's
//      send button is gated on React's controlled-input state which
//      doesn't pick up the AX-set value. The Return key event makes
//      Cursor's input handler read the value and submit it.
//    - AX write PLUS CGEventPostToPid Return makes Cursor's chat
//      input pick up the message AND submit. Verified end-to-end:
//      JSONL grows with the user message + assistant response, and
//      agent-visor remains frontmost the entire time.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log
import AgentVisorCore

enum CursorAXSender {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "CursorAXSender")

    /// Cursor's todesktop bundle identifier.
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    /// Returns true on success. On failure logs why and returns false
    /// so the caller can fall back / surface the problem.
    static func send(text: String, toSession session: SessionState) -> Bool {
        guard let cursorPid = runningCursorPID() else {
            logger.info("Cursor not running")
            return false
        }

        let app = AXUIElementCreateApplication(cursorPid)
        guard var window = findWorkspaceWindow(in: app, cwd: session.cwd) else {
            logger.info("could not find workspace window for cwd=\(session.cwd, privacy: .public)")
            return false
        }

        // Switch the workspace window's primary editor tab to the
        // target session. Cursor's URL handler always activates the
        // app via LaunchServices (NSWorkspace.OpenConfiguration's
        // activates=false flag is silently ignored when Cursor's URL
        // handler calls createPanel(ViewColumn.Active) internally —
        // verified 2026-05-20 with run-loop-pumped focus trace).
        //
        // Mitigation: dispatch the URL, then IMMEDIATELY reassert
        // agent-visor's frontmost state on the main queue + poll for
        // the AXTextArea instead of sleeping a flat 800ms. The
        // activation race fires before the window-server composites
        // Cursor's frontmost frame, so the user sees at most a
        // sub-frame flicker (target: <1 frame, ~16ms).
        let activeTabLabel = activeClaudeTabTitle(in: window)
        let targetTitle = CursorSessionTitleStore.snapshotTitle(forSessionId: session.sessionId)
            ?? session.displayTitle
        let alreadyActive = activeTabMatchesTarget(active: activeTabLabel, target: targetTitle)
        if !alreadyActive {
            // Use the full multi-window-correct route. If the user
            // sends without first clicking the pill (rare — most flows
            // pre-warm via preSwitchTab), or if some other gesture
            // changed Cursor's main window between pill-click and send,
            // we still want the URL to land on the right extension host
            // so it reveals the existing tab rather than spawning a
            // new one in the wrong workspace.
            routeToSessionTab(session: session, cursorPid: cursorPid, reason: "send-route")
            // After routing, the now-main window owns the correct
            // extension host's session tab. Re-resolve the window via
            // AXMainWindow so the AX walk below targets it, not the
            // possibly-wrong window we picked via title fuzzy match
            // when multiple Cursor windows share the same workspace
            // last-path-component.
            if let mainWindow = mainWindow(forApp: cursorPid) {
                window = mainWindow
            }
            // Race agent-visor's activation against Cursor's URL-induced
            // activation. We don't await — fire the activate and continue.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
            logger.info(
                "send-route session=\(session.sessionId.prefix(8), privacy: .public) target=\"\(targetTitle, privacy: .public)\" wasActive=\"\(activeTabLabel ?? "nil", privacy: .public)\""
            )
        }

        // Poll for the AXTextArea — proceeds as soon as the new tab's
        // webview mounts its chat input. Re-asserts agent-visor focus
        // on every poll iteration to defeat Cursor's activation.
        guard let input = waitForMessageInput(in: window, timeout: 1.5) else {
            logger.info("could not find AXTextArea desc=Message input within timeout")
            return false
        }

        // 1. Focus the textarea so the Return key is delivered to it.
        let focusErr = AXUIElementSetAttributeValue(
            input, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        if focusErr != .success {
            logger.error("AXFocus failed rc=\(focusErr.rawValue)")
            // Continue anyway — sometimes focus is already on the
            // composer and the set fails as a no-op.
        }

        // 2. Clear any leftover placeholder/draft, then set the value.
        _ = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, "" as CFString)
        let setErr = AXUIElementSetAttributeValue(
            input, kAXValueAttribute as CFString, text as CFString
        )
        guard setErr == .success else {
            logger.error("AXValue set failed rc=\(setErr.rawValue)")
            return false
        }

        // Small settle window so the webview registers the new value
        // before we deliver the Return key. Empirically ~150-250 ms.
        Thread.sleep(forTimeInterval: 0.25)

        // 3. Deliver Return key directly to Cursor's pid. Bypasses
        //    frontmost-app routing — agent-visor stays in focus.
        guard postReturnKey(toPID: cursorPid) else {
            logger.error("CGEventPostToPid failed for pid=\(cursorPid)")
            return false
        }

        // Final activation reassertion — belt and suspenders against
        // any lingering activation from Cursor's tab-switch handler.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        logger.info(
            "sent \(text.count) chars to Cursor pid=\(cursorPid) session=\(session.sessionId.prefix(8), privacy: .public)"
        )
        return true
    }

    // MARK: - Helpers

    private static func runningCursorPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: cursorBundleID)
            .first?
            .processIdentifier
    }

    /// Locate the Cursor AXWindow whose title matches the session's
    /// workspace folder.
    private static func findWorkspaceWindow(
        in app: AXUIElement,
        cwd: String
    ) -> AXUIElement? {
        let workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
        guard let windows: [AXUIElement] = axAttribute(app, kAXWindowsAttribute) else {
            return nil
        }
        for window in windows {
            let title: String = axAttribute(window, kAXTitleAttribute) ?? ""
            if windowMatchesWorkspace(title: title, workspaceName: workspaceName) {
                return window
            }
        }
        // Fallback: if no title match, take the first window with a
        // Message input — better to send to the wrong workspace than
        // fail silently (and we log the fallback).
        for window in windows {
            if findMessageInput(in: window) != nil {
                logger.info("workspace title-match failed, falling back to first window with chat")
                return window
            }
        }
        return nil
    }

    /// Pre-warm: route Cursor to the given session's tab WITHOUT
    /// performing any subsequent AX write. Used when the user clicks
    /// a session pill in agent-visor — by tying the (unavoidable)
    /// tab-switch activation to an explicit user action rather than
    /// to the send action, subsequent sends from the chat composer
    /// can be fully silent (active-tab match → no URL dispatch).
    ///
    /// IMPORTANT — multi-window correctness:
    /// Each Cursor window owns its own extension-host process with
    /// its own `sessionPanels` map. The `cursor://anthropic.claude-code/open?session=<id>`
    /// URL is delivered to whichever extension host is in the window
    /// that Cursor's window-server currently considers "main." If the
    /// user has multiple Cursor windows open and the wrong one is main,
    /// the URL routes to a host that doesn't own the session, and that
    /// host SPAWNS A NEW TAB (running `claude --resume <id>`) instead
    /// of revealing the existing one.
    ///
    /// Fix: resolve the session's owning workspace folder via its
    /// IDE lock file, raise that workspace window via LaunchServices
    /// (`open -a Cursor <folder>`), wait for AXMainWindow to flip
    /// to the target, and only then dispatch the cursor:// URL.
    ///
    /// On Cursor's main process activating itself: `launchMainService.start`
    /// unconditionally calls `app.focus({steal:true})` on macOS (verified
    /// in `Resources/app/out/main.js`). The activation is unavoidable;
    /// this preSwitchTab is what ties it to the pill-click gesture.
    static func preSwitchTab(toSession session: SessionState) {
        guard let cursorPid = runningCursorPID() else { return }
        routeToSessionTab(session: session, cursorPid: cursorPid, reason: "preSwitchTab")
        // Aggressive reactivate so agent-visor reclaims focus quickly
        // after Cursor's URL-handler activation.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Full multi-window-correct tab routing: raise the workspace
    /// window matching the session's cwd, wait for AXMainWindow to
    /// flip, then dispatch the cursor:// URL. Blocks for up to ~600ms
    /// total (subprocess + AX poll). Falls back to bare URL dispatch
    /// if no IDE lock file matches the cwd.
    private static func routeToSessionTab(session: SessionState, cursorPid: pid_t, reason: String) {
        let workspaceFolder = findIDEWorkspaceFolder(forSessionCwd: session.cwd)
        if let workspaceFolder = workspaceFolder {
            let folderName = URL(fileURLWithPath: workspaceFolder).lastPathComponent
            let opened = openViaLaunchServices(path: workspaceFolder)
            waitForMainWindowTitle(contains: folderName, forApp: cursorPid, timeout: 0.6)
            logger.info(
                "\(reason, privacy: .public) raised workspace=\(folderName, privacy: .public) opened=\(opened, privacy: .public) session=\(session.sessionId.prefix(8), privacy: .public)"
            )
        } else {
            logger.info(
                "\(reason, privacy: .public) no lock file for cwd=\(session.cwd, privacy: .public) — bare URL dispatch may land on wrong window"
            )
        }
        _ = switchTabSilently(toSessionId: session.sessionId)
    }

    /// Dispatch `cursor://anthropic.claude-code/open?session=<id>` so
    /// Cursor's URL handler switches the primary editor to the target
    /// session. NSWorkspace.OpenConfiguration.activates=false routes
    /// the GURL Apple Event to Cursor's process WITHOUT a NEW
    /// activation; Cursor's main process activates itself anyway via
    /// `app.focus({steal:true})`. Returns true if dispatched.
    private static func switchTabSilently(toSessionId sessionId: String) -> Bool {
        guard let url = URL(string: "cursor://anthropic.claude-code/open?session=\(sessionId)") else {
            return false
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.hides = true
        cfg.promptsUserIfNeeded = false
        // Non-blocking — we don't care about the callback; the AX
        // settle delay covers the actual tab-switch latency.
        NSWorkspace.shared.open(url, configuration: cfg, completionHandler: nil)
        return true
    }

    /// Description of the currently active Claude editor tab in this
    /// window. Cursor sets `AXSelected = true` (and `AXValue = 1`) on
    /// the active `AXRadioButton` tab. Returns the tab's label sans
    /// the trailing ", Editor Group N" suffix.
    static func activeClaudeTabTitle(in window: AXUIElement) -> String? {
        var tabs: [AXUIElement] = []
        collectTabs(in: window, into: &tabs)
        for tab in tabs {
            let selected: Bool = (axAttribute(tab, kAXSelectedAttribute) as Bool?) ?? false
            let value: Int = (axAttribute(tab, kAXValueAttribute) as Int?) ?? 0
            guard selected || value == 1 else { continue }
            let desc: String = axAttribute(tab, kAXDescriptionAttribute) ?? ""
            let label = desc.split(separator: ",").first.map { String($0) } ?? desc
            return normalizeTabLabel(label)
        }
        return nil
    }

    /// True iff the user-intended session title corresponds to
    /// Cursor's currently active tab. Handles Cursor's "…" truncation
    /// of long tab labels: `active` is what Cursor shows (possibly
    /// truncated), `target` is what we believe the full title to be.
    /// Match iff target starts with active (one-directional).
    private static func activeTabMatchesTarget(active: String?, target: String) -> Bool {
        guard let activeLabel = active, !activeLabel.isEmpty else { return false }
        let normalizedTarget = normalizeTabLabel(target)
        let normalizedActive = normalizeTabLabel(activeLabel)
        if normalizedActive == normalizedTarget { return true }
        return normalizedTarget.hasPrefix(normalizedActive)
    }

    /// (Kept for reference / future use — silent tab switching is not
    /// currently possible, see `send`'s comment.) Switch via AXPress
    /// is documented to be a no-op for Cursor's tab AXRadioButtons.
    private static func switchToTab(matching target: String, in window: AXUIElement) -> Bool {
        guard !target.isEmpty else { return false }
        var tabs: [AXUIElement] = []
        collectTabs(in: window, into: &tabs)

        // Build a normalized prefix for matching. Cursor truncates
        // long tab titles with " …" — strip trailing ellipsis / dots
        // and whitespace so partial matches work both directions.
        let normalizedTarget = normalizeTabLabel(target)

        // Matching rule: a tab's label is a match iff the target
        // STARTS WITH the label. This accounts for Cursor truncating
        // long tab titles with " …" (the tab desc becomes the prefix
        // of the full session title we get from the title store).
        //
        // Among multiple matches, prefer the LONGEST label — that's
        // the most specific match. Without this, a tab labelled
        // "Obsidian" would be eclipsed by an earlier "Obsidian for
        // AI systems …" tab whose label is also a prefix of itself
        // but NOT of the target "Obsidian" — exact match wins.
        //
        // Reverse-direction match (label hasPrefix target) is
        // intentionally NOT considered: it caused the bug where
        // target="Obsidian" wrongly matched tab "Obsidian for AI
        // systems …" because the label happens to start with the
        // target string.
        var bestMatch: AXUIElement?
        var bestLabel: String = ""
        var bestSelected = false
        for tab in tabs {
            let desc: String = axAttribute(tab, kAXDescriptionAttribute) ?? ""
            let tabLabel = desc.split(separator: ",").first.map { String($0) } ?? desc
            let normalizedLabel = normalizeTabLabel(tabLabel)
            guard !normalizedLabel.isEmpty else { continue }
            guard normalizedTarget.hasPrefix(normalizedLabel) else { continue }
            if normalizedLabel.count > bestLabel.count {
                bestMatch = tab
                bestLabel = normalizedLabel
                let selectedFlag: Bool = (axAttribute(tab, kAXSelectedAttribute) as Bool?) ?? false
                let valueFlag: Int = (axAttribute(tab, kAXValueAttribute) as Int?) ?? 0
                bestSelected = selectedFlag || valueFlag == 1
            }
        }
        guard let target = bestMatch else { return false }
        if bestSelected { return false }  // already on the right tab
        let pressErr = AXUIElementPerformAction(target, kAXPressAction as CFString)
        if pressErr != .success {
            logger.error("AXPress on tab failed rc=\(pressErr.rawValue)")
            return false
        }
        return true
    }

    private static func collectTabs(in elem: AXUIElement, into out: inout [AXUIElement], depth: Int = 0) {
        if depth > 60 { return }
        let role: String = axAttribute(elem, kAXRoleAttribute) ?? ""
        if role == "AXRadioButton" {
            let sub: String = axAttribute(elem, kAXSubroleAttribute) ?? ""
            let desc: String = axAttribute(elem, kAXDescriptionAttribute) ?? ""
            if sub == "AXTabButton" || desc.contains("Editor Group") {
                out.append(elem)
            }
        }
        guard let kids: [AXUIElement] = axAttribute(elem, kAXChildrenAttribute) else { return }
        for c in kids {
            collectTabs(in: c, into: &out, depth: depth + 1)
        }
    }

    private static func normalizeTabLabel(_ s: String) -> String {
        var t = s
        while t.hasSuffix("…") || t.hasSuffix(".") || t.hasSuffix(" ") {
            t.removeLast()
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cursor window titles look like "<file> — <workspaceName>".
    /// Match by suffix after the em-dash or hyphen separator.
    private static func windowMatchesWorkspace(title: String, workspaceName: String) -> Bool {
        guard !workspaceName.isEmpty else { return false }
        // Em-dash ('—') is the standard separator; some titles use a
        // plain hyphen on older builds. Check both.
        let separators = [" — ", " - "]
        for sep in separators {
            if let range = title.range(of: sep, options: .backwards) {
                let suffix = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if suffix == workspaceName { return true }
            }
        }
        // Fallback: workspace name appears anywhere in title.
        return title.contains(workspaceName)
    }

    /// Poll for the workspace window's `Message input` AXTextArea,
    /// re-activating agent-visor on every iteration to defeat any
    /// activation Cursor performs in response to URL dispatch /
    /// tab-switch DOM events. Returns as soon as the input is found.
    private static func waitForMessageInput(in window: AXUIElement, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
            if let input = findMessageInput(in: window) {
                logger.info("found chat input after \(attempt) poll iter(s)")
                return input
            }
            attempt += 1
            Thread.sleep(forTimeInterval: 0.04)
        }
        return nil
    }

    private static func findMessageInput(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 60 { return nil }
        let role: String = axAttribute(root, kAXRoleAttribute) ?? ""
        let desc: String = axAttribute(root, kAXDescriptionAttribute) ?? ""
        if role == "AXTextArea" && desc == "Message input" {
            return root
        }
        guard let kids: [AXUIElement] = axAttribute(root, kAXChildrenAttribute) else {
            return nil
        }
        for child in kids {
            if let hit = findMessageInput(in: child, depth: depth + 1) {
                return hit
            }
        }
        return nil
    }

    private static func postReturnKey(toPID pid: pid_t) -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
        else { return false }
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)
        up.postToPid(pid)
        return true
    }

    /// Convenience generic wrapper around AXUIElementCopyAttributeValue
    /// that returns the typed value or nil. Saves the boilerplate at
    /// each call site.
    private static func axAttribute<T>(_ elem: AXUIElement, _ key: String) -> T? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(elem, key as CFString, &ref)
        if err != .success { return nil }
        return ref as? T
    }

    // MARK: - Workspace routing (multi-window correctness)

    /// Find the workspace folder matching a session's cwd by reading
    /// IDE lock files at `~/.claude/ide/<port>.lock`. Each lock file is
    /// one Cursor extension host's metadata; `workspaceFolders` is the
    /// list of folders that host serves. Pick the longest matching
    /// prefix of `cwd` so a session whose cwd is a subdirectory still
    /// resolves to the right owning host.
    private static func findIDEWorkspaceFolder(forSessionCwd cwd: String) -> String? {
        let lockDir = NSHomeDirectory() + "/.claude/ide"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: lockDir) else {
            return nil
        }
        var bestMatch: (folder: String, length: Int)? = nil
        for file in files where file.hasSuffix(".lock") {
            let path = lockDir + "/" + file
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folders = json["workspaceFolders"] as? [String]
            else { continue }
            for folder in folders {
                if cwd == folder || cwd.hasPrefix(folder + "/") {
                    if bestMatch == nil || folder.count > bestMatch!.length {
                        bestMatch = (folder, folder.count)
                    }
                }
            }
        }
        return bestMatch?.folder
    }

    /// `open -a Cursor <path>` via `/usr/bin/open`. Cursor handles the
    /// document Apple Event internally and routes to the workspace-
    /// matching window, bringing it forward as main. Sequoia permits
    /// this as a user-initiated document action even from a background
    /// LSUIElement source, where cross-app AXRaise silently no-ops.
    private static func openViaLaunchServices(path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Cursor", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Read Cursor's current AXMainWindow as an AXUIElement, or nil if
    /// it's not yet readable. Used after `routeToSessionTab` to grab
    /// the window the URL handler will have just landed in.
    private static func mainWindow(forApp pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var mainRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
              let main = mainRef,
              CFGetTypeID(main) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(main, to: AXUIElement.self)
    }

    /// Poll Cursor's AXMainWindow until its title contains the given
    /// substring (typically the workspace folder's last path component),
    /// or `timeout` elapses. Synchronization point between the
    /// LaunchServices raise (async Apple Event) and the subsequent
    /// `cursor://…/open` URL dispatch (which routes to whichever window
    /// is main at delivery time).
    private static func waitForMainWindowTitle(contains substring: String, forApp pid: pid_t, timeout: TimeInterval) {
        let appElement = AXUIElementCreateApplication(pid)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var mainRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
               let main = mainRef,
               CFGetTypeID(main) == AXUIElementGetTypeID() {
                let mainWindow = unsafeBitCast(main, to: AXUIElement.self)
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(mainWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   title.contains(substring) {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
    }
}
