import type { NativeHelperUsageGlance } from "@agent-visor/protocol";

const usageURL = "https://github.com/settings/copilot";

/** The bridge retains the legacy bucket name even on token-based billing.
 * Accept AI credits only when both billing flags and a finite allowance agree.
 * quota_remaining was checked against GitHub's Usage screen; credits_used is
 * a different counter and must not replace entitlement - quota_remaining.
 */
export function copilotUsageGlance(
  value: unknown,
  observedAt = new Date(),
): NativeHelperUsageGlance | undefined {
  const root = record(value);
  const quota = record(record(root?.quota_snapshots)?.premium_interactions);
  if (root?.token_based_billing !== true || quota?.token_based_billing !== true
    || quota.has_quota !== true || quota.unlimited !== false) return undefined;
  const total = quota.entitlement;
  const remaining = quota.quota_remaining;
  const percent = quota.percent_remaining;
  if (!finite(total) || total <= 0 || total > 1_000_000_000_000
    || !finite(remaining) || remaining < 0 || remaining > total
    || !finite(percent) || percent < 0 || percent > 100
    || Math.abs(percent - remaining / total * 100) > 1) return undefined;
  const reset = root.quota_reset_date_utc ?? root.quota_reset_date;
  if (typeof reset !== "string"
    || !/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z)?$/.test(reset)) return undefined;
  const resetsAt = new Date(reset.length === 10 ? `${reset}T00:00:00.000Z` : reset);
  if (!Number.isFinite(observedAt.getTime()) || !Number.isFinite(resetsAt.getTime()) || resetsAt <= observedAt
    || resetsAt.toISOString().slice(0, 10) !== reset.slice(0, 10)) return undefined;

  const left = Math.floor(percent);
  const tone = left <= 10 ? "critical" : left <= 25 ? "warning" : "normal";
  const format = new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 });
  const plan = root.copilot_plan === "business" ? "Copilot Business"
    : root.copilot_plan === "enterprise" ? "Copilot Enterprise" : "GitHub Copilot";
  const summary = `${format.format(remaining)} of ${format.format(total)} AI credits remaining\n`
    + `${format.format(total - remaining)} used this cycle · ${plan}`;
  const detail = `GitHub Copilot, ${left} percent of your monthly AI-credit allowance remaining, `
    + summary.replace("\n", ", ");
  return {
    id: "copilot", heading: "GitHub Copilot", width: 64, label: `CP ${left}%`,
    detail, summary, usageURL, tone, priority: 110, accessibilityLabel: detail,
    observedAt: observedAt.toISOString(),
    windows: [{ title: "Monthly AI-credit allowance", remainingPercent: left, tone,
      resetsAt: resetsAt.toISOString() }],
  };
}

/** Use the already authenticated loopback bridge; never read or copy its token.
 * No redirects, external hosts, unbounded bodies, or unbounded waits.
 */
export async function readCopilotUsage(
  endpoint = process.env.AGENT_VISOR_COPILOT_USAGE_URL ?? "http://127.0.0.1:4141/usage",
): Promise<NativeHelperUsageGlance | undefined> {
  try {
    const url = new URL(endpoint);
    if (url.protocol !== "http:" || !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
      || !["/usage", "/usage/"].includes(url.pathname)
      || url.username || url.password || url.search || url.hash) return undefined;
    const response = await fetch(url, { redirect: "error", signal: AbortSignal.timeout(5_000) });
    if (!response.ok || !response.body) {
      await response.body?.cancel();
      return undefined;
    }
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let bytes = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > 65_536) return undefined;
        chunks.push(value);
      }
      return copilotUsageGlance(JSON.parse(Buffer.concat(chunks).toString("utf8")));
    } finally {
      await reader.cancel();
    }
  } catch {
    return undefined;
  }
}

function finite(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}
