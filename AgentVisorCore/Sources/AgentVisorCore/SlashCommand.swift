import Foundation

/// One slash command that can appear in the agent-visor autocomplete
/// popover. Sourced from a markdown file on disk (user skill, project
/// skill, plugin command) or from the hardcoded builtin list.
///
/// The `name` is the canonical short form (no leading slash, no plugin
/// prefix). Nested skill files like `foo/bar.md` produce a name of
/// `foo:bar`. Aliases are alternate names that filter equally well.
public struct SlashCommand: Equatable, Sendable {
    public let name: String
    public let aliases: [String]
    public let description: String
    public let argumentHint: String?
    public let argNames: [String]
    public let source: SlashCommandSource
    public let isHidden: Bool
    /// True for builtins that open a TUI-only modal dialog (e.g.
    /// /config, /login, /logout, /model). These still WORK from the
    /// agent-visor composer — agent-visor sends the keystroke to
    /// the TUI pane — but the dialog opens in the terminal, not in
    /// the visor window. The popover dims these rows and labels them
    /// "Opens in terminal" so the user knows where to look after
    /// running them.
    public let opensInTerminalDialog: Bool

    public init(
        name: String,
        aliases: [String] = [],
        description: String = "",
        argumentHint: String? = nil,
        argNames: [String] = [],
        source: SlashCommandSource,
        isHidden: Bool = false,
        opensInTerminalDialog: Bool = false
    ) {
        self.name = name
        self.aliases = aliases
        self.description = description
        self.argumentHint = argumentHint
        self.argNames = argNames
        self.source = source
        self.isHidden = isHidden
        self.opensInTerminalDialog = opensInTerminalDialog
    }
}

/// Where a slash command originated. Used to drive precedence on name
/// collisions (project > user > plugin > builtin) and to render an
/// optional source badge in the popover row.
public enum SlashCommandSource: Equatable, Sendable {
    case builtin
    case userSkill(filePath: String)
    case projectSkill(filePath: String)
    case plugin(pluginName: String, marketplace: String, filePath: String)
}
