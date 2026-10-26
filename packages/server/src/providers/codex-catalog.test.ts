import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { menuPresentation } from "../menu.js";
import { SessionRepository } from "../sessions.js";
import { CodexProvider } from "./codex.js";
import { LiveProviderEnvironment } from "./environment.js";

describe("Codex unarchived catalog", () => {
  it("includes old direct conversations past the first page and removes archived records on refresh", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "visor-codex-catalog-"));
    const database = path.join(home, ".codex/state_5.sqlite");
    mkdirSync(path.dirname(database), { recursive: true });
    const sql = (statement: string) => execFileSync("/usr/bin/sqlite3", [database, statement]);
    sql("create table threads (id text primary key, rollout_path text, cwd text, title text, updated_at integer, archived integer, source text)");
    class Environment extends LiveProviderEnvironment {
      scans = 0;
      fail = false;
      override async processes() { return []; }
      override async codexSettingsCatalog() { return undefined; }
      override async sqlite(file: string, query: string) {
        if (this.fail) throw new Error("temporary database failure");
        return super.sqlite(file, query);
      }
      override async scanLinePrefixes(...args: Parameters<LiveProviderEnvironment["scanLinePrefixes"]>) {
        this.scans += 1;
        return super.scanLinePrefixes(...args);
      }
    }
    try {
      const updated = Date.parse("2026-01-01T00:00:00Z") / 1_000;
      for (let index = 0; index < 205; index += 1) {
        const id = `direct-${String(index).padStart(3, "0")}`;
        const rollout = path.join(home, `${id}.jsonl`);
        writeFileSync(rollout, JSON.stringify({ type: "event_msg", timestamp: "2026-01-01T00:00:00Z",
          payload: { type: "task_complete", turn_id: "done" } }) + "\n");
        sql(`insert into threads values ('${id}', '${rollout}', '/project', '${id}', ${updated}, 0, 'vscode')`);
      }
      const managed = path.join(home, "managed.jsonl");
      writeFileSync(managed, JSON.stringify({ type: "session_meta", payload: { id: "managed", originator: "Agent Room" } }) + "\n");
      sql(`insert into threads values ('managed', '${managed}', '/project', 'hi', ${updated}, 0, 'vscode')`);
      // An archived row must be excluded even if its transcript was just touched.
      sql(`insert into threads values ('archived', '${managed}', '/project', 'archived', ${updated}, 1, 'vscode')`);
      const environment = new Environment(home);
      const repository = new SessionRepository([new CodexProvider(environment)]);
      const snapshot = await repository.refresh();
      expect(snapshot.sessions).toHaveLength(206);
      expect(snapshot.sessions.some(({ id }) => id === "direct-204")).toBe(true);
      const menu = menuPresentation(snapshot, [], updated * 1_000);
      expect(menu.navigatorPills.find(({ id }) => id === "direct-204")?.defaultOverflowEligible).toBe(false);
      expect(menu.pills.every(({ id }) => id.startsWith("direct-"))).toBe(true);
      expect(menu.navigatorPills.find(({ id }) => id === "managed")?.defaultOverflowEligible).toBe(false);
      const scans = environment.scans;
      await repository.refresh();
      expect(environment.scans).toBe(scans);
      environment.fail = true;
      expect((await repository.refresh()).sessions).toHaveLength(206);
      environment.fail = false;
      sql("update threads set archived=1");
      expect((await repository.refresh()).sessions).toEqual([]);
      sql("update threads set archived=0 where id='direct-204'");
      expect((await repository.refresh()).sessions.map(({ id }) => id)).toEqual(["direct-204"]);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("distinguishes an empty SQLite result from a failed query", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "visor-codex-sqlite-"));
    try {
      const database = path.join(home, "empty.sqlite");
      execFileSync("/usr/bin/sqlite3", [database, "create table example (id text)"]);
      const environment = new LiveProviderEnvironment(home);
      expect(await environment.sqlite(database, "select * from example")).toEqual([]);
      await expect(environment.sqlite(database, "select * from missing_table")).rejects.toThrow();
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("retains cached Codex rows as unavailable when the home database disappears", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "visor-codex-missing-database-"));
    const database = path.join(home, ".codex/state_5.sqlite");
    mkdirSync(path.dirname(database), { recursive: true });
    const sql = (statement: string) => execFileSync("/usr/bin/sqlite3", [database, statement]);
    const threadID = "missing-database";
    const rollout = path.join(home, `${threadID}.jsonl`);
    try {
      sql("create table threads (id text primary key, rollout_path text, cwd text, title text, updated_at integer, archived integer, source text)");
      const updated = Date.parse("2026-10-21T18:00:00Z") / 1_000;
      writeFileSync(rollout, JSON.stringify({ type: "event_msg", timestamp: "2026-10-21T18:00:00Z",
        payload: { type: "task_complete", turn_id: "done" } }) + "\n");
      sql(`insert into threads values ('${threadID}', '${rollout}', '/project', 'Missing database', ${updated}, 0, 'vscode')`);
      class Environment extends LiveProviderEnvironment {
        override async processes() { return []; }
        override async codexSettingsCatalog() { return undefined; }
      }
      const environment = new Environment(home);
      const repository = new SessionRepository([new CodexProvider(environment)]);
      expect(await repository.refresh()).toMatchObject({
        sessions: [expect.objectContaining({
          id: threadID,
          presence: expect.objectContaining({ state: "unknown", evidence: "catalog" }),
        })],
      });

      rmSync(database);
      expect(await repository.refresh()).toMatchObject({
        sessions: [expect.objectContaining({
          id: threadID,
          presence: expect.objectContaining({ state: "unknown", evidence: "unavailable" }),
        })],
      });
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("retains cached Codex rows as unavailable when a catalog page is malformed", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "visor-codex-malformed-catalog-"));
    const database = path.join(home, ".codex/state_5.sqlite");
    mkdirSync(path.dirname(database), { recursive: true });
    const sql = (statement: string) => execFileSync("/usr/bin/sqlite3", [database, statement]);
    const threadID = "malformed-catalog";
    const rollout = path.join(home, `${threadID}.jsonl`);
    try {
      sql("create table threads (id text primary key, rollout_path text, cwd text, title text, updated_at integer, archived integer, source text)");
      const updated = Date.parse("2026-10-21T18:00:00Z") / 1_000;
      writeFileSync(rollout, JSON.stringify({ type: "event_msg", timestamp: "2026-10-21T18:00:00Z",
        payload: { type: "task_complete", turn_id: "done" } }) + "\n");
      sql(`insert into threads values ('${threadID}', '${rollout}', '/project', 'Malformed catalog', ${updated}, 0, 'vscode')`);
      class Environment extends LiveProviderEnvironment {
        malformed = false;
        override async processes() { return []; }
        override async codexSettingsCatalog() { return undefined; }
        override async sqlite(file: string, query: string) {
          if (this.malformed && query.includes("from threads")) {
            return [{ id: threadID, rollout_path: rollout, updated_at: updated, archived: 0, source: "vscode" }];
          }
          return super.sqlite(file, query);
        }
      }
      const environment = new Environment(home);
      const repository = new SessionRepository([new CodexProvider(environment)]);
      await repository.refresh();
      environment.malformed = true;

      expect(await repository.refresh()).toMatchObject({
        sessions: [expect.objectContaining({
          id: threadID,
          presence: expect.objectContaining({ state: "unknown", evidence: "unavailable" }),
        })],
      });
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("suppresses a removed CLI identity when the Codex Desktop catalog retains it after restart", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "visor-codex-remove-restart-"));
    const database = path.join(home, ".codex/state_5.sqlite");
    const historyPath = path.join(home, "retained-history.json");
    mkdirSync(path.dirname(database), { recursive: true });
    const sql = (statement: string) => execFileSync("/usr/bin/sqlite3", [database, statement]);
    const target = "removed-cli";
    const targetCanonical = "codex:native:removed-cli";
    const other = "other-desktop";
    const targetThread = "removed-cli";
    const otherThread = "other-desktop";
    try {
      sql("create table threads (id text primary key, rollout_path text, cwd text, title text, updated_at integer, archived integer, source text)");
      const updated = Date.parse("2026-10-21T18:00:00Z") / 1_000;
      for (const [threadID, title] of [[targetThread, "Removed CLI"], [otherThread, "Other Desktop"]]) {
        const rollout = path.join(home, `${threadID}.jsonl`);
        writeFileSync(rollout, JSON.stringify({ type: "event_msg", timestamp: "2026-10-21T18:00:00Z",
          payload: { type: "task_complete", turn_id: "done" } }) + "\n");
        sql(`insert into threads values ('${threadID}', '${rollout}', '/project', '${title}', ${updated}, 0, 'vscode')`);
      }

      let seedSessions = [{
        id: target,
        provider: "codex" as const,
        title: "Removed CLI",
        subtitle: "Codex CLI session",
        cwd: "/project",
        owner: "Codex CLI",
        section: "ready" as const,
        sessionClass: "terminal" as const,
        conversationState: "open" as const,
        turnState: "ready" as const,
        updatedAt: "2026-10-21T18:00:00.000Z",
        canOpenOwner: false,
        canEnterChat: false,
        historyIdentity: {
          verified: true,
          current: true,
          canonicalId: targetCanonical,
          configHome: path.join(home, ".codex"),
        },
      }];
      const seed = new SessionRepository([{
        id: "codex",
        discover: async () => structuredClone(seedSessions),
      }], { retainedHistoryPath: historyPath });
      await seed.refresh();
      seedSessions = [];
      await seed.refresh();
      expect(seed.historyPage().sessions).toContainEqual(expect.objectContaining({ id: target }));
      await expect(seed.removeHistorySession(target)).resolves.toBeUndefined();

      const repository = new SessionRepository([new CodexProvider(new LiveProviderEnvironment(home))], {
        retainedHistoryPath: historyPath,
      });
      const snapshot = await repository.refresh();
      expect(snapshot.sessions.map(({ id }) => id)).toContain(other);
      expect(snapshot.sessions.map(({ id }) => id)).not.toContain(target);
      expect(repository.historyPage().sessions.map(({ id }) => id)).not.toContain(target);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("uses the exact archived bit even when the retained Codex transcript is missing", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "visor-codex-archived-lifetime-"));
    const database = path.join(home, ".codex/state_5.sqlite");
    const historyPath = path.join(home, "retained-history.json");
    mkdirSync(path.dirname(database), { recursive: true });
    const sql = (statement: string) => execFileSync("/usr/bin/sqlite3", [database, statement]);
    const threadID = "archived-without-transcript";
    try {
      sql("create table threads (id text primary key, rollout_path text, cwd text, title text, updated_at integer, archived integer, source text)");
      const updated = Date.parse("2026-10-21T18:00:00Z") / 1_000;
      sql(`insert into threads values ('${threadID}', '${path.join(home, "missing.jsonl")}', '/project', 'Archived', ${updated}, 1, 'cli')`);

      let sessions = [{
        id: threadID,
        provider: "codex" as const,
        title: "Archived",
        subtitle: "Codex CLI session",
        cwd: "/project",
        owner: "Codex CLI",
        section: "ready" as const,
        sessionClass: "terminal" as const,
        conversationState: "open" as const,
        turnState: "ready" as const,
        updatedAt: "2026-10-21T18:00:00.000Z",
        canOpenOwner: false,
        canEnterChat: false,
        historyIdentity: {
          verified: true,
          current: true,
          canonicalId: `codex:native:${threadID}`,
          configHome: path.join(home, ".codex"),
        },
      }];
      const seed = new SessionRepository([{
        id: "codex",
        discover: async () => structuredClone(sessions),
      }], { retainedHistoryPath: historyPath });
      await seed.refresh();
      sessions = [];
      await seed.refresh();
      expect(seed.historyPage().sessions).toContainEqual(expect.objectContaining({ id: threadID }));

      const repository = new SessionRepository([new CodexProvider(new LiveProviderEnvironment(home))], {
        retainedHistoryPath: historyPath,
      });
      await repository.refresh();
      expect(repository.historyPage().sessions).not.toContainEqual(expect.objectContaining({ id: threadID }));
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("preserves retained History when Codex lifetime evidence is unknown", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "visor-codex-unknown-lifetime-"));
    const database = path.join(home, ".codex/state_5.sqlite");
    const historyPath = path.join(home, "retained-history.json");
    mkdirSync(path.dirname(database), { recursive: true });
    const sql = (statement: string) => execFileSync("/usr/bin/sqlite3", [database, statement]);
    const threadID = "unknown-lifetime";
    class Environment extends LiveProviderEnvironment {
      fail = false;

      override async sqlite(file: string, query: string) {
        if (this.fail) throw new Error("temporary database failure");
        return super.sqlite(file, query);
      }
    }
    try {
      sql("create table threads (id text primary key, rollout_path text, cwd text, title text, updated_at integer, archived integer, source text)");
      const updated = Date.parse("2026-10-21T18:00:00Z") / 1_000;
      sql(`insert into threads values ('${threadID}', '${path.join(home, "missing.jsonl")}', '/project', 'Unknown lifetime', ${updated}, 0, 'cli')`);
      let sessions = [{
        id: threadID,
        provider: "codex" as const,
        title: "Unknown lifetime",
        subtitle: "Codex CLI session",
        cwd: "/project",
        owner: "Codex CLI",
        section: "ready" as const,
        sessionClass: "terminal" as const,
        conversationState: "open" as const,
        turnState: "ready" as const,
        updatedAt: "2026-10-21T18:00:00.000Z",
        canOpenOwner: false,
        canEnterChat: false,
        historyIdentity: {
          verified: true,
          current: true,
          canonicalId: `codex:native:${threadID}`,
          configHome: path.join(home, ".codex"),
        },
      }];
      const seed = new SessionRepository([{
        id: "codex",
        discover: async () => structuredClone(sessions),
      }], { retainedHistoryPath: historyPath });
      await seed.refresh();
      sessions = [];
      await seed.refresh();

      const environment = new Environment(home);
      const repository = new SessionRepository([new CodexProvider(environment)], {
        retainedHistoryPath: historyPath,
      });
      await repository.refresh();
      expect(repository.historyPage().sessions).toContainEqual(expect.objectContaining({ id: threadID }));

      environment.fail = true;
      await repository.refresh();
      expect(repository.historyPage().sessions).toContainEqual(expect.objectContaining({ id: threadID }));

      environment.fail = false;
      sql("delete from threads");
      await repository.refresh();
      expect(repository.historyPage().sessions).toContainEqual(expect.objectContaining({ id: threadID }));
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});
