import Foundation

/// Read-only view of the process tree, injectable so the detector can be
/// tested without spawning real processes.
public protocol ProcessInfoReader {
    func parentPID(of pid: pid_t) -> pid_t?
    func bundleID(of pid: pid_t) -> String?
}

public enum TerminalHost: String, Equatable, Sendable, CaseIterable {
    case ghostty
    case iterm2
    case terminalApp
    case claudeDesktop
    /// Codex.app GUI/app-server surface. Codex GUI threads have no
    /// per-thread TTY, but Agent Visor still needs a concrete host label
    /// for pills, popovers, and read-only navigation.
    case codexApp
    /// VS Code and VS Code Insiders. The EditorAdapter is parameterized
    /// by bundle ID at construction so we don't need separate enum cases
    /// for the two channels.
    case vscode
    case cursor
    /// Zed editor (dev.zed.Zed). Hosts other agents (claude, codex,
    /// cursor-agent) as ACP children — those agents write to their
    /// canonical on-disk transcript stores, so agent-visor sees the
    /// session via existing discovery; the host badge marks WHO is
    /// driving the agent. Read-only: Zed exposes no public IPC for
    /// reopening a thread, so click navigation just activates the app.
    case zed
    case unknown
}

public enum TerminalHostDetector {
    /// Cap the parent walk so a malformed tree (cycles, very deep stacks)
    /// can never spin. Real terminal session ancestors are within ~5 hops.
    private static let maxAncestors = 16

    public static func detect(pid: pid_t, reader: ProcessInfoReader) -> TerminalHost {
        var current: pid_t? = pid
        for _ in 0..<maxAncestors {
            guard let pid = current else { break }
            if let bundleID = reader.bundleID(of: pid), let host = host(forBundleID: bundleID) {
                return host
            }
            current = reader.parentPID(of: pid)
        }
        return .unknown
    }

    private static func host(forBundleID bundleID: String) -> TerminalHost? {
        switch bundleID {
        case "com.mitchellh.ghostty":               return .ghostty
        case "com.googlecode.iterm2":               return .iterm2
        case "com.apple.Terminal":                  return .terminalApp
        case "com.anthropic.claudefordesktop":      return .claudeDesktop
        case "com.openai.codex":                    return .codexApp
        case "com.microsoft.VSCode",
             "com.microsoft.VSCodeInsiders":        return .vscode
        case "com.todesktop.230313mzl4w4u92":       return .cursor
        case "dev.zed.Zed":                         return .zed
        default:                                    return nil
        }
    }
}
