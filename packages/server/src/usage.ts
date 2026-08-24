import { spawn } from "node:child_process";
import { access } from "node:fs/promises";
import { constants } from "node:fs";
import os from "node:os";
import type { NativeHelperUsageGlance } from "@agent-visor/protocol";

export function codexUsageGlance(value: unknown): NativeHelperUsageGlance | undefined {
  const root = record(value);
  const limits = record(root?.rateLimits);
  if (!limits) return undefined;
  const primary = usageWindow(limits.primary);
  const secondary = usageWindow(limits.secondary);
  const windows = [primary, secondary].filter((window): window is UsageWindow => Boolean(window));
  if (!windows.length) return undefined;

  const fiveHour = windows.find((window) => window.minutes === 300)
    ?? (primary?.minutes === undefined ? primary : undefined);
  const weekly = windows.find((window) => window.minutes === 10_080)
    ?? (secondary?.minutes === undefined ? secondary : undefined);
  const values = [fiveHour && { label: "5h", detail: "5 hour", value: fiveHour.remaining }];
  if (weekly) values.push({ label: "7d", detail: "weekly", value: weekly.remaining });
  const available = values.filter((item): item is NonNullable<typeof item> => Boolean(item));
  const label = available.map((item) => `${item.label} ${item.value}%`).join(" | ");
  const detail = `Codex usage, ${available.map((item) =>
    `${item.detail} ${item.value} percent remaining`).join(", ")}`;
  const lowest = Math.min(...available.map((item) => item.value));
  return {
    id: "codex",
    label,
    detail,
    tone: lowest <= 10 ? "critical" : lowest <= 25 ? "warning" : "normal",
    priority: 100,
    accessibilityLabel: detail,
  };
}

export async function readCodexUsage(): Promise<NativeHelperUsageGlance | undefined> {
  const executable = await codexExecutable();
  if (!executable) return undefined;
  return new Promise((resolve) => {
    const child = spawn(executable, ["app-server", "--listen", "stdio://"], {
      stdio: ["pipe", "pipe", "ignore"],
    });
    let buffer = "";
    let bytes = 0;
    let done = false;
    const deadline = setTimeout(() => finish(undefined), 5_000);

    child.once("error", () => finish(undefined));
    child.once("close", () => finish(undefined));
    child.stdin.on("error", () => finish(undefined));
    child.stdout.on("error", () => finish(undefined));
    child.stdout.on("data", (chunk: Buffer) => {
      bytes += chunk.length;
      if (bytes > 1_048_576) return finish(undefined);
      buffer += chunk.toString("utf8");
      while (buffer.includes("\n")) {
        const newline = buffer.indexOf("\n");
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        let message: Record<string, unknown> | undefined;
        try { message = record(JSON.parse(line)); } catch { continue; }
        if (message?.id === 1 && message.result) {
          write({ method: "initialized" });
          write({ id: 2, method: "account/rateLimits/read" });
        } else if (message?.id === 2) {
          finish(codexUsageGlance(message.result));
        }
      }
    });

    write({
      id: 1,
      method: "initialize",
      params: { clientInfo: { name: "agent-visor", version: "2.6.2" } },
    });

    function write(message: unknown): void {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    }

    function finish(value: NativeHelperUsageGlance | undefined): void {
      if (done) return;
      done = true;
      clearTimeout(deadline);
      child.stdin.destroy();
      child.stdout.destroy();
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
      resolve(value);
    }
  });
}

type UsageWindow = { remaining: number; minutes?: number };

function usageWindow(value: unknown): UsageWindow | undefined {
  const item = record(value);
  if (!item || typeof item.usedPercent !== "number" || !Number.isFinite(item.usedPercent)) {
    return undefined;
  }
  const used = Math.min(100, Math.max(0, Math.round(item.usedPercent)));
  return {
    remaining: 100 - used,
    ...(typeof item.windowDurationMins === "number"
      ? { minutes: Math.round(item.windowDurationMins) } : {}),
  };
}

async function codexExecutable(): Promise<string | undefined> {
  const home = os.homedir();
  for (const candidate of [
    process.env.CODEX_BINARY,
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    `${home}/.local/bin/codex`,
  ]) {
    if (!candidate) continue;
    try {
      await access(candidate, constants.X_OK);
      return candidate;
    } catch { /* try the next known path */ }
  }
  return undefined;
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}
