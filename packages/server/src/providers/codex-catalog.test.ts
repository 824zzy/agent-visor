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
      expect(menu.navigatorPills.find(({ id }) => id === "direct-204")?.defaultOverflowEligible).toBe(true);
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
});
