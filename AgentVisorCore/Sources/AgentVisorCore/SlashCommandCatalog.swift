import Foundation

/// Snapshot of every slash command available in a session: builtins,
/// user-scoped skills, project-scoped skills, and plugin commands.
public struct SlashCommandCatalog: Sendable {
    public let commands: [SlashCommand]

    public init(commands: [SlashCommand]) {
        self.commands = commands
    }
}

/// One enabled plugin and the directory where its files live.
/// Resolved by the host app from `~/.claude/settings.json` plus the
/// `~/.claude/plugins/installed_plugins.json` metadata.
public struct EnabledPlugin: Sendable {
    public let name: String
    public let marketplace: String
    public let directory: URL

    public init(name: String, marketplace: String, directory: URL) {
        self.name = name
        self.marketplace = marketplace
        self.directory = directory
    }
}

/// Indirection over filesystem reads so the catalog loader can be
/// fully unit-tested with in-memory fixtures.
public protocol SlashCommandFileSystem: Sendable {
    /// Recursively enumerate every `*.md` file under `directory`.
    /// Returns `[]` for missing directories.
    func enumerateMarkdownFiles(in directory: URL) -> [URL]
    /// Read the UTF-8 contents of a markdown file, or nil if missing.
    func read(_ url: URL) -> String?
}

/// Assembles the catalog from the configured sources, applying
/// precedence rules on name collisions: project > user > plugin > builtin.
public enum SlashCommandCatalogLoader {

    /// Walks each configured directory, parses every markdown file,
    /// dedupes by command name, and returns a single catalog.
    /// `nil` source directories are skipped silently — callers pass
    /// nil for sources that don't apply (e.g., a session with no
    /// project skills dir on disk).
    public static func load(
        fileSystem: SlashCommandFileSystem,
        builtins: [SlashCommand],
        userSkillsDir: URL?,
        userCommandsDir: URL?,
        projectSkillsDir: URL?,
        projectCommandsDir: URL?,
        enabledPlugins: [EnabledPlugin]
    ) -> SlashCommandCatalog {

        // Precedence order is the order in which we WRITE into the
        // byName map: later writes win. Builtins go in first; user then
        // overrides; plugin overrides nothing it doesn't share a name
        // with; project overrides last so it sits on top.
        var byName: [String: SlashCommand] = [:]

        for cmd in builtins {
            byName[cmd.name] = cmd
        }

        for plugin in enabledPlugins {
            for cmd in commandsFromPlugin(plugin, fileSystem: fileSystem) {
                byName[cmd.name] = cmd
            }
        }

        if let dir = userSkillsDir {
            for cmd in commandsFromUserDir(dir, fileSystem: fileSystem) {
                byName[cmd.name] = cmd
            }
        }
        if let dir = userCommandsDir {
            for cmd in commandsFromUserDir(dir, fileSystem: fileSystem) {
                byName[cmd.name] = cmd
            }
        }
        if let dir = projectSkillsDir {
            for cmd in commandsFromProjectDir(dir, fileSystem: fileSystem) {
                byName[cmd.name] = cmd
            }
        }
        if let dir = projectCommandsDir {
            for cmd in commandsFromProjectDir(dir, fileSystem: fileSystem) {
                byName[cmd.name] = cmd
            }
        }

        return SlashCommandCatalog(commands: Array(byName.values).sorted { $0.name < $1.name })
    }

    // MARK: - per-source helpers

    private static func commandsFromUserDir(_ dir: URL, fileSystem: SlashCommandFileSystem) -> [SlashCommand] {
        parseFiles(in: dir, fileSystem: fileSystem) { filePath in
            .userSkill(filePath: filePath)
        }
    }

    private static func commandsFromProjectDir(_ dir: URL, fileSystem: SlashCommandFileSystem) -> [SlashCommand] {
        parseFiles(in: dir, fileSystem: fileSystem) { filePath in
            .projectSkill(filePath: filePath)
        }
    }

    private static func commandsFromPlugin(_ plugin: EnabledPlugin, fileSystem: SlashCommandFileSystem) -> [SlashCommand] {
        // Default plugin layout matches claude-code's: <plugin>/commands
        // and <plugin>/skills are both walked. Plugins with custom
        // commandsPath in plugin.json aren't supported in v1 — defer
        // until we hit a real plugin that uses one.
        let commandsDir = plugin.directory.appendingPathComponent("commands")
        let skillsDir = plugin.directory.appendingPathComponent("skills")
        let make: (String) -> SlashCommandSource = { path in
            .plugin(pluginName: plugin.name, marketplace: plugin.marketplace, filePath: path)
        }
        return parseFiles(in: commandsDir, fileSystem: fileSystem, sourceBuilder: make)
            + parseFiles(in: skillsDir, fileSystem: fileSystem, sourceBuilder: make)
    }

    /// Shared walk: enumerate, read, parse-frontmatter, attach source.
    private static func parseFiles(
        in directory: URL,
        fileSystem: SlashCommandFileSystem,
        sourceBuilder: (String) -> SlashCommandSource
    ) -> [SlashCommand] {
        var result: [SlashCommand] = []
        for url in fileSystem.enumerateMarkdownFiles(in: directory) {
            guard let body = fileSystem.read(url) else { continue }
            let fallbackName = SlashCommandNameDeriver.derive(filePath: url, baseDirectory: directory)
            guard let parsed = SlashCommandFrontmatterParser.parse(
                markdown: body,
                fallbackName: fallbackName
            ) else { continue }

            // The parser doesn't know about source/file path; rebuild
            // the command with the correct source and (if missing) a
            // file-derived name.
            let cmd = SlashCommand(
                name: parsed.name.isEmpty ? fallbackName : parsed.name,
                aliases: parsed.aliases,
                description: parsed.description,
                argumentHint: parsed.argumentHint,
                argNames: parsed.argNames,
                source: sourceBuilder(url.path),
                isHidden: parsed.isHidden
            )
            result.append(cmd)
        }
        return result
    }
}

/// Maps a markdown file path back to its canonical command name based
/// on its position under a source directory.
///
/// Rules (matching claude-code's loadSkillsDir conventions):
///
/// * `foo.md` → `foo`
/// * `foo/bar.md` → `foo:bar`
/// * `foo/SKILL.md` → `foo`
/// * `foo/bar/SKILL.md` → `foo:bar`
public enum SlashCommandNameDeriver {
    public static func derive(filePath: URL, baseDirectory: URL) -> String {
        let basePath = baseDirectory.path.hasSuffix("/")
            ? baseDirectory.path
            : baseDirectory.path + "/"
        let fullPath = filePath.path

        // Strip the base dir prefix; if the file isn't actually under the
        // base, fall back to the basename without extension.
        guard fullPath.hasPrefix(basePath) else {
            return filePath.deletingPathExtension().lastPathComponent
        }
        let relative = String(fullPath.dropFirst(basePath.count))
        // Split by `/` to get the segments; drop the file extension on
        // the last segment.
        var segments = relative.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return "" }
        let lastIdx = segments.count - 1
        let lastName = segments[lastIdx]
        // SKILL.md is a marker file — drop it so the parent dir wins.
        if lastName.uppercased() == "SKILL.MD" {
            segments.removeLast()
        } else {
            // Drop the .md extension on the last segment.
            let withoutExt = (lastName as NSString).deletingPathExtension
            segments[lastIdx] = withoutExt
        }
        return segments.joined(separator: ":")
    }
}
