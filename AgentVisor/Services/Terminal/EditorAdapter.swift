//
//  EditorAdapter.swift
//  AgentVisor
//
//  Brings a VS Code (or Cursor, or VS Code Insiders) editor window to
//  the foreground for a Claude Code session running inside the editor's
//  plugin. Pure AX path — neither VS Code nor Cursor exposes a usable
//  scripting surface, so we enumerate AX windows, read their titles,
//  and match the session's project name to the workspace folder shown
//  in the title bar.
//
//  Send-text is deferred: the VS Code plugin doesn't accept text the
//  way a terminal does. `sendText` returns false until that's designed.
//

import AppKit
import ApplicationServices
import AgentVisorCore
import Foundation
import os.log

struct EditorAdapter: TerminalAdapter {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "EditorAdapter")

    let bundleID: String
    let displayName: String

    func sendText(_ text: String, toSession session: SessionState) -> Bool {
        // Cursor: AX-write the message into the chat input + Return
        // key via CGEventPostToPid (which delivers to a specific pid
        // without requiring frontmost). agent-visor stays in focus.
        // Verified 2026-05-20: JSONL grows with the user message and
        // assistant response; Cursor remains backgrounded.
        if bundleID == CursorAXSender.cursorBundleID {
            return CursorAXSender.send(text: text, toSession: session)
        }
        // VS Code stable / Insiders: no equivalent AX shape verified
        // yet — likely works with the same approach (Anthropic's
        // extension shares code with the Cursor variant), but needs
        // a separate empirical check before enabling.
        return false
    }

    @discardableResult
    private func runOsa(source: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
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

    func focusSession(_ session: SessionState) -> Bool {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first
        else {
            Self.logger.info("focusSession: \(displayName, privacy: .public) not running")
            return false
        }

        let pid = app.processIdentifier

        // === LaunchServices path (Cursor only) ===
        // Bring the session's workspace window forward via
        // `open -a Cursor <workspaceFolder>`. Cursor's "open document"
        // Apple Event handler focuses an existing matching window or
        // opens a new one — Sequoia permits this from background apps,
        // unlike cross-app AXRaise.
        //
        // Workspace-folder resolution is delegated to the pure-logic
        // [[CursorWorkspaceResolver]] in Core:
        //   - claude-code-in-Cursor sessions: the longest workspaceFolder
        //     from `~/.claude/ide/*.lock` that's a prefix of `session.cwd`.
        //     This picks the specific extension host that owns the session,
        //     so the subsequent `cursor://anthropic.claude-code/open` URL
        //     reveals the EXISTING chat tab instead of spawning a new one.
        //   - cursor-agent / IDE Agents Window sessions: `session.cwd`
        //     directly. Those have no lock file, so previously the
        //     resolver returned nil and routing fell through to fuzzy
        //     AppleScript title matching — which lands on whatever Cursor
        //     window happens to be frontmost when the user's session
        //     workspace isn't currently open. Direct cwd routing makes
        //     LaunchServices open or focus the right workspace window.
        if bundleID == "com.todesktop.230313mzl4w4u92" {
            let candidateFolders = collectIDEWorkspaceFolders()
            if let workspaceFolder = CursorWorkspaceResolver.resolveWorkspaceFolder(
                sessionCwd: session.cwd,
                agentID: session.agentID,
                candidateFolders: candidateFolders
            ) {
                Self.logger.error("focusSession: Cursor resolved workspace=\(workspaceFolder, privacy: .public) for cwd=\(session.cwd, privacy: .public) agent=\(String(describing: session.agentID), privacy: .public)")

                // Cursor-agent / IDE Agents Window gate: only invoke
                // LaunchServices when one of Cursor's open windows
                // already hosts the workspace. Otherwise `open -a Cursor`
                // would treat the click as "open document" and spawn a
                // surprise new window for a workspace the user didn't
                // ask to reopen. Without a matching window we fall
                // through to a plain `app.activate()` below — Cursor
                // comes to the front on whatever window it had open,
                // and the user can navigate from there. claude-code-
                // in-Cursor sessions skip this gate because their
                // cursor:// URL routing relies on LaunchServices to
                // bring the host forward as main before the URL fires.
                if session.agentID == .cursor {
                    let titles = windowTitles(forApp: pid)
                    let hasMatch = CursorWindowTitleMatcher.hasMatchingWindow(
                        workspaceFolder: workspaceFolder,
                        cursorWindowTitles: titles
                    )
                    if !hasMatch {
                        Self.logger.error("focusSession: skip openViaLS — no matching Cursor window for workspace=\(workspaceFolder, privacy: .public) titles=\(titles.joined(separator: " | "), privacy: .public)")
                        app.activate()
                        let folderName = URL(fileURLWithPath: workspaceFolder).lastPathComponent
                        Self.postToast("Cursor doesn't have \"\(folderName)\" open. Activated Cursor — open the workspace from there to view the agent transcript.")
                        return true
                    }
                }

                let opened = openViaLaunchServices(path: workspaceFolder)
                Self.logger.error("focusSession: openViaLS opened=\(opened)")
                if session.agentID == .cursor {
                    let folderName = URL(fileURLWithPath: workspaceFolder).lastPathComponent
                    Self.postToast("Opened \"\(folderName)\" in Cursor. Cursor doesn't expose a way to reopen old agent transcripts directly — find it in Cursor's Composer history.")
                }
                // Poll AXMain by title containment — workspace folder's
                // last path component appears in the matched window's
                // title after Cursor brings it forward.
                let folderName = URL(fileURLWithPath: workspaceFolder).lastPathComponent
                waitForMainWindowTitle(contains: folderName, forApp: pid, timeout: 1.5)
                // Only dispatch the cursor:// claude-code URL for sessions
                // that ARE claude-code-extension sessions. AgentID.cursor
                // sessions are cursor-agent / IDE Agents Window — that URL
                // routes to the wrong extension host and spawns a phantom
                // new tab. Raising the workspace window is enough for them.
                if session.agentID == .claudeCode {
                    _ = openCursorChat(sessionId: session.sessionId)
                }
                return true
            }
        }
        // === End LaunchServices path ===

        // Fallback: existing AppleScript path. Used when no IDE lock
        // file matches the session's cwd — e.g., the session was
        // started outside Cursor's chat UI, or the extension didn't
        // write a lock file (older version). Best-effort; multi-window
        // cross-window case may still spawn a duplicate tab.
        let titles = windowTitles(forApp: pid)
        Self.logger.error("focusSession: fallback AppleScript path; project=\(session.bestProjectName, privacy: .public) titles=\(titles.joined(separator: " | "), privacy: .public)")

        let matchIdx = EditorWindowMatcher.bestMatch(
            titles: titles,
            projectName: session.bestProjectName
        )

        if let matchIdx = matchIdx {
            // Capture the target window's AXUIElement upfront. AX z-order
            // reshuffles after raise, so an index re-lookup later would
            // land on a different window. The reference itself is stable.
            let targetWindow = window(at: matchIdx, forApp: pid)
            // 0. Promote agent-visor's NSApp to active for the duration
            //    of the raise. Sequoia silently denies cross-app AXRaise
            //    when the source app is a background utility (NSPanel,
            //    LSUIElement). The raise returns success at every layer
            //    (pure AX returns .success, System Events AppleScript
            //    returns "ok") yet Cursor's window-server never honors
            //    it — confirmed by AppleScript itself querying AXMain
            //    after raise and getting back the OLD window. Briefly
            //    activating agent-visor's process makes the raise come
            //    from an "active" source, which Sequoia permits.
            //    Subsequent URL dispatch then routes to the right host's
            //    extension, which has the session in its sessionPanels
            //    and reveals the existing tab.
            DispatchQueue.main.sync {
                NSApp.activate(ignoringOtherApps: true)
            }
            // 1. Pure-AX: set kAXMainWindow on the app, kAXMain +
            //    kAXFocused on the target window, AXRaise. Returns
            //    success on Sequoia but has no visible effect on its
            //    own; serves as a fallback hint if later steps fail.
            _ = raiseWindow(at: matchIdx, forApp: pid)
            // 2. AppleScript AXRaise via System Events — within-app
            //    z-order reorder, addressed by AX index, not title
            //    (title races against active editing).
            let processName = app.localizedName ?? displayName
            let asResult = appleScriptRaise(processName: processName, windowIndex: matchIdx + 1)
            Self.logger.error("focusSession: matchIdx=\(matchIdx) asResult=\(asResult, privacy: .public)")
            // 3. AppleScript app-level activate via Apple Event.
            _ = runOsa(source: "tell application id \"\(bundleID)\" to activate")
            // 4. Block until Cursor's AXMainWindow actually flips to the
            //    target. The osascript subprocess exits as soon as the
            //    Apple Event is dispatched, NOT when Cursor has processed
            //    it. Without this poll, the URL dispatch below races
            //    against Cursor's runloop and often arrives at the OLD
            //    main window — which then routes the cursor://…/open
            //    handler to its extension host. That host doesn't own
            //    the session, so it spawns a new tab instead of revealing
            //    the existing one.
            if let targetWindow = targetWindow, bundleID == "com.todesktop.230313mzl4w4u92" {
                waitForMainWindow(target: targetWindow, forApp: pid, timeout: 0.5)
            }
        } else {
            Self.logger.error("focusSession: NO MATCH for project=\(session.bestProjectName, privacy: .public)")
        }

        // Cursor: dispatch the URI handler INSTEAD OF NSRunningApplication.activate().
        // Reason: each Cursor window has its own extension-host process with its own
        // sessionPanels map. The `cursor://anthropic.claude-code/open?session=<id>`
        // URL is delivered to whichever extension host is in the workspace-matching
        // window — but only if that window is the one Cursor's window-server
        // currently considers "main." NSRunningApplication.activate() would reassert
        // whichever window was last main, clobbering our AppleScript raise and
        // sending the URL to the wrong host, which then spawns a duplicate tab
        // because its sessionPanels doesn't know about this session. The URL
        // dispatch itself brings Cursor to the foreground; activate() is redundant.
        if bundleID == "com.todesktop.230313mzl4w4u92" {
            // Same gate as the lock-file path above: only the
            // claude-code extension owns the cursor://anthropic.claude-code
            // URL, so only AgentID.claudeCode sessions should dispatch
            // it. cursor-agent CLI / IDE Agents Window sessions just
            // need the workspace window raised.
            if session.agentID == .claudeCode {
                _ = openCursorChat(sessionId: session.sessionId)
            } else {
                app.activate()
            }
        } else {
            // VS Code stable / Insiders: AX path only (URI handler spike for
            // those is Phase 2 follow-up). activate() needed because there's
            // no URL dispatch to bring the app forward.
            app.activate()
        }

        return true
    }

    /// Surface a transient toast in the main window. Used for Cursor
    /// pill clicks where the focusSession call resolved correctly but
    /// the user can't see anything happen — Cursor doesn't expose a
    /// public way to reopen an agent transcript inside Composer, so
    /// even a perfect focus is a visual no-op when the workspace
    /// window was already frontmost.
    fileprivate static func postToast(_ text: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cvShowToast,
                object: nil,
                userInfo: ["text": text]
            )
        }
    }

    /// Opens Cursor to the claude-code chat tab matching the given
    /// sessionId via the extension's registered URI handler. The
    /// extension's package.json activates on `onWebviewPanel:claudeVSCodePanel`
    /// and registers a UriHandler at path `/open` that dispatches to
    /// `claude-vscode.primaryEditor.open` with the session query param.
    /// Verified by reading extension.js in
    /// `~/.cursor/extensions/anthropic.claude-code-<ver>-darwin-arm64`.
    private func openCursorChat(sessionId: String) -> Bool {
        let urlString = "cursor://anthropic.claude-code/open?session=\(sessionId)"
        guard let url = URL(string: urlString) else {
            Self.logger.error("openCursorChat: bad URL \(urlString, privacy: .public)")
            return false
        }
        let ok = NSWorkspace.shared.open(url)
        Self.logger.info("openCursorChat: session=\(sessionId.prefix(8), privacy: .public) opened=\(ok)")
        return ok
    }

    /// Runs `perform action "AXRaise"` on the window at the given
    /// AppleScript index (1-based, matches AX z-order). Uses
    /// /usr/bin/osascript as a subprocess: TCC's AppleEvents permission
    /// is checked for the CALLING process. osascript already holds the
    /// grant for System Events; agent-visor itself does not. The
    /// existing Ghostty scripting path uses the same osascript-subprocess
    /// pattern.
    private func appleScriptRaise(processName: String, windowIndex: Int) -> String {
        let escapedProcess = AppleScriptEscaper.escape(processName)
        // Diagnostic version: after AXRaise, wait briefly inside the same
        // osascript invocation and query AXMainWindow via System Events.
        // The returned string is the main window name as AppleScript sees
        // it. Comparing this with the Swift-side AX poll tells us whether
        // raise really failed (AS sees wrong main) or whether our direct-
        // AX read is lagging (AS sees right main but Swift AX doesn't).
        let script = """
        tell application "System Events" to tell process "\(escapedProcess)"
            perform action "AXRaise" of window \(windowIndex)
            delay 0.25
            try
                set mw to first window whose value of attribute "AXMain" is true
                return name of mw
            on error
                return "no-main"
            end try
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let mainName = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                return "ok mainAfter=\(mainName)"
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            return "exit:\(proc.terminationStatus):\(errMsg)"
        } catch {
            return "spawn-fail:\(error.localizedDescription)"
        }
    }

    // MARK: - AX helpers

    private func windowTitles(forApp pid: pid_t) -> [String] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let windows = windowsRef as? [AXUIElement]
        else {
            return []
        }
        return windows.map { window in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(
                window,
                kAXTitleAttribute as CFString,
                &titleRef
            )
            return (titleRef as? String) ?? ""
        }
    }

    // MARK: - Path C (lock-file + LaunchServices)

    /// Read every `~/.claude/ide/<port>.lock` and return the union of
    /// their `workspaceFolders`. Pure I/O — the routing rule (which
    /// folder to pick for a given session) lives in
    /// `CursorWorkspaceResolver` and is unit-tested.
    private func collectIDEWorkspaceFolders() -> [String] {
        let lockDir = NSHomeDirectory() + "/.claude/ide"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: lockDir) else {
            return []
        }
        var folders: [String] = []
        for file in files where file.hasSuffix(".lock") {
            let path = lockDir + "/" + file
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lockFolders = json["workspaceFolders"] as? [String]
            else { continue }
            folders.append(contentsOf: lockFolders)
        }
        return folders
    }

    /// Bring the workspace's editor window to the foreground via
    /// LaunchServices: `open -a <appName> <path>`. The editor handles
    /// the open document Apple Event internally, routing to the
    /// workspace-matching window and bringing it forward as main. This
    /// is the Sequoia-friendly path — `open -a` is a user-initiated
    /// document action, not a cross-app AXRaise from a background
    /// process, so the OS permits it without question.
    private func openViaLaunchServices(path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", displayName, path]
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

    /// Poll AXMainWindow until the main window's title contains the
    /// given substring (typically the workspace folder's name), or
    /// `timeout` elapses. Used after LaunchServices open to wait for
    /// Cursor's main to actually flip before dispatching the session
    /// URL.
    private func waitForMainWindowTitle(contains substring: String, forApp pid: pid_t, timeout: TimeInterval) {
        let appElement = AXUIElementCreateApplication(pid)
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        var lastTitle = "?"
        while Date() < deadline {
            var mainRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
               let main = mainRef,
               CFGetTypeID(main) == AXUIElementGetTypeID() {
                let mainWindow = unsafeBitCast(main, to: AXUIElement.self)
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(mainWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String {
                    lastTitle = title
                    if title.contains(substring) {
                        Self.logger.error("waitForMainWindowTitle: matched after \(polls) polls (title=\(title, privacy: .public))")
                        return
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.04)
            polls += 1
        }
        Self.logger.error("waitForMainWindowTitle: TIMEOUT \(polls) polls substring=\(substring, privacy: .public) lastTitle=\(lastTitle, privacy: .public)")
    }

    /// Fetch the AXUIElement for the window at the given AX index, or
    /// nil if AX read fails or index is out of range.
    private func window(at index: Int, forApp pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let windows = windowsRef as? [AXUIElement],
        index < windows.count
        else {
            return nil
        }
        return windows[index]
    }

    /// Poll Cursor's AXMainWindow until it matches `target`, or until
    /// `timeout` elapses. This is the synchronization point between our
    /// AppleScript "activate" Apple Event (which Cursor processes async
    /// on its own runloop) and the subsequent cursor://…/open URL
    /// dispatch (which routes to whichever window IS main at the moment
    /// LaunchServices delivers it). Without this poll, the URL fires
    /// before Cursor has flipped main, and the cursor://anthropic.claude-code/open
    /// handler runs in the OLD main window's extension host — which
    /// doesn't own the session, so it spawns a duplicate tab instead of
    /// revealing the existing one.
    private func waitForMainWindow(target: AXUIElement, forApp pid: pid_t, timeout: TimeInterval) {
        let appElement = AXUIElementCreateApplication(pid)
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        // Log the target's title once for cross-reference
        var targetTitleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXTitleAttribute as CFString, &targetTitleRef)
        let targetTitle = (targetTitleRef as? String) ?? "?"
        var lastMainTitle: String = "?"
        while Date() < deadline {
            var mainRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
               let main = mainRef,
               CFGetTypeID(main) == AXUIElementGetTypeID() {
                let mainWindow = unsafeBitCast(main, to: AXUIElement.self)
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(mainWindow, kAXTitleAttribute as CFString, &titleRef)
                lastMainTitle = (titleRef as? String) ?? "?"
                if CFEqual(mainWindow, target) {
                    Self.logger.error("waitForMainWindow: target main after \(polls) polls target=\(targetTitle, privacy: .public)")
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
            polls += 1
        }
        Self.logger.error("waitForMainWindow: TIMEOUT after \(polls) polls target=\(targetTitle, privacy: .public) lastMain=\(lastMainTitle, privacy: .public)")
    }

    /// Synthesize a left mouse click in the target window's title-bar
    /// drag region and post it directly to the app's PID. Bypasses
    /// the system event tap (same pattern as PermissionModeCycler),
    /// so the event reaches the app regardless of which window is
    /// currently frontmost — and, critically, updates the app's own
    /// internal "last focused window" state synchronously, ahead of
    /// any URL we're about to dispatch.
    ///
    /// The click point is `pos + (85, 4)`: 85px in from the left edge
    /// to clear macOS traffic lights (~12-72px), 4px down from the
    /// top edge to land in the title-bar drag region above any tab
    /// strip or toolbar. Cursor's title bar is a custom Electron
    /// frame; the topmost few pixels are always reserved for window
    /// drag and don't deliver clicks to controls.
    @discardableResult
    private func clickWindowToFocus(at index: Int, forApp pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let windows = windowsRef as? [AXUIElement],
        index < windows.count
        else {
            Self.logger.error("clickWindowToFocus: no AX windows at idx=\(index)")
            return false
        }
        let window = windows[index]

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef
        else {
            Self.logger.error("clickWindowToFocus: no pos/size for window idx=\(index)")
            return false
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(posVal, to: AXValue.self), .cgPoint, &pos),
              AXValueGetValue(unsafeBitCast(sizeVal, to: AXValue.self), .cgSize, &size) else {
            Self.logger.error("clickWindowToFocus: invalid pos/size values for window idx=\(index)")
            return false
        }

        let clickPoint = CGPoint(x: pos.x + 85, y: pos.y + 4)

        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseDown,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseUp,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        )
        else {
            Self.logger.error("clickWindowToFocus: CGEvent create failed")
            return false
        }
        down.postToPid(pid)
        up.postToPid(pid)
        Self.logger.error("clickWindowToFocus: pid=\(pid) idx=\(index) point=(\(Int(clickPoint.x)),\(Int(clickPoint.y))) winSize=(\(Int(size.width)),\(Int(size.height)))")
        return true
    }

    private func raiseWindow(at index: Int, forApp pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let windows = windowsRef as? [AXUIElement],
        index < windows.count
        else {
            return false
        }
        let window = windows[index]
        // Sequoia teardown of window state on activate(): the OS picks
        // whichever window was last "main" for the app, not whatever we
        // just AXRaised. Setting kAXMainWindowAttribute on the *app*
        // element redirects that pick to our target window. Then the
        // window-level main/focused/raise calls reinforce it.
        let setMainErr = AXUIElementSetAttributeValue(
            appElement,
            kAXMainWindowAttribute as CFString,
            window
        )
        let setWinMainErr = AXUIElementSetAttributeValue(
            window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let setWinFocErr = AXUIElementSetAttributeValue(
            window,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        let raiseErr = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        Self.logger.error("raiseWindow: idx=\(index) appMain=\(setMainErr.rawValue) winMain=\(setWinMainErr.rawValue) winFoc=\(setWinFocErr.rawValue) raise=\(raiseErr.rawValue)")
        return raiseErr == .success
    }
}
