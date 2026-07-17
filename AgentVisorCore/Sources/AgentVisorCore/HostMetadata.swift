// Display metadata for each `TerminalHost` case — the human-readable
// name, the macOS bundle ID for icon lookup, and a fallback SF Symbol
// name used when the app isn't installed (so NSWorkspace.icon would
// return a generic blank-document icon).
//
// Pure Swift / Foundation only: the SF Symbol name is a string so this
// stays in Core. The actual NSImage resolution lives in the app target
// (HostStatusBadge).

import Foundation

public struct HostMetadata: Equatable, Sendable {
    public let displayName: String
    public let bundleID: String?
    public let fallbackSFSymbol: String

    public init(displayName: String, bundleID: String?, fallbackSFSymbol: String) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.fallbackSFSymbol = fallbackSFSymbol
    }

    public static func metadata(for host: TerminalHost) -> HostMetadata {
        switch host {
        case .ghostty:
            return .init(displayName: "Ghostty",
                         bundleID: "com.mitchellh.ghostty",
                         fallbackSFSymbol: "terminal.fill")
        case .iterm2:
            return .init(displayName: "iTerm2",
                         bundleID: "com.googlecode.iterm2",
                         fallbackSFSymbol: "terminal.fill")
        case .terminalApp:
            return .init(displayName: "Terminal",
                         bundleID: "com.apple.Terminal",
                         fallbackSFSymbol: "terminal.fill")
        case .claudeDesktop:
            return .init(displayName: "Claude Desktop",
                         bundleID: "com.anthropic.claudefordesktop",
                         fallbackSFSymbol: "bubble.left.fill")
        case .codexApp:
            return .init(displayName: "Codex",
                         bundleID: "com.openai.codex",
                         fallbackSFSymbol: "sparkles")
        case .vscode:
            return .init(displayName: "VS Code",
                         bundleID: "com.microsoft.VSCode",
                         fallbackSFSymbol: "chevron.left.forwardslash.chevron.right")
        case .cursor:
            return .init(displayName: "Cursor",
                         bundleID: "com.todesktop.230313mzl4w4u92",
                         fallbackSFSymbol: "cursorarrow.rays")
        case .zed:
            // Zed hosts agents (claude-acp, codex-acp, cursor) as ACP
            // children but exposes no public IPC for thread reveal —
            // click navigation activates the app and stops there.
            return .init(displayName: "Zed",
                         bundleID: "dev.zed.Zed",
                         fallbackSFSymbol: "bolt.square")
        case .unknown:
            return .init(displayName: "Unknown host",
                         bundleID: nil,
                         fallbackSFSymbol: "terminal")
        }
    }
}
