import Foundation

/// Hardcoded list of claude-code's stable built-in slash commands.
/// These don't appear on disk anywhere we can read — they live inside
/// claude-code's binary as TypeScript imports. The list will drift
/// across claude-code releases; run `scripts/sync-claude-builtins.sh`
/// before each agent-visor release and reconcile.
///
/// Snapshot taken from claude-code 2.1.128.
///
/// Hidden commands (isHidden: true) stay reachable by exact-name query
/// but don't appear in the empty-query browse list. We hide TUI-only
/// affordances agent-visor doesn't render (vim mode, prompt-bar color),
/// out-of-band flows (browser OAuth, OS installers), and host-mode
/// surfaces irrelevant when claude is driven through agent-visor.
public enum SlashCommandBuiltins {

    public static let all: [SlashCommand] = [
        // MARK: - Visible

        SlashCommand(
            name: "add-dir",
            description: "Add a directory to the session's allow-list",
            argumentHint: "path",
            source: .builtin
        ),
        SlashCommand(
            name: "agents",
            description: "Manage background agents",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "btw",
            description: "Send a side-channel question while Claude works",
            source: .builtin
        ),
        SlashCommand(
            name: "bug",
            description: "Report a bug to Anthropic",
            source: .builtin
        ),
        SlashCommand(
            name: "clear",
            description: "Free up context by clearing the conversation",
            source: .builtin
        ),
        SlashCommand(
            name: "color",
            description: "Set the prompt bar color for this session",
            source: .builtin
        ),
        SlashCommand(
            name: "compact",
            description: "Free up context by summarizing the conversation so far",
            source: .builtin
        ),
        SlashCommand(
            name: "config",
            description: "Open config panel",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "context",
            description: "Visualize current context usage as a colored grid",
            source: .builtin
        ),
        SlashCommand(
            name: "copy",
            description: "Copy Claude's last response to clipboard (or /copy N for the Nth-latest)",
            argumentHint: "N",
            source: .builtin
        ),
        SlashCommand(
            name: "doctor",
            description: "Diagnose your claude-code install",
            source: .builtin
        ),
        SlashCommand(
            name: "effort",
            description: "Set effort level (low / medium / high / xhigh / max)",
            argumentHint: "level",
            source: .builtin
        ),
        SlashCommand(
            name: "exit",
            aliases: ["quit"],
            description: "Exit the conversation",
            source: .builtin
        ),
        SlashCommand(
            name: "fast",
            description: "Toggle fast mode",
            source: .builtin
        ),
        SlashCommand(
            name: "feedback",
            description: "Send feedback to Anthropic",
            source: .builtin
        ),
        SlashCommand(
            name: "goal",
            description: "Define a high-level goal and let Claude break it into atomic steps",
            source: .builtin
        ),
        SlashCommand(
            name: "help",
            description: "Show available commands and shortcuts",
            source: .builtin
        ),
        SlashCommand(
            name: "hooks",
            description: "Manage lifecycle hooks",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "init",
            description: "Initialize a new CLAUDE.md file with codebase documentation",
            source: .builtin
        ),
        SlashCommand(
            name: "keybindings",
            description: "Customize keybindings",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "mcp",
            description: "Configure and manage MCP servers",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "memory",
            description: "Open CLAUDE.md memory files",
            source: .builtin
        ),
        SlashCommand(
            name: "model",
            description: "Switch the model for the current session",
            argumentHint: "model",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "output-style",
            description: "Switch output style",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "permissions",
            description: "Manage tool permission rules",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "plan",
            description: "Preview plan mode (read-only research)",
            source: .builtin
        ),
        SlashCommand(
            name: "pr-comments",
            description: "Fetch GitHub PR comments for the current branch",
            source: .builtin
        ),
        SlashCommand(
            name: "release-notes",
            description: "Show release notes",
            source: .builtin
        ),
        SlashCommand(
            name: "reload-plugins",
            description: "Reload plugins to apply config changes",
            source: .builtin
        ),
        SlashCommand(
            name: "rename",
            description: "Set a display name for this session",
            argumentHint: "name",
            source: .builtin
        ),
        SlashCommand(
            name: "resume",
            aliases: ["continue"],
            description: "Resume a previous conversation",
            argumentHint: "session",
            source: .builtin
        ),
        SlashCommand(
            name: "review",
            description: "Run a code review on the current branch",
            source: .builtin
        ),
        SlashCommand(
            name: "rewind",
            description: "Rewind the conversation to a previous turn",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "security-review",
            description: "Run a security review on the pending changes",
            source: .builtin
        ),
        SlashCommand(
            name: "skills",
            description: "Manage skills",
            source: .builtin
        ),
        SlashCommand(
            name: "status",
            description: "Show session and install status",
            source: .builtin
        ),
        SlashCommand(
            name: "statusline",
            description: "Configure the status line",
            source: .builtin,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "todos",
            description: "Show current TODO list",
            source: .builtin
        ),
        SlashCommand(
            name: "ultrareview",
            description: "Cloud-hosted multi-agent code review",
            source: .builtin
        ),
        SlashCommand(
            name: "upgrade",
            description: "Update claude-code to the latest version",
            source: .builtin
        ),
        SlashCommand(
            name: "usage",
            aliases: ["cost"],
            description: "Show session cost, plan usage, and activity stats",
            source: .builtin
        ),

        // MARK: - Hidden (exact-name match only)

        SlashCommand(
            name: "vim",
            description: "Toggle vim mode in the prompt input",
            source: .builtin,
            isHidden: true,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "login",
            description: "Switch to an API-usage-billed account",
            source: .builtin,
            isHidden: true,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "logout",
            description: "Sign out of the current account",
            source: .builtin,
            isHidden: true,
            opensInTerminalDialog: true
        ),
        SlashCommand(
            name: "ide",
            description: "Connect to an IDE on startup",
            source: .builtin,
            isHidden: true
        ),
        SlashCommand(
            name: "install-github-app",
            description: "Install the GitHub app",
            source: .builtin,
            isHidden: true
        ),
        SlashCommand(
            name: "terminal-setup",
            description: "Run terminal integration setup",
            source: .builtin,
            isHidden: true
        ),
        SlashCommand(
            name: "migrate-installer",
            description: "Migrate the claude-code installer",
            source: .builtin,
            isHidden: true
        ),
        SlashCommand(
            name: "remote-control",
            description: "Start a remote-control session",
            source: .builtin,
            isHidden: true
        ),
    ]
}
