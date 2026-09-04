import { spawn } from "node:child_process";
import { access } from "node:fs/promises";
import { constants } from "node:fs";
import os from "node:os";
import type { ChatUsageGlance, NativeHelperUsageGlance } from "@agent-visor/protocol";
import { agentVisorVersion } from "./runtime-version.js";

/**
 * Project the existing provider-authoritative native usage record into the
 * Chat status contract. A missing window or timestamp stays absent: Chat must
 * never display a guessed quota value.
 */
export function chatUsageGlanceFromNative(
  value: NativeHelperUsageGlance | undefined,
): ChatUsageGlance | undefined {
  if (!value || value.id !== "codex" || !value.observedAt || !value.windows?.length) {
    return undefined;
  }
  const percentUsed = Math.max(...value.windows.map((window) => 100 - window.remainingPercent));
  if (!Number.isFinite(percentUsed) || percentUsed < 0 || percentUsed > 100) return undefined;
  return {
    provider: "codex",
    percentUsed,
    label: value.label,
    detail: value.detail,
    observedAt: value.observedAt,
  };
}

export function codexUsageGlance(
  value: unknown,
  observedAt = new Date(),
): NativeHelperUsageGlance | undefined {
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
  const windowPresentations = [fiveHour && {
    label: "5h", detail: "5 hour", title: "5 hour limit",
    value: fiveHour.remaining, window: fiveHour,
  }];
  if (weekly) windowPresentations.push({
    label: "7d", detail: "weekly", title: "Weekly limit",
    value: weekly.remaining, window: weekly,
  });
  const recognizedWindows = windowPresentations.filter(
    (item): item is NonNullable<typeof item> => Boolean(item),
  );
  if (!recognizedWindows.length) return undefined;
  const label = recognizedWindows.map((item) => `${item.label} ${item.value}%`).join(" | ");
  const detail = `Codex usage, ${recognizedWindows.map((item) =>
    `${item.detail} ${item.value} percent remaining`).join(", ")}`;
  const lowest = Math.min(...recognizedWindows.map((item) => item.value));
  return {
    id: "codex",
    heading: "Codex Usage",
    width: recognizedWindows.length === 1 ? 64 : 114,
    label,
    detail,
    tone: usageTone(lowest),
    priority: 100,
    accessibilityLabel: detail,
    observedAt: observedAt.toISOString(),
    windows: recognizedWindows.map(({ title, window }) => ({
      title,
      remainingPercent: window.remaining,
      tone: usageTone(window.remaining),
      ...(window.resetsAt === undefined ? {} : { resetsAt: window.resetsAt }),
    })),
    ...resetCredits(root),
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
      params: { clientInfo: { name: "agent-visor", version: agentVisorVersion() } },
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

type UsageWindow = { remaining: number; minutes?: number; resetsAt?: string };

function usageWindow(value: unknown): UsageWindow | undefined {
  const item = record(value);
  if (!item || typeof item.usedPercent !== "number" || !Number.isFinite(item.usedPercent)) {
    return undefined;
  }
  const used = Math.min(100, Math.max(0, Math.round(item.usedPercent)));
  const resetsAt = resetTime(item.resetsAt);
  return {
    remaining: 100 - used,
    ...(typeof item.windowDurationMins === "number"
      ? { minutes: Math.round(item.windowDurationMins) } : {}),
    ...(resetsAt ? { resetsAt } : {}),
  };
}

function usageTone(remaining: number): "normal" | "warning" | "critical" {
  return remaining <= 10 ? "critical" : remaining <= 25 ? "warning" : "normal";
}

function resetTime(value: unknown): string | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  const date = new Date(value * 1_000);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

function resetCredits(root: Record<string, unknown> | undefined): { resetCreditsAvailable?: number } {
  const count = record(root?.rateLimitResetCredits)?.availableCount;
  return typeof count === "number" && Number.isInteger(count)
    && count >= 0 && count <= 1_000_000
    ? { resetCreditsAvailable: count } : {};
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
