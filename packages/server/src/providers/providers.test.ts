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
import { processInstanceToken } from "./shared.js";
import { SessionRepository } from "../sessions.js";

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
    environment.starts.set(42, new Date("2026-08-22T07:59:00.000Z"));
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
      controlTarget: { kind: "terminal", target: {
        application: "Ghostty", tty: "ttys001", cwd,
        processStartToken: processInstanceToken(
          42,
          "2026-08-22T07:59:00.000Z",
        ),
      } },
    }]);
  });

  it("excludes Claude SDK sessions", async () => {
    const environment = new FixtureEnvironment();
    const metadata = `${home}/.claude/sessions/42.json`;
    environment.processRows = [{
      pid: 42,
      parentPID: 7,
      command: "/usr/local/bin/claude",
      arguments: "claude --session-id claude-sdk",
    }];
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(metadata, JSON.stringify({
      sessionId: "claude-sdk",
      cwd,
      kind: "interactive",
      entrypoint: "sdk-ts",
      name: "internal-job",
    }));

    expect(await new ClaudeProvider(environment).discover()).toEqual([]);
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
    const models = `${home}/.pi/agent/models-store.json`;
    environment.files.set(models, JSON.stringify({
      "openai-codex": { models: [{
        id: "gpt-5.6-sol", name: "GPT-5.6 Sol", contextWindow: 114_688,
      }] },
    }));
    environment.stamps.set(models, { modifiedAt: now, size: environment.files.get(models)!.length });
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
      modelCatalog: {
        "gpt-5.6-sol": { displayName: "GPT-5.6 Sol", contextWindow: 114_688 },
      },
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
    environment.stamps.delete(models);
    expect((await provider.discover())[0]?.modelCatalog).toBeUndefined();
  });

  it("uses Pi hook identity for a resumed session in its exact terminal", async () => {
    const environment = new FixtureEnvironment();
    const root = `${home}/.pi/agent/sessions`;
    const project = `${root}/--Users-me-Codes-agent-visor--`;
    const transcript = `${project}/pi-resumed.jsonl`;
    const body = [
      { type: "session", id: "pi-resumed", cwd, timestamp: "2026-08-16T01:39:47.387Z" },
      { type: "message", id: "message", parentId: "root", role: "user", content: "Continue" },
    ].map((value) => JSON.stringify(value)).join("\n") + "\n";
    environment.directories.set(root, ["--Users-me-Codes-agent-visor--"]);
    environment.directories.set(project, ["pi-resumed.jsonl"]);
    environment.files.set(transcript, body);
    environment.headTails.set(transcript, { head: body, tail: body });
    environment.stamps.set(transcript, { modifiedAt: now, size: Buffer.byteLength(body) });
    environment.processRows = [
      { pid: 43, parentPID: 7, tty: "ttys001", command: "/opt/homebrew/bin/pi", arguments: "pi" },
      terminalProcesses[1]!,
      { pid: 44, parentPID: 8, tty: "ttys002", command: "/opt/homebrew/bin/pi", arguments: "pi" },
      { pid: 8, parentPID: 1, tty: "ttys002", command: "/Applications/iTerm.app/Contents/MacOS/iTerm2", arguments: "iTerm2" },
    ];
    environment.cwdByPID.set(43, cwd);
    environment.cwdByPID.set(44, cwd);
    environment.starts.set(43, new Date("2026-08-22T07:30:00.000Z"));
    environment.starts.set(44, new Date("2026-08-22T07:31:00.000Z"));

    const provider = new PiProvider(environment);
    provider.noteHook({
      sessionId: "pi-resumed",
      cwd,
      provider: "pi",
      event: "SessionHeartbeat",
      status: "alive",
      receivedAt: now.toISOString(),
      pid: 43,
      tty: "ttys001",
      sessionFile: transcript,
    });

    expect(await provider.discover()).toMatchObject([{
      id: "pi-resumed",
      owner: "Ghostty",
      canOpenOwner: true,
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: { application: "Ghostty", tty: "ttys001", cwd },
      },
    }]);

    provider.noteHook({
      sessionId: "pi-resumed",
      cwd,
      provider: "pi",
      event: "SessionEnd",
      status: "ended",
      receivedAt: now.toISOString(),
    });
    expect((await provider.discover())[0]).toMatchObject({
      id: "pi-resumed",
      owner: "Pi",
      canOpenOwner: false,
    });
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
    const models = `${home}/.codex/models_cache.json`;
    environment.files.set(models, JSON.stringify({
      models: [{ slug: "gpt-5.6-sol", display_name: "GPT-5.6-Sol", context_window: 258_400 }],
    }));
    environment.stamps.set(models, { modifiedAt: now, size: environment.files.get(models)!.length });
    environment.processRows = [{
      pid: 50,
      parentPID: 1,
      command: "/Applications/Codex.app/Contents/MacOS/Codex",
      arguments: "/Applications/Codex.app/Contents/MacOS/Codex",
    }];

    const provider = new CodexProvider(environment);
    const sessions = await provider.discover();

    expect(sessions[0]).toMatchObject({
      id: "codex-1",
      title: "Codex title",
      provider: "codex",
      owner: "Codex",
      canEnterChat: true,
      modelCatalog: {
        "gpt-5.6-sol": { displayName: "GPT-5.6-Sol", contextWindow: 258_400 },
      },
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: "codex://threads/codex-1" },
    });

    environment.files.set(models, JSON.stringify({
      models: [{
        slug: "gpt-oversized", display_name: "x".repeat(300), context_window: 100_000,
      }],
    }));
    environment.stamps.set(models, {
      modifiedAt: new Date(now.valueOf() + 1_000), size: environment.files.get(models)!.length,
    });
    expect((await provider.discover())[0]?.modelCatalog).toBeUndefined();

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

  it.each([
    { section: "ready", event: "Stop", status: "waiting_for_input", ageMs: 121_000 },
    { section: "ready", event: "Stop", status: "waiting_for_input", ageMs: 3_600_000 },
    { section: "ready", event: "Stop", status: "waiting_for_input", ageMs: 41 * 3_600_000 },
    { section: "working", event: "UserPromptSubmit", status: "working", ageMs: 3_600_000 },
    { section: "needs_you", event: "PermissionRequest", status: "approval", ageMs: 3_600_000 },
  ])("keeps Open Chat available for tracked Codex $section after $ageMs ms idle", async ({
    section, event, status, ageMs,
  }) => {
    const environment = new FixtureEnvironment();
    const database = `${home}/.codex/sqlite/state_5.sqlite`;
    const rollout = `${home}/.codex/sessions/ready.jsonl`;
    const completedAt = new Date(now.valueOf() - ageMs);
    environment.stamps.set(database, { modifiedAt: now, size: 100 });
    environment.stamps.set(rollout, { modifiedAt: completedAt, size: 100 });
    environment.sqliteRows.set(database, [{
      id: "ready-codex", rollout_path: rollout, cwd, title: "Ready Codex",
      updated_at: completedAt.valueOf() / 1_000, archived: 0, source: "vscode",
    }]);
    const repository = new SessionRepository([new CodexProvider(environment)], {
      now: () => now,
    });
    expect((await repository.refresh()).sessions).toMatchObject([{
      id: "ready-codex", section: "history", canOpenOwner: true, canEnterChat: false,
    }]);

    const completed = repository.applyHook({
      sessionId: "ready-codex", provider: "codex", cwd,
      event, status, receivedAt: completedAt.toISOString(),
    });

    expect(completed.sessions).toMatchObject([{
      id: "ready-codex", section, canOpenOwner: true, canEnterChat: true,
    }]);
    expect((await repository.refresh()).sessions).toEqual(completed.sessions);

    expect(repository.applyHook({
      sessionId: "ready-codex", provider: "codex", cwd,
      event: "SessionEnd", status: "ended", receivedAt: now.toISOString(),
    }).sessions).toMatchObject([{
      id: "ready-codex", section: "history", canOpenOwner: true, canEnterChat: false,
    }]);

    environment.stamps.delete(rollout);
    expect((await repository.refresh()).sessions).toEqual([]);
  });

  it("discovers authoritative headless Codex jobs", async () => {
    const environment = new FixtureEnvironment();
    const database = `${home}/.codex/sqlite/state_5.sqlite`;
    const rollout = `${home}/.codex/sessions/2026/08/22/rollout-codex-exec.jsonl`;
    environment.stamps.set(database, { modifiedAt: now, size: 100 });
    environment.stamps.set(rollout, { modifiedAt: now, size: 100 });
    environment.sqliteRows.set(database, [{
      id: "codex-exec",
      rollout_path: rollout,
      cwd,
      title: "Headless job",
      updated_at: Math.floor(now.valueOf() / 1_000),
      archived: 0,
      source: "exec",
    }]);

    const sessions = await new CodexProvider(environment).discover();

    expect(sessions).toMatchObject([{
      id: "codex-exec",
      title: "Headless job",
      canOpenOwner: true,
      controlTarget: { kind: "url", url: "codex://threads/codex-exec" },
    }]);
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
