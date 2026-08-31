import path from "node:path";
import type {
  DiscoveredProviderSession,
  HookSessionEvent,
  ProviderAdapter,
} from "../sessions.js";
import type { ProcessRecord, ProviderEnvironment } from "./environment.js";
import {
  isRecord, iso, ownerForProcess, processInstanceToken, terminalTargetForProcess,
} from "./shared.js";

type ModelCatalogCache = {
  signature?: string;
  value?: DiscoveredProviderSession["modelCatalog"];
};

type PiNameState = {
  completeThrough: number;
  parents: Map<string, string>;
  names: Map<string, string>;
  lastID?: string;
  name: string;
};

type PiHeader = { id: string; cwd: string; createdAt: Date; byteCount: number };

type PiFile = {
  path: string;
  id: string;
  cwd: string;
  createdAt: Date;
  modifiedAt: Date;
  size: number;
  hasConversation: boolean;
};

export class PiProvider implements ProviderAdapter {
  readonly id = "pi" as const;
  private readonly nameCache = new Map<string, PiNameState>();
  private readonly headerCache = new Map<string, PiHeader>();
  private readonly runtimeBySession = new Map<string, HookSessionEvent>();
  private readonly modelCatalogCache: ModelCatalogCache = {};

  constructor(private readonly environment: ProviderEnvironment) {}

  noteHook(event: HookSessionEvent): void {
    if (event.event === "SessionEnd") {
      this.runtimeBySession.delete(event.sessionId);
    } else if (event.pid !== undefined && event.tty) {
      this.runtimeBySession.set(event.sessionId, structuredClone(event));
    }
  }

  async discover(): Promise<DiscoveredProviderSession[]> {
    const root = path.join(this.environment.home, ".pi", "agent", "sessions");
    const files = await piFiles(this.environment, root, this.headerCache);
    const modelCatalog = await piModelCatalog(this.environment, this.modelCatalogCache);
    const processes = await this.environment.processes();
    const piProcesses = processes.filter((process) =>
      process.tty && path.basename(process.command) === "pi");
    const matched = new Map<string, ProcessRecord>();
    const used = new Set<number>();

    for (const file of files) {
      const runtime = this.runtimeBySession.get(file.id);
      if (runtime?.pid === undefined || runtime.cwd !== file.cwd) continue;
      if (runtime.sessionFile && path.resolve(runtime.sessionFile) !== path.resolve(file.path)) continue;
      const process = piProcesses.find((candidate) => candidate.pid === runtime.pid);
      if (!process || normalizeTTY(process.tty) !== normalizeTTY(runtime.tty)) continue;
      if (await this.environment.cwd(process.pid) !== file.cwd) continue;
      used.add(process.pid);
      matched.set(file.id, process);
    }

    for (const file of files) {
      if (matched.has(file.id)) continue;
      let best: { process: ProcessRecord; distance: number } | undefined;
      for (const process of piProcesses) {
        if (used.has(process.pid) || await this.environment.cwd(process.pid) !== file.cwd) continue;
        const startedAt = await this.environment.processStartedAt(process.pid);
        if (!startedAt) continue;
        const distance = Math.abs(startedAt.valueOf() - file.createdAt.valueOf());
        if (distance <= 5_000 && (!best || distance < best.distance)) {
          best = { process, distance };
        }
      }
      if (best) {
        used.add(best.process.pid);
        matched.set(file.id, best.process);
      }
    }

    const sorted = [...files].sort((left, right) =>
      right.modifiedAt.valueOf() - left.modifiedAt.valueOf());
    let historicalCount = 0;
    const selected = sorted.filter((file) => {
      if (matched.has(file.id)) return true;
      if (!file.hasConversation || historicalCount >= 30) return false;
      historicalCount += 1;
      return true;
    });
    return Promise.all(selected.map(async (file): Promise<DiscoveredProviderSession> => {
      const process = matched.get(file.id);
      const title = await piTranscriptTitle(this.environment, file, this.nameCache);
      const terminalTarget = process
        ? terminalTargetForProcess(
          process,
          file.cwd,
          processes,
          processInstanceToken(
            process.pid,
            await this.environment.processStartedAt(process.pid),
          ),
        )
        : undefined;
      return {
        id: file.id,
        provider: "pi",
        title: title || undefined,
        subtitle: process ? "Pi session" : "From Pi history",
        cwd: file.cwd,
        owner: process ? ownerForProcess(process.pid, processes) : "Pi",
        section: "history",
        updatedAt: iso(file.modifiedAt),
        canOpenOwner: process !== undefined,
        canEnterChat: true,
        chatPath: file.path,
        ...(modelCatalog ? { modelCatalog } : {}),
        ...(terminalTarget ? {
          controlTarget: { kind: "terminal" as const, target: terminalTarget },
          messageTransport: "terminal" as const,
        } : {}),
      };
    }));
  }
}

async function piModelCatalog(
  environment: ProviderEnvironment,
  cache: ModelCatalogCache,
): Promise<DiscoveredProviderSession["modelCatalog"]> {
  const file = path.join(environment.home, ".pi", "agent", "models-store.json");
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
    if (!isRecord(value)) return cache.value = undefined;
    const catalog: NonNullable<DiscoveredProviderSession["modelCatalog"]> = {};
    for (const [providerID, provider] of Object.entries(value)) {
      if (!isRecord(provider) || !Array.isArray(provider.models)) continue;
      for (const item of provider.models.slice(0, 200)) {
        if (!isRecord(item)) continue;
        const id = boundedCatalogString(item.id);
        const displayName = boundedCatalogString(item.name);
        const contextWindow = positiveInteger(item.contextWindow);
        if (id && displayName) {
          const entry = { displayName, ...(contextWindow ? { contextWindow } : {}) };
          catalog[`${providerID}:${id}`] = entry;
          catalog[id] ??= entry;
        }
      }
    }
    return cache.value = Object.keys(catalog).length ? catalog : undefined;
  } catch {
    return cache.value = undefined;
  }
}

function normalizeTTY(value: string | undefined): string | undefined {
  return value?.replace(/^\/dev\//, "");
}

async function piFiles(
  environment: ProviderEnvironment,
  root: string,
  headerCache: Map<string, PiHeader>,
): Promise<PiFile[]> {
  const paths = await jsonlPaths(environment, root, 0);
  const files: PiFile[] = [];
  for (const filePath of paths) {
    let header = headerCache.get(filePath);
    let firstLine = "";
    if (!header) {
      const prefix = await environment.read(filePath, 64 * 1_024);
      firstLine = prefix?.split("\n", 1)[0] ?? "";
      if (!firstLine) continue;
      let value: unknown;
      try { value = JSON.parse(firstLine); } catch { continue; }
      if (!isRecord(value) || value.type !== "session") continue;
      const id = string(value.id);
      const cwd = string(value.cwd);
      const createdAt = new Date(string(value.timestamp));
      if (!id || !cwd || Number.isNaN(createdAt.valueOf())) continue;
      header = { id, cwd, createdAt, byteCount: Buffer.byteLength(firstLine) + 1 };
      headerCache.set(filePath, header);
    }
    const stamp = await environment.stamp(filePath);
    if (!stamp) continue;
    files.push({
      path: filePath,
      id: header.id,
      cwd: header.cwd,
      createdAt: header.createdAt,
      modifiedAt: stamp.modifiedAt,
      size: stamp.size,
      hasConversation: stamp.size > header.byteCount,
    });
  }
  return files;
}

async function jsonlPaths(
  environment: ProviderEnvironment,
  directory: string,
  depth: number,
): Promise<string[]> {
  if (depth > 4) return [];
  const results: string[] = [];
  for (const name of await environment.directory(directory)) {
    const child = path.join(directory, name);
    if (name.endsWith(".jsonl")) {
      results.push(child);
    } else {
      results.push(...await jsonlPaths(environment, child, depth + 1));
    }
  }
  return results;
}

async function piTranscriptTitle(
  environment: ProviderEnvironment,
  file: PiFile,
  cache: Map<string, PiNameState>,
): Promise<string> {
  let state = cache.get(file.path);
  if (!state || file.size < state.completeThrough) {
    state = {
      completeThrough: 0,
      parents: new Map(),
      names: new Map(),
      name: "",
    };
    cache.set(file.path, state);
  }
  if (file.size === state.completeThrough) return state.name;
  state.completeThrough = await environment.scanLinePrefixes(
    file.path,
    64 * 1_024,
    (line) => {
    const type = stringField(line, "type");
    if (!type || type === "session") return;
    const backwards = type === "custom";
    const id = stringField(line, "id", backwards);
    if (!id) return;
    const parent = stringField(line, "parentId", backwards);
    if (parent) state.parents.set(id, parent);
    if (type === "session_info") {
      const name = stringField(line, "name");
      if (name) state.names.set(id, name);
    }
    state.lastID = id;
  }, state.completeThrough);

  const visited = new Set<string>();
  for (let id = state.lastID; id && !visited.has(id); id = state.parents.get(id)) {
    visited.add(id);
    const name = state.names.get(id);
    if (name) {
      state.name = name;
      return name;
    }
  }
  state.name = "";
  return state.name;
}

function stringField(line: string, key: string, backwards = false): string | undefined {
  const marker = `"${key}"`;
  const keyIndex = backwards ? line.lastIndexOf(marker) : line.indexOf(marker);
  if (keyIndex < 0) return undefined;
  const colon = line.indexOf(":", keyIndex + marker.length);
  if (colon < 0) return undefined;
  const start = line.indexOf("\"", colon + 1);
  if (start < 0) return undefined;
  const end = line.indexOf("\"", start + 1);
  return end < 0 ? undefined : line.slice(start + 1, end);
}

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function positiveInteger(value: unknown): number | undefined {
  return Number.isSafeInteger(value) && (value as number) > 0 ? value as number : undefined;
}

function boundedCatalogString(value: unknown): string {
  const result = string(value);
  return result.length <= 256 ? result : "";
}
