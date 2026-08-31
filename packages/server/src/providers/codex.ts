import type { NativeHelperTerminalTarget } from "@agent-visor/protocol";
import path from "node:path";
import type { DiscoveredProviderSession, ProviderAdapter } from "../sessions.js";
import type { ProcessRecord, ProviderEnvironment } from "./environment.js";
import { CodexLifecycleReader } from "./codex-lifecycle.js";
import {
  isRecord, iso, ownerForProcess, processInstanceToken, terminalTargetForProcess,
} from "./shared.js";

type ModelCatalogCache = {
  signature?: string;
  value?: DiscoveredProviderSession["modelCatalog"];
};

type CodexRow = {
  id: string;
  rolloutPath: string;
  cwd: string;
  title: string;
  updatedAt: number;
  archived: boolean;
  source: string;
};

const threadsSQL = `
select id, rollout_path, cwd, substr(title, 1, 500) as title,
       updated_at, archived, source
from threads
where archived = 0
   or (archived = 1 and updated_at >= strftime('%s','now') - 86400)
order by updated_at desc
limit 200`;

export class CodexProvider implements ProviderAdapter {
  readonly id = "codex" as const;
  private lastRows: CodexRow[] = [];
  private readonly modelCatalogCache: ModelCatalogCache = {};
  private readonly lifecycleReader = new CodexLifecycleReader();

  constructor(private readonly environment: ProviderEnvironment) {}

  async discover(): Promise<DiscoveredProviderSession[]> {
    const database = await codexDatabase(this.environment);
    if (!database) return [];
    const queried = rows(await this.environment.sqlite(database, threadsSQL));
    if (queried.length > 0) this.lastRows = queried;
    const candidates = queried.length > 0 ? queried : this.lastRows;
    const indexTitles = await codexIndexTitles(this.environment);
    const modelCatalog = await codexModelCatalog(this.environment, this.modelCatalogCache);
    const processes = await this.environment.processes();
    const cliProcesses = processes.filter((process) =>
      process.tty
      && path.basename(process.command) === "codex"
      && !/(?:app|mcp|exec)-server/.test(process.arguments));
    const usedThreads = new Set<string>();
    const results: DiscoveredProviderSession[] = [];

    for (const process of cliProcesses) {
      const cwd = await this.environment.cwd(process.pid);
      const thread = candidates
        .filter((row) => row.source === "cli" && row.cwd === cwd && !usedThreads.has(row.id))
        .sort((left, right) => right.updatedAt - left.updatedAt)[0];
      if (!thread) continue;
      usedThreads.add(thread.id);
      results.push(await this.session(
        thread,
        indexTitles,
        ownerForProcess(process.pid, processes),
        modelCatalog,
        terminalTargetForProcess(
          process,
          thread.cwd,
          processes,
          processInstanceToken(
            process.pid,
            await this.environment.processStartedAt(process.pid),
          ),
        ),
      ));
    }

    const cutoff = this.environment.now().valueOf() - this.environment.observedWindowMs;
    for (const thread of candidates) {
      if (usedThreads.has(thread.id)
        || (thread.source !== "vscode" && thread.source !== "exec")) continue;
      if (thread.cwd.includes(".claude-mem") || thread.cwd.includes("observer-sessions")) continue;
      if (thread.rolloutPath.includes("/archived_sessions/")) continue;
      const rollout = await this.environment.stamp(thread.rolloutPath);
      if (!rollout) continue;
      const active = thread.archived
        ? Math.abs(this.environment.now().valueOf() - rollout.modifiedAt.valueOf()) <= 120_000
        : thread.updatedAt * 1_000 >= cutoff;
      if (!active) continue;
      results.push(await this.session(thread, indexTitles, "Codex", modelCatalog));
    }

    return results;
  }

  private async session(
    thread: CodexRow,
    indexTitles: Map<string, string>,
    owner: string,
    modelCatalog?: DiscoveredProviderSession["modelCatalog"],
    terminalTarget?: NativeHelperTerminalTarget,
  ): Promise<DiscoveredProviderSession> {
    const storedTitle = indexTitles.get(thread.id) || thread.title;
    const title = storedTitle || await codexRolloutTitle(this.environment, thread.rolloutPath);
    const codexLifecycle = owner === "Codex" && !terminalTarget
      ? await this.lifecycleReader.read(this.environment, thread.id, thread.rolloutPath)
      : undefined;
    // Ready attention and the recent-session window are separate policies.
    // A completed task becomes History after 30 minutes, but is still a shortcut.
    const section = codexLifecycle?.phase === "ready"
      && this.environment.now().valueOf() - Date.parse(codexLifecycle.observedAt) > 30 * 60_000
      ? "history" : codexLifecycle?.phase ?? "history";
    return {
      id: thread.id,
      provider: "codex",
      title: title || undefined,
      subtitle: section !== "history"
        ? (section === "working" ? "Agent is working" : "Ready to continue")
        : (owner === "Codex" ? "Codex app session" : "Codex CLI session"),
      cwd: thread.cwd,
      owner,
      section,
      updatedAt: codexLifecycle?.observedAt ?? iso(thread.updatedAt * 1_000),
      ...(codexLifecycle ? { codexLifecycle } : {}),
      canOpenOwner: true,
      canEnterChat: owner !== "Codex"
        || this.environment.now().valueOf() - thread.updatedAt * 1_000 <= 120_000,
      chatPath: thread.rolloutPath,
      messageTransport: "codex_app_server",
      ...(modelCatalog ? { modelCatalog } : {}),
      controlTarget: terminalTarget
        ? { kind: "terminal", target: terminalTarget }
        : { kind: "url", url: `codex://threads/${thread.id}` },
    };
  }
}

async function codexDatabase(environment: ProviderEnvironment): Promise<string | undefined> {
  const candidates = [
    path.join(environment.home, ".codex", "sqlite", "state_5.sqlite"),
    path.join(environment.home, ".codex", "state_5.sqlite"),
  ];
  let best: { path: string; modifiedAt: number } | undefined;
  for (const candidate of candidates) {
    const database = await environment.stamp(candidate);
    if (!database) continue;
    const wal = await environment.stamp(`${candidate}-wal`);
    const modifiedAt = Math.max(database.modifiedAt.valueOf(), wal?.modifiedAt.valueOf() ?? 0);
    if (!best || modifiedAt > best.modifiedAt) best = { path: candidate, modifiedAt };
  }
  return best?.path;
}

function rows(values: unknown[]): CodexRow[] {
  return values.flatMap((value) => {
    if (!isRecord(value)) return [];
    const id = string(value.id);
    const rolloutPath = string(value.rollout_path);
    const cwd = string(value.cwd);
    const updatedAt = number(value.updated_at);
    if (!id || !rolloutPath || !cwd || updatedAt === undefined) return [];
    return [{
      id,
      rolloutPath,
      cwd,
      title: string(value.title),
      updatedAt,
      archived: number(value.archived) === 1,
      source: string(value.source),
    }];
  });
}

async function codexModelCatalog(
  environment: ProviderEnvironment,
  cache: ModelCatalogCache,
): Promise<DiscoveredProviderSession["modelCatalog"]> {
  const file = path.join(environment.home, ".codex", "models_cache.json");
  const stamp = await environment.stamp(file);
  if (!stamp) {
    cache.signature = undefined;
    return cache.value = undefined;
  }
  const signature = `${stamp.modifiedAt.valueOf()}:${stamp.size}`;
  if (cache.signature === signature) return cache.value;
  cache.signature = signature;
  const raw = await environment.read(file, 5 * 1_048_576);
  if (!raw) return cache.value = undefined;
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value) || !Array.isArray(value.models)) return cache.value = undefined;
    const catalog: NonNullable<DiscoveredProviderSession["modelCatalog"]> = {};
    for (const item of value.models.slice(0, 100)) {
      if (!isRecord(item)) continue;
      const id = boundedCatalogString(item.slug);
      const displayName = boundedCatalogString(item.display_name);
      const contextWindow = positiveInteger(item.context_window);
      if (id && displayName) catalog[id] = {
        displayName,
        ...(contextWindow ? { contextWindow } : {}),
      };
    }
    return cache.value = Object.keys(catalog).length ? catalog : undefined;
  } catch {
    return cache.value = undefined;
  }
}

async function codexIndexTitles(environment: ProviderEnvironment): Promise<Map<string, string>> {
  const content = await environment.read(
    path.join(environment.home, ".codex", "session_index.jsonl"),
    5 * 1_048_576,
  );
  const titles = new Map<string, string>();
  for (const line of content?.split("\n") ?? []) {
    try {
      const value: unknown = JSON.parse(line);
      if (!isRecord(value)) continue;
      const id = string(value.id);
      const title = string(value.thread_name);
      if (id && title) titles.set(id, title);
    } catch { /* skip incomplete writes */ }
  }
  return titles;
}

async function codexRolloutTitle(
  environment: ProviderEnvironment,
  rolloutPath: string,
): Promise<string> {
  const content = await environment.readHeadTail(rolloutPath);
  for (const line of content?.head.split("\n") ?? []) {
    try {
      const value: unknown = JSON.parse(line);
      if (!isRecord(value) || !isRecord(value.payload)) continue;
      if (value.payload.type !== "user_message") continue;
      const message = string(value.payload.message);
      if (message) return message;
    } catch { /* skip incomplete writes */ }
  }
  return "";
}

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function positiveInteger(value: unknown): number | undefined {
  return Number.isSafeInteger(value) && (value as number) > 0 ? value as number : undefined;
}

function boundedCatalogString(value: unknown): string {
  const result = string(value);
  return result.length <= 256 ? result : "";
}
