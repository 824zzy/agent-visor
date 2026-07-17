//
//  FileOpener.swift
//  AgentVisor
//
//  Resolves a file path to a launch action: which editor app to open
//  it in, given the user's `EditorPreference`. Auto mode probes the
//  install chain (Cursor → VS Code → VS Code Insiders → Zed → Xcode),
//  matching the order users in this ecosystem typically have installed.
//
//  Why an explicit chain (not just `NSWorkspace.open`):
//  `NSWorkspace.open(URL)` defers to the user's macOS default for the
//  file's UTI. For *.swift that's Xcode; for *.py that's whatever they
//  last picked. The chat's "click filename to open" affordance is a
//  code-editing action — Cursor / VS Code is the right default, not
//  the system text-handler default. Users who genuinely want
//  LaunchServices behavior can pick `.systemDefault`.
//

import AppKit
import Foundation

enum FileOpener {
    /// Open `path` in whichever editor the active preference resolves
    /// to. No-op if the path doesn't exist on disk (path was edited
    /// away, or the chat row references a file under a workspace
    /// root we can't access).
    @MainActor
    static func open(path: String) {
        let expanded = path.hasPrefix("~")
            ? (path as NSString).expandingTildeInPath
            : path
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        let url = URL(fileURLWithPath: expanded)

        let preference = EditorPreferenceSelector.shared.preference
        if let bundleID = resolveBundleID(for: preference) {
            launch(bundleID: bundleID, url: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Detection chain for `.auto`. Returns the bundle id of the first
    /// installed candidate; nil to fall through to `NSWorkspace.open`.
    /// Order: user's likely intent for code-edit clicks.
    private static let autoChain: [String] = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",          // VS Code stable
        "com.microsoft.VSCodeInsiders",  // VS Code Insiders
        "dev.zed.Zed",                   // Zed
        "com.apple.dt.Xcode",            // Xcode
    ]

    private static func resolveBundleID(for preference: EditorPreference) -> String? {
        switch preference {
        case .systemDefault:
            return nil
        case .auto:
            for bundleID in autoChain {
                if isInstalled(bundleID: bundleID) {
                    return bundleID
                }
            }
            return nil
        case .cursor, .vscode, .vscodeInsiders, .zed, .xcode:
            // If the user pinned a specific editor that isn't actually
            // installed, don't silently swallow the click — fall back
            // to LaunchServices so SOMETHING opens.
            guard let bundleID = preference.bundleID else { return nil }
            return isInstalled(bundleID: bundleID) ? bundleID : nil
        }
    }

    private static func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private static func launch(bundleID: String, url: URL) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }
}
