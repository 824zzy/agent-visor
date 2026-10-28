import {
  transcriptPhase,
  type HistoryRepairSelection,
  type NativeHelperTerminalTarget,
  type SessionPresence,
} from "@agent-visor/protocol";
import path from "node:path";
import { BoundedWork } from "../machine.js";
import type {
  DiscoveredProviderSession,
  HookSessionEvent,
  ProviderAdapter,
  ProviderDiscoveryAuthority,
  RetainedHistoryLifetime,
  RetainedHistoryOriginLookup,
} from "../sessions.js";
import type { ProcessRecord, ProviderEnvironment } from "./environment.js";
import { CodexTranscriptReader } from "./codex-lifecycle.js";
import { type CodexCliObservation } from "./codex-cli-observer.js";
import type { HerdrSurfaceTarget } from "./herdr.js";
import type { RetainedHistoryRecord, RetainedHistoryResumeCapability } from "../retained-history.js";
import type {
  ResumeLiveness,
  ResumeProviderAdapter,
  ResumeReconciliation,
  ResumeRepairValidation,
  ResumeTargetResult,
  ResumeWorkingDirectoryValidation,
} from "../resume.js";
import { CodexResumeAdapter } from "./codex-resume.js";
import {
  canonicalCodexHome, codexDesktopBindings, codexInstanceID, codexSessionID,
  codexThreadReference, isCodexDesktop, type CodexHome, type CodexInstance,
} from "./codex-instances.js";
import {
  isRecord, iso, ownerForProcess, processInstanceToken, terminalTargetForProcess,
} from "./shared.js";

type DesktopEvidence = {
  pid: number | undefined; ownerToken: string | undefined; rollouts: Set<string>; observedAt: string;
};

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

// Bound background presence proof without adding discovery to user actions.
const desktopPresenceMaxAgeMs = 30_000;
const codexSettingsCatalogTtlMs = 60_000;
const maxSettingsCatalogCWDs = 64;
type CliBinding = { cwd: string; owner: string; terminal?: NativeHelperTerminalTarget;
  herdr?: HerdrSurfaceTarget; sessionFile?: string; observed?: boolean; proven?: boolean;
  resume?: RetainedHistoryResumeCapability;
  runtime?: { pid: number; processStartToken: string }; runtimeUncertain?: boolean };

export class CodexProvider implements ProviderAdapter {
  readonly id = "codex" as const;
  private readonly modelCatalogCache = new Map<string, ModelCatalogCache>();
  private readonly settingsCatalogByCWD = new Map<string, {
    expiresAt: number;
    value: Promise<NonNullable<DiscoveredProviderSession["chatSettingsCatalog"]> | undefined>;
  }>();
  private readonly transcriptReader = new CodexTranscriptReader();
  private readonly discoveryWork = new BoundedWork(1);
  private readonly lastSessionsByInstance = new Map<string, DiscoveredProviderSession[]>();
  private readonly desktopEvidenceByInstance = new Map<string, DesktopEvidence>();
  private readonly cliHookByPID = new Map<number, HookSessionEvent>();
  private readonly endedCliInstances = new Set<string>();
  /** Explicit observer/host identity only; never a cached control capability. */
  private readonly cliOrigins = new Map<string, Pick<CliBinding, "cwd" | "sessionFile" | "runtime">>();
  private retainedHistoryOriginLookup?: RetainedHistoryOriginLookup;
  private lastDiscoveryAuthority: "authoritative" | "unavailable" = "authoritative";
  private readonly resumeAdapter: CodexResumeAdapter;

  constructor(
    private readonly environment: ProviderEnvironment,
    private readonly configuredHomes: () => CodexHome[] = () => [],
    private readonly saveDiscoveredHome?: (home: CodexHome) => Promise<void>,
    private readonly ignoredHomes: () => string[] = () => [],
  ) {
    this.resumeAdapter = new CodexResumeAdapter(
      environment,
      () => this.discoverFreshForResume(),
      () => this.lastDiscoveryAuthority,
    );
  }

  private async discoverFreshForResume(): Promise<DiscoveredProviderSession[] | undefined> {
    return this.discoveryWork.run(async () => {
      const inventory = this.environment.processesFreshInventory
        ? await this.environment.processesFreshInventory() : undefined;
      if (!inventory || inventory.state !== "authoritative") {
        this.lastDiscoveryAuthority = "unavailable";
        this.desktopEvidenceByInstance.clear();
        return undefined;
      }
      return this.discoverOnce(inventory.processes);
    });
  }

  discoveryAuthority(): ProviderDiscoveryAuthority {
    return this.lastDiscoveryAuthority;
  }

  resumeLiveness(record: RetainedHistoryRecord): Promise<ResumeLiveness> {
    return this.resumeAdapter.resumeLiveness(record);
  }

  resumeTarget(record: RetainedHistoryRecord, attemptId: string, nonce: string): ResumeTargetResult {
    return this.resumeAdapter.resumeTarget(record, attemptId, nonce);
  }

  validateRepair(
    record: RetainedHistoryRecord,
    selection: HistoryRepairSelection,
  ): ResumeRepairValidation {
    return this.resumeAdapter.validateRepair(record, selection);
  }

  validateWorkingDirectory(
    record: RetainedHistoryRecord,
    candidateCwd: string,
  ): Promise<ResumeWorkingDirectoryValidation> {
    return this.resumeAdapter.validateWorkingDirectory(record, candidateCwd);
  }

  reconcileResume(
    record: RetainedHistoryRecord,
    dispatch: import("@agent-visor/protocol").NativeHelperGhosttyResumeDispatch,
  ): Promise<ResumeReconciliation> {
    return this.resumeAdapter.reconcileResume(record, dispatch);
  }

  noteHook(event: HookSessionEvent): void {
    if (event.provider !== this.id || !event.pid || !event.tty || !Number.isFinite(Date.parse(event.receivedAt))) return;
    const previous = this.cliHookByPID.get(event.pid);
    if (previous && previous.receivedAt > event.receivedAt) return;
    if (event.event === "SessionEnd") {
      if (previous?.sessionId === event.sessionId) this.cliHookByPID.delete(event.pid);
    } else if (["SessionStart", "UserPromptSubmit"].includes(event.event)) {
      this.cliHookByPID.set(event.pid, structuredClone(event));
    }
  }

  private async cliBindings(instance: CodexInstance, processes: ProcessRecord[]): Promise<Map<string, CliBinding[]>> {
    const bindings = new Map<string, CliBinding[]>();
    const originPrefix = instance.path + "\u0000";
    const observations = new Map<number, CodexCliObservation>();
    const directory = path.join(instance.path, "agent-visor", "cli");
    for (const file of (await this.environment.directory(directory)).filter(file => /^\d+\.json$/.test(file)).slice(0, 512)) {
      try {
        const value = await this.environment.codexCliObservation?.(Number.parseInt(file), instance.path);
        if (value && value.home === instance.path && file === `${value.pid}.json`
          && Date.parse(value.observedAt) <= this.environment.now().valueOf()) observations.set(value.pid, value);
      } catch { /* Partial or invalid observer data never grants a route. */ }
    }
    const live = processes.filter(process => process.tty && path.basename(process.command) === "codex"
      && !/(?:app|mcp|exec)-server/.test(process.arguments));
    for (const pid of this.cliHookByPID.keys()) if (!live.some(process => process.pid === pid)) this.cliHookByPID.delete(pid);
    const liveTokens = new Map(live.map(value => [value.pid, value.processStartToken]));
    const verifiedThreads = new Map<number, string>();
    const add = (id: string, binding: CliBinding, frontend?: ProcessRecord) => {
      if (frontend?.processStartToken) {
        this.endedCliInstances.delete(frontend.processStartToken);
        binding = { ...binding, runtime: { pid: frontend.pid, processStartToken: frontend.processStartToken } };
        verifiedThreads.set(frontend.pid, id);
      }
      bindings.set(id, [...(bindings.get(id) ?? []), binding]);
    };
    for (const process of live) {
      const cwd = await this.environment.cwd(process.pid);
      if (!cwd) continue;
      const started = await this.environment.processStartedAt(process.pid);
      const processStartToken = process.processStartToken
        ?? (started ? processInstanceToken(process.pid, started) : undefined);
      const processWithToken = processStartToken ? { ...process, processStartToken } : process;
      liveTokens.set(process.pid, processStartToken);
      const resume = await this.codexResumeCapability(processWithToken, instance.path);
      const herdr = await this.environment.herdrCodexSurface?.(process.pid, cwd, instance.path);
      if (herdr?.provider === "codex" && herdr.pid === process.pid && herdr.cwd === cwd) {
        add(herdr.sessionId, { cwd, owner: "Herdr", herdr, observed: true, proven: true,
          ...(resume ? { resume } : {}) }, processWithToken); continue;
      }
      // A modern Codex server is its own identity boundary. If its exact
      // thread/client inventory is unavailable or ambiguous, do not downgrade
      // to the legacy hook/observer record or Desktop catalog.
      if (this.environment.readCodexTuiBinding) {
        const modern = await this.environment.readCodexTuiBinding(process.pid, instance.path).catch(() => undefined);
        if (modern?.sessionIds.length === 1 && modern.inventory) {
          add(modern.sessionIds[0]!, { cwd, owner: "Codex CLI", observed: true, proven: true,
            ...(resume ? { resume } : {}),
            terminal: terminalTargetForProcess(processWithToken, cwd, processes, processStartToken) }, processWithToken);
          continue;
        }
        const capability = await this.environment.codexTuiTransportCapability?.(process.pid, instance.path)
          .catch(() => "unknown" as const);
        // A cleanly observed absence authorizes the existing bounded observer
        // route. An undefined, failed, or ambiguous modern probe remains an
        // identity boundary and must not downgrade to stale legacy data.
        if (capability !== "unsupported") continue;
      }
      const hook = this.cliHookByPID.get(process.pid);
      const observation = observations.get(process.pid);
      const useObservation = observation && (!hook || Date.parse(observation.observedAt) >= Date.parse(hook.receivedAt));
      const identity = useObservation ? observation : hook;
      if (!identity || identity.tty?.replace(/^\/dev\//, "") !== process.tty) continue;
      if (this.environment.codexProcessHome && await this.environment.codexProcessHome(process.pid) !== instance.path) continue;
      if (!started || started.valueOf() > Date.parse(useObservation ? observation.observedAt : hook!.receivedAt)
        || (useObservation && (observation.ended
          || observation.processStartToken !== processStartToken))) continue;
      const owner = ownerForProcess(process.pid, processes);
      const exactHerdr = owner === "Herdr"
        ? await this.environment.herdrSurface?.(process.pid, identity.sessionId, cwd) : undefined;
      add(identity.sessionId, { cwd, owner, sessionFile: identity.sessionFile, observed: true, proven: true,
        ...(exactHerdr ? { herdr: exactHerdr } : {}),
        ...(resume ? { resume } : {}),
        terminal: terminalTargetForProcess(processWithToken, cwd, processes, processStartToken) }, processWithToken);
    }
    // Remember explicit CLI provenance even when its process/host route is now
    // unavailable. An old Desktop transcript must not silently take it over.
    for (const observation of observations.values()) if (!bindings.has(observation.sessionId)) {
      add(observation.sessionId, {
        cwd: observation.cwd,
        owner: "Codex CLI",
        sessionFile: observation.sessionFile,
        runtime: { pid: observation.pid, processStartToken: observation.processStartToken },
        observed: false,
        proven: true,
      });
    }
    for (const [id, candidates] of bindings) {
      if (!this.cliOrigins.has(originPrefix + id) && this.cliOrigins.size >= 512) this.cliOrigins.delete(this.cliOrigins.keys().next().value!);
      this.cliOrigins.set(originPrefix + id, { cwd: candidates[0]!.cwd, sessionFile: candidates[0]!.sessionFile,
        runtime: candidates[0]!.runtime ?? this.cliOrigins.get(originPrefix + id)?.runtime });
    }
    for (const [key, origin] of this.cliOrigins) {
      if (!key.startsWith(originPrefix)) continue;
      const id = key.slice(originPrefix.length);
      if (bindings.has(id)) continue;
      // A transient observer read failure may remove navigation authority,
      // but cannot turn a proven CLI conversation into a Desktop route.
      add(id, { ...origin, owner: "Codex CLI", observed: false, proven: true });
    }
    for (const [id, candidates] of bindings) for (const binding of candidates) {
      const runtime = binding.runtime;
      binding.runtimeUncertain = Boolean(runtime && !this.endedCliInstances.has(runtime.processStartToken)
        && (!liveTokens.has(runtime.pid) || !liveTokens.get(runtime.pid) || liveTokens.get(runtime.pid) === runtime.processStartToken)
        && (!verifiedThreads.has(runtime.pid) || verifiedThreads.get(runtime.pid) === id));
    }
    return bindings;
  }

  private async codexResumeCapability(
    process: ProcessRecord,
    configRoot: string,
  ): Promise<RetainedHistoryResumeCapability | undefined> {
    const token = process.processStartToken;
    if (!token || !this.environment.processProvenance) return undefined;
    const proof = await this.environment.processProvenance(process.pid, "codex_cli", token).catch(() => undefined);
    if (!proof || proof.state !== "available") return undefined;
    const value = proof.value;
    if (value.argvState !== "complete" || value.pid !== process.pid
      || value.processStartToken !== token || value.profileState === "unknown"
      || value.configRootRef !== configRoot || value.settingsFileRef !== undefined
      || value.settingSources !== undefined) return undefined;
    return {
      version: 1,
      provider: "codex_cli",
      host: "Ghostty",
      executableRef: value.executableRef,
      ...(value.executableVersion ? { executableVersion: value.executableVersion } : {}),
      configRootRef: configRoot,
      ...(value.profileRef ? { profileRef: value.profileRef } : {}),
      profileState: value.profileState,
      overrideNames: [...value.overrideNames],
      provenanceObservedAt: value.observedAt,
    };
  }

  setRetainedHistoryOriginLookup(lookup: RetainedHistoryOriginLookup): void {
    this.retainedHistoryOriginLookup = lookup;
  }

  private boundSession(instance: CodexInstance, thread: CodexRow, titles: Map<string, string>,
    modelCatalog: DiscoveredProviderSession["modelCatalog"], bindings: Map<string, CliBinding[]>,
    desktopEvidence?: DesktopEvidence) {
    // A resumed thread keeps its workspace cwd; the frontend may have been
    // launched elsewhere. UUID, home and process identity establish ownership.
    const candidates = bindings.get(thread.id) ?? [];
    const matches = candidates.filter(binding =>
      !binding.sessionFile || path.resolve(binding.sessionFile) === path.resolve(thread.rolloutPath));
    const binding = matches.length === 1 ? matches[0] : undefined;
    return this.session(instance, thread, titles,
      binding?.owner ?? (candidates.length ? "Codex CLI" : instance.label), modelCatalog, binding?.terminal, binding?.herdr,
      binding?.observed === true, binding?.proven === true, instance.path, binding?.resume,
      desktopEvidence?.rollouts.has(path.resolve(thread.rolloutPath))
        && path.basename(thread.rolloutPath).endsWith(`-${thread.id}.jsonl`)
        && !candidates.some(value => value.observed || value.runtimeUncertain) ? desktopEvidence.observedAt : undefined);
  }

  private async desktopRollouts(instance: CodexInstance, processes: ProcessRecord[]): Promise<Set<string>> {
    const files = instance.pid
      ? await this.environment.codexDesktopRollouts?.(instance.pid, instance.path, processes).catch(() => []) : [];
    return new Set(files?.map(file => path.resolve(file)));
  }

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

  discover(processOverride?: ProcessRecord[]): Promise<DiscoveredProviderSession[]> {
    return this.discoveryWork.run(() => this.discoverOnce(processOverride));
  }

  private async discoverOnce(processOverride?: ProcessRecord[]): Promise<DiscoveredProviderSession[]> {
    let authority: "authoritative" | "unavailable" = "authoritative";
    const instances = await this.instances();
    for (const id of this.desktopEvidenceByInstance.keys()) {
      if (!instances.some(instance => instance.id === id)) this.desktopEvidenceByInstance.delete(id);
    }
    const results: DiscoveredProviderSession[] = [];
    const retained: string[] = [];
    const automationCutoff = Math.floor(
      (this.environment.now().valueOf() - this.environment.observedWindowMs) / 1_000,
    );
    const processes = processOverride ?? await this.environment.processes();
    for (const instance of instances) {
      let found: DiscoveredProviderSession[] = [];
      try {
        const database = await codexDatabase(this.environment, instance.path);
        if (!database) {
          this.desktopEvidenceByInstance.delete(instance.id);
          authority = "unavailable";
          found = this.lastSessionsByInstance.get(instance.id) ?? [];
          retained.push(...found.map((session) => session.id));
        } else {
          const candidates: CodexRow[] = [];
          for (let offset = 0; ; offset += catalogPageSize) {
            const page = await this.environment.sqlite(database, threadsSQL(offset, automationCutoff));
            const parsed = parseRows(page);
            if (!parsed.complete) throw new Error("Incomplete provider database response");
            candidates.push(...parsed.rows.filter((thread) => !thread.archived));
            if (page.length < catalogPageSize) break;
          }
          const bindings = await this.cliBindings(instance, processes);
          const desktopRollouts = await this.desktopRollouts(instance, processes);
          // Ambient scans can omit rows. Only an authoritative background scan
          // may prove a remembered CLI instance ended and permit Desktop takeover.
          const uncertain = [...bindings.values()].flat().filter(binding => binding.runtimeUncertain
            && binding.runtime && !processes.some(value => value.pid === binding.runtime!.pid));
          if (desktopRollouts.size && uncertain.length) {
            const inventory = await this.environment.processesFreshInventory?.().catch(() => undefined);
            if (inventory?.state === "authoritative") for (const binding of uncertain) {
              const runtime = binding.runtime!;
              const process = inventory.processes.find(value => value.pid === runtime.pid);
              if (!process || (process.processStartToken && process.processStartToken !== runtime.processStartToken)) {
                if (this.endedCliInstances.size >= 512) this.endedCliInstances.delete(this.endedCliInstances.values().next().value!);
                this.endedCliInstances.add(runtime.processStartToken);
                binding.runtimeUncertain = false;
              }
            }
          }
          const desktopEvidence: DesktopEvidence = { pid: instance.pid,
            ownerToken: processes.find(value => value.pid === instance.pid)?.processStartToken,
            rollouts: desktopRollouts, observedAt: this.environment.now().toISOString() };
          this.desktopEvidenceByInstance.set(instance.id, desktopEvidence);
          const candidateIDs = new Set(candidates.map((thread) => thread.id));
          const liveBindingOmitted = [...bindings.entries()].some(([id, values]) =>
            values.some(binding => binding.observed === true && binding.proven === true)
              && !candidateIDs.has(id));
          if (liveBindingOmitted) {
            this.desktopEvidenceByInstance.delete(instance.id);
            authority = "unavailable";
            found = this.lastSessionsByInstance.get(instance.id) ?? [];
            retained.push(...found.map((session) => session.id));
          } else {
            retained.push(...candidates.map((thread) => codexSessionID(instance.id, thread.id)));
            this.transcriptReader.retain(retained);
            const indexTitles = await codexIndexTitles(this.environment, instance.path);
            const cache = this.modelCatalogCache.get(instance.id) ?? {};
            this.modelCatalogCache.set(instance.id, cache);
            const modelCatalog = await codexModelCatalog(this.environment, instance.path, cache);
            for (const thread of candidates) {
              if (!["vscode", "cli", "exec"].includes(thread.source)) continue;
              if (thread.cwd.includes(".claude-mem") || thread.cwd.includes("observer-sessions")) continue;
              const rollout = await this.environment.stamp(thread.rolloutPath);
              if (!rollout) continue;
              if (thread.source === "exec" && thread.updatedAt < automationCutoff) continue;
              found.push(await this.boundSession(instance, thread, indexTitles, modelCatalog, bindings, desktopEvidence));
            }
            this.lastSessionsByInstance.set(instance.id, found);
          }
        }
      } catch {
        this.desktopEvidenceByInstance.delete(instance.id);
        authority = "unavailable";
        // One unreadable home must not hide the others. Keep its last good
        // read, the same way the repository keeps a failed provider's.
        found = this.lastSessionsByInstance.get(instance.id) ?? [];
        retained.push(...found.map((session) => session.id));
      }
      results.push(...found);
    }
    // A successful empty catalog is authoritative after every configured home was read.
    this.transcriptReader.retain(retained);
    this.lastDiscoveryAuthority = authority;
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
    const processes = await (this.environment.processesFresh?.() ?? this.environment.processes());
    const bindings = await this.cliBindings(instance, processes);
    const desktopEvidence = this.desktopEvidenceByInstance.get(instance.id);
    const evidenceAge = this.environment.now().valueOf() - Date.parse(desktopEvidence?.observedAt ?? "");
    const sameDesktop = evidenceAge >= 0 && evidenceAge <= desktopPresenceMaxAgeMs
      && desktopEvidence?.ownerToken && desktopEvidence.pid === instance.pid
      && desktopEvidence.ownerToken === processes.find(value => value.pid === instance.pid)?.processStartToken;
    const session = await this.boundSession(instance, thread, indexTitles, modelCatalog, bindings,
      sameDesktop ? desktopEvidence : undefined);
    // Transcript reads can overlap a failed/newer discovery. Do not publish
    // runtime proof that was invalidated while the read was in flight.
    if (session.presence?.evidence === "runtime" && desktopEvidence
      && (this.desktopEvidenceByInstance.get(instance.id) !== desktopEvidence
        || this.environment.now().valueOf() - Date.parse(desktopEvidence.observedAt) > desktopPresenceMaxAgeMs)) {
      return this.boundSession(instance, thread, indexTitles, modelCatalog, bindings);
    }
    return session;
  }

  /**
   * Read only the exact SQLite lifetime bit for retained History. This seam
   * deliberately does not stamp or read the rollout: an archived thread may
   * have a missing transcript, while a missing row/read failure remains
   * unknown rather than proving deletion.
   */
  async historyLifetime(sessionId: string): Promise<RetainedHistoryLifetime> {
    const reference = codexThreadReference(sessionId);
    if (!reference) return "unknown";
    try {
      const instance = (await this.instances()).find((item) => item.id === reference.instanceID);
      if (!instance) return "unknown";
      const database = await codexDatabase(this.environment, instance.path);
      if (!database) return "unknown";
      const thread = rows(await this.environment.sqlite(database, threadByIDSQL(reference.threadID)))[0];
      if (!thread || thread.id !== reference.threadID) return "unknown";
      return thread.archived ? "archived" : "open";
    } catch {
      return "unknown";
    }
  }

  private async session(
    instance: CodexInstance,
    thread: CodexRow,
    indexTitles: Map<string, string>,
    owner: string,
    modelCatalog?: DiscoveredProviderSession["modelCatalog"],
    terminalTarget?: NativeHelperTerminalTarget,
    herdrTarget?: HerdrSurfaceTarget,
    cliObserved = false,
    cliProven = false,
    configHome?: string,
    resume?: RetainedHistoryResumeCapability,
    desktopObservedAt?: string,
  ): Promise<DiscoveredProviderSession> {
    const sessionID = codexSessionID(instance.id, thread.id);
    const desktopObserved = desktopObservedAt !== undefined;
    const presence: SessionPresence = cliObserved && cliProven
      ? { state: "open", evidence: "frontend", observedAt: this.environment.now().toISOString() }
      : desktopObserved
        ? { state: "open", evidence: "runtime", observedAt: desktopObservedAt! }
        : { state: "unknown", evidence: "catalog", observedAt: this.environment.now().toISOString() };
    // Keep the public native UUID separate from the durable home-qualified
    // identity. Custom homes already carry their hash in `sessionID`; native
    // history retains the explicit `native` home discriminator for old rows.
    const canonicalSessionID = `codex:${instance.id}:${thread.id}`;
    const retainedOrigin = this.retainedHistoryOriginLookup?.("codex", sessionID);
    const durableCliOrigin = retainedOrigin?.provider === "codex";
    const provenCli = !desktopObserved && (cliProven || durableCliOrigin);
    if (desktopObserved) owner = instance.label;
    const storedTitle = indexTitles.get(thread.id) || thread.title;
    const title = storedTitle || await codexRolloutTitle(this.environment, thread.rolloutPath);
    const rolloutStamp = await this.environment.stamp(thread.rolloutPath);
    let unverifiedHost = owner === "Herdr" || owner === "Unknown";
    const verifiedCli = Boolean(terminalTarget || herdrTarget);
    const latestTranscript = verifiedCli || !unverifiedHost
      ? await this.transcriptReader.read(this.environment, sessionID, thread.rolloutPath, thread.id)
      : undefined;
    const movedToDesktop = desktopObserved || latestTranscript?.originator === "Codex Desktop";
    // CLI lifecycle remains hook-owned unless a later client record proves
    // Desktop ownership or an exact live CLI binding restores transcript state.
    // Catalog source alone does not track client switches.
    const transcript = verifiedCli || thread.source !== "cli" || movedToDesktop ? latestTranscript : undefined;
    // The latest client metadata is provenance, not a process binding. It may
    // forbid a wrong Desktop fallback, but never identifies a terminal by cwd.
    const cliWithoutBinding = !desktopObserved && !terminalTarget && !herdrTarget
      && ((thread.source === "cli" && !movedToDesktop) || owner === "Codex CLI"
        || ["codex-tui", "codex_cli_rs"].includes(transcript?.originator ?? "")
        || durableCliOrigin);
    if (cliWithoutBinding) { owner = "Codex CLI"; unverifiedHost = true; }
    const sessionClass = thread.source === "exec"
      ? "automation" as const
      : (thread.source === "cli" && !movedToDesktop) || terminalTarget || herdrTarget || cliWithoutBinding ? "terminal" as const : "interactive" as const;
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
    const controlTarget = herdrTarget ? { kind: "herdr_surface" as const, target: herdrTarget } : terminalTarget
      ? { kind: "terminal" as const, target: terminalTarget }
      : unverifiedHost ? undefined : desktopTarget;
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
      presence,
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
      ...(instance.id === "native" && !terminalTarget && !herdrTarget
        ? { routeState: unverifiedHost ? "unavailable" as const : "available" as const, routeOwnership: "unverified" as const }
        : {}),
      ...(modelCatalog ? { modelCatalog } : {}),
      ...(controlTarget ? { controlTarget } : {}),
      ...(presence.state === "unknown" || (sessionClass === "terminal" && !controlTarget)
        ? { ambientEligible: false } : {}),
      ...(provenCli ? {
        historyIdentity: {
          verified: true,
          current: cliObserved,
          canonicalId: retainedOrigin?.canonicalId ?? canonicalSessionID,
          ...(retainedOrigin?.aliases?.length ? { aliases: retainedOrigin.aliases } : {}),
          ...(terminalTarget ? { host: terminalTarget.application } : {}),
          ...(herdrTarget ? { host: "Herdr" as const } : {}),
          ...(retainedOrigin?.host && !terminalTarget && !herdrTarget ? { host: retainedOrigin.host } : {}),
          ...(retainedOrigin?.configHome ? { configHome: retainedOrigin.configHome } : configHome ? { configHome } : {}),
          ...(resume ? { resume } : {}),
        },
      } : {}),
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

function parseRows(values: unknown[]): { rows: CodexRow[]; complete: boolean } {
  const parsed = values.map(parseRow);
  return {
    rows: parsed.flatMap((row) => row ? [row] : []),
    complete: parsed.every((row) => row !== undefined),
  };
}

function rows(values: unknown[]): CodexRow[] {
  return parseRows(values).rows;
}

function parseRow(value: unknown): CodexRow | undefined {
  if (!isRecord(value)) return undefined;
  const id = string(value.id);
  const rolloutPath = string(value.rollout_path);
  const cwd = string(value.cwd);
  const updatedAt = number(value.updated_at);
  const archived = number(value.archived);
  const source = string(value.source);
  if (!id || !rolloutPath || !cwd || updatedAt === undefined || archived === undefined || !source) return undefined;
  return {
    id,
    rolloutPath,
    cwd,
    title: string(value.title),
    updatedAt,
    archived: archived === 1,
    source,
  };
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
