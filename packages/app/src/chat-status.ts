import type { ChatMetadata, SessionSummary } from "@agent-visor/protocol";

export type ChatStatusSummary = {
  model?: string;
  effort?: string;
  context?: { used: number; window: number; percent: number; label: string };
  permission?: { raw: string; label: string };
  usage?: ChatMetadata["usageGlance"];
  project: string;
  source: string;
  path: string;
  readOnly: boolean;
  readOnlyReason?: string;
  accessibilityLabel: string;
};

/**
 * Format the status surface from daemon-authoritative metadata. Missing
 * values stay absent. In particular, this function never invents a usage
 * percentage or permission capability from the session title.
 */
export function chatStatusSummary(
  session: Pick<SessionSummary, "source" | "project" | "cwd">,
  metadata: ChatMetadata | undefined,
  capabilities: { canSendText?: boolean; readOnlyReason?: string },
): ChatStatusSummary {
  const model = metadata?.model ?? metadata?.modelId;
  const effort = metadata?.reasoningEffort;
  const context = contextSummary(metadata?.contextTokens, metadata?.contextWindow);
  const permission = session.source === "Claude Code" && metadata?.permissionMode
    ? { raw: metadata.permissionMode, label: displayMode(metadata.permissionMode) }
    : undefined;
  const usageProvider = session.source === "Codex" ? "codex"
    : session.source === "Claude Code" ? "claude" : undefined;
  const usage = metadata?.usageGlance && metadata.usageGlance.provider === usageProvider
    ? metadata.usageGlance
    : undefined;
  // An unopened page is not yet a verified read-only page. Keep that state
  // neutral until the daemon supplies explicit capabilities.
  const readOnly = capabilities.canSendText === false;
  const parts = [
    model,
    effort ? `Reasoning ${displayMode(effort)}` : undefined,
    context ? `Context ${context.percent}%` : undefined,
    permission ? `Permission ${permission.label}` : undefined,
    usage ? `Usage ${usage.percentUsed}%` : undefined,
    session.project,
    readOnly ? "Read only" : undefined,
  ].filter((value): value is string => Boolean(value));
  return {
    ...(model ? { model } : {}),
    ...(effort ? { effort } : {}),
    ...(context ? { context } : {}),
    ...(permission ? { permission } : {}),
    ...(usage ? { usage } : {}),
    project: session.project,
    source: session.source,
    path: session.cwd,
    readOnly,
    ...(capabilities.readOnlyReason ? { readOnlyReason: capabilities.readOnlyReason } : {}),
    accessibilityLabel: parts.join(", "),
  };
}

export function contextSummary(
  used: number | undefined,
  window: number | undefined,
): ChatStatusSummary["context"] {
  if (typeof used !== "number" || typeof window !== "number"
    || !Number.isSafeInteger(used) || !Number.isSafeInteger(window)
    || used <= 0 || window <= 0 || used > window) {
    return undefined;
  }
  const usedTokens = used;
  const contextWindow = window;
  const percent = Math.min(100, Math.round(usedTokens / contextWindow * 100));
  return {
    used: usedTokens,
    window: contextWindow,
    percent,
    label: `${usedTokens.toLocaleString("en-US")} / ${contextWindow.toLocaleString("en-US")} tokens (${percent}%)`,
  };
}

export function displayMode(value: string): string {
  return value
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/[-_]+/g, " ")
    .split(" ")
    .filter(Boolean)
    .map((part) => part[0]!.toUpperCase() + part.slice(1))
    .join(" ")
    .replace(/\bOpenai\b/g, "OpenAI")
    .replace(/\bMcp\b/g, "MCP");
}

/** Match Swift PermissionModeCycle: unsupported/future modes fail closed. */
export function nextPermissionMode(value: string): string | undefined {
  switch (value) {
    case "default": return "acceptEdits";
    case "acceptEdits": return "plan";
    case "plan": return "default";
    case "auto":
    case "bypassPermissions": return "default";
    default: return undefined;
  }
}
