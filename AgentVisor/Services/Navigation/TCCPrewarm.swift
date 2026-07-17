//
//  TCCPrewarm.swift
//  AgentVisor
//
//  Fires a no-op AppleScript at each automation target (Ghostty, iTerm2)
//  during app launch so macOS shows the "Agent Visor wants to control
//  X" TCC prompt BEFORE the notch is open. Without this, the first
//  AppleScript call happens when the user types in the chat composer,
//  by which time the notch panel is up at a high `windowLevel` and the
//  TCC alert renders behind it — unreachable without killing the app.
//
//  Probes run on a background queue so app launch isn't blocked by the
//  user's grant/deny decision. One probe per target per agent-visor
//  process. Re-probes when a target app newly launches via
//  NSWorkspace.didLaunchApplicationNotification, so users who start
//  their terminal after agent-visor still get the prompt before they
//  type in the chat.
//

import AppKit
import AgentVisorCore
import Foundation
import os.log

private let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "TCCPrewarm")

enum TCCPrewarm {

    /// Bundle id → AppleScript target name (the `tell application "X"`
    /// identifier, which is NOT the same as the bundle id).
    private static let targets: [(bundleID: String, scriptName: String)] = [
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.googlecode.iterm2", "iTerm"),
    ]

    /// Targets we've already probed in this agent-visor process. Skipped
    /// so a rapid app-relaunch doesn't double-prompt the user.
    private static var probed = Set<String>()
    private static let lock = NSLock()

    /// Wire up workspace observation and probe everything currently
    /// running. Idempotent.
    static func start() {
        DispatchQueue.global(qos: .utility).async {
            probeRunningTargets()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            guard let target = targets.first(where: { $0.bundleID == bundleID }) else { return }
            DispatchQueue.global(qos: .utility).async {
                probe(target.scriptName, bundleID: target.bundleID)
            }
        }
    }

    private static func probeRunningTargets() {
        let running = NSWorkspace.shared.runningApplications
        for target in targets {
            guard running.contains(where: { $0.bundleIdentifier == target.bundleID }) else {
                continue
            }
            probe(target.scriptName, bundleID: target.bundleID)
        }
    }

    private static func probe(_ scriptName: String, bundleID: String) {
        lock.lock()
        let alreadyProbed = probed.contains(bundleID)
        if !alreadyProbed { probed.insert(bundleID) }
        lock.unlock()
        guard !alreadyProbed else { return }

        // `count windows` is the lightest query that actually crosses
        // the scripting bridge. `return name` is too benign — macOS
        // resolves it from app metadata without invoking TCC, so the
        // prompt wouldn't fire and the real call later would still
        // surprise the user. Counting windows is read-only, fast, and
        // matches the shape of our production calls (which iterate
        // windows / terminals).
        let script = "tell application \"\(scriptName)\" to count windows"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            logger.info("Prewarm \(scriptName, privacy: .public) exit=\(proc.terminationStatus, privacy: .public)")
        } catch {
            logger.warning("Prewarm \(scriptName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
