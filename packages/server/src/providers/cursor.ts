import type { NativeHelperTerminalTarget } from "@agent-visor/protocol";
import path from "node:path";
import type { DiscoveredProviderSession, ProviderAdapter } from "../sessions.js";
import type { ProcessRecord, ProviderEnvironment } from "./environment.js";
import {
  iso, isRecord, ownerForProcess, processInstanceToken, terminalTargetForProcess,
} from "./shared.js";

type CursorTranscript = {
  id: string;
  projectKey: string;
  cwd: string;
  path: string;
  modifiedAt: Date;
  size: number;
};

export class CursorProvider implements ProviderAdapter {
  readonly id = "cursor" as const;
  private readonly cwdByProject = new Map<string, string>();
  private readonly titleCache = new Map<string, { signature: string; title: string }>();

  constructor(private readonly environment: ProviderEnvironment) {}

  async discover(): Promise<DiscoveredProviderSession[]> {
    const transcripts = await cursorTranscripts(this.environment, this.cwdByProject);
    const processes = await this.environment.processes();
    const cli = processes.filter((process) =>
      process.tty
      && process.arguments.includes("/.local/share/cursor-agent/")
      && !process.arguments.includes(" worker-server"));
    const used = new Set<string>();
    const results: DiscoveredProviderSession[] = [];

    for (const process of cli) {
      const cwd = await this.environment.cwd(process.pid);
      if (!cwd) continue;
      const key = encodeProjectKey(cwd);
      const transcript = transcripts
        .filter((candidate) => candidate.projectKey === key && !used.has(candidate.id))
        .sort(newest)[0];
      if (!transcript) continue;
      used.add(transcript.id);
      results.push(await cursorSession(
        this.environment,
        transcript,
        ownerForProcess(process.pid, processes),
        "history",
        this.titleCache,
        terminalTargetForProcess(
          process,
          transcript.cwd,
          processes,
          processInstanceToken(
            process.pid,
            await this.environment.processStartedAt(process.pid),
          ),
        ),
      ));
    }

    const cutoff = this.environment.now().valueOf() - this.environment.observedWindowMs;
    let historicalCount = 0;
    for (const transcript of transcripts.sort(newest)) {
      if (used.has(transcript.id) || transcript.modifiedAt.valueOf() < cutoff
        || historicalCount >= 30) continue;
      historicalCount += 1;
      results.push(await cursorSession(
        this.environment,
        transcript,
        "Cursor",
        "history",
        this.titleCache,
      ));
    }

    return results;
  }
}

async function cursorTranscripts(
  environment: ProviderEnvironment,
  cwdByProject: Map<string, string>,
): Promise<CursorTranscript[]> {
  const root = path.join(environment.home, ".cursor", "projects");
  const results: CursorTranscript[] = [];
  for (const projectKey of await environment.directory(root)) {
    let cwd = cwdByProject.get(projectKey);
    if (!cwd) {
      cwd = await decodeProjectKey(environment, projectKey);
      cwdByProject.set(projectKey, cwd);
    }
    const sessionsRoot = path.join(root, projectKey, "agent-transcripts");
    for (const id of await environment.directory(sessionsRoot)) {
      const transcriptPath = path.join(sessionsRoot, id, `${id}.jsonl`);
      const stamp = await environment.stamp(transcriptPath);
      if (!stamp) continue;
      results.push({
        id,
        projectKey,
        cwd,
        path: transcriptPath,
        modifiedAt: stamp.modifiedAt,
        size: stamp.size,
      });
    }
  }
  return results;
}

async function cursorSession(
  environment: ProviderEnvironment,
  transcript: CursorTranscript,
  owner: string,
  section: "working" | "history",
  titleCache: Map<string, { signature: string; title: string }>,
  terminalTarget?: NativeHelperTerminalTarget,
): Promise<DiscoveredProviderSession> {
  return {
    id: transcript.id,
    provider: "cursor",
    title: await cursorTranscriptTitle(environment, transcript, titleCache) || undefined,
    subtitle: section === "history" ? "From Cursor history" : "Cursor session",
    cwd: transcript.cwd,
    owner,
    section,
    updatedAt: iso(transcript.modifiedAt),
    canOpenOwner: true,
    canEnterChat: true,
    chatPath: transcript.path,
    ...(terminalTarget ? { controlTarget: { kind: "terminal" as const, target: terminalTarget } } : {}),
  };
}

async function cursorTranscriptTitle(
  environment: ProviderEnvironment,
  transcript: CursorTranscript,
  cache: Map<string, { signature: string; title: string }>,
): Promise<string> {
  const signature = `${transcript.modifiedAt.valueOf()}:${transcript.size}`;
  const cached = cache.get(transcript.path);
  if (cached?.signature === signature) return cached.title;
  const content = await environment.readHeadTail(transcript.path);
  for (const line of content?.head.split("\n") ?? []) {
    try {
      const value: unknown = JSON.parse(line);
      if (!isRecord(value) || value.role !== "user" || !isRecord(value.message)) continue;
      const blocks = value.message.content;
      if (!Array.isArray(blocks)) continue;
      for (const block of blocks) {
        if (!isRecord(block) || block.type !== "text" || typeof block.text !== "string") continue;
        const match = /<user_query>([\s\S]*?)<\/user_query>/.exec(block.text);
        const title = (match?.[1] ?? block.text).trim();
        if (title) {
          cache.set(transcript.path, { signature, title });
          return title;
        }
      }
    } catch { /* skip incomplete writes */ }
  }
  cache.set(transcript.path, { signature, title: "" });
  return "";
}

async function decodeProjectKey(
  environment: ProviderEnvironment,
  projectKey: string,
): Promise<string> {
  if (projectKey === "empty-window") return "/";
  const homeKey = encodeProjectKey(environment.home);
  if (projectKey === homeKey) return environment.home;
  if (projectKey.startsWith(`${homeKey}-`)) {
    const resolved = await resolveChildren(
      environment,
      environment.home,
      projectKey.slice(homeKey.length + 1),
      0,
    );
    if (resolved) return resolved;
  }
  return `/${projectKey.split("-").filter(Boolean).join("/")}`;
}

async function resolveChildren(
  environment: ProviderEnvironment,
  base: string,
  remaining: string,
  depth: number,
): Promise<string | undefined> {
  if (!remaining) return base;
  if (depth > 12) return undefined;
  const entries = await environment.directory(base);
  const candidates = entries.flatMap((name) => {
    const forms = [name, name.replace(/^\./, "")];
    return forms.some((form) => remaining === form || remaining.startsWith(`${form}-`))
      ? [{ name, length: Math.max(...forms.map((form) => form.length)) }]
      : [];
  }).sort((left, right) => right.length - left.length);
  for (const candidate of candidates) {
    const forms = [candidate.name, candidate.name.replace(/^\./, "")];
    const form = forms.find((value) => remaining === value || remaining.startsWith(`${value}-`));
    if (!form) continue;
    const child = path.join(base, candidate.name);
    if (!await environment.isDirectory(child)) continue;
    const suffix = remaining === form ? "" : remaining.slice(form.length + 1);
    const resolved = await resolveChildren(environment, child, suffix, depth + 1);
    if (resolved) return resolved;
  }
  return undefined;
}

function encodeProjectKey(cwd: string): string {
  const trimmed = cwd.replace(/^\/+|\/+$/g, "");
  return trimmed ? trimmed.replaceAll("/", "-") : "empty-window";
}

function newest(left: CursorTranscript, right: CursorTranscript): number {
  return right.modifiedAt.valueOf() - left.modifiedAt.valueOf();
}
