import { lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";

type Completion = { identity: string; activityAt: string; seen: boolean };
const retentionMs = 7 * 24 * 60 * 60_000;
const maxEntries = 2_048;

/** IDs and completion dates only; no transcript, title, or navigation recency. */
export class CompletionAttention {
  private readonly entries = new Map<string, Completion>();
  private fingerprint = "";

  constructor(private readonly file: string | undefined, private readonly now: () => Date) {
    if (!file) return;
    try {
      const stat = lstatSync(file);
      if (!stat.isFile() || stat.size > 1_048_576) return;
      const value = JSON.parse(readFileSync(file, "utf8"));
      if (value?.version !== 1 || !Array.isArray(value.entries) || value.entries.length > maxEntries) return;
      for (const [key, entry] of value.entries) {
        if (typeof key !== "string" || key.length > 1_024
          || typeof entry?.identity !== "string" || entry.identity.length > 1_024
          || typeof entry.seen !== "boolean" || typeof entry.activityAt !== "string") continue;
        const age = this.now().valueOf() - Date.parse(entry.activityAt);
        if (Number.isFinite(age) && age >= 0 && age <= retentionMs) this.entries.set(key, entry);
      }
      this.fingerprint = this.serialize();
    } catch { /* Missing or invalid state never marks a completion seen. */ }
  }

  get(key: string, identity: string): Completion | undefined {
    const entry = this.entries.get(key);
    return entry?.identity === identity && Date.parse(entry.activityAt) >= this.now().valueOf() - retentionMs
      ? entry : undefined;
  }

  observe(key: string, identity: string, activityAt: string): void {
    if (!this.get(key, identity)) this.entries.set(key, { identity, activityAt, seen: false });
  }

  acknowledge(key: string, identity: string, activityAt: string): void {
    this.entries.set(key, { identity, activityAt, seen: true });
  }

  forget(key: string): void { this.entries.delete(key); }

  save(): void {
    const cutoff = this.now().valueOf() - retentionMs;
    for (const [key, entry] of this.entries) {
      if (Date.parse(entry.activityAt) < cutoff) this.entries.delete(key);
    }
    while (this.entries.size > maxEntries) this.entries.delete(this.entries.keys().next().value!);
    const value = this.serialize();
    if (!this.file || value === this.fingerprint) return;
    const draft = `${this.file}.${randomUUID()}.tmp`;
    try {
      mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
      try { if (!lstatSync(this.file).isFile()) throw new Error("Invalid attention file"); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
      writeFileSync(draft, value, { mode: 0o600, flag: "wx" });
      renameSync(draft, this.file);
      this.fingerprint = value;
    } catch { console.warn("Agent Visor could not save completion attention state."); }
    finally { rmSync(draft, { force: true }); }
  }

  private serialize(): string { return JSON.stringify({ version: 1, entries: [...this.entries] }); }
}
