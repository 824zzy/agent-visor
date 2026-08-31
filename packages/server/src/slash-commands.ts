import { homedir } from "node:os";
import path from "node:path";
import { constants } from "node:fs";
import { open, opendir, realpath, stat } from "node:fs/promises";
import type { Dirent } from "node:fs";
import {
  CHAT_SLASH_COMMAND_MAX_RESULTS,
  CHAT_SLASH_SOURCE_LABEL_MAX_CHARS,
  type ChatCommands,
  type ChatSlashCommand,
} from "@agent-visor/protocol";

const slashCommandMaxDepth = 4;
// ponytail: if skills become deeper than the Swift loader's supported tree,
// update this walk and its parity tests before increasing the depth.
const slashCommandMaxEntriesPerDirectory = 2_048;
// ponytail: if a command directory exceeds this entry bound, add paged or
// indexed discovery before increasing the traversal work allowed here.
const slashCommandMaxFilesPerDirectory = 2_048;
// ponytail: if catalogs need more than this many markdown files, add a
// paged protocol instead of increasing one response's discovery work.
const slashCommandMaxFileBytes = 512 * 1_024;
// ponytail: if command documents need more bytes, add bounded streaming or a
// documented wire limit before increasing this pre-read safety bound.
const slashCommandMaxSettingsBytes = 512 * 1_024;
// ponytail: if settings need more bytes, add a bounded settings parser before
// increasing this limit; never read the whole settings file into memory.
const slashCommandMaxPlugins = 64;
// ponytail: if settings enable more than 64 plugins, add paged plugin
// discovery before increasing this one-request scan.
const slashCommandMaxPluginComponentLength = 128;
// ponytail: if marketplace or plugin names exceed one safe path component,
// add an explicit identifier mapping before increasing this boundary.
const slashCommandMaxVersionsPerPlugin = 64;
// ponytail: if one plugin has more than 64 cached versions, add a bounded
// version-selection index before increasing this scan.
const slashCommandMaxDiscoveryWork = 16_384;
// ponytail: if command discovery needs more work, add an indexed or paged
// catalog before increasing this global filesystem-operation budget.
const slashCommandMaxDiscoveredFiles = 4_096;
// ponytail: if more candidate files are needed before parsing, add a paged
// discovery protocol rather than increasing this global result budget.
const slashCommandMaxProbeWork = 4_096;
// ponytail: if exhausted sources need a deeper probe, add an indexed catalog
// rather than allowing a fallback probe to become unbounded.

export type SlashCommandFileSystem = {
  opendir(directory: string): Promise<SlashDirectoryHandle>;
  open(file: string, flags: number): Promise<SlashFileHandle>;
  realpath(file: string): Promise<string>;
  stat(file: string): Promise<{ size: number; isDirectory(): boolean }>;
};

type SlashDirectoryEntry = Pick<Dirent, "name" | "isDirectory" | "isSymbolicLink">;
type SlashDirectoryHandle = AsyncIterable<SlashDirectoryEntry> & {
  close(): Promise<void>;
};

type SlashFileHandle = {
  stat(): Promise<{ size: number; isFile(): boolean }>;
  read(buffer: Uint8Array, offset: number, length: number, position: number): Promise<{ bytesRead: number }>;
  close(): Promise<void>;
};

const nativeFileSystem: SlashCommandFileSystem = {
  opendir: (directory) => opendir(directory),
  open: (file, flags) => open(file, flags),
  realpath,
  stat,
};

type DiscoveryBudget = {
  workRemaining: number;
  filesRemaining: number;
  truncated: boolean;
  claimedCandidates: Set<string>;
};

function discoveryBudget(): DiscoveryBudget {
  return {
    workRemaining: slashCommandMaxDiscoveryWork,
    filesRemaining: slashCommandMaxDiscoveredFiles,
    truncated: false,
    claimedCandidates: new Set(),
  };
}

function spend(budget: DiscoveryBudget): boolean {
  if (budget.workRemaining <= 0) return false;
  budget.workRemaining -= 1;
  return true;
}

function hasWork(budget: DiscoveryBudget): boolean {
  return budget.workRemaining > 0 && budget.filesRemaining > 0;
}

/**
 * Swift's built-in list is compiled into the app, so the Electron daemon
 * keeps the same release snapshot here. Filesystem commands are merged below
 * with the same project > user > plugin > builtin precedence.
 */
const builtinCommands: ChatSlashCommand[] = [
  command("add-dir", "Add a directory to the session's allow-list", "path"),
  command("agents", "Manage background agents", undefined, true),
  command("btw", "Send a side-channel question while Claude works"),
  command("bug", "Report a bug to Anthropic"),
  command("clear", "Free up context by clearing the conversation"),
  command("color", "Set the prompt bar color for this session"),
  command("compact", "Free up context by summarizing the conversation so far"),
  command("config", "Open config panel", undefined, true),
  command("context", "Visualize current context usage as a colored grid"),
  command("copy", "Copy Claude's last response to clipboard (or /copy N for the Nth-latest)", "N"),
  command("doctor", "Diagnose your claude-code install"),
  command("effort", "Set effort level (low / medium / high / xhigh / max)", "level"),
  command("exit", "Exit the conversation", undefined, false, ["quit"]),
  command("fast", "Toggle fast mode"),
  command("feedback", "Send feedback to Anthropic"),
  command("goal", "Define a high-level goal and let Claude break it into atomic steps"),
  command("help", "Show available commands and shortcuts"),
  command("hooks", "Manage lifecycle hooks", undefined, true),
  command("init", "Initialize a new CLAUDE.md file with codebase documentation"),
  command("keybindings", "Customize keybindings", undefined, true),
  command("mcp", "Configure and manage MCP servers", undefined, true),
  command("memory", "Open CLAUDE.md memory files"),
  command("model", "Switch the model for the current session", "model", true),
  command("output-style", "Switch output style", undefined, true),
  command("permissions", "Manage tool permission rules", undefined, true),
  command("plan", "Preview plan mode (read-only research)"),
  command("pr-comments", "Fetch GitHub PR comments for the current branch"),
  command("release-notes", "Show release notes"),
  command("reload-plugins", "Reload plugins to apply config changes"),
  command("rename", "Set a display name for this session", "name"),
  command("resume", "Resume a previous conversation", "session", false, ["continue"]),
  command("review", "Run a code review on the current branch"),
  command("rewind", "Rewind the conversation to a previous turn", undefined, true),
  command("security-review", "Run a security review on the pending changes"),
  command("skills", "Manage skills"),
  command("status", "Show session and install status"),
  command("statusline", "Configure the status line", undefined, true),
  command("todos", "Show current TODO list"),
  command("ultrareview", "Cloud-hosted multi-agent code review"),
  command("upgrade", "Update claude-code to the latest version"),
  command("usage", "Show session cost, plan usage, and activity stats", undefined, false, ["cost"]),
  command("vim", "Toggle vim mode in the prompt input", undefined, true, [], true),
  command("login", "Switch to an API-usage-billed account", undefined, true, [], true),
  command("logout", "Sign out of the current account", undefined, true, [], true),
  command("ide", "Connect to an IDE on startup", undefined, false, [], true),
  command("install-github-app", "Install the GitHub app", undefined, false, [], true),
  command("terminal-setup", "Run terminal integration setup", undefined, false, [], true),
  command("migrate-installer", "Migrate the claude-code installer", undefined, false, [], true),
  command("remote-control", "Start a remote-control session", undefined, false, [], true),
];

function command(
  name: string,
  description: string,
  argumentHint?: string,
  opensInTerminalDialog = false,
  aliases: string[] = [],
  isHidden = false,
): ChatSlashCommand {
  return {
    name,
    aliases,
    description,
    ...(argumentHint ? { argumentHint } : {}),
    argNames: [],
    source: "builtin",
    isHidden,
    opensInTerminalDialog,
  };
}

type CommandSource = ChatSlashCommand["source"];

export type SlashCommandCatalog = Pick<ChatCommands, "commands" | "truncated">;

type MarkdownProbeResult =
  | { kind: "found"; path: string }
  | { kind: "complete-none" }
  | { kind: "unknown-bound-exhausted" };

type EnabledPlugin = {
  name: string;
  marketplace: string;
  directory: string;
};

/** Load commands from the same disk locations as SlashCommandCatalogBuilder. */
export async function loadSlashCommands(
  cwd?: string,
  home = homedir(),
  options: { fileSystem?: SlashCommandFileSystem } = {},
): Promise<ChatCommands["commands"]> {
  return (await loadSlashCommandCatalog(cwd, home, options)).commands;
}

export async function loadSlashCommandCatalog(
  cwd?: string,
  home = homedir(),
  options: { fileSystem?: SlashCommandFileSystem } = {},
): Promise<SlashCommandCatalog> {
  const fileSystem = options.fileSystem ?? nativeFileSystem;
  const budget = discoveryBudget();
  const root = home;
  const settingsPath = path.join(root, ".claude", "settings.json");
  const plugins = await enabledPlugins(
    settingsPath,
    path.join(root, ".claude", "plugins", "cache"),
    fileSystem,
    budget,
  );
  const byName = new Map<string, ChatSlashCommand>(builtinCommands.map((entry) => [entry.name, entry]));

  const visit = async (
    directory: string,
    source: { source: Exclude<CommandSource, "builtin">; sourceLabel: string },
    allowedRoot?: string,
  ): Promise<void> => {
    if (hasWork(budget)) {
      await mergeDirectory(byName, directory, source, fileSystem, budget, allowedRoot);
    }
    if (!hasWork(budget)) {
      const probeResult = await probeMarkdownCandidate(
        directory,
        fileSystem,
        budget,
        allowedRoot,
        { remaining: slashCommandMaxProbeWork },
      );
      if (probeResult.kind !== "complete-none") budget.truncated = true;
    }
  };

  for (const plugin of plugins) {
    const source = { source: "plugin" as const, sourceLabel: plugin.name };
    await visit(path.join(plugin.directory, "commands"), source, plugin.directory);
    await visit(path.join(plugin.directory, "skills"), source, plugin.directory);
  }
  const userSource = { source: "user" as const, sourceLabel: "user" };
  await visit(path.join(root, ".claude", "skills"), userSource);
  await visit(path.join(root, ".claude", "commands"), userSource);
  if (cwd) {
    const projectSource = { source: "project" as const, sourceLabel: "project" };
    await visit(path.join(cwd, ".claude", "skills"), projectSource);
    await visit(path.join(cwd, ".claude", "commands"), projectSource);
  }
  // ponytail: if this catalog reaches the wire ceiling, add query/page
  // transport before raising the shared protocol bound.
  const commands = [...byName.values()]
    .sort((left, right) => left.name.localeCompare(right.name))
    .slice(0, CHAT_SLASH_COMMAND_MAX_RESULTS);
  return {
    commands,
    truncated: budget.truncated || byName.size > CHAT_SLASH_COMMAND_MAX_RESULTS,
  };
}

async function enabledPlugins(
  settingsPath: string,
  pluginsRoot: string,
  fileSystem: SlashCommandFileSystem,
  budget: DiscoveryBudget,
): Promise<EnabledPlugin[]> {
  let settings: unknown;
  if (!hasWork(budget)) return [];
  const settingsText = await readBoundedFile(settingsPath, slashCommandMaxSettingsBytes, fileSystem, budget);
  if (settingsText === undefined) return [];
  try { settings = JSON.parse(settingsText); } catch { return []; }
  if (!isRecord(settings) || !isRecord(settings.enabledPlugins)) return [];
  let resolvedPluginsRoot: string;
  if (!spend(budget)) return [];
  try { resolvedPluginsRoot = await fileSystem.realpath(pluginsRoot); } catch { return []; }
  const result: EnabledPlugin[] = [];
  let pluginCount = 0;
  for (const [key, value] of Object.entries(settings.enabledPlugins)) {
    if (pluginCount >= slashCommandMaxPlugins || !hasWork(budget)) {
      budget.truncated = true;
      break;
    }
    pluginCount += 1;
    if (!spend(budget)) {
      budget.truncated = true;
      break;
    }
    if (value !== true) continue;
    const separator = key.indexOf("@");
    if (separator <= 0 || separator === key.length - 1) continue;
    const name = key.slice(0, separator);
    const marketplace = key.slice(separator + 1);
    if (!safePluginComponent(name) || !safePluginComponent(marketplace)) continue;
    // Resolve before containment so legitimate `/tmp` -> `/private/tmp` parent
    // symlinks remain usable while the plugin root boundary is still checked.
    const cacheDir = path.join(pluginsRoot, marketplace, name);
    let resolvedCacheDir: string;
    try { resolvedCacheDir = await fileSystem.realpath(cacheDir); } catch { continue; }
    if (!pathWithin(resolvedPluginsRoot, resolvedCacheDir)) continue;
    const versions = await boundedDirectoryEntries(
      fileSystem,
      resolvedCacheDir,
      slashCommandMaxVersionsPerPlugin,
      budget,
    );
    if (!versions) continue;
    const directories: string[] = [];
    for (const versionEntry of versions) {
      const version = entryName(versionEntry);
      const versionPath = path.join(resolvedCacheDir, version);
      let isDirectory = versionEntry.isDirectory();
      if (versionEntry.isSymbolicLink()) {
        if (!spend(budget)) {
          budget.truncated = true;
          break;
        }
        try { isDirectory = (await fileSystem.stat(versionPath)).isDirectory(); }
        catch { continue; }
      }
      if (!isDirectory) continue;
      let resolvedVersion: string;
      if (!spend(budget)) {
        budget.truncated = true;
        break;
      }
      try { resolvedVersion = await fileSystem.realpath(versionPath); } catch { continue; }
      if (pathWithin(resolvedPluginsRoot, resolvedVersion)) directories.push(resolvedVersion);
    }
    const directory = directories.sort((left, right) => right.localeCompare(left))[0];
    if (directory) result.push({ name, marketplace, directory });
  }
  return result;
}

async function mergeDirectory(
  byName: Map<string, ChatSlashCommand>,
  directory: string,
  source: { source: Exclude<CommandSource, "builtin">; sourceLabel: string },
  fileSystem: SlashCommandFileSystem,
  budget: DiscoveryBudget,
  allowedRoot?: string,
): Promise<void> {
  let resolvedDirectory: string;
  if (!spend(budget)) return;
  try { resolvedDirectory = await fileSystem.realpath(directory); } catch { return; }
  if (allowedRoot && !pathWithin(allowedRoot, resolvedDirectory)) return;
  const files = await markdownFiles(resolvedDirectory, fileSystem, budget, allowedRoot);
  for (let index = 0; index < files.length; index += 1) {
    const file = files[index]!;
    if (!hasWork(budget)) {
      if (files.slice(index).some((candidate) => !budget.claimedCandidates.has(candidate))) {
        budget.truncated = true;
      }
      return;
    }
    budget.claimedCandidates.add(file);
    const markdown = await readBoundedFile(file, slashCommandMaxFileBytes, fileSystem, budget);
    if (markdown === undefined) continue;
    const parsed = parseCommand(markdown, deriveName(file, resolvedDirectory), source);
    if (parsed) byName.set(parsed.name, parsed);
  }
}

async function readBoundedFile(
  file: string,
  maximumBytes: number,
  fileSystem: SlashCommandFileSystem,
  budget: DiscoveryBudget,
): Promise<string | undefined> {
  if (!spend(budget)) {
    budget.truncated = true;
    return undefined;
  }
  let handle: SlashFileHandle;
  try {
    const noFollow = constants.O_NOFOLLOW ?? 0;
    handle = await fileSystem.open(file, constants.O_RDONLY | noFollow);
  } catch {
    return undefined;
  }
  try {
    if (!spend(budget)) {
      budget.truncated = true;
      return undefined;
    }
    const details = await handle.stat();
    if (!details.isFile() || !Number.isFinite(details.size) || !Number.isInteger(details.size)
      || details.size < 0
      || details.size > maximumBytes) {
      if (details.size > maximumBytes) budget.truncated = true;
      return undefined;
    }
    if (!spend(budget)) {
      budget.truncated = true;
      return undefined;
    }
    // ponytail: keep one sentinel byte to detect growth between fstat and read;
    // add bounded streaming before raising either command/settings cap.
    const buffer = Buffer.alloc(details.size + 1);
    let bytesRead = 0;
    while (bytesRead < buffer.length) {
      const result = await handle.read(buffer, bytesRead, buffer.length - bytesRead, bytesRead);
      if (!Number.isInteger(result.bytesRead) || result.bytesRead <= 0
        || result.bytesRead > buffer.length - bytesRead) break;
      bytesRead += result.bytesRead;
    }
    const finalDetails = await handle.stat();
    if (bytesRead !== details.size || !finalDetails.isFile() || finalDetails.size !== details.size) {
      budget.truncated = true;
      return undefined;
    }
    return buffer.subarray(0, details.size).toString("utf8");
  } catch {
    return undefined;
  } finally {
    try { await handle.close(); } catch { /* preserve discovery result */ }
  }
}

async function markdownFiles(
  directory: string,
  fileSystem: SlashCommandFileSystem,
  budget: DiscoveryBudget,
  allowedRoot?: string,
): Promise<string[]> {
  const result: string[] = [];
  const seenDirectories = new Set<string>();
  await walkMarkdown(directory, 0, seenDirectories, result, fileSystem, budget, allowedRoot);
  return result.sort((left, right) => left.localeCompare(right));
}

async function walkMarkdown(
  directory: string,
  depth: number,
  seenDirectories: Set<string>,
  result: string[],
  fileSystem: SlashCommandFileSystem,
  budget: DiscoveryBudget,
  allowedRoot?: string,
): Promise<void> {
  if (depth > slashCommandMaxDepth || result.length >= slashCommandMaxFilesPerDirectory) {
    budget.truncated = true;
    return;
  }
  let resolved: string;
  if (!spend(budget)) return;
  try { resolved = await fileSystem.realpath(directory); } catch { return; }
  if (allowedRoot && !pathWithin(allowedRoot, resolved)) return;
  if (seenDirectories.has(resolved)) return;
  seenDirectories.add(resolved);
  const entries = await boundedDirectoryEntries(
    fileSystem,
    resolved,
    slashCommandMaxEntriesPerDirectory,
    budget,
  );
  if (!entries) return;
  const skillEntry = entries.find((entry) => entryName(entry).toLowerCase() === "skill.md");
  if (skillEntry) {
    let skillIsDirectory = skillEntry.isDirectory();
    if (skillEntry.isSymbolicLink()) {
      if (!spend(budget)) {
        budget.truncated = true;
        return;
      }
      try { skillIsDirectory = (await fileSystem.stat(path.join(resolved, entryName(skillEntry)))).isDirectory(); }
      catch { return; }
    }
    if (!skillIsDirectory && !skillEntry.isSymbolicLink()) {
      if (budget.filesRemaining <= 0 || !spend(budget)) return;
      budget.filesRemaining -= 1;
      const skillPath = path.join(resolved, entryName(skillEntry));
      budget.claimedCandidates.add(skillPath);
      result.push(skillPath);
      return;
    }
  }
  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index]!;
    if (result.length >= slashCommandMaxFilesPerDirectory || !hasWork(budget)) {
      if (entries.slice(index).some(isDirectMarkdownCandidate)) budget.truncated = true;
      return;
    }
    const name = entryName(entry);
    const entryPath = path.join(resolved, name);
    let isDirectory = entry.isDirectory();
    if (entry.isSymbolicLink()) {
      if (!spend(budget)) {
        budget.truncated = true;
        return;
      }
      try { isDirectory = (await fileSystem.stat(entryPath)).isDirectory(); } catch { continue; }
    }
    if (isDirectory) {
      if (depth < slashCommandMaxDepth) {
        await walkMarkdown(entryPath, depth + 1, seenDirectories, result, fileSystem, budget, allowedRoot);
      } else {
        // ponytail: if the maximum discovery depth changes, keep this explicit
        // skipped-subtree signal aligned with the walk boundary.
        budget.truncated = true;
      }
      continue;
    }
    if (entry.isSymbolicLink()) continue;
    if (!name.toLowerCase().endsWith(".md")) continue;
    if (["claude.md", "readme.md"].includes(name.toLowerCase())) continue;
    if (budget.filesRemaining <= 0 || !spend(budget)) {
      budget.truncated = true;
      return;
    }
    budget.filesRemaining -= 1;
    budget.claimedCandidates.add(entryPath);
    result.push(entryPath);
  }
}

async function boundedDirectoryEntries(
  fileSystem: SlashCommandFileSystem,
  directory: string,
  maximum: number,
  budget: DiscoveryBudget,
): Promise<SlashDirectoryEntry[] | undefined> {
  if (!spend(budget)) return undefined;
  let handle: SlashDirectoryHandle;
  try { handle = await fileSystem.opendir(directory); } catch { return undefined; }
  const entries: SlashDirectoryEntry[] = [];
  let overflow = false;
  let visited = 0;
  try {
    for await (const entry of handle) {
      if (!spend(budget)) return undefined;
      visited += 1;
      if (visited > maximum) {
        // A non-hidden overflow entry proves the directory scan is incomplete,
        // even when that entry could not itself become a command.
        if (!entryName(entry).startsWith(".")) budget.truncated = true;
        overflow = true;
        break;
      }
      if (entryName(entry).startsWith(".")) continue;
      entries.push(entry);
    }
  } catch {
    return undefined;
  } finally {
    try { await handle.close(); } catch { /* the iterator can close the handle first */ }
  }
  return overflow ? undefined : entries;
}

async function probeMarkdownCandidate(
  directory: string,
  fileSystem: SlashCommandFileSystem,
  budget: DiscoveryBudget,
  allowedRoot: string | undefined,
  probe: { remaining: number },
  depth = 0,
  seenDirectories = new Set<string>(),
): Promise<MarkdownProbeResult> {
  if (depth > slashCommandMaxDepth || probe.remaining <= 0) {
    return { kind: "unknown-bound-exhausted" };
  }
  if (!probeSpend(probe)) return { kind: "unknown-bound-exhausted" };
  let resolved: string;
  try { resolved = await fileSystem.realpath(directory); } catch { return { kind: "complete-none" }; }
  if (allowedRoot && !pathWithin(allowedRoot, resolved)) return { kind: "complete-none" };
  if (seenDirectories.has(resolved)) return { kind: "complete-none" };
  seenDirectories.add(resolved);
  if (!probeSpend(probe)) return { kind: "unknown-bound-exhausted" };
  let handle: SlashDirectoryHandle;
  try { handle = await fileSystem.opendir(resolved); } catch { return { kind: "complete-none" }; }
  const entries: SlashDirectoryEntry[] = [];
  try {
    for await (const entry of handle) {
      if (entries.length >= slashCommandMaxEntriesPerDirectory) {
        return { kind: "unknown-bound-exhausted" };
      }
      if (!probeSpend(probe)) return { kind: "unknown-bound-exhausted" };
      if (!entryName(entry).startsWith(".")) entries.push(entry);
    }
  } catch {
    return { kind: "unknown-bound-exhausted" };
  } finally {
    try { await handle.close(); } catch { /* the iterator can close the handle first */ }
  }

  const skillEntry = entries.find((entry) => entryName(entry).toLowerCase() === "skill.md");
  if (skillEntry) {
    let skillIsDirectory = skillEntry.isDirectory();
    if (skillEntry.isSymbolicLink()) {
      if (!probeSpend(probe)) return { kind: "unknown-bound-exhausted" };
      try {
        skillIsDirectory = (await fileSystem.stat(path.join(resolved, entryName(skillEntry)))).isDirectory();
      } catch {
        skillIsDirectory = false;
      }
    }
    if (!skillIsDirectory && !skillEntry.isSymbolicLink()) {
      const skillPath = path.join(resolved, entryName(skillEntry));
      const valid = await probeFileWithinRoot(skillPath, fileSystem, allowedRoot, probe);
      if (valid === "unknown") return { kind: "unknown-bound-exhausted" };
      if (valid && !budget.claimedCandidates.has(skillPath)) return { kind: "found", path: skillPath };
    }
  }
  for (const entry of entries) {
    const entryPath = path.join(resolved, entryName(entry));
    let isDirectory = entry.isDirectory();
    if (entry.isSymbolicLink()) {
      if (!probeSpend(probe)) return { kind: "unknown-bound-exhausted" };
      try { isDirectory = (await fileSystem.stat(entryPath)).isDirectory(); }
      catch { continue; }
    }
    if (isDirectory) {
      const nested = await probeMarkdownCandidate(
        entryPath, fileSystem, budget, allowedRoot, probe, depth + 1, seenDirectories,
      );
      if (nested.kind !== "complete-none") return nested;
      continue;
    }
    if (entry.isSymbolicLink()) continue;
    if (!isDirectMarkdownCandidate(entry)) continue;
    const valid = await probeFileWithinRoot(entryPath, fileSystem, allowedRoot, probe);
    if (valid === "unknown") return { kind: "unknown-bound-exhausted" };
    if (valid && !budget.claimedCandidates.has(entryPath)) return { kind: "found", path: entryPath };
  }
  return { kind: "complete-none" };
}

function probeSpend(probe: { remaining: number }): boolean {
  if (probe.remaining <= 0) return false;
  probe.remaining -= 1;
  return true;
}

async function probeFileWithinRoot(
  file: string,
  fileSystem: SlashCommandFileSystem,
  allowedRoot: string | undefined,
  probe: { remaining: number },
): Promise<boolean | "unknown"> {
  if (!allowedRoot) return true;
  if (!probeSpend(probe)) return "unknown";
  try { return pathWithin(allowedRoot, await fileSystem.realpath(file)); } catch { return false; }
}

function isDirectMarkdownCandidate(entry: SlashDirectoryEntry): boolean {
  const name = entryName(entry).toLowerCase();
  return !entry.isDirectory()
    && !entry.isSymbolicLink()
    && name.endsWith(".md")
    && name !== "claude.md"
    && name !== "readme.md";
}

function entryName(entry: SlashDirectoryEntry): string {
  return String(entry.name);
}

function parseCommand(
  markdown: string,
  fallbackName: string,
  source: { source: Exclude<CommandSource, "builtin">; sourceLabel: string },
): ChatSlashCommand | undefined {
  // ponytail: if command field ceilings change, update the protocol and this
  // parser together so discovery stays bounded before it reaches the wire.
  const parsed = frontmatter(markdown);
  if (!parsed) return undefined;
  const fields = parsed.fields;
  if (!source.sourceLabel || source.sourceLabel.length > CHAT_SLASH_SOURCE_LABEL_MAX_CHARS) return undefined;
  const name = scalar(fields.name) || fallbackName;
  if (!name || name.length > 512) return undefined;
  const description = (scalar(fields.description) || firstParagraph(parsed.body)).slice(0, 16_384);
  const argumentHint = scalar(fields.argumentHint);
  return {
    name,
    aliases: inlineArray(fields.aliases).filter((alias) => alias.length <= 512).slice(0, 32),
    description,
    ...(argumentHint && argumentHint.length <= 512 ? { argumentHint } : {}),
    argNames: inlineArray(fields.argNames).filter((argName) => argName.length <= 512).slice(0, 32),
    source: source.source,
    sourceLabel: source.sourceLabel,
    isHidden: bool(fields.isHidden),
    opensInTerminalDialog: false,
  };
}

function frontmatter(markdown: string): { fields: Record<string, string>; body: string } | undefined {
  if (!markdown.startsWith("---")) return { fields: {}, body: markdown };
  const lines = markdown.split("\n");
  const close = lines.slice(1).findIndex((line) => line === "---");
  if (close < 0) return undefined;
  const fields: Record<string, string> = {};
  for (const line of lines.slice(1, close + 1)) {
    const separator = line.indexOf(":");
    if (separator <= 0) continue;
    fields[line.slice(0, separator).trim()] = line.slice(separator + 1).trim();
  }
  return { fields, body: lines.slice(close + 2).join("\n") };
}

function scalar(value: string | undefined): string {
  if (!value) return "";
  const trimmed = value.trim();
  if (trimmed.length >= 2) {
    const first = trimmed[0];
    const last = trimmed[trimmed.length - 1];
    if ((first === "\"" && last === "\"") || (first === "'" && last === "'")) {
      return trimmed.slice(1, -1);
    }
  }
  return trimmed;
}

function inlineArray(value: string | undefined): string[] {
  if (!value) return [];
  const trimmed = value.trim();
  if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) return [];
  return trimmed.slice(1, -1).split(",").map((item) => scalar(item)).filter(Boolean);
}

function bool(value: string | undefined): boolean {
  const normalized = value?.toLowerCase();
  return normalized === "true" || normalized === "yes";
}

function firstParagraph(body: string): string {
  const lines = body.split("\n");
  const result: string[] = [];
  let sawContent = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) {
      if (sawContent) break;
      continue;
    }
    sawContent = true;
    result.push(trimmed);
  }
  return result.join(" ");
}

function deriveName(filePath: string, directory: string): string {
  const relative = path.relative(directory, filePath).split(path.sep);
  const last = relative.pop();
  if (!last) return "";
  if (last.toLowerCase() === "skill.md") return relative.join(":");
  relative.push(last.slice(0, -path.extname(last).length));
  return relative.join(":");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safePluginComponent(value: string): boolean {
  return value.length > 0
    && value.length <= slashCommandMaxPluginComponentLength
    && value !== "."
    && value !== ".."
    && !/[\\/\u0000]/.test(value);
}

function pathWithin(root: string, candidate: string): boolean {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return relative === "" || (relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}
