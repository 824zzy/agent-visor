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

  it("does not rewrite durable history when only resume provenance confirmation advances", () => {
    const pathName = storePath();
    const resume = {
      version: 1 as const,
      provider: "claude_code" as const,
      host: "Ghostty" as const,
      executableRef: "/usr/local/bin/claude",
      configRootRef: "/Users/me/.claude",
      profileState: "verified_absent" as const,
      overrideNames: [],
      provenanceObservedAt: "2026-10-21T18:00:00.000Z",
    };
    const store = new RetainedHistoryStore({ path: pathName });
    store.observe(fixture("claude-provenance-confirmation", {
      resume,
      current: true,
    }));
    const before = readFileSync(pathName, "utf8");

    store.observe(fixture("claude-provenance-confirmation", {
      resume: { ...resume, provenanceObservedAt: "2026-10-21T18:01:00.000Z" },
      current: true,
    }));

    expect(readFileSync(pathName, "utf8")).toBe(before);
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

  it("retains canonical history and removal suppression across many public projections", () => {
    const pathName = storePath();
    const canonicalId = "claude-canonical-history";
    const projectionIds = Array.from({ length: 18 }, (_, index) => `claude-projection-${index}`);
    const store = new RetainedHistoryStore({ path: pathName });

    for (const [index, id] of projectionIds.entries()) {
      store.observe(fixture(id, {
        canonicalId,
        updatedAt: new Date(1_700_000_000_000 + index).toISOString(),
        observedAt: new Date(1_700_000_000_000 + index).toISOString(),
      }));
    }
    store.closeMissing(new Set());

    const restarted = new RetainedHistoryStore({ path: pathName });
    expect(restarted.page()).toMatchObject({
      total: 1,
      records: [{ id: projectionIds.at(-1), canonicalId, closedAt: expect.any(String) }],
    });
    expect(restarted.getForProvider("claude_code", canonicalId)).toMatchObject({ canonicalId });
    const retainedAlias = projectionIds.at(-2)!;
    expect(restarted.getForProvider("claude_code", retainedAlias)).toMatchObject({ canonicalId });

    expect(restarted.remove(retainedAlias, "agent_visor")).toBe("removed");
    const afterRemoval = new RetainedHistoryStore({ path: pathName });
    expect(afterRemoval.getForProvider("claude_code", canonicalId)).toBeUndefined();
    expect(afterRemoval.getOriginForProvider("claude_code", canonicalId)).toMatchObject({ canonicalId });
    expect(afterRemoval.isSuppressed("claude_code", [canonicalId, retainedAlias])).toBe(true);
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

  it("fails closed when a bare public identity is shared by Claude and Codex", () => {
    const store = new RetainedHistoryStore({ path: storePath() });
    const id = "019f3931-ec11-7f31-8400-1c8624aa9e4d";
    store.observe(fixture(id));
    store.observe(fixture(id, {
      provider: "codex",
      owner: "Codex CLI",
      cwd: "/Users/me/.codex/project",
      transcriptPath: "/Users/me/.codex/sessions/019f3931-ec11-7f31-8400-1c8624aa9e4d.jsonl",
    }));

    expect(store.get(id)).toBeUndefined();
    expect(store.getForProvider("claude_code", id)?.provider).toBe("claude_code");
    expect(store.getForProvider("codex", id)?.provider).toBe("codex");
  });

  it("clears stale Ghostty launch authority after a newer current context", () => {
    const store = new RetainedHistoryStore({ path: storePath() });
    const resume = {
      version: 1 as const,
      provider: "claude_code" as const,
      host: "Ghostty" as const,
      executableRef: "/usr/local/bin/claude",
      profileState: "verified_absent" as const,
      overrideNames: [],
      provenanceObservedAt: "2026-10-21T18:00:00.000Z",
    };
    store.observe(fixture("claude-context", { resume, current: true }));
    store.closeMissing(new Set());

    store.observe(fixture("claude-context", {
      host: "cmux",
      resume,
      observedAt: "2026-10-21T18:01:00.000Z",
      current: true,
    }));

    const record = store.get("claude-context");
    expect(record).toMatchObject({
      host: "cmux",
      resumeUnavailableReason: "host_not_supported",
    });
    expect(record?.resume).toBeUndefined();

    store.observe(fixture("claude-context", {
      resume,
      observedAt: "2026-10-21T18:02:00.000Z",
      current: true,
    }));
    expect(store.get("claude-context")).toMatchObject({
      host: "Ghostty",
      resume,
    });
    expect(store.get("claude-context")?.resumeUnavailableReason).toBeUndefined();
  });
});
