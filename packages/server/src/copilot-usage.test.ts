import { createServer, type Server } from "node:http";
import { afterEach, describe, expect, it } from "vitest";
import { copilotUsageGlance, readCopilotUsage } from "./copilot-usage.js";

const now = new Date("2026-10-05T21:30:00.000Z");
// GitHub's UI shows 11,193 / 140,000 AI credits for this account. The
// unrelated credits_used counter must not yield 54,797 credits used here.
function payload() {
  return {
    copilot_plan: "business", token_based_billing: true,
    quota_reset_date_utc: "2026-11-01T00:00:00.000Z",
    quota_snapshots: { premium_interactions: {
      token_based_billing: true, has_quota: true, unlimited: false,
      entitlement: 140_000, quota_remaining: 128_807.1,
      percent_remaining: 92, credits_used: 54_797,
    } },
  };
}

const servers: Server[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

async function endpoint(status: number, body: string, headers = {}): Promise<string> {
  const server = createServer((_request, response) => {
    response.writeHead(status, { "Content-Type": "application/json", ...headers });
    response.end(body);
  });
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Missing test port");
  return `http://127.0.0.1:${address.port}/usage`;
}

describe("Copilot credit usage", () => {
  it("shows compact remaining usage and the balance verified against GitHub", () => {
    expect(copilotUsageGlance(payload(), now)).toMatchObject({
      id: "copilot", heading: "GitHub Copilot", width: 64, label: "CP 92%",
      summary: "128,807.1 of 140,000 AI credits remaining\n11,192.9 used this cycle · Copilot Business",
      usageURL: "https://github.com/settings/copilot", tone: "normal", priority: 110,
      observedAt: "2026-10-05T21:30:00.000Z",
      windows: [{ title: "Monthly AI-credit allowance", remainingPercent: 92,
        tone: "normal", resetsAt: "2026-11-01T00:00:00.000Z" }],
    });
    expect(copilotUsageGlance(payload(), now)?.detail).not.toContain("54,797");
    expect(copilotUsageGlance(payload(), now)?.resetCreditsAvailable).toBeUndefined();
  });

  it.each([[25, "warning"], [10, "critical"], [0, "critical"]] as const)(
    "keeps a fixed width and warns at %s percent remaining", (percent, tone) => {
      const data = payload();
      Object.assign(data.quota_snapshots.premium_interactions, {
        percent_remaining: percent, quota_remaining: 1400 * percent,
      });
      expect(copilotUsageGlance(data, now)).toMatchObject({ label: `CP ${percent}%`, tone, width: 64 });
    },
  );

  it("does not relabel legacy premium requests or a pooled seat without a personal allowance", () => {
    const legacy = payload();
    legacy.token_based_billing = false;
    expect(copilotUsageGlance(legacy, now)).toBeUndefined();
    const ambiguous = payload();
    ambiguous.quota_snapshots.premium_interactions.token_based_billing = false;
    expect(copilotUsageGlance(ambiguous, now)).toBeUndefined();
    const pooled = payload();
    pooled.quota_snapshots.premium_interactions.entitlement = 0;
    expect(copilotUsageGlance(pooled, now)).toBeUndefined();
  });

  it("rejects missing, nonfinite, contradictory and expired snapshots", () => {
    expect(copilotUsageGlance({}, now)).toBeUndefined();
    for (const change of [
      { has_quota: false }, { quota_remaining: -1 }, { quota_remaining: 140001 },
      { percent_remaining: 101 }, { percent_remaining: 50 }, { entitlement: Infinity },
    ]) {
      const data = payload();
      Object.assign(data.quota_snapshots.premium_interactions, change);
      expect(copilotUsageGlance(data, now)).toBeUndefined();
    }
    for (const reset of ["not-a-date", "2026-02-30", "2026-10-01T00:00:00.000Z", "2026-11-01T00:00:00"]) {
      expect(copilotUsageGlance({ ...payload(), quota_reset_date_utc: reset }, now)).toBeUndefined();
    }
  });

  it("reads the loopback bridge without credentials or following redirects", async () => {
    const source = { ...payload(), quota_reset_date_utc:
      new Date(Date.UTC(new Date().getUTCFullYear() + 1, 0, 1)).toISOString() };
    await expect(readCopilotUsage(await endpoint(200, JSON.stringify(source))))
      .resolves.toMatchObject({ id: "copilot", label: "CP 92%" });
    await expect(readCopilotUsage(await endpoint(302, "", {
      Location: "https://github.com/settings/copilot",
    }))).resolves.toBeUndefined();
    await expect(readCopilotUsage("https://example.com/usage")).resolves.toBeUndefined();
    await expect(readCopilotUsage("http://secret@127.0.0.1:4141/usage")).resolves.toBeUndefined();
  });

  it("leaves quota unavailable on HTTP errors, invalid JSON, or an oversized response", async () => {
    for (const [status, body] of [[401, "{}"], [200, "bad-json"], [200, " ".repeat(65_537)]] as const) {
      await expect(readCopilotUsage(await endpoint(status, body))).resolves.toBeUndefined();
    }
  });

  it("times out when the bridge stalls while sending a response", async () => {
    const server = createServer((_request, response) => {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.write("{");
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Missing test port");
    await expect(readCopilotUsage(`http://127.0.0.1:${address.port}/usage`)).resolves.toBeUndefined();
  }, 7_000);
});
