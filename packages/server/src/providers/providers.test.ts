import { describe, expect, it } from "vitest";
import { AuggieProvider } from "./auggie.js";
import { ClaudeProvider } from "./claude.js";
import { CodexProvider } from "./codex.js";
import { CursorProvider } from "./cursor.js";
import type {
  FileStamp,
  ProcessRecord,
  ProviderEnvironment,
} from "./environment.js";
import { PiProvider } from "./pi.js";
import { ZedProvider } from "./zed.js";

const home = "/Users/me";
const cwd = `${home}/Codes/agent-visor`;
const now = new Date("2026-08-22T08:00:00.000Z");

class FixtureEnvironment implements ProviderEnvironment {
  readonly home = home;
  readonly observedWindowMs = 42 * 60 * 60 * 1_000;
  processRows: ProcessRecord[] = [];
  directories = new Map<string, string[]>();
  stamps = new Map<string, FileStamp>();
  files = new Map<string, string>();
  headTails = new Map<string, { head: string; tail: string }>();
  sqliteRows = new Map<string, unknown[]>();
  cwdByPID = new Map<number, string>();
  starts = new Map<number, Date>();

  now(): Date { return now; }
  async processes(): Promise<ProcessRecord[]> { return this.processRows; }
  async cwd(pid: number): Promise<string | undefined> { return this.cwdByPID.get(pid); }
  async processStartedAt(pid: number): Promise<Date | undefined> { return this.starts.get(pid); }
  async directory(path: string): Promise<string[]> { return this.directories.get(path) ?? []; }
  async isDirectory(path: string): Promise<boolean> { return this.directories.has(path); }
  async stamp(path: string): Promise<FileStamp | undefined> { return this.stamps.get(path); }
  async read(path: string): Promise<string | undefined> { return this.files.get(path); }
  async readHeadTail(path: string): Promise<{ head: string; tail: string } | undefined> {
    return this.headTails.get(path);
  }
  async scanLinePrefixes(
    path: string,
    prefixBytes: number,
    visit: (line: string) => void,
    startAt = 0,
  ): Promise<number> {
    const content = this.files.get(path) ?? "";
    const complete = content.lastIndexOf("\n") + 1;
    for (const line of content.slice(startAt, complete).split("\n")) {
      if (line) visit(line.slice(0, prefixBytes));
    }
    return complete;
  }
  async sqlite(database: string): Promise<unknown[]> { return this.sqliteRows.get(database) ?? []; }
}

const terminalProcesses: ProcessRecord[] = [
  { pid: 42, parentPID: 7, tty: "ttys001", command: "/usr/local/bin/claude", arguments: "claude" },
  { pid: 7, parentPID: 1, tty: "ttys001", command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
];

describe("live provider adapters", () => {
  it("keeps Claude names in Claude metadata", async () => {
    const environment = new FixtureEnvironment();
    const metadata = `${home}/.claude/sessions/42.json`;
    environment.processRows = terminalProcesses;
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(metadata, JSON.stringify({
      sessionId: "claude-1",
      cwd,
      kind: "interactive",
      entrypoint: "cli",
      status: "busy",
      name: "Claude title",
    }));
    environment.stamps.set(metadata, { modifiedAt: now, size: 100 });

    const sessions = await new ClaudeProvider(environment).discover();

    expect(sessions).toMatchObject([{
      id: "claude-1",
      title: "Claude title",
      provider: "claude_code",
      owner: "Ghostty",
      section: "working",
      messageTransport: "terminal",
      controlTarget: { kind: "terminal", target: { application: "Ghostty", tty: "ttys001", cwd } },
    }]);
  });

  it("reads Pi identity and its active transcript name", async () => {
    const environment = new FixtureEnvironment();
    const root = `${home}/.pi/agent/sessions`;
    const project = `${root}/--Users-me-Codes-agent-visor--`;
    const transcript = `${project}/pi-1.jsonl`;
    const body = [
      { type: "session", id: "pi-1", cwd, timestamp: "2026-08-22T07:59:58.000Z" },
      { type: "session_info", id: "info-old", parentId: "root", name: "Old name" },
      { type: "custom", data: { id: "nested-id" }, id: "custom", parentId: "info-old" },
      { type: "session_info", id: "info-active", parentId: "custom", name: "Active Pi name" },
      { type: "message", id: "message", parentId: "info-active", role: "user", content: "Continue" },
    ].map((value) => JSON.stringify(value)).join("\n") + "\n";
    environment.directories.set(root, ["--Users-me-Codes-agent-visor--"]);
    environment.directories.set(project, ["pi-1.jsonl"]);
    environment.files.set(transcript, body);
    environment.headTails.set(transcript, { head: body, tail: body });
    environment.stamps.set(transcript, { modifiedAt: now, size: Buffer.byteLength(body) });
    environment.processRows = [
      { pid: 43, parentPID: 7, tty: "ttys001", command: "/opt/homebrew/bin/pi", arguments: "pi" },
      terminalProcesses[1]!,
    ];
    environment.cwdByPID.set(43, cwd);
    environment.starts.set(43, new Date("2026-08-22T07:59:59.000Z"));

    const provider = new PiProvider(environment);
    const sessions = await provider.discover();

    expect(sessions[0]).toMatchObject({
      id: "pi-1",
      title: "Active Pi name",
      provider: "pi",
      owner: "Ghostty",
      messageTransport: "terminal",
      controlTarget: { kind: "terminal", target: { application: "Ghostty", tty: "ttys001", cwd } },
    });

    const appended = [
      { type: "session_info", id: "new-info", parentId: "message", name: "Renamed Pi branch" },
      { type: "message", id: "new-message", parentId: "new-info", role: "assistant", content: "Done" },
    ].map((value) => JSON.stringify(value)).join("\n") + "\n";
    environment.files.set(transcript, body + appended);
    environment.stamps.set(transcript, {
      modifiedAt: new Date(now.valueOf() + 1_000),
      size: Buffer.byteLength(body + appended),
    });

    expect((await provider.discover())[0]?.title).toBe("Renamed Pi branch");
  });

  it("keeps Codex titles in the Codex thread database", async () => {
    const environment = new FixtureEnvironment();
    const database = `${home}/.codex/sqlite/state_5.sqlite`;
    const rollout = `${home}/.codex/sessions/2026/08/22/rollout-codex-1.jsonl`;
    environment.stamps.set(database, { modifiedAt: now, size: 100 });
    environment.stamps.set(rollout, { modifiedAt: now, size: 100 });
    environment.sqliteRows.set(database, [{
      id: "codex-1",
      rollout_path: rollout,
      cwd,
      title: "Codex title",
      updated_at: Math.floor(now.valueOf() / 1_000),
      archived: 0,
      source: "vscode",
    }]);
    environment.processRows = [{
      pid: 50,
      parentPID: 1,
      command: "/Applications/Codex.app/Contents/MacOS/Codex",
      arguments: "/Applications/Codex.app/Contents/MacOS/Codex",
    }];

    const sessions = await new CodexProvider(environment).discover();

    expect(sessions[0]).toMatchObject({
      id: "codex-1",
      title: "Codex title",
      provider: "codex",
      owner: "Codex",
      canEnterChat: true,
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: "codex://threads/codex-1" },
    });

    environment.sqliteRows.set(database, [{
      id: "codex-1",
      rollout_path: rollout,
      cwd,
      title: "Codex title",
      updated_at: Math.floor((now.valueOf() - 3_600_000) / 1_000),
      archived: 0,
      source: "vscode",
    }]);
    environment.stamps.set(rollout, {
      modifiedAt: new Date(now.valueOf() - 3_600_000),
      size: 100,
    });
    expect((await new CodexProvider(environment).discover())[0]?.canEnterChat).toBe(false);
  });

  it("uses Cursor transcript content without sharing another provider parser", async () => {
    const environment = new FixtureEnvironment();
    const root = `${home}/.cursor/projects`;
    const project = `${root}/Users-me-Codes-agent-visor`;
    const sessionsRoot = `${project}/agent-transcripts`;
    const transcriptDir = `${sessionsRoot}/cursor-1`;
    const transcript = `${transcriptDir}/cursor-1.jsonl`;
    const body = JSON.stringify({
      role: "user",
      message: { content: [{ type: "text", text: "<user_query>\nCursor title\n</user_query>" }] },
    });
    environment.directories.set(root, ["Users-me-Codes-agent-visor"]);
    environment.directories.set(cwd, []);
    environment.directories.set(sessionsRoot, ["cursor-1"]);
    environment.directories.set(transcriptDir, ["cursor-1.jsonl"]);
    environment.stamps.set(transcript, { modifiedAt: now, size: body.length });
    environment.headTails.set(transcript, { head: body, tail: body });
    environment.processRows = [{
      pid: 51,
      parentPID: 7,
      tty: "ttys001",
      command: "/usr/bin/node",
      arguments: `${home}/.local/share/cursor-agent/current/bin/cursor-agent`,
    }, terminalProcesses[1]!];
    environment.cwdByPID.set(51, cwd);

    const sessions = await new CursorProvider(environment).discover();

    expect(sessions[0]).toMatchObject({
      id: "cursor-1",
      title: "Cursor title",
      provider: "cursor",
      owner: "Ghostty",
      controlTarget: {
        kind: "terminal",
        target: { application: "Ghostty", tty: "ttys001", cwd: "/Users/me/Codes/agent/visor" },
      },
    });
  });

  it("keeps Zed title authority and underlying provider identity", async () => {
    const environment = new FixtureEnvironment();
    const database = `${home}/Library/Application Support/Zed/db/0-stable/db.sqlite`;
    environment.stamps.set(database, { modifiedAt: now, size: 100 });
    environment.sqliteRows.set(database, [{
      thread_id: "ABCD",
      session_id: "pi-1",
      agent_id: "pi-acp",
      title: "Generated title",
      title_override: "Zed title",
      updated_at: now.toISOString(),
      interacted_at: now.toISOString(),
      main_worktree_paths: cwd,
      archived: 0,
    }]);
    environment.processRows = [{
      pid: 52,
      parentPID: 1,
      command: "/Applications/Zed.app/Contents/MacOS/zed",
      arguments: "/Applications/Zed.app/Contents/MacOS/zed",
    }];

    const sessions = await new ZedProvider(environment).discover();

    expect(sessions[0]).toMatchObject({
      id: "pi-1",
      title: "Zed title",
      provider: "pi",
      owner: "Zed",
      authority: 2,
      controlTarget: {
        kind: "application",
        target: { pid: 52, bundleIdentifier: "dev.zed.Zed" },
      },
    });
  });

  it("keeps Auggie observe-only until its documented hook reports a session", async () => {
    const environment = new FixtureEnvironment();
    await expect(new AuggieProvider(environment).discover()).resolves.toEqual([]);
  });
});
