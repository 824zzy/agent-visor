import { transcriptPhase, type NativeHelperTerminalTarget } from "@agent-visor/protocol";
import path from "node:path";
import type { DiscoveredProviderSession, ProviderAdapter } from "../sessions.js";
import type { ProcessRecord, ProviderEnvironment } from "./environment.js";
import { CodexTranscriptReader } from "./codex-lifecycle.js";
import {
  canonicalCodexHome, codexDesktopBindings, codexInstanceID, codexSessionID,
  codexThreadReference, isCodexDesktop, type CodexHome, type CodexInstance,
} from "./codex-instances.js";
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

const catalogPageSize = 200;
const threadsSQL = (offset: number, automationCutoff: number): string => `
select id, rollout_path, cwd, substr(title, 1, 500) as title,
       updated_at, archived, source
from threads
where archived = 0
  and (source in ('vscode', 'cli') or (source = 'exec' and updated_at >= ${automationCutoff}))
order by id
limit ${catalogPageSize} offset ${offset}`;

const threadByIDSQL = (id: string): string => `
select id, rollout_path, cwd, substr(title, 1, 500) as title,
       updated_at, archived, source
from threads
where id = '${id.replaceAll("'", "''")}'
limit 1`;

const codexSettingsCatalogTtlMs = 60_000;
const maxSettingsCatalogCWDs = 64;

export class CodexProvider implements ProviderAdapter {
  readonly id = "codex" as const;
  private readonly modelCatalogCache = new Map<string, ModelCatalogCache>();
  private readonly settingsCatalogByCWD = new Map<string, {
    expiresAt: number;
    value: Promise<NonNullable<DiscoveredProviderSession["chatSettingsCatalog"]> | undefined>;
  }>();
  private readonly transcriptReader = new CodexTranscriptReader();
  private readonly lastSessionsByInstance = new Map<string, DiscoveredProviderSession[]>();

  constructor(
    private readonly environment: ProviderEnvironment,
    private readonly configuredHomes: () => CodexHome[] = () => [],
    private readonly saveDiscoveredHome?: (home: CodexHome) => Promise<void>,
    private readonly ignoredHomes: () => string[] = () => [],
  ) {}

  private async instances(): Promise<CodexInstance[]> {
    const nativeHome = await canonicalCodexHome(path.join(this.environment.home, ".codex"));
    const desktopProcessRunning = (await this.environment.processes()).some(isCodexDesktop);
    const bindings = await codexDesktopBindings(this.environment, nativeHome);
    const homes: CodexInstance[] = [{
      id: "native", path: nativeHome, label: "Codex", pid: bindings.get(nativeHome),
      allowDefaultURL: !desktopProcessRunning,
    }];
    const seen = new Set([nativeHome]);
    const ignored = new Set(await Promise.all(this.ignoredHomes().map(canonicalCodexHome)));
    for (const home of this.configuredHomes()) {
      const canonical = await canonicalCodexHome(home.path);
      if (seen.has(canonical)) continue;
      seen.add(canonical);
      homes.push({
        id: codexInstanceID(canonical, nativeHome), path: canonical,
        label: home.label, pid: bindings.get(canonical),
      });
    }
    for (const [home, pid] of bindings) {
      if (seen.has(home) || ignored.has(home) || !await codexDatabase(this.environment, home)) continue;
      seen.add(home);
      const config = await this.environment.read(path.join(home, "config.toml"), 64 * 1_024);
      const label = /^\s*model_provider\s*=\s*["']copilot_api["']/m.test(config ?? "")
        ? "Codex · Copilot" : `Codex · ${path.basename(home)}`.slice(0, 64);
      homes.push({ id: codexInstanceID(home, nativeHome), path: home, label, pid });
      await this.saveDiscoveredHome?.({ path: home, label });
    }
    return homes;
  }

  async discover(): Promise<DiscoveredProviderSession[]> {
    const instances = await this.instances();
    const results: DiscoveredProviderSession[] = [];
    const retained: string[] = [];
    const automationCutoff = Math.floor(
      (this.environment.now().valueOf() - this.environment.observedWindowMs) / 1_000,
    );
    const processes = await this.environment.processes();
    const cliProcesses = processes.filter((process) =>
      process.tty
      && path.basename(process.command) === "codex"
      && !/(?:app|mcp|exec)-server/.test(process.arguments));
    for (const instance of instances) {
      let found: DiscoveredProviderSession[] = [];
      try {
        const database = await codexDatabase(this.environment, instance.path);
        if (!database) {
          this.lastSessionsByInstance.delete(instance.id);
          continue;
        }
        const candidates: CodexRow[] = [];
        for (let offset = 0; ; offset += catalogPageSize) {
          const page = await this.environment.sqlite(database, threadsSQL(offset, automationCutoff));
          candidates.push(...rows(page).filter((thread) => !thread.archived));
          if (page.length < catalogPageSize) break;
        }
        retained.push(...candidates.map((thread) => codexSessionID(instance.id, thread.id)));
        this.transcriptReader.retain(retained);
        const indexTitles = await codexIndexTitles(this.environment, instance.path);
        const cache = this.modelCatalogCache.get(instance.id) ?? {};
        this.modelCatalogCache.set(instance.id, cache);
        const modelCatalog = await codexModelCatalog(this.environment, instance.path, cache);
        const usedThreads = new Set<string>();
        for (const process of instance.id === "native" ? cliProcesses : []) {
          const cwd = await this.environment.cwd(process.pid);
          const thread = candidates
            .filter((row) => row.source === "cli" && row.cwd === cwd && !usedThreads.has(row.id))
            .sort((left, right) => right.updatedAt - left.updatedAt)[0];
          if (!thread) continue;
          usedThreads.add(thread.id);
          found.push(await this.session(
            instance, thread,
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

        for (const thread of candidates) {
          if (usedThreads.has(thread.id)
            || !["vscode", "cli", "exec"].includes(thread.source)) continue;
          if (thread.cwd.includes(".claude-mem") || thread.cwd.includes("observer-sessions")) continue;
          const rollout = await this.environment.stamp(thread.rolloutPath);
          if (!rollout) continue;
          if (thread.source === "exec" && thread.updatedAt < automationCutoff) continue;
          found.push(await this.session(instance, thread, indexTitles, instance.label, modelCatalog));
        }
        this.lastSessionsByInstance.set(instance.id, found);
      } catch {
        // One unreadable home must not hide the others. Keep its last good
        // read, the same way the repository keeps a failed provider's.
        found = this.lastSessionsByInstance.get(instance.id) ?? [];
        retained.push(...found.map((session) => session.id));
      }
      results.push(...found);
    }
    // A successful empty catalog is authoritative after every configured home was read.
    this.transcriptReader.retain(retained);
    return results;
  }

  /**
   * Opening a chat is an exact lookup, including an already-open conversation
   * that was archived and removed from the normal catalog.
   */
  async resolve(sessionId: string): Promise<DiscoveredProviderSession | undefined> {
    const reference = codexThreadReference(sessionId);
    if (!reference) return undefined;
    const instance = (await this.instances()).find((item) => item.id === reference.instanceID);
    if (!instance) return undefined;
    const database = await codexDatabase(this.environment, instance.path);
    if (!database) return undefined;
    const thread = rows(await this.environment.sqlite(database, threadByIDSQL(reference.threadID)))[0];
    if (!thread || thread.id !== reference.threadID) return undefined;
    // A database row alone is not enough to prove that the opened transcript
    // still exists. Discovery applies the same evidence requirement.
    if (!await this.environment.stamp(thread.rolloutPath)) return undefined;
    const indexTitles = await codexIndexTitles(this.environment, instance.path);
    const cache = this.modelCatalogCache.get(instance.id) ?? {};
    this.modelCatalogCache.set(instance.id, cache);
    const modelCatalog = await codexModelCatalog(this.environment, instance.path, cache);
    const processes = await this.environment.processes();
    const cliCandidates = instance.id === "native" && thread.source === "cli"
      ? await Promise.all(processes
        .filter((process) => process.tty
          && path.basename(process.command) === "codex"
          && !/(?:app|mcp|exec)-server/.test(process.arguments))
        .map(async (process) => ({ process, cwd: await this.environment.cwd(process.pid) })))
      : [];
    const cliProcess = cliCandidates.find(({ cwd }) => cwd === thread.cwd)?.process;
    const terminalTarget = cliProcess
      ? terminalTargetForProcess(
        cliProcess,
        thread.cwd,
        processes,
        processInstanceToken(
          cliProcess.pid,
          await this.environment.processStartedAt(cliProcess.pid),
        ),
      )
      : undefined;
    return this.session(
      instance, thread,
      indexTitles,
      cliProcess ? ownerForProcess(cliProcess.pid, processes) : instance.label,
      modelCatalog,
      terminalTarget,
    );
  }

  private async session(
    instance: CodexInstance,
    thread: CodexRow,
    indexTitles: Map<string, string>,
    owner: string,
    modelCatalog?: DiscoveredProviderSession["modelCatalog"],
    terminalTarget?: NativeHelperTerminalTarget,
  ): Promise<DiscoveredProviderSession> {
    const sessionID = codexSessionID(instance.id, thread.id);
    const sessionClass = thread.source === "exec"
      ? "automation" as const
      : thread.source === "cli" ? "terminal" as const : "interactive" as const;
    const storedTitle = indexTitles.get(thread.id) || thread.title;
    const title = storedTitle || await codexRolloutTitle(this.environment, thread.rolloutPath);
    const rolloutStamp = await this.environment.stamp(thread.rolloutPath);
    const transcript = !terminalTarget
      ? await this.transcriptReader.read(this.environment, sessionID, thread.rolloutPath, thread.id)
      : undefined;
    const lifecycle = transcript?.lifecycle;
    const managedBy = transcript?.originator === "Agent Room" ? "Agent Room" as const : undefined;
    // Transcript markers are claims, not liveness. A desktop turn whose process
    // died right after `task_started` never writes a completion marker, so the
    // marker alone would read as Working for months. The shared stale ceiling
    // (the same one Swift's TranscriptPhaseInferrer uses) decides whether the
    // claim is still current. A completion uses its boundary timestamp; a long
    // live turn uses actual turn progress after its start. File modification
    // time is not activity: opening an old thread also writes settings records.
    // Catalog membership is a separate policy: a dormant thread stays listed
    // and openable as Recent.
    const asyncQuestionAt = transcript?.pendingAsyncQuestions?.reduce<string | undefined>(
      (latest, question) => !latest || question.observedAt > latest ? question.observedAt : latest, undefined,
    );
    const phase = asyncQuestionAt || (transcript?.pendingQuestionIds?.length && lifecycle?.phase === "working") ? "needs_you" : lifecycle
      ? transcriptPhase({
        marker: lifecycle.phase === "working" ? "started" : "completed",
        transcriptModifiedAt: lifecycle.phase === "ready" ? lifecycle.observedAt : transcript?.activityAt,
        now: this.environment.now(),
      })
      : "recent";
    // A dead start marker is not lifecycle evidence: it must not gate hooks or
    // report a turn in progress. A dormant completion is still a true "turn
    // complete" fact, only too old to deserve Ready attention.
    const codexLifecycle = phase === "recent" && lifecycle?.phase === "working" ? undefined : lifecycle;
    const section = thread.archived || phase === "recent" ? "history" : phase;
    const desktopTarget: DiscoveredProviderSession["controlTarget"] = instance.pid
      ? { kind: "codex_thread", target: {
          pid: instance.pid, home: instance.path, threadId: thread.id,
        } }
      : instance.allowDefaultURL
        ? { kind: "url", url: `codex://threads/${thread.id}` }
        : undefined;
    const controlTarget = terminalTarget
      ? { kind: "terminal" as const, target: terminalTarget }
      : desktopTarget;
    const sourceProfile = instance.id === "native"
      ? undefined : instance.label.replace(/^Codex · /, "").trim();
    return {
      id: sessionID,
      provider: "codex",
      title: title || undefined,
      subtitle: section !== "history"
        ? (section === "needs_you" ? "Answer required in Codex" : section === "working" ? "Agent is working" : "Ready to continue")
        : (terminalTarget ? "Codex CLI session" : `${instance.label} app session`),
      cwd: thread.cwd,
      owner,
      ...(sourceProfile ? { sourceProfile } : {}),
      section,
      updatedAt: section === "needs_you" ? [transcript?.questionAt, asyncQuestionAt].filter((at): at is string => Boolean(at)).sort().at(-1)!
        : codexLifecycle?.observedAt ?? iso(thread.updatedAt * 1_000),
      ...(codexLifecycle ? { codexLifecycle } : {}),
      conversationState: thread.archived ? "archived" : "open",
      ...(codexLifecycle ? { turnState: section === "needs_you" ? "needs_you" as const : codexLifecycle.phase === "working" ? "working" as const : "ready" as const } : {}),
      ...(codexLifecycle?.turnId ? { turnId: codexLifecycle.turnId } : {}),
      ...(rolloutStamp
        ? { transcriptRevision: `${rolloutStamp.modifiedAt.valueOf()}:${rolloutStamp.size}` }
        : {}),
      canOpenOwner: controlTarget !== undefined,
      // Desktop discovery already requires an existing transcript. Inactivity
      // does not prevent reading it; send/cancel authority is checked separately.
      canEnterChat: true,
      sessionClass,
      ...(managedBy ? { managedBy } : {}),
      chatPath: thread.rolloutPath,
      ...(instance.id === "native" ? { messageTransport: "codex_app_server" as const } : {}),
      ...(instance.id === "native" && !terminalTarget
        ? { routeState: "available" as const, routeOwnership: "unverified" as const }
        : {}),
      ...(modelCatalog ? { modelCatalog } : {}),
      ...(controlTarget ? { controlTarget } : {}),
    };
  }

  async chatSettings(session: DiscoveredProviderSession): Promise<NonNullable<DiscoveredProviderSession["chatSettingsCatalog"]> | undefined> {
    if (!this.environment.codexSettingsCatalog || session.provider !== "codex"
      || codexThreadReference(session.id)?.instanceID !== "native") return undefined;
    const now = Date.now();
    for (const [cwd, cached] of this.settingsCatalogByCWD) {
      if (cached.expiresAt <= now) this.settingsCatalogByCWD.delete(cwd);
    }
    const existing = this.settingsCatalogByCWD.get(session.cwd);
    if (existing) return existing.value;
    const value = this.environment.codexSettingsCatalog(session.cwd).catch(() => undefined);
    this.settingsCatalogByCWD.set(session.cwd, {
      expiresAt: now + codexSettingsCatalogTtlMs,
      value,
    });
    while (this.settingsCatalogByCWD.size > maxSettingsCatalogCWDs) {
      const oldest = this.settingsCatalogByCWD.keys().next().value;
      if (oldest === undefined) break;
      this.settingsCatalogByCWD.delete(oldest);
    }
    return value;
  }
}

async function codexDatabase(environment: ProviderEnvironment, home: string): Promise<string | undefined> {
  const candidates = [
    path.join(home, "sqlite", "state_5.sqlite"),
    path.join(home, "state_5.sqlite"),
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
  home: string,
  cache: ModelCatalogCache,
): Promise<DiscoveredProviderSession["modelCatalog"]> {
  const file = path.join(home, "models_cache.json");
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

async function codexIndexTitles(environment: ProviderEnvironment, home: string): Promise<Map<string, string>> {
  const content = await environment.read(
    path.join(home, "session_index.jsonl"),
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
