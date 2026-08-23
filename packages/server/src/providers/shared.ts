import path from "node:path";
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

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function iso(value: Date | number): string {
  return new Date(value).toISOString();
}
