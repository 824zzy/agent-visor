import { accessSync, constants, existsSync, readFileSync, readdirSync } from "node:fs";
import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

export type AgentConnection = {
  id: "claude" | "codex" | "cursor" | "auggie" | "pi";
  name: string;
  available: boolean;
  installed: boolean;
  control: "toggle" | "automatic" | "read_only";
};

type HookEvent = readonly [
  name: string,
  matcher: "none" | "wildcard" | "regex" | "compaction",
  timeout?: number,
];

const claudeEvents: readonly HookEvent[] = [
  ["UserPromptSubmit", "none"], ["PreToolUse", "wildcard"],
  ["PostToolUse", "wildcard"], ["PostToolUseFailure", "wildcard"],
  ["PermissionRequest", "wildcard", 86_400], ["Notification", "wildcard"],
  ["Stop", "none"], ["StopFailure", "none"], ["SubagentStop", "none"],
  ["SessionStart", "none"], ["SessionEnd", "none"],
  ["PreCompact", "compaction"], ["PostCompact", "compaction"],
];

const codexEvents: readonly HookEvent[] = [
  ["UserPromptSubmit", "none"], ["PreToolUse", "wildcard"],
  ["PostToolUse", "wildcard"], ["PermissionRequest", "wildcard"],
  ["Stop", "none"], ["SessionStart", "none"], ["SessionEnd", "none"],
  ["PreCompact", "compaction"],
];

const auggieEvents: readonly HookEvent[] = [
  ["PreToolUse", "regex"], ["PostToolUse", "regex"], ["SessionStart", "none"],
  ["SessionEnd", "none"], ["Stop", "none"],
];

export class AgentConnectionsRepository {
  private pendingChange = Promise.resolve();

  constructor(private readonly options: { home: string; resources: string }) {}

  current(): AgentConnection[] {
    const codexRoot = path.join(this.options.home, ".codex");
    const auggieRoot = path.join(this.options.home, ".augment");
    const piExtension = path.join(this.options.home, ".pi/agent/extensions/agent-visor.ts");
    return [this.claudeState, {
      id: "auggie", name: "Auggie", control: "toggle",
      available: exists(auggieRoot) || executableAvailable(this.options.home, "auggie"),
      installed: hasInstalledHook(path.join(auggieRoot, "settings.json"), "agent-visor-state-auggie.sh"),
    }, {
      id: "codex", name: "Codex", control: "toggle",
      available: exists(codexRoot) || executableAvailable(
        this.options.home, "codex", ["/Applications/Codex.app/Contents/Resources/codex"],
      ),
      installed: hasInstalledHook(path.join(codexRoot, "hooks.json"), "agent-visor-codex-state.py"),
    }, {
      id: "cursor", name: "Cursor", control: "read_only",
      available: exists(path.join(this.options.home, ".cursor")) || executableAvailable(
        this.options.home, "cursor-agent",
        ["/Applications/Cursor.app/Contents/Resources/app/bin/cursor-agent"],
      ),
      installed: false,
    }, {
      id: "pi", name: "Pi", control: "automatic",
      available: exists(path.join(this.options.home, ".pi/agent"))
        || executableAvailable(this.options.home, "pi"),
      installed: exists(piExtension),
    }];
  }

  async refresh(): Promise<void> {
    const root = path.join(this.options.home, ".pi/agent");
    const pi = this.current().find(({ id }) => id === "pi");
    if (!pi?.available) return;
    const directory = path.join(root, "extensions");
    await mkdir(directory, { recursive: true });
    await copyAtomic(
      path.join(this.options.resources, "agent-visor-pi.ts.txt"),
      path.join(directory, "agent-visor.ts"),
    );
  }

  setEnabled(agent: AgentConnection["id"], enabled: boolean): Promise<void> {
    const change = this.pendingChange.then(() => this.changeConnection(agent, enabled));
    this.pendingChange = change.catch(() => undefined);
    return change;
  }

  private async changeConnection(agent: AgentConnection["id"], enabled: boolean): Promise<void> {
    if (agent === "claude") {
      if (enabled) await this.installClaude();
      else await this.uninstallClaude();
      return;
    }
    if (agent === "codex") {
      if (enabled) await this.installCodex();
      else await this.uninstallCodex();
      return;
    }
    if (agent === "auggie") {
      if (enabled) await this.installAuggie();
      else await this.uninstallAuggie();
      return;
    }
    throw new Error(`${agent} connection control is unavailable.`);
  }

  private get claudeState(): AgentConnection {
    const root = path.join(this.options.home, ".claude");
    return {
      id: "claude", name: "Claude Code", control: "toggle",
      available: true, installed: hasInstalledHook(path.join(root, "settings.json"), "agent-visor-state.py"),
    };
  }

  private async installClaude(): Promise<void> {
    await installHook({
      root: path.join(this.options.home, ".claude"), settingsFile: "settings.json",
      scriptName: "agent-visor-state.py", resources: this.options.resources,
      events: claudeEvents,
    });
  }

  private async uninstallClaude(): Promise<void> {
    const root = path.join(this.options.home, ".claude");
    await uninstallHook(root, "settings.json", "agent-visor-state.py");
  }

  private async installCodex(): Promise<void> {
    const root = path.join(this.options.home, ".codex");
    if (!this.current().find(({ id }) => id === "codex")?.available) {
      throw new Error("Codex is not available.");
    }
    await installHook({
      root, settingsFile: "hooks.json", scriptName: "agent-visor-codex-state.py",
      resources: this.options.resources, events: codexEvents,
    });
  }

  private async uninstallCodex(): Promise<void> {
    await uninstallHook(path.join(this.options.home, ".codex"), "hooks.json", "agent-visor-codex-state.py");
  }

  private async installAuggie(): Promise<void> {
    const root = path.join(this.options.home, ".augment");
    if (!this.current().find(({ id }) => id === "auggie")?.available) {
      throw new Error("Auggie is not available.");
    }
    await installHook({
      root, settingsFile: "settings.json", scriptName: "agent-visor-state-auggie.sh",
      resources: this.options.resources, events: auggieEvents,
    });
  }

  private async uninstallAuggie(): Promise<void> {
    await uninstallHook(path.join(this.options.home, ".augment"), "settings.json", "agent-visor-state-auggie.sh");
  }
}

function exists(target: string): boolean {
  return existsSync(target);
}

function executableAvailable(home: string, name: string, extra: string[] = []): boolean {
  const candidates = [
    path.join(home, ".local/bin", name),
    `/opt/homebrew/bin/${name}`,
    `/usr/local/bin/${name}`,
    ...extra,
  ];
  const nvmRoot = path.join(home, ".nvm/versions/node");
  try {
    for (const version of readdirSync(nvmRoot)) {
      candidates.push(path.join(nvmRoot, version, "bin", name));
    }
  } catch { /* no nvm installation */ }
  return candidates.some((candidate) => {
    try {
      accessSync(candidate, constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function hasInstalledHook(settingsPath: string, script: string): boolean {
  try {
    return readFileSync(settingsPath, "utf8").includes(script);
  } catch {
    return false;
  }
}

async function readObject(target: string): Promise<Record<string, unknown>> {
  try {
    const value: unknown = JSON.parse(await readFile(target, "utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("must contain a JSON object");
    return value as Record<string, unknown>;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw new Error(`Cannot read agent settings at ${target}: ${String(error)}`);
  }
}

function objectValue(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : {};
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function validatedHooks(value: unknown, settingsPath: string): Record<string, unknown> {
  if (value === undefined) return {};
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Invalid hooks in ${settingsPath}.`);
  }
  for (const entries of Object.values(value)) {
    if (!Array.isArray(entries)) throw new Error(`Invalid hooks in ${settingsPath}.`);
    for (const entry of entries) {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        throw new Error(`Invalid hooks in ${settingsPath}.`);
      }
      const hooks = (entry as Record<string, unknown>).hooks;
      if (hooks !== undefined && (!Array.isArray(hooks) || hooks.some((hook) =>
        !hook || typeof hook !== "object" || Array.isArray(hook)))) {
        throw new Error(`Invalid hooks in ${settingsPath}.`);
      }
    }
  }
  return value as Record<string, unknown>;
}

function removeHook(hooks: Record<string, unknown>, script: string): Record<string, unknown> {
  return Object.fromEntries(Object.entries(hooks).flatMap(([event, value]) => {
    const entries = arrayValue(value).flatMap((entry) => {
      const object = objectValue(entry);
      if (object.hooks === undefined) return [object];
      const kept = arrayValue(object.hooks).filter((hook) =>
        !String(objectValue(hook).command ?? "").includes(script));
      return kept.length ? [{ ...object, hooks: kept }] : [];
    });
    return entries.length ? [[event, entries]] : [];
  }));
}

async function installHook(options: {
  root: string;
  settingsFile: string;
  scriptName: string;
  resources: string;
  events: readonly HookEvent[];
}): Promise<void> {
  const hooksDirectory = path.join(options.root, "hooks");
  const script = path.join(hooksDirectory, options.scriptName);
  const settingsPath = path.join(options.root, options.settingsFile);
  const settings = await readObject(settingsPath);
  const hooks = validatedHooks(settings.hooks, settingsPath);
  await mkdir(hooksDirectory, { recursive: true });
  await copyAtomic(path.join(options.resources, options.scriptName), script);
  const command = `python3 ${shellQuote(script)}`;
  for (const [event, matcher, timeout] of options.events) {
    const entries = arrayValue(hooks[event]);
    if (JSON.stringify(entries).includes(options.scriptName)) continue;
    const hook = { type: "command", command, ...(timeout ? { timeout } : {}) };
    const matchers = matcher === "compaction" ? ["auto", "manual"]
      : matcher === "wildcard" ? ["*"] : matcher === "regex" ? [".*"] : [undefined];
    hooks[event] = [
      ...entries,
      ...matchers.map((value) => ({ ...(value ? { matcher: value } : {}), hooks: [hook] })),
    ];
  }
  settings.hooks = hooks;
  await writeObjectAtomic(settingsPath, settings);
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

async function uninstallHook(root: string, settingsFile: string, scriptName: string): Promise<void> {
  const settingsPath = path.join(root, settingsFile);
  if (!exists(settingsPath)) {
    await unlink(path.join(root, "hooks", scriptName)).catch(() => undefined);
    return;
  }
  const settings = await readObject(settingsPath);
  await unlink(path.join(root, "hooks", scriptName)).catch(() => undefined);
  const hooks = removeHook(validatedHooks(settings.hooks, settingsPath), scriptName);
  if (Object.keys(hooks).length) settings.hooks = hooks;
  else delete settings.hooks;
  await writeObjectAtomic(settingsPath, settings);
}

async function copyAtomic(source: string, target: string): Promise<void> {
  const contents = await readFile(source);
  try {
    if (contents.equals(await readFile(target))) {
      await chmod(target, 0o755);
      return;
    }
  } catch { /* target is absent or unreadable */ }
  const temporary = `${target}.tmp-${process.pid}`;
  await writeFile(temporary, contents);
  await chmod(temporary, 0o755);
  await rename(temporary, target);
}

async function writeObjectAtomic(target: string, value: Record<string, unknown>): Promise<void> {
  await mkdir(path.dirname(target), { recursive: true });
  const temporary = `${target}.tmp-${process.pid}`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, target);
}
