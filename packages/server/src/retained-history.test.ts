import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  RetainedHistoryStore,
  type RetainedHistoryObservation,
} from "./retained-history.js";

const directories: string[] = [];

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

function fixture(id = "claude-1", overrides: Partial<RetainedHistoryObservation> = {}): RetainedHistoryObservation {
  return {
    id,
    provider: "claude_code",
    title: "Review the release",
    subtitle: "Ready to continue",
    project: "agent-visor",
    owner: "Ghostty",
    host: "Ghostty",
    cwd: "/Users/me/Codes/agent-visor",
    transcriptPath: "/Users/me/.claude/projects/agent-visor/claude-1.jsonl",
    updatedAt: "2026-10-21T18:00:00.000Z",
    observedAt: "2026-10-21T18:00:00.000Z",
    ...overrides,
  };
}

function storePath(): string {
  const directory = mkdtempSync(path.join(tmpdir(), "agent-visor-history-"));
  directories.push(directory);
  return path.join(directory, "retained-history.json");
}

describe("RetainedHistoryStore", () => {
  it("keeps an observed row out of history until its frontend is absent", () => {
    const store = new RetainedHistoryStore({ path: storePath() });

    store.observe(fixture());

    expect(store.page()).toMatchObject({ records: [], total: 0 });
    store.closeMissing(new Set());
    expect(store.page()).toMatchObject({
      total: 1,
      records: [{ id: "claude-1", title: "Review the release", closedAt: expect.any(String) }],
    });
  });

  it("reopens a retained identity when the exact conversation is observed again", () => {
    const store = new RetainedHistoryStore({ path: storePath() });
    store.observe(fixture());
    store.closeMissing(new Set());
    store.observe(fixture("claude-1", { title: "Review the release again" }));

    expect(store.page()).toMatchObject({ records: [], total: 0 });
  });

  it("does not rewrite a row when only the observation timestamp changes", () => {
    const pathName = storePath();
    const store = new RetainedHistoryStore({ path: pathName });
    store.observe(fixture("claude-stable", { observedAt: "2026-10-21T18:00:00.000Z" }));

    store.observe(fixture("claude-stable", { observedAt: "2026-10-21T18:01:00.000Z" }));

    const persisted = JSON.parse(readFileSync(pathName, "utf8")) as {
      records: Array<{ observedAt: string }>;
    };
    expect(persisted.records[0]?.observedAt).toBe("2026-10-21T18:00:00.000Z");
  });

  it("persists minimal metadata and reconstructs the same retained row", () => {
    const pathName = storePath();
    const first = new RetainedHistoryStore({ path: pathName });
    first.observe(fixture("claude-safe", {
      sourceProfile: "claude-copilot",
      secret: "must-not-persist",
      environment: { ANTHROPIC_API_KEY: "secret" },
    } as RetainedHistoryObservation & { secret: string; environment: object }));
    first.closeMissing(new Set());

    const second = new RetainedHistoryStore({ path: pathName });

    expect(second.page()).toMatchObject({
      total: 1,
      records: [{ id: "claude-safe", sourceProfile: "claude-copilot", cwd: "/Users/me/Codes/agent-visor" }],
    });
    const serialized = readFileSync(pathName, "utf8");
    expect(serialized).not.toContain("must-not-persist");
    expect(serialized).not.toContain("ANTHROPIC_API_KEY");
  });

  it("searches and pages every retained record without an implicit cap", () => {
    const store = new RetainedHistoryStore({ path: storePath() });
    for (let index = 0; index < 1_005; index += 1) {
      store.observe(fixture(`claude-${index}`, {
        title: index === 1_004 ? "needle conversation" : `Conversation ${index}`,
        updatedAt: new Date(1_700_000_000_000 + index).toISOString(),
        observedAt: new Date(1_700_000_000_000 + index).toISOString(),
      }));
    }
    store.closeMissing(new Set());

    const first = store.page("needle", undefined, 10);
    expect(first.total).toBe(1);
    expect(first.records[0]?.title).toBe("needle conversation");

    const all = store.page(undefined, undefined, 1_000);
    expect(all.total).toBe(1_005);
    expect(all.records).toHaveLength(1_000);
    expect(all.nextCursor).toBeDefined();
    const remainder = store.page(undefined, all.nextCursor, 1_000);
    expect(remainder.records).toHaveLength(5);
    expect(remainder.nextCursor).toBeUndefined();
  });

  it("ignores malformed or incompatible persisted records without making them launchable", () => {
    const pathName = storePath();
    const now = new Date("2026-10-21T18:00:00.000Z");
    const directory = path.dirname(pathName);
    void directory;
    writeFileSync(pathName, JSON.stringify({
      version: 99,
      records: [fixture("incompatible")],
    }));

    const store = new RetainedHistoryStore({ path: pathName, now: () => now });

    expect(store.page()).toMatchObject({ records: [], total: 0 });
  });
});
