import XCTest
@testable import AgentVisorCore

/// Walks user-skills, project-skills, and plugin command directories
/// and assembles the deduped list of slash commands available in a
/// session. Precedence on name collisions: project > user > plugin >
/// builtin. The FS is injected for testability.
final class SlashCommandCatalogLoaderTests: XCTestCase {

    /// In-memory filesystem that the loader treats like real disk.
    /// File contents are markdown strings keyed by `URL`. Enumeration is
    /// a prefix match on `URL.path`.
    struct InMemoryFS: SlashCommandFileSystem {
        let files: [URL: String]
        func enumerateMarkdownFiles(in directory: URL) -> [URL] {
            let dirPath = directory.path
            return files.keys
                .filter { url in
                    let p = url.path
                    return p.hasPrefix(dirPath + "/") && p.hasSuffix(".md")
                }
                .sorted { $0.path < $1.path }
        }
        func read(_ url: URL) -> String? {
            files[url]
        }
    }

    private static let userSkills = URL(fileURLWithPath: "/u/.claude/skills")
    private static let userCommands = URL(fileURLWithPath: "/u/.claude/commands")
    private static let projectSkills = URL(fileURLWithPath: "/p/.claude/skills")
    private static let projectCommands = URL(fileURLWithPath: "/p/.claude/commands")

    private static let testBuiltins: [SlashCommand] = [
        SlashCommand(name: "clear", description: "Free up context", source: .builtin),
        SlashCommand(name: "compact", description: "Summarize so far", source: .builtin),
    ]

    // MARK: - Scenario 1: empty filesystem yields just builtins

    func test_givenEmptyFilesystem_whenCatalogLoads_thenOnlyBuiltinsArePresent() {
        // Given no on-disk files
        let fs = InMemoryFS(files: [:])
        // When the catalog loads with two builtins and no skill dirs
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: Self.testBuiltins,
            userSkillsDir: nil,
            userCommandsDir: nil,
            projectSkillsDir: nil,
            projectCommandsDir: nil,
            enabledPlugins: []
        )
        // Then the builtin names are present and nothing else
        XCTAssertEqual(catalog.commands.map { $0.name }.sorted(), ["clear", "compact"])
    }

    // MARK: - Scenario 2: user skill becomes a userSkill-sourced command

    func test_givenSingleUserSkillFile_whenCatalogLoads_thenCommandIsPresentWithUserSkillSource() {
        // Given /u/.claude/skills/standup.md with frontmatter
        let skill = Self.userSkills.appendingPathComponent("standup.md")
        let fs = InMemoryFS(files: [
            skill: """
            ---
            name: standup
            description: Generate a stand-up update
            ---
            """
        ])
        // When the catalog loads
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: [],
            userSkillsDir: Self.userSkills,
            userCommandsDir: nil,
            projectSkillsDir: nil,
            projectCommandsDir: nil,
            enabledPlugins: []
        )
        // Then the command exists with .userSkill(filePath:) source
        XCTAssertEqual(catalog.commands.count, 1)
        XCTAssertEqual(catalog.commands.first?.name, "standup")
        if case .userSkill(let path) = catalog.commands.first?.source {
            XCTAssertEqual(path, skill.path)
        } else {
            XCTFail("Expected .userSkill source, got \(String(describing: catalog.commands.first?.source))")
        }
    }

    // MARK: - Scenario 3: project skill overrides user skill of the same name

    func test_givenUserAndProjectSkillsWithSameName_whenCatalogLoads_thenProjectWins() {
        // Given a "foo" command defined at both user and project scope
        let userFoo = Self.userSkills.appendingPathComponent("foo.md")
        let projFoo = Self.projectSkills.appendingPathComponent("foo.md")
        let fs = InMemoryFS(files: [
            userFoo: "---\nname: foo\ndescription: User version\n---",
            projFoo: "---\nname: foo\ndescription: Project version\n---",
        ])
        // When the catalog loads
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: [],
            userSkillsDir: Self.userSkills,
            userCommandsDir: nil,
            projectSkillsDir: Self.projectSkills,
            projectCommandsDir: nil,
            enabledPlugins: []
        )
        // Then only one /foo is present, sourced from the project skill, with project description
        XCTAssertEqual(catalog.commands.count, 1)
        XCTAssertEqual(catalog.commands.first?.description, "Project version")
        if case .projectSkill = catalog.commands.first?.source {} else {
            XCTFail("Expected .projectSkill source")
        }
    }

    // MARK: - Scenario 4: project skill overrides a builtin of the same name

    func test_givenProjectSkillAndBuiltinWithSameName_whenCatalogLoads_thenProjectWins() {
        // Given a project-level skill that shadows a builtin
        let projClear = Self.projectSkills.appendingPathComponent("clear.md")
        let fs = InMemoryFS(files: [
            projClear: "---\nname: clear\ndescription: Custom clear\n---"
        ])
        // When the catalog loads with the builtin "clear" present
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: Self.testBuiltins,  // contains "clear"
            userSkillsDir: nil,
            userCommandsDir: nil,
            projectSkillsDir: Self.projectSkills,
            projectCommandsDir: nil,
            enabledPlugins: []
        )
        // Then the single "clear" entry uses the project description
        let clear = catalog.commands.first { $0.name == "clear" }
        XCTAssertEqual(clear?.description, "Custom clear")
        if case .projectSkill = clear?.source {} else {
            XCTFail("Expected project to override builtin")
        }
    }

    // MARK: - Scenario 5: plugin commands dir is walked

    func test_givenPluginWithCommandsDir_whenCatalogLoads_thenPluginCommandsAreIncluded() {
        // Given a plugin at /plugins/foo with a commands/bar.md
        let pluginDir = URL(fileURLWithPath: "/plugins/foo")
        let cmdsDir = pluginDir.appendingPathComponent("commands")
        let barFile = cmdsDir.appendingPathComponent("bar.md")
        let fs = InMemoryFS(files: [
            barFile: "---\nname: bar\ndescription: Plugin bar\n---"
        ])
        let plugin = EnabledPlugin(name: "foo", marketplace: "official", directory: pluginDir)
        // When the catalog loads
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: [],
            userSkillsDir: nil,
            userCommandsDir: nil,
            projectSkillsDir: nil,
            projectCommandsDir: nil,
            enabledPlugins: [plugin]
        )
        // Then /bar is present and sourced from the plugin
        XCTAssertEqual(catalog.commands.first?.name, "bar")
        if case .plugin(let name, let market, _) = catalog.commands.first?.source {
            XCTAssertEqual(name, "foo")
            XCTAssertEqual(market, "official")
        } else {
            XCTFail("Expected .plugin source")
        }
    }

    // MARK: - Scenario 6: plugin SKILL.md uses parent directory as command name

    func test_givenPluginSkillFile_whenCatalogLoads_thenCommandNameIsParentDirName() {
        // Given a plugin skill at /plugins/foo/skills/do/SKILL.md (the
        // claude-mem layout). The frontmatter has `name: do` but even if
        // it didn't, the parent dir name should drive the command name.
        let pluginDir = URL(fileURLWithPath: "/plugins/foo")
        let skillFile = pluginDir
            .appendingPathComponent("skills")
            .appendingPathComponent("do")
            .appendingPathComponent("SKILL.md")
        let fs = InMemoryFS(files: [
            skillFile: """
            ---
            name: do
            description: Execute a plan
            ---
            """
        ])
        let plugin = EnabledPlugin(name: "foo", marketplace: "official", directory: pluginDir)
        // When the catalog loads
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: [],
            userSkillsDir: nil,
            userCommandsDir: nil,
            projectSkillsDir: nil,
            projectCommandsDir: nil,
            enabledPlugins: [plugin]
        )
        // Then the command name is "do" (parent dir, not "SKILL")
        XCTAssertEqual(catalog.commands.first?.name, "do")
    }

    // MARK: - Scenario 7: enabled plugin missing on disk is skipped silently

    func test_givenEnabledPluginWithNoFilesOnDisk_whenCatalogLoads_thenItIsSilentlySkipped() {
        // Given a plugin registered but with no files in its commands/ or skills/ dirs
        let pluginDir = URL(fileURLWithPath: "/plugins/ghost")
        let fs = InMemoryFS(files: [:])
        let plugin = EnabledPlugin(name: "ghost", marketplace: "official", directory: pluginDir)
        // When the catalog loads
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: [],
            userSkillsDir: nil,
            userCommandsDir: nil,
            projectSkillsDir: nil,
            projectCommandsDir: nil,
            enabledPlugins: [plugin]
        )
        // Then the catalog is empty and no error fires
        XCTAssertTrue(catalog.commands.isEmpty)
    }

    // MARK: - Scenario 8: nested skill file becomes colon-namespaced name

    func test_givenNestedUserSkillFile_whenCatalogLoads_thenCommandNameIsColonNamespaced() {
        // Given /u/.claude/skills/foo/bar.md with no `name` in frontmatter
        let nested = Self.userSkills
            .appendingPathComponent("foo")
            .appendingPathComponent("bar.md")
        let fs = InMemoryFS(files: [
            nested: "---\ndescription: Nested thing\n---"
        ])
        // When the catalog loads
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: [],
            userSkillsDir: Self.userSkills,
            userCommandsDir: nil,
            projectSkillsDir: nil,
            projectCommandsDir: nil,
            enabledPlugins: []
        )
        // Then the command name is "foo:bar" (colon-joined relative path
        // without the .md extension)
        XCTAssertEqual(catalog.commands.first?.name, "foo:bar")
    }

    // MARK: - Scenario 9: hidden commands stay in catalog (filter decides visibility)

    func test_givenHiddenSkill_whenCatalogLoads_thenItStaysInCatalogWithHiddenFlagSet() {
        // Given a hidden skill in user dir
        let hidden = Self.userSkills.appendingPathComponent("internal.md")
        let fs = InMemoryFS(files: [
            hidden: """
            ---
            name: internal
            description: Internal tool
            isHidden: true
            ---
            """
        ])
        // When the catalog loads
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: [],
            userSkillsDir: Self.userSkills,
            userCommandsDir: nil,
            projectSkillsDir: nil,
            projectCommandsDir: nil,
            enabledPlugins: []
        )
        // Then the hidden command is still in the catalog; the filter
        // layer is responsible for hiding it from default display while
        // keeping it callable on exact match.
        XCTAssertEqual(catalog.commands.first?.name, "internal")
        XCTAssertEqual(catalog.commands.first?.isHidden, true)
    }

    // MARK: - Scenario 10: filename fallback when frontmatter omits name

    func test_givenFrontmatterWithoutNameField_whenCatalogLoads_thenNameComesFromFilename() {
        // Given /u/.claude/skills/save-to-obsidian.md with no `name` field
        let file = Self.userSkills.appendingPathComponent("save-to-obsidian.md")
        let fs = InMemoryFS(files: [
            file: "---\ndescription: Save to wiki\n---"
        ])
        // When the catalog loads
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: [],
            userSkillsDir: Self.userSkills,
            userCommandsDir: nil,
            projectSkillsDir: nil,
            projectCommandsDir: nil,
            enabledPlugins: []
        )
        // Then the filename basename is used as the command name
        XCTAssertEqual(catalog.commands.first?.name, "save-to-obsidian")
    }

    // MARK: - Scenario 11: legacy commands dir works alongside skills dir

    func test_givenUserSkillsAndLegacyUserCommands_whenCatalogLoads_thenBothPathsAreEnumerated() {
        // Given separate files in both the new skills dir and the
        // deprecated commands dir
        let skill = Self.userSkills.appendingPathComponent("new-style.md")
        let legacy = Self.userCommands.appendingPathComponent("old-style.md")
        let fs = InMemoryFS(files: [
            skill: "---\nname: new-style\ndescription: Modern\n---",
            legacy: "---\nname: old-style\ndescription: Legacy\n---",
        ])
        // When both are configured
        let catalog = SlashCommandCatalogLoader.load(
            fileSystem: fs,
            builtins: [],
            userSkillsDir: Self.userSkills,
            userCommandsDir: Self.userCommands,
            projectSkillsDir: nil,
            projectCommandsDir: nil,
            enabledPlugins: []
        )
        // Then both commands are present, both with .userSkill source
        let names = catalog.commands.map { $0.name }.sorted()
        XCTAssertEqual(names, ["new-style", "old-style"])
    }
}
