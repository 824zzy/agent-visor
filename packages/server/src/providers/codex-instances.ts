import { createHash } from "node:crypto";
import { access, realpath } from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import os from "node:os";
import type { ProviderEnvironment, ProcessRecord } from "./environment.js";

export type CodexHome = { path: string; label: string };
export type CodexInstance = CodexHome & { id: string; pid?: number; allowDefaultURL?: boolean };
export type CodexHomeStatus = { path: string; status: "running" | "saved" | "missing" | "unreadable" };

const appExecutable = /(?:^|\/)(?:Codex\.app\/Contents\/MacOS\/Codex|ChatGPT\.app\/Contents\/MacOS\/ChatGPT)$/;
const threadKey = /^codex:([0-9a-f]{64}):([0-9a-f-]{36})$/;

export async function canonicalCodexHome(value: string): Promise<string> {
  const expanded = value === "~" ? os.homedir()
    : value.startsWith("~/") ? path.join(os.homedir(), value.slice(2)) : value;
  const absolute = path.resolve(expanded);
  return realpath(absolute).catch(() => absolute);
}

export function codexInstanceID(home: string, nativeHome: string): string {
  return home === nativeHome ? "native"
    : createHash("sha256").update(home).digest("hex");
}

export function codexSessionID(instanceID: string, threadID: string): string {
  return instanceID === "native" ? threadID : `codex:${instanceID}:${threadID}`;
}

export function codexThreadReference(sessionID: string): { instanceID: string; threadID: string } | undefined {
  if (!sessionID.startsWith("codex:")) return sessionID ? { instanceID: "native", threadID: sessionID } : undefined;
  const match = threadKey.exec(sessionID);
  return match?.[1] && match[2] ? { instanceID: match[1], threadID: match[2] } : undefined;
}

export async function codexDesktopBindings(
  environment: ProviderEnvironment,
  nativeHome: string,
): Promise<Map<string, number>> {
  const bindings = new Map<string, number>();
  const processes = await environment.processes();
  for (const process of processes.filter(isCodexDesktop)) {
    const command = await environment.codexDesktopCommand?.(process.pid);
    if (command === undefined || !command.trim().startsWith(process.command)) continue;
    const match = /(?:^|\s)CODEX_HOME=([^\s]+)/.exec(command);
    // A custom Electron data dir with no readable CODEX_HOME is not the native owner.
    if (!match && command.includes("--user-data-dir=")) continue;
    const home = match?.[1] ? await canonicalCodexHome(match[1]) : nativeHome;
    if (!bindings.has(home)) bindings.set(home, process.pid);
  }
  return bindings;
}

export function isCodexDesktop(process: ProcessRecord): boolean {
  return process.pid > 0 && appExecutable.test(process.command);
}

export async function codexHomeStatuses(
  environment: ProviderEnvironment,
  configured: CodexHome[],
): Promise<CodexHomeStatus[]> {
  const native = await canonicalCodexHome(path.join(environment.home, ".codex"));
  const bindings = await codexDesktopBindings(environment, native);
  const homes = [{ path: native, canonical: native }, ...await Promise.all(configured.map(async (home) => ({
    path: home.path, canonical: await canonicalCodexHome(home.path),
  })))];
  const seen = new Set<string>();
  return Promise.all(homes.filter((home) => {
    if (seen.has(home.canonical)) return false;
    seen.add(home.canonical);
    return true;
  })
    .map(async ({ path: requested, canonical: home }) => {
    let found = false;
    for (const database of [path.join(home, "sqlite", "state_5.sqlite"), path.join(home, "state_5.sqlite")]) {
      if (!await environment.stamp(database)) continue;
      found = true;
      try {
        await access(database, constants.R_OK);
        return { path: requested, status: bindings.has(home) ? "running" as const : "saved" as const };
      } catch { /* try the other database before reporting unreadable */ }
    }
    return { path: requested, status: found ? "unreadable" as const : "missing" as const };
  }));
}
