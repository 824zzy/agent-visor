import path from "node:path";
import type { NativeHelperFocusTarget, NativeHelperTerminalTarget } from "@agent-visor/protocol";
import type { ProcessRecord } from "./environment.js";

export function ownerForProcess(pid: number, processes: ProcessRecord[]): string {
  const byPID = new Map(processes.map((process) => [process.pid, process]));
  let process = byPID.get(pid);
  const visited = new Set<number>();

  while (process && !visited.has(process.pid)) {
    visited.add(process.pid);
    const identity = `${process.command} ${process.arguments}`.toLowerCase();
    if (identity.includes("ghostty")) return "Ghostty";
    if (identity.includes("iterm")) return "iTerm2";
    if (identity.includes("/terminal.app/") || path.basename(process.command) === "Terminal") {
      return "Terminal";
    }
    if (identity.includes("/cursor.app/")) return "Cursor";
    if (identity.includes("/zed") && identity.includes(".app/")) return "Zed";
    if (identity.includes("/claude.app/")) return "Claude";
    if (identity.includes("/codex.app/")) return "Codex";
    process = byPID.get(process.parentPID);
  }

  return "Terminal";
}

export function applicationTargetForProcess(
  pid: number,
  processes: ProcessRecord[],
): NativeHelperFocusTarget | undefined {
  const byPID = new Map(processes.map((process) => [process.pid, process]));
  let current = byPID.get(pid);
  const visited = new Set<number>();
  while (current && !visited.has(current.pid)) {
    visited.add(current.pid);
    const identity = `${current.command} ${current.arguments}`.toLowerCase();
    const bundleIdentifier = identity.includes("/claude.app/")
      ? "com.anthropic.claudefordesktop"
      : identity.includes("/cursor.app/")
        ? "com.todesktop.230313mzl4w4u92"
        : identity.includes("/zed") && identity.includes(".app/")
          ? "dev.zed.Zed"
          : undefined;
    if (bundleIdentifier) return { pid: current.pid, bundleIdentifier };
    current = byPID.get(current.parentPID);
  }
  return undefined;
}

export function terminalTargetForProcess(
  process: ProcessRecord,
  cwd: string,
  processes: ProcessRecord[],
): NativeHelperTerminalTarget | undefined {
  if (!process.tty) return undefined;
  const owner = ownerForProcess(process.pid, processes);
  if (!(["Ghostty", "iTerm2", "Terminal"] as const).includes(
    owner as "Ghostty" | "iTerm2" | "Terminal",
  )) return undefined;
  return { application: owner as "Ghostty" | "iTerm2" | "Terminal", tty: process.tty, cwd };
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function iso(value: Date | number): string {
  return new Date(value).toISOString();
}
