import type { AppSettings, NativeHelperUsageGlance } from "@agent-visor/protocol";

type Provider = "codex" | "copilot";
type Preferences = Pick<AppSettings, "codexUsageGlanceEnabled" | "copilotUsageGlanceEnabled">;
const providers: Provider[] = ["codex", "copilot"];

/** Independent caches and in-flight reads: one provider must never erase,
 * disable, mark stale, or wait to present another provider's successful read.
 */
export class UsageGlances {
  private readonly latest = new Map<Provider, NativeHelperUsageGlance>();
  private readonly pending = new Map<Provider, Promise<void>>();

  constructor(private readonly readers: Record<Provider,
    () => Promise<NativeHelperUsageGlance | undefined>>) {}

  current(preferences: Preferences, now = Date.now()): NativeHelperUsageGlance[] {
    return providers.filter((id) => enabled(id, preferences)).flatMap((id) => {
      const value = this.latest.get(id);
      if (!value) return [];
      const observedAt = value.observedAt ? Date.parse(value.observedAt) : NaN;
      const stale = value.stale || !Number.isFinite(observedAt) || now - observedAt > 600_000;
      return stale ? [{ ...value, stale: true,
        tone: value.tone === "critical" ? "critical" as const : "warning" as const,
        detail: `Last known usage; refresh unavailable. ${value.detail}`.slice(0, 512),
        accessibilityLabel: `Last known usage; refresh unavailable. ${value.accessibilityLabel}`.slice(0, 512),
      }] : [value];
    });
  }

  async refresh(preferences: Preferences, changed: () => void): Promise<void> {
    await Promise.all(providers.filter((id) => enabled(id, preferences)).map((id) => {
      const pending = this.pending.get(id);
      if (pending) return pending;
      const operation = (async () => {
        let value: NativeHelperUsageGlance | undefined;
        try { value = await this.readers[id](); } catch { /* retain only this provider's last observation */ }
        const previous = this.latest.get(id);
        if (value?.id === id) this.latest.set(id, value);
        else if (previous) this.latest.set(id, { ...previous, stale: true });
        changed();
      })().finally(() => { this.pending.delete(id); });
      this.pending.set(id, operation);
      return operation;
    }));
  }
}

function enabled(id: Provider, preferences: Preferences): boolean {
  return id === "codex" ? preferences.codexUsageGlanceEnabled : preferences.copilotUsageGlanceEnabled;
}
