//
//  ClaudeSessionMonitor.swift
//  AgentVisor
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import AgentVisorCore
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
        SessionFileWatcherManager.shared.delegate = self
        CodexMetadataWatcher.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        CodexMetadataWatcher.shared.start()

        // Scan for existing sessions on a background thread (Process needs a run loop)
        DispatchQueue.global(qos: .userInitiated).async {
            Self.writeLog("[Discovery] Starting process scan...")
            let discovered = Self.discoverExistingSessions()
            Self.writeLog("[Discovery] Found \(discovered.count) sessions")
            Task {
                await SessionStore.shared.bootstrapSessions(discovered)
                await SessionStore.shared.startPeriodicPruning()
                await MainActor.run {
                    for info in discovered {
                        SessionFileWatcherManager.shared.startWatching(
                            sessionId: info.sessionId,
                            cwd: info.cwd,
                            agentID: info.agentID
                        )
                    }
                }
                // Replay any PermissionRequest sidecars left by a prior
                // run. Must happen AFTER bootstrap or discovery would
                // overwrite the synthesized .waitingForApproval phase
                // back to .idle. Stale sidecars (tool already resolved
                // in JSONL during downtime) are deleted, not replayed.
                await PendingPermissionStore.replayOnStartup()
            }
        }

        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.agentID == .claudeCode, event.sessionPhase == .processing {
                    Task {
                        // Use the session's stable launch cwd, not event.cwd
                        // which drifts after cd commands.
                        let cwd = await SessionStore.shared.getSession(id: event.sessionId)?.cwd ?? event.cwd
                        await MainActor.run {
                            InterruptWatcherManager.shared.startWatching(
                                sessionId: event.sessionId,
                                cwd: cwd
                            )
                        }
                    }
                }

                // Start the session-file watcher for any hook event so
                // file-driven syncs work even when no follow-up hook fires
                // (e.g. /compact, where the boundary line is appended tens
                // of seconds after PreCompact).
                Task {
                    let cwd = await SessionStore.shared.getSession(id: event.sessionId)?.cwd ?? event.cwd
                    await MainActor.run {
                        SessionFileWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: cwd,
                            agentID: event.agentID
                        )
                    }
                }

                if event.isTerminalLifecycleStatus {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                        SessionFileWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        CodexMetadataWatcher.shared.stop()
        HookSocketServer.shared.stop()
    }

    /// Discover existing sessions across every registered agent
    /// provider. Each provider owns its discovery logic — process
    /// scans, transcript walks, sqlite reads — and we just iterate
    /// the registry. The two-pass shape (live, then historical with
    /// liveIds excluded) is the same one that lived inline here
    /// before the refactor.
    nonisolated static func discoverExistingSessions() -> [DiscoveredSession] {
        var results: [DiscoveredSession] = []
        for provider in AgentRegistry.all {
            results.append(contentsOf: provider.discoverLiveSessions())
        }
        let liveIds = Set(results.map(\.sessionId))
        for provider in AgentRegistry.all {
            results.append(contentsOf: provider.discoverHistoricalSessions(
                excluding: liveIds,
                limit: historicalSessionLimit
            ))
        }
        AgentDiscoveryUtilities.writeLog("[Discovery] Total: \(results.count) sessions")
        return results
    }

    /// Per-provider cap on historical rows surfaced into the sidebar.
    /// Prevents a heavy historical user from flooding the sidebar
    /// with hundreds of dead sessions on launch.
    nonisolated private static let historicalSessionLimit = 30


    /// REMOVED: Terminal ID matching was unreliable (AX pane ≠ Ghostty terminal ordering).
    /// Messaging now uses SessionNavigator (TTY markers on demand) which is always correct.
    private static func _removed_resolveGhosttyNames(_ sessions: inout [(sessionId: String, cwd: String, pid: Int, tty: String)]) {
        guard !sessions.isEmpty else { return }

        // Save current app, briefly activate Ghostty for focus-based matching
        let originalApp = NSWorkspace.shared.frontmostApplication
        if let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first {
            ghostty.activate()
            usleep(300000) // 300ms for activation
        }

        var matchedIds = Set<String>() // Track used terminal IDs to avoid duplicates

        for i in sessions.indices {
            let tty = sessions[i].tty
            let ttyPath = "/dev/\(tty)"

            // Write marker to this session's TTY
            let marker = "GN\(UInt32.random(in: 100000...999999))"
            let seq = "\u{1b}7\(marker)\u{1b}8"
            guard let handle = FileHandle(forWritingAtPath: ttyPath),
                  let data = seq.data(using: .utf8) else { continue }
            handle.write(data)
            handle.closeFile()
            usleep(200000) // 200ms for terminal to render

            // Use SessionNavigator's AX approach to find the pane, click it to focus
            guard let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first else { continue }
            let ghosttyPid = ghostty.processIdentifier
            let appElement = AXUIElementCreateApplication(ghosttyPid)

            var foundPane = false
            if let windows = getAXWindows(appElement) {
                for window in windows {
                    var panes: [AXUIElement] = []
                    collectPanes(element: window, panes: &panes)
                    for pane in panes {
                        var valueRef: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(pane, kAXValueAttribute as CFString, &valueRef) == .success,
                              let content = valueRef as? String,
                              content.contains(marker) else { continue }

                        // Found the pane! Focus it via AX + click
                        if let pos = getAXPosition(of: pane), let size = getAXSize(of: pane) {
                            // First try AX press action
                            AXUIElementPerformAction(pane, kAXPressAction as CFString)
                            usleep(100000)

                            // Also do a real click for reliability
                            let clickX = pos.x + size.width / 2
                            let clickY = pos.y + size.height / 2
                            let source = CGEventSource(stateID: .combinedSessionState)
                            if let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left) {
                                mouseDown.post(tap: .cghidEventTap)
                            }
                            usleep(50000)
                            if let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left) {
                                mouseUp.post(tap: .cghidEventTap)
                            }
                            usleep(300000) // Longer wait for focus to settle

                            // Query ALL windows for focused terminal (not just front window)
                            let focusScript = """
                            tell application "Ghostty"
                                set output to ""
                                repeat with w from 1 to (count windows)
                                    set ft to focused terminal of selected tab of window w
                                    set output to output & (id of ft) & "|||" & (name of ft) & linefeed
                                end repeat
                                return output
                            end tell
                            """
                            if let output = try? runProcess("/usr/bin/osascript", arguments: ["-e", focusScript]) {
                                // Check each window's focused terminal, find one we haven't used
                                for line in output.components(separatedBy: "\n") {
                                    let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|||")
                                    guard parts.count == 2 else { continue }
                                    let termId = parts[0]
                                    let termName = parts[1]
                                        .replacingOccurrences(of: "✳ ", with: "")
                                        .replacingOccurrences(of: "⠂ ", with: "")
                                        .replacingOccurrences(of: "⠐ ", with: "")
                                    if !matchedIds.contains(termId) {
                                        sessions[i].cwd = sessions[i].cwd + "|||" + termName + "|||" + termId
                                        matchedIds.insert(termId)
                                        writeLog("[Discovery] Matched via TTY marker: \(sessions[i].sessionId.prefix(8)) -> \(termName) (id: \(termId.prefix(8)))")
                                        break
                                    }
                                }
                            }
                        }
                        foundPane = true
                        break
                    }
                    if foundPane { break }
                }
            }

            // Clear marker
            let clearSeq = "\u{1b}8\u{1b}[K"
            if let clearHandle = FileHandle(forWritingAtPath: ttyPath),
               let clearData = clearSeq.data(using: .utf8) {
                clearHandle.write(clearData)
                clearHandle.closeFile()
            }

            if !foundPane {
                writeLog("[Discovery] No pane found for: \(sessions[i].sessionId.prefix(8))")
            }
        }

        // Restore the original app
        DispatchQueue.main.async {
            originalApp?.activate()
        }
    }

    private static func getAXWindows(_ app: AXUIElement) -> [AXUIElement]? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        return windows
    }

    private static func collectPanes(element: AXUIElement, panes: inout [AXUIElement]) {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXTextArea" {
            panes.append(element)
            return
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children { collectPanes(element: child, panes: &panes) }
    }

    private static func getAXPosition(of element: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              let posRef,
              CFGetTypeID(posRef) == AXValueGetTypeID() else { return nil }
        let posValue = unsafeBitCast(posRef, to: AXValue.self)
        var point = CGPoint.zero
        return AXValueGetValue(posValue, .cgPoint, &point) ? point : nil
    }

    private static func getAXSize(of element: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeRef,
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let sizeValue = unsafeBitCast(sizeRef, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(sizeValue, .cgSize, &size) ? size : nil
    }

    nonisolated private static func writeLog(_ message: String) {
        let line = "\(Date()): \(message)\n"
        let path = AppPaths.navLogPath
        guard let data = line.data(using: .utf8) else { return }
        // Create the file on first write if it doesn't exist; otherwise
        // FileHandle(forWritingAtPath:) returns nil and the log is
        // silently dropped (debugging this path is annoying).
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }

    private static func runProcess(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Permission Handling

    /// Approve a pending permission. When the original PermissionRequest
    /// hook script still has its socket open (live path), the response
    /// goes through `HookSocketServer.respondToPermission`. When the
    /// pending state was replayed from a sidecar after a agent-visor
    /// restart, the original hook script has already exited (sock.recv
    /// returned EOF on our previous teardown) and claude-code has
    /// fallen back to its native approval menu in the TUI. In that
    /// case the socket response goes nowhere, so we send Enter to the
    /// terminal to confirm the default-selected "Yes" option in
    /// claude-code's menu.
    /// `updatedPermissions` carries the upstream-supplied
    /// `permission_suggestions` payload back to claude-code when the
    /// user picked the "Yes, and don't ask again…" option. Dropped on
    /// the no-live-socket fallback (the user gets a one-shot allow
    /// instead of the persisted rule); acceptable trade-off because
    /// the recovery path runs only when the original socket already
    /// failed.
    func approvePermission(sessionId: String, updatedPermissions: [AnyCodable]? = nil) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            let liveToolId = HookSocketServer.shared
                .getPendingPermission(sessionId: sessionId)?.toolId
            let hasLiveSocket = liveToolId == permission.toolUseId

            if hasLiveSocket {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "allow",
                    updatedPermissions: updatedPermissions
                )
            } else {
                // No live socket → send Enter to confirm the default
                // "Yes" option in claude-code's native menu, then
                // delete the sidecar so we don't replay it again.
                Self.sendTUIKey(named: "enter", session: session)
                PendingPermissionStore.delete(
                    sessionId: sessionId,
                    toolUseId: permission.toolUseId
                )
            }

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            let liveToolId = HookSocketServer.shared
                .getPendingPermission(sessionId: sessionId)?.toolId
            let hasLiveSocket = liveToolId == permission.toolUseId

            if hasLiveSocket {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "deny",
                    reason: reason
                )
            } else {
                // No live socket → send Esc to cancel claude-code's
                // native approval menu (matches the menu's footer
                // hint "Esc to cancel"), then delete the sidecar.
                Self.sendTUIKey(named: "escape", session: session)
                PendingPermissionStore.delete(
                    sessionId: sessionId,
                    toolUseId: permission.toolUseId
                )
            }

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Send a single keystroke to the session's terminal pane. Routes
    /// through the right adapter for the host (iTerm2 / Ghostty).
    private static func sendTUIKey(named keyName: String, session: SessionState) {
        let host: String
        if TerminalAdapterRegistry.adapter(for: session) is ITermAdapter {
            host = "iterm2"
        } else {
            host = "ghostty"
        }
        Self.writeLog("[ApprovalFallback] sending key=\(keyName) host=\(host) sid=\(session.sessionId.prefix(8)) tty=\(session.tty ?? "nil") cwd=\(session.cwd)")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok: Bool
            if TerminalAdapterRegistry.adapter(for: session) is ITermAdapter {
                if keyName == "escape" {
                    ok = ITermAdapter().sendEscape(toSession: session)
                } else {
                    ok = ITermAdapter().sendSteps([.key(keyName)], toSession: session)
                }
            } else {
                ok = GhosttyScripting.sendKeystroke(named: keyName, toSession: session)
            }
            Self.writeLog("[ApprovalFallback] result key=\(keyName) ok=\(ok) sid=\(session.sessionId.prefix(8))")
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}

// MARK: - Session File Watcher Delegate

extension ClaudeSessionMonitor: SessionFileWatcherDelegate {
    nonisolated func didExtendSessionFile(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.fileExtended(sessionId: sessionId, cwd: cwd))
        }
    }
}

extension ClaudeSessionMonitor: CodexMetadataWatcherDelegate {
    nonisolated func didChangeCodexMetadata() {
        Task {
            await SessionStore.shared.refreshCodexMetadataAfterExternalChange()
        }
    }
}
