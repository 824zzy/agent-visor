import type { NativeHelperUsageGlance } from "@agent-visor/protocol";
import { describe, expect, it, vi } from "vitest";
import { UsageGlances } from "./usage-glances.js";

const preferences = { codexUsageGlanceEnabled: true, copilotUsageGlanceEnabled: true };
function glance(id: "codex" | "copilot"): NativeHelperUsageGlance {
  return { id, label: id === "codex" ? "7d 84%" : "CP 92%", detail: `${id} remaining`,
    tone: "normal", priority: id === "codex" ? 100 : 110, accessibilityLabel: id,
    observedAt: new Date().toISOString() };
}

describe("independent provider usage", () => {
  it("keeps CP visible and readable when Codex usage is disabled", async () => {
    const codex = vi.fn(async () => glance("codex"));
    const usage = new UsageGlances({ codex, copilot: async () => glance("copilot") });
    const cpOnly = { ...preferences, codexUsageGlanceEnabled: false };
    await usage.refresh(cpOnly, () => {});
    expect(usage.current(cpOnly).map((value) => value.label)).toEqual(["CP 92%"]);
    expect(codex).not.toHaveBeenCalled();
    expect(usage.current({ ...cpOnly, copilotUsageGlanceEnabled: false })).toEqual([]);
  });

  it("retains only the failed provider's last value as stale and recovers independently", async () => {
    let fail = false;
    const usage = new UsageGlances({ codex: async () => glance("codex"),
      copilot: async () => { if (fail) throw new Error("unavailable"); return glance("copilot"); } });
    await usage.refresh(preferences, () => {});
    fail = true;
    await usage.refresh(preferences, () => {});
    expect(usage.current(preferences)).toMatchObject([
      { id: "codex", tone: "normal" }, { id: "copilot", label: "CP 92%", stale: true, tone: "warning" },
    ]);
    expect(usage.current(preferences)[1].detail).toContain("Last known usage");
    expect(usage.current(preferences)[1].accessibilityLabel).toContain("Last known usage");
    fail = false;
    await usage.refresh(preferences, () => {});
    expect(usage.current(preferences)[1].stale).toBeUndefined();
    expect(usage.current(preferences)[1].tone).toBe("normal");
  });

  it("presents CP while Codex is slow and coalesces repeated refreshes", async () => {
    let release!: (value: NativeHelperUsageGlance) => void;
    const codex = vi.fn(() => new Promise<NativeHelperUsageGlance>((resolve) => { release = resolve; }));
    const changed = vi.fn();
    const usage = new UsageGlances({ codex, copilot: async () => glance("copilot") });
    const first = usage.refresh(preferences, changed);
    const repeated = usage.refresh(preferences, changed);
    await vi.waitFor(() => expect(usage.current(preferences).map((value) => value.id)).toEqual(["copilot"]));
    expect(changed).toHaveBeenCalled();
    expect(codex).toHaveBeenCalledTimes(1);
    release(glance("codex"));
    await Promise.all([first, repeated]);
    expect(usage.current(preferences).map((value) => value.id)).toEqual(["codex", "copilot"]);
  });

  it("does not invent a first value and marks an old observation stale", async () => {
    const old = glance("copilot");
    old.observedAt = "2026-10-05T21:00:00.000Z";
    const usage = new UsageGlances({ codex: async () => undefined, copilot: async () => old });
    await usage.refresh(preferences, () => {});
    expect(usage.current(preferences, Date.parse("2026-10-05T21:11:00.000Z")))
      .toMatchObject([{ id: "copilot", stale: true, tone: "warning" }]);
  });
});
