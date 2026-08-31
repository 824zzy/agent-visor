import { mkdtemp, mkdir, opendir, open, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { loadSlashCommandCatalog, loadSlashCommands, type SlashCommandFileSystem } from "./slash-commands.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) =>
    rm(directory, { recursive: true, force: true })));
});

describe("filesystem slash-command catalog", () => {
  it("merges the Swift command locations with deterministic precedence", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const plugin = path.join(home, ".claude", "plugins", "cache", "marketplace", "review-tools", "1.0.0");
    await mkdir(path.join(home, ".claude", "commands"), { recursive: true });
    await mkdir(path.join(project, ".claude", "commands"), { recursive: true });
    await mkdir(path.join(plugin, "commands"), { recursive: true });
    await writeFile(path.join(home, ".claude", "settings.json"), JSON.stringify({
      enabledPlugins: { "review-tools@marketplace": true },
    }));
    await writeFile(path.join(plugin, "commands", "audit.md"), "---\naliases: [inspect]\n---\nPlugin audit\n");
    await writeFile(path.join(home, ".claude", "commands", "audit.md"), "---\ndescription: User audit\n---\n");
    await writeFile(path.join(project, ".claude", "commands", "audit.md"), "---\nname: audit\n---\nProject audit\n");
    await writeFile(path.join(project, ".claude", "commands", "ship.md"), "---\nargumentHint: target\nisHidden: true\n---\nShip it\n");

    const commands = await loadSlashCommands(project, home);
    const byName = new Map(commands.map((command) => [command.name, command]));

    expect(byName.get("compact")).toMatchObject({ source: "builtin" });
    expect(byName.get("audit")).toMatchObject({ source: "project", description: "Project audit" });
    expect(byName.get("ship")).toMatchObject({
      source: "project", argumentHint: "target", isHidden: true,
    });
    expect(byName.get("audit")?.aliases).toEqual([]);
    expect(commands.map(({ name }) => name)).toEqual([...byName.keys()].sort((left, right) => left.localeCompare(right)));
  });

  it("treats a SKILL.md directory as one command and ignores its references", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-skill-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const skill = path.join(project, ".claude", "skills", "review");
    await mkdir(path.join(skill, "references", "nested"), { recursive: true });
    await writeFile(path.join(skill, "SKILL.md"), "---\ndescription: Review skill\n---\nReview it\n");
    await writeFile(path.join(skill, "notes.md"), "---\nname: notes\n---\nNot a command\n");
    await writeFile(path.join(skill, "references", "guide.md"), "---\nname: guide\n---\nNot a command\n");
    await writeFile(path.join(skill, "references", "nested", "deep.md"), "---\nname: deep\n---\nNot a command\n");

    const commands = await loadSlashCommands(project, home);
    const names = commands.map(({ name }) => name);

    expect(names).toContain("review");
    expect(names.filter((name) => name.startsWith("review:"))).toEqual([]);
    expect(names).not.toContain("notes");
    expect(names).not.toContain("guide");
    expect(names).not.toContain("deep");
  });

  it("skips oversized and over-depth files while bounding a large catalog", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-bounds-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const commandsDirectory = path.join(project, ".claude", "commands");
    await mkdir(commandsDirectory, { recursive: true });
    await writeFile(path.join(commandsDirectory, "aaa-oversized.md"), "x".repeat(600_000));
    const deepDirectory = path.join(commandsDirectory, "a", "b", "c", "d", "e");
    await mkdir(deepDirectory, { recursive: true });
    await writeFile(path.join(deepDirectory, "deep.md"), "---\ndescription: Too deep\n---\n");
    await Promise.all(Array.from({ length: 1_100 }, (_, index) => writeFile(
      path.join(commandsDirectory, `command-${String(index).padStart(4, "0")}.md`),
      `---\nname: generated-${index}\n---\nGenerated\n`,
    )));

    const catalog = await loadSlashCommandCatalog(project, home);
    const commands = catalog.commands;
    const names = commands.map(({ name }) => name);

    expect(commands.length).toBe(1_000);
    expect(catalog.truncated).toBe(true);
    expect(names).not.toContain("aaa-oversized");
    expect(names).not.toContain("deep");
    expect(names).toContain("generated-0");
  });

  it("marks truncation only after a result is actually beyond the catalog ceiling", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-result-cap-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const commandsDirectory = path.join(project, ".claude", "commands");
    await mkdir(commandsDirectory, { recursive: true });
    const builtinCount = (await loadSlashCommandCatalog(undefined, home)).commands.length;
    const customCount = 1_000 - builtinCount;
    const writeCommands = async (count: number) => {
      await Promise.all(Array.from({ length: count }, (_, index) => writeFile(
        path.join(commandsDirectory, `extra-${String(index).padStart(4, "0")}.md`),
        `---\nname: extra-${index}\n---\nExtra\n`,
      )));
    };

    await writeCommands(customCount);
    const exact = await loadSlashCommandCatalog(project, home);
    expect(exact.commands).toHaveLength(1_000);
    expect(exact.truncated).toBe(false);

    await writeFile(path.join(commandsDirectory, "extra-over-cap.md"), "---\nname: over-cap\n---\nExtra\n");
    const over = await loadSlashCommandCatalog(project, home);
    expect(over.commands).toHaveLength(1_000);
    expect(over.truncated).toBe(true);
  });

  it("marks an irrelevant directory overflow as truncated before a later command", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-directory-overflow-truth-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const commandsDirectory = path.join(project, ".claude", "commands");
    await mkdir(commandsDirectory, { recursive: true });
    const resolvedCommands = await realpath(commandsDirectory);
    const entries = Array.from({ length: 2_048 }, (_, index) => ({
      name: `note-${String(index).padStart(4, "0")}.txt`,
      isDirectory: () => false,
      isSymbolicLink: () => false,
    }));
    entries.push(
      { name: "overflow.txt", isDirectory: () => false, isSymbolicLink: () => false },
      { name: "later.md", isDirectory: () => false, isSymbolicLink: () => false },
    );
    const fileSystem: SlashCommandFileSystem = {
      opendir: async (directory) => {
        if (directory === resolvedCommands) {
          return {
            async *[Symbol.asyncIterator]() {
              yield* entries;
            },
            close: async () => undefined,
          };
        }
        return opendir(directory);
      },
      open,
      realpath,
      stat,
    };

    const catalog = await loadSlashCommandCatalog(project, home, { fileSystem });

    expect(catalog.commands.map(({ name }) => name)).not.toContain("later");
    expect(catalog.truncated).toBe(true);
  });

  it("probes later sources honestly after an earlier source exhausts work", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-cross-source-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const noisyUserSkills = path.join(home, ".claude", "skills");
    const projectCommands = path.join(project, ".claude", "commands");
    await mkdir(noisyUserSkills, { recursive: true });
    await mkdir(projectCommands, { recursive: true });
    await writeFile(path.join(projectCommands, "later.md"), "---\nname: later\n---\nLater\n");
    const resolvedNoisyUserSkills = await realpath(noisyUserSkills);
    const noisyEntries = Array.from({ length: 2_048 }, (_, index) => ({
      name: `directory-${index}`,
      isDirectory: () => true,
      isSymbolicLink: () => false,
    }));
    const quietEntries = Array.from({ length: 8 }, (_, index) => ({
      name: `note-${index}.txt`,
      isDirectory: () => false,
      isSymbolicLink: () => false,
    }));
    const fileSystem: SlashCommandFileSystem = {
      opendir: async (directory) => {
        if (directory === resolvedNoisyUserSkills) {
          return {
            async *[Symbol.asyncIterator]() {
              yield* noisyEntries;
            },
            close: async () => undefined,
          };
        }
        if (directory.startsWith(`${resolvedNoisyUserSkills}${path.sep}`)) {
          return {
            async *[Symbol.asyncIterator]() {
              yield* quietEntries;
            },
            close: async () => undefined,
          };
        }
        return opendir(directory);
      },
      open,
      realpath: async (file) => file.startsWith(resolvedNoisyUserSkills)
        ? file
        : realpath(file),
      stat,
    };

    const withLater = await loadSlashCommandCatalog(project, home, { fileSystem });
    expect(withLater.commands.map(({ name }) => name)).not.toContain("later");
    expect(withLater.truncated).toBe(true);

    await rm(path.join(project, ".claude"), { recursive: true, force: true });
    const withoutLater = await loadSlashCommandCatalog(project, home, { fileSystem });
    expect(withoutLater.commands.map(({ name }) => name)).not.toContain("later");
    expect(withoutLater.truncated).toBe(true);
  });

  it("keeps a genuinely empty source complete", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-empty-source-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const catalog = await loadSlashCommandCatalog(project, home);

    expect(catalog.truncated).toBe(false);
  });

  it("skips dotfiles and dot-directories like Swift discovery", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-hidden-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const commandsDirectory = path.join(project, ".claude", "commands");
    await mkdir(path.join(commandsDirectory, ".private"), { recursive: true });
    await writeFile(path.join(commandsDirectory, "visible.md"), "---\nname: visible\n---\nVisible\n");
    await writeFile(path.join(commandsDirectory, ".hidden.md"), "---\nname: hidden-file\n---\nHidden\n");
    await writeFile(path.join(commandsDirectory, ".private", "nested.md"), "---\nname: hidden-directory\n---\nHidden\n");

    const names = (await loadSlashCommands(project, home)).map(({ name }) => name);

    expect(names).toContain("visible");
    expect(names).not.toContain("hidden-file");
    expect(names).not.toContain("hidden-directory");
  });

  it("does not read command files from an over-cap directory", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-directory-cap-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const commandsDirectory = path.join(project, ".claude", "commands");
    await mkdir(commandsDirectory, { recursive: true });
    await Promise.all(Array.from({ length: 2_100 }, (_, index) => writeFile(
      path.join(commandsDirectory, `command-${String(index).padStart(4, "0")}.md`),
      `---\nname: generated-${index}\n---\nGenerated\n`,
    )));
    const reads: string[] = [];
    const fileSystem: SlashCommandFileSystem = {
      opendir,
      open: async (file, flags) => {
        reads.push(file);
        return open(file, flags);
      },
      realpath,
      stat,
    };

    await loadSlashCommands(project, home, { fileSystem });

    expect(reads.filter((file) => file.endsWith(".md"))).toEqual([]);
  });

  it("does not read commands from a plugin with too many cached versions", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-plugin-cap-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const pluginRoot = path.join(home, ".claude", "plugins", "cache", "marketplace", "bounded-plugin");
    await mkdir(pluginRoot, { recursive: true });
    await mkdir(path.join(home, ".claude"), { recursive: true });
    await writeFile(path.join(home, ".claude", "settings.json"), JSON.stringify({
      enabledPlugins: { "bounded-plugin@marketplace": true },
    }));
    await Promise.all(Array.from({ length: 65 }, (_, index) => {
      const version = path.join(pluginRoot, `version-${String(index).padStart(2, "0")}`);
      return mkdir(path.join(version, "commands"), { recursive: true })
        .then(() => writeFile(path.join(version, "commands", "should-not-read.md"),
          "---\nname: should-not-read\n---\nNo\n"));
    }));
    const reads: string[] = [];
    const fileSystem: SlashCommandFileSystem = {
      opendir,
      open: async (file, flags) => {
        reads.push(file);
        return open(file, flags);
      },
      realpath,
      stat,
    };

    const names = (await loadSlashCommands(project, home, { fileSystem })).map(({ name }) => name);

    expect(names).not.toContain("should-not-read");
    expect(reads.filter((file) => file.endsWith("should-not-read.md"))).toEqual([]);
  });

  it("rejects unsafe plugin components and versions resolved outside the cache root", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-plugin-path-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const cacheRoot = path.join(home, ".claude", "plugins", "cache");
    const validVersion = path.join(cacheRoot, "marketplace", "valid-plugin", "1.0.0");
    const outsideVersion = path.join(root, "outside-version");
    await mkdir(path.join(validVersion, "commands"), { recursive: true });
    await mkdir(path.join(outsideVersion, "commands"), { recursive: true });
    await writeFile(path.join(validVersion, "commands", "valid.md"), "---\nname: valid\n---\nValid\n");
    await writeFile(path.join(outsideVersion, "commands", "escaped.md"), "---\nname: escaped\n---\nOutside\n");
    await mkdir(path.join(cacheRoot, "marketplace", "linked-plugin"), { recursive: true });
    await symlink(outsideVersion, path.join(cacheRoot, "marketplace", "linked-plugin", "1.0.0"));
    const oversizedName = "x".repeat(513);
    const settingsPath = path.join(home, ".claude", "settings.json");
    await mkdir(path.dirname(settingsPath), { recursive: true });
    await writeFile(settingsPath, JSON.stringify({
      enabledPlugins: {
        "valid-plugin@marketplace": true,
        "linked-plugin@marketplace": true,
        "../escape@marketplace": true,
        "valid-plugin@../../outside": true,
        "bad/name@marketplace": true,
        [`nul\u0000-plugin@marketplace`]: true,
        [`${oversizedName}@marketplace`]: true,
      },
    }));

    const names = (await loadSlashCommands(project, home)).map(({ name }) => name);

    expect(names).toContain("valid");
    expect(names).not.toContain("escaped");
  });

  it("splits plugin identifiers at the first @ and allows a safe later @", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-plugin-at-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const version = path.join(home, ".claude", "plugins", "cache", "market@place", "safe", "1.0.0");
    await mkdir(path.join(version, "commands"), { recursive: true });
    await writeFile(path.join(version, "commands", "first-at.md"), "---\nname: first-at\n---\nWorks\n");
    const settingsPath = path.join(home, ".claude", "settings.json");
    await mkdir(path.dirname(settingsPath), { recursive: true });
    await writeFile(settingsPath, JSON.stringify({ enabledPlugins: { "safe@market@place": true } }));

    const names = (await loadSlashCommands(project, home)).map(({ name }) => name);

    expect(names).toContain("first-at");
  });

  it("marks a bounded remaining-source probe unknown when a symlinked directory hides a candidate", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-probe-symlink-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const userSkills = path.join(home, ".claude", "skills");
    const linked = path.join(root, "linked-skill");
    await mkdir(path.join(linked, "nested"), { recursive: true });
    await writeFile(path.join(linked, "nested", "hidden.md"), "---\nname: hidden-after-link\n---\nHidden\n");
    await mkdir(userSkills, { recursive: true });
    await symlink(linked, path.join(userSkills, "linked"), "dir");
    const commandsDirectory = path.join(userSkills, "noise");
    await mkdir(commandsDirectory, { recursive: true });
    await Promise.all(Array.from({ length: 17_000 }, (_, index) => writeFile(
      path.join(commandsDirectory, `noise-${String(index).padStart(5, "0")}.md`),
      "---\nname: noise\n---\nNoise\n",
    )));

    const catalog = await loadSlashCommandCatalog(project, home);

    expect(catalog.truncated).toBe(true);
  });

  it("follows an in-root symlinked skill directory during normal discovery", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-symlink-skill-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const target = path.join(project, "shared-skill");
    const skills = path.join(project, ".claude", "skills");
    await mkdir(path.join(target), { recursive: true });
    await writeFile(path.join(target, "SKILL.md"), "---\nname: linked-skill\n---\nLinked\n");
    await mkdir(skills, { recursive: true });
    await symlink(target, path.join(skills, "linked"), "dir");

    const names = (await loadSlashCommands(project, home)).map(({ name }) => name);

    expect(names).toContain("linked-skill");
  });

  it("does not probe final symlinked command or SKILL.md files as readable candidates", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-probe-final-symlink-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const userSkills = path.join(home, ".claude", "skills");
    const userCommands = path.join(home, ".claude", "commands");
    const projectSkills = path.join(project, ".claude", "skills");
    const projectCommands = path.join(project, ".claude", "commands");
    const cache = path.join(home, ".claude", "plugins", "cache");
    const linkedSkill = path.join(projectSkills, "linked");
    const outsideCommand = path.join(root, "outside-command.md");
    const outsideSkill = path.join(root, "outside-skill.md");
    await mkdir(userSkills, { recursive: true });
    await mkdir(userCommands, { recursive: true });
    await mkdir(linkedSkill, { recursive: true });
    await mkdir(projectCommands, { recursive: true });
    await mkdir(cache, { recursive: true });
    await writeFile(path.join(home, ".claude", "settings.json"), "{}");
    await writeFile(outsideCommand, "---\nname: escaped-command\n---\nOutside\n");
    await writeFile(outsideSkill, "---\nname: escaped-skill\n---\nOutside\n");
    await symlink(outsideCommand, path.join(projectCommands, "linked.md"));
    await symlink(outsideSkill, path.join(linkedSkill, "SKILL.md"));
    const repeated = "---\nname: repeated\n---\nRepeated\n";
    const fill = async (directory: string) => Promise.all(Array.from({ length: 2_048 }, (_, index) => writeFile(
      path.join(directory, `command-${String(index).padStart(4, "0")}.md`), repeated,
    )));
    await fill(userSkills);
    await fill(userCommands);

    const catalog = await loadSlashCommandCatalog(project, home);
    const names = catalog.commands.map(({ name }) => name);

    expect(names).toContain("repeated");
    expect(names).not.toContain("escaped-command");
    expect(names).not.toContain("escaped-skill");
    expect(catalog.truncated).toBe(false);
  });

  it("marks a skipped directory below the maximum walk depth as truncated", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-depth-boundary-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const boundary = path.join(project, ".claude", "commands", "one", "two", "three", "four");
    await mkdir(boundary, { recursive: true });
    await writeFile(path.join(boundary, "leaf.md"), "---\nname: boundary-leaf\n---\nLeaf\n");

    const exact = await loadSlashCommandCatalog(project, home);
    expect(exact.commands.map(({ name }) => name)).toContain("boundary-leaf");
    expect(exact.truncated).toBe(false);

    await mkdir(path.join(boundary, "deeper"), { recursive: true });
    await writeFile(path.join(boundary, "deeper", "deep.md"), "---\nname: too-deep\n---\nDeep\n");
    const beyond = await loadSlashCommandCatalog(project, home);

    expect(beyond.commands.map(({ name }) => name)).not.toContain("too-deep");
    expect(beyond.truncated).toBe(true);
  });

  it("rejects plugin command and skill subdirectories that resolve outside the version root", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-plugin-subdir-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const version = path.join(home, ".claude", "plugins", "cache", "marketplace", "safe", "1.0.0");
    const outside = path.join(root, "outside");
    await mkdir(path.join(version, "commands"), { recursive: true });
    await mkdir(path.join(version, "skills"), { recursive: true });
    await mkdir(path.join(outside, "commands"), { recursive: true });
    await mkdir(path.join(outside, "skills"), { recursive: true });
    await writeFile(path.join(outside, "commands", "escaped.md"), "---\nname: escaped-command\n---\nOutside\n");
    await writeFile(path.join(outside, "skills", "SKILL.md"), "---\nname: escaped-skill\n---\nOutside\n");
    await symlink(path.join(outside, "commands"), path.join(version, "commands", "linked"), "dir");
    await symlink(path.join(outside, "skills"), path.join(version, "skills", "linked"), "dir");
    const settingsPath = path.join(home, ".claude", "settings.json");
    await mkdir(path.dirname(settingsPath), { recursive: true });
    await writeFile(settingsPath, JSON.stringify({ enabledPlugins: { "safe@marketplace": true } }));

    const names = (await loadSlashCommands(project, home)).map(({ name }) => name);

    expect(names).not.toContain("escaped-command");
    expect(names).not.toContain("escaped-skill");
  });

  it("does not read an oversized settings file", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-settings-cap-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const settingsPath = path.join(home, ".claude", "settings.json");
    await mkdir(path.dirname(settingsPath), { recursive: true });
    await mkdir(path.join(project, ".claude", "commands"), { recursive: true });
    await writeFile(settingsPath, "x".repeat(512 * 1_024 + 1));
    await writeFile(path.join(project, ".claude", "commands", "visible.md"), "---\nname: visible\n---\nVisible\n");
    const reads: string[] = [];
    const fileSystem: SlashCommandFileSystem = {
      opendir,
      open: async (file, flags) => {
        const handle = await open(file, flags);
        return {
          stat: () => handle.stat(),
          read: async (...args) => {
            reads.push(file);
            return handle.read(...args);
          },
          close: () => handle.close(),
        };
      },
      realpath,
      stat,
    };

    const names = (await loadSlashCommands(project, home, { fileSystem })).map(({ name }) => name);

    expect(names).toContain("visible");
    expect(reads).not.toContain(settingsPath);
  });

  it("rejects a symlinked command file at the no-follow open boundary", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-symlink-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const commandsDirectory = path.join(project, ".claude", "commands");
    await mkdir(commandsDirectory, { recursive: true });
    const target = path.join(root, "outside.md");
    await writeFile(target, "---\nname: escaped\n---\nShould not load\n");
    await symlink(target, path.join(commandsDirectory, "escaped.md"));

    const names = (await loadSlashCommands(project, home)).map(({ name }) => name);

    expect(names).not.toContain("escaped");
  });

  it("rejects a command that grows after the bounded stat", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-slash-growth-"));
    temporaryDirectories.push(root);
    const home = path.join(root, "home");
    const project = path.join(root, "project");
    const commandPath = path.join(project, ".claude", "commands", "growth.md");
    await mkdir(path.dirname(commandPath), { recursive: true });
    await writeFile(commandPath, "---\nname: growth\n---\nGrowth\n");
    const fileSystem: SlashCommandFileSystem = {
      opendir,
      open: async (file, flags) => {
        const handle = await open(file, flags);
        if (!file.endsWith("/growth.md")) return handle;
        return {
          stat: async () => ({ size: 1, isFile: () => true }),
          read: async (_buffer, _offset, length) => ({ bytesRead: length }),
          close: () => handle.close(),
        };
      },
      realpath,
      stat,
    };

    const catalog = await loadSlashCommandCatalog(project, home, { fileSystem });

    expect(catalog.commands.map(({ name }) => name)).not.toContain("growth");
    expect(catalog.truncated).toBe(true);
  });
});
