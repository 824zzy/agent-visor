import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it, vi } from "vitest";
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
import { applicationTargetForProcess, processInstanceToken } from "./shared.js";
import { SessionRepository, type DiscoveredProviderSession } from "../sessions.js";
import { activateMenuPill, activateSessionNotification, menuPresentation } from "../menu.js";
import { NativeSessionControls } from "../session-controls.js";
import { FakeNativeHelper } from "../native-helper.js";
import { ClaudeDesktopSessions } from "./claude-desktop.js";

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
  codexSettingsCatalog: ProviderEnvironment["codexSettingsCatalog"];

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

function claudeDesktopStateFixture() {
  const environment = new FixtureEnvironment();
  const id = "claude-completion";
  const transcript = `${home}/.claude/projects/-Users-me-Codes-agent-visor/${id}.jsonl`;
  environment.processRows = [
    { pid: 42, parentPID: 7, command: `${home}/Library/Application Support/Claude-3p/claude-code/claude`, arguments: "claude" },
    { pid: 7, parentPID: 1, command: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: "Claude" },
  ];
  environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
  environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
    sessionId: id, cwd, kind: "interactive", entrypoint: "claude-desktop-3p", name: "Claude completion",
  }));
  const provider = new ClaudeProvider(environment);
  const repository = new SessionRepository([provider], { now: () => now });
  let revision = 0;
  return {
    repository,
    setTranscript(records: unknown[]) {
      const tail = records.map(record => JSON.stringify(record)).join("\n") + "\n";
      environment.headTails.set(transcript, { head: "", tail });
      // Bookkeeping can change mtime after a response without starting a turn.
      environment.stamps.set(transcript, { modifiedAt: now, size: ++revision });
    },
    hook(event: string, status: string, receivedAt: string) {
      return repository.applyHook({ sessionId: id, cwd, provider: "claude_code", event, status, receivedAt });
    },
    expectPhase(phase: "working" | "ready" | "needs_you") {
      const snapshot = repository.current();
      expect(snapshot.sessions).toMatchObject([{ section: phase, attentionTier: phase }]);
      expect(menuPresentation(snapshot, [], now.valueOf()).pills).toMatchObject([{ phase }]);
    },
  };
}

describe("Herdr hosted conversations", () => {
  function herdrFixture() {
    const environment = new FixtureEnvironment();
    environment.processRows = [
      { pid: 42, parentPID: 20, tty: "ttys023", command: "/usr/local/bin/claude", arguments: "claude" },
      { pid: 20, parentPID: 10, tty: "ttys023", command: "/bin/zsh", arguments: "zsh" },
      { pid: 10, parentPID: 1, command: "/Users/me/.local/bin/herdr", arguments: "herdr server" },
      // The visible client is a separate process tree, not this pane's owner.
      { pid: 70, parentPID: 7, tty: "ttys034", command: "/Users/me/.local/bin/herdr", arguments: "herdr" },
      terminalProcesses[1]!,
    ];
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
      sessionId: "herdr-conversation", cwd, kind: "interactive", status: "idle", name: "codes-6e",
    }));
    environment.starts.set(42, now);
    const helper = new FakeNativeHelper();
    const repository = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    repository.setControls(new NativeSessionControls(helper));
    return { environment, repository, helper };
  }

  it("keeps a detached Herdr conversation Ready without inventing an Apple Terminal route", async () => {
    const { repository } = herdrFixture();
    const snapshot = await repository.refresh();
    expect(snapshot.sessions).toMatchObject([{
      id: "herdr-conversation", title: "codes-6e", owner: "Herdr", section: "ready",
      sessionClass: "terminal", canOpenOwner: false,
    }]);
    expect(menuPresentation(snapshot, [], now.valueOf()).pills).toMatchObject([{
      id: "herdr-conversation", phase: "ready",
      inspector: { runtimeItems: ["Claude Code · Herdr"] },
    }]);
  });

  it("keeps idle Claude activity and gray pills stable across bookkeeping-only file touches", async () => {
    const { environment, repository } = herdrFixture();
    const transcript = `${home}/.claude/projects/-Users-me-Codes-agent-visor/herdr-conversation.jsonl`;
    const activityAt = "2026-08-22T06:05:00.000Z";
    const body = [
      { type: "assistant", timestamp: "2026-08-22T06:00:00.000Z", message: { stop_reason: "end_turn" } },
      { type: "user", timestamp: activityAt, message: { content: "<command-name>/status</command-name>" } },
      { type: "system", subtype: "informational", timestamp: "2026-08-22T07:00:00.000Z" },
    ].map(record => JSON.stringify(record)).join("\n");
    environment.headTails.set(transcript, { head: body, tail: body });
    environment.stamps.set(transcript, { modifiedAt: new Date(activityAt), size: body.length });
    await repository.refresh();
    const before = menuPresentation(repository.current(), [], now.valueOf()).pills[0];
    expect(before).toMatchObject({ inactive: true, attentionTier: "history", inspector: { activityAt } });

    // Cache invalidation is not a new turn: bytes and conversation events are unchanged.
    environment.stamps.set(transcript, { modifiedAt: now, size: body.length });
    await repository.refresh();
    const after = menuPresentation(repository.current(), [], now.valueOf()).pills[0];
    expect(after).toEqual(before);
    expect(repository.current().sessions[0]).toMatchObject({
      lifecycleStatus: "ready", updatedAt: activityAt,
    });
    expect(after?.completionUnseen).not.toBe(true);
    const restarted = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    expect(menuPresentation(await restarted.refresh(), [], now.valueOf()).pills[0]).toEqual(before);
  });

  it("keeps fresh busy Claude evidence orange when the transcript still shows the previous completed turn", async () => {
    const { environment, repository } = herdrFixture();
    const transcript = `${home}/.claude/projects/-Users-me-Codes-agent-visor/herdr-conversation.jsonl`;
    const body = JSON.stringify({ type: "assistant", timestamp: "2026-08-22T06:00:00.000Z", message: { stop_reason: "end_turn" } });
    environment.headTails.set(transcript, { head: body, tail: body });
    environment.stamps.set(transcript, { modifiedAt: now, size: body.length });
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
      sessionId: "herdr-conversation", cwd, kind: "interactive", status: "busy", name: "codes-6e",
    }));
    expect((await repository.refresh()).sessions[0]).toMatchObject({
      lifecycleStatus: "working", updatedAt: now.toISOString(),
    });
    expect(menuPresentation(repository.current(), [], now.valueOf()).pills[0]).toMatchObject({
      phase: "working", attentionTier: "working",
    });
  });

  it("does not use bookkeeping tail timestamps when a bounded transcript read loses the latest lifecycle", async () => {
    const { environment, repository } = herdrFixture();
    const transcript = `${home}/.claude/projects/-Users-me-Codes-agent-visor/herdr-conversation.jsonl`;
    const activityAt = "2026-08-22T06:00:00.000Z";
    environment.headTails.set(transcript, {
      head: JSON.stringify({ type: "assistant", timestamp: activityAt, message: { stop_reason: "end_turn" } }),
      // A 64 KiB tail can begin inside a long record, then contain only bookkeeping.
      tail: 'partial record suffix\n' + JSON.stringify({ type: "system", subtype: "informational", timestamp: now.toISOString() }),
    });
    environment.stamps.set(transcript, { modifiedAt: now, size: 100_000 });
    expect((await repository.refresh()).sessions[0]).toMatchObject({
      lifecycleStatus: "ready", updatedAt: activityAt,
    });
    expect(menuPresentation(repository.current(), [], now.valueOf()).pills[0]).toMatchObject({
      inactive: true, attentionTier: "history", inspector: { activityAt },
    });
    expect(repository.current().sessions[0]?.completionUnseen).not.toBe(true);
  });

  it("preserves completion acknowledgment through bookkeeping writes and restarts, but not a genuine new completion", async () => {
    const { environment } = herdrFixture();
    const directory = mkdtempSync(path.join(tmpdir(), "av-claude-attention-"));
    const completionAttentionPath = path.join(directory, "completion-attention.json");
    const transcript = `${home}/.claude/projects/-Users-me-Codes-agent-visor/herdr-conversation.jsonl`;
    const options = { now: () => now, completionAttentionPath };
    let revision = 0;
    const setTranscript = (completedAt: string, bookkeeping: boolean) => {
      const records: unknown[] = [{ type: "assistant", timestamp: completedAt, message: { stop_reason: "end_turn" } }];
      if (bookkeeping) records.push({ type: "system", subtype: "informational", timestamp: now.toISOString() });
      const body = records.map(record => JSON.stringify(record)).join("\n");
      environment.headTails.set(transcript, { head: body, tail: body });
      environment.stamps.set(transcript, { modifiedAt: new Date(now.valueOf() + revision++), size: body.length });
    };
    try {
      setTranscript("2026-08-22T07:55:00.000Z", false);
      const repository = new SessionRepository([new ClaudeProvider(environment)], options);
      await repository.refresh();
      expect(repository.current().sessions[0]?.completionUnseen).toBe(true);
      repository.acknowledgeReady("herdr-conversation");
      setTranscript("2026-08-22T07:55:00.000Z", true);
      await repository.refresh();
      expect(repository.current().sessions[0]).toMatchObject({ attentionTier: "acknowledged_ready", updatedAt: "2026-08-22T07:55:00.000Z" });
      expect(repository.current().sessions[0]?.completionUnseen).not.toBe(true);
      const restarted = new SessionRepository([new ClaudeProvider(environment)], options);
      await restarted.refresh();
      expect(restarted.current().sessions[0]?.completionUnseen).not.toBe(true);
      setTranscript("2026-08-22T07:59:00.000Z", true);
      await restarted.refresh();
      expect(restarted.current().sessions[0]).toMatchObject({
        completionUnseen: true, attentionTier: "ready", updatedAt: "2026-08-22T07:59:00.000Z",
      });
    } finally { rmSync(directory, { recursive: true, force: true }); }
  });

  it.each([true, false])("uses stable session provenance for idle transcripts without event timestamps (metadata start: %s)", async (metadataStart) => {
    const { environment, repository } = herdrFixture();
    const processStartedAt = "2026-08-22T06:00:00.000Z";
    const sessionStartedAt = "2026-08-22T06:05:00.000Z";
    environment.starts.set(42, new Date(processStartedAt));
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
      sessionId: "herdr-conversation", cwd, kind: "interactive", status: "idle", name: "codes-6e",
      ...(metadataStart ? { startedAt: Date.parse(sessionStartedAt) } : {}),
    }));
    const transcript = `${home}/.claude/projects/-Users-me-Codes-agent-visor/herdr-conversation.jsonl`;
    environment.headTails.set(transcript, { head: "", tail: JSON.stringify({ type: "system", subtype: "informational", timestamp: now.toISOString() }) });
    environment.stamps.set(transcript, { modifiedAt: now, size: 100 });
    expect((await repository.refresh()).sessions[0]).toMatchObject({
      lifecycleStatus: "ready", updatedAt: metadataStart ? sessionStartedAt : processStartedAt,
    });
    expect(menuPresentation(repository.current(), [], now.valueOf()).pills[0]?.inactive).toBe(true);
    expect(repository.current().sessions[0]?.completionUnseen).not.toBe(true);
  });

  it.each(["bookkeeping-only tail", "failed read"])("retains known idle activity when a later transcript read loses event timestamps: %s", async (read) => {
    const { environment, repository } = herdrFixture();
    const transcript = `${home}/.claude/projects/-Users-me-Codes-agent-visor/herdr-conversation.jsonl`;
    const activityAt = "2026-08-22T06:00:00.000Z";
    const body = JSON.stringify({ type: "assistant", timestamp: activityAt, message: { stop_reason: "end_turn" } });
    environment.headTails.set(transcript, { head: body, tail: body });
    environment.stamps.set(transcript, { modifiedAt: new Date(activityAt), size: body.length });
    await repository.refresh();
    const before = menuPresentation(repository.current(), [], now.valueOf()).pills[0];
    if (read === "failed read") environment.headTails.delete(transcript);
    else environment.headTails.set(transcript, { head: "", tail: JSON.stringify({ type: "system", subtype: "informational", timestamp: now.toISOString() }) });
    environment.stamps.set(transcript, { modifiedAt: now, size: 100_000 });
    await repository.refresh();
    expect(menuPresentation(repository.current(), [], now.valueOf()).pills[0]).toEqual(before);
    expect(repository.current().sessions[0]?.completionUnseen).not.toBe(true);
    // Failure must remain recoverable; it must not cache a false completion or suppress new work.
    const completedAt = "2026-08-22T07:59:00.000Z";
    const recovered = JSON.stringify({ type: "assistant", timestamp: completedAt, message: { stop_reason: "end_turn" } });
    environment.headTails.set(transcript, { head: recovered, tail: recovered });
    if (read !== "failed read") environment.stamps.set(transcript, { modifiedAt: new Date(now.valueOf() + 1), size: recovered.length });
    await repository.refresh();
    expect(repository.current().sessions[0]).toMatchObject({ updatedAt: completedAt, completionUnseen: true });
  });

  it("reports unavailable Herdr navigation without opening Chat or clearing attention", async () => {
    const { repository, helper } = herdrFixture();
    await repository.refresh();
    const before = repository.current();
    const effects: unknown[] = [];
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: "herdr-conversation" },
      repository, message => effects.push(message));
    expect(effects).toEqual([{
      type: "native_effect", action: "session_focus_failed",
      message: "This session is running in Herdr. Exact Herdr navigation is not available in this build. Open its pane in Herdr; no new session was created.",
    }]);
    expect(repository.current()).toEqual(before);
    expect([
      ...helper.terminalFocusRequests, ...helper.focusRequests, ...helper.codexThreadRequests,
      ...helper.claudeAttachRequests, ...helper.ghosttyTerminalFocusRequests, ...helper.terminalSendRequests,
    ]).toEqual([]);
  });

  it("reports unavailable Herdr notification navigation but keeps explicit Chat access", async () => {
    const { repository } = herdrFixture();
    await repository.refresh();
    const effects: unknown[] = [];
    await activateSessionNotification({ version: 1, type: "event", event: "notification_action", action: "activate", sessionId: "herdr-conversation" },
      repository, message => effects.push(message));
    expect(effects).toMatchObject([{ type: "native_effect", action: "session_focus_failed" }]);
    effects.length = 0;
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: "herdr-conversation", intent: "chat" },
      repository, message => effects.push(message));
    expect(effects).toEqual([{ type: "native_action", action: "open_chat", sessionId: "herdr-conversation" }]);
  });

  it.each(["Herdr", "Unknown"])("does not replace a %s Codex CLI route with a Codex Desktop deep link", async owner => {
    const { environment } = herdrFixture();
    environment.processRows[0] = { ...environment.processRows[0]!, command: "/usr/local/bin/codex", arguments: "codex" };
    if (owner === "Unknown") environment.processRows = [environment.processRows[0]!];
    environment.cwdByPID.set(42, cwd);
    const database = `${home}/.codex/sqlite/state_5.sqlite`;
    const rollout = `${home}/.codex/sessions/rollout-herdr.jsonl`;
    environment.stamps.set(database, { modifiedAt: now, size: 100 });
    environment.stamps.set(rollout, { modifiedAt: now, size: 100 });
    environment.sqliteRows.set(database, [{ id: "herdr-codex", rollout_path: rollout, cwd,
      title: "Herdr CLI", updated_at: Math.floor(now.valueOf() / 1000), archived: 0, source: "cli" }]);
    const sessions = await new CodexProvider(environment).discover();
    expect(sessions).toMatchObject([{ owner: "Codex CLI", canOpenOwner: false, routeState: "unavailable" }]);
    expect(sessions[0]?.controlTarget).toBeUndefined();
  });

  it.each(["Herdr", "Unknown"])("does not turn a %s background worker into a Terminal attach route", async owner => {
    const { environment } = herdrFixture();
    const id = "8e45ed2c-cd3b-4140-a8da-4614085a3536";
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
      sessionId: id, cwd, kind: "bg", jobId: "8e45ed2c", entrypoint: "cli", status: "idle",
    }));
    if (owner === "Unknown") environment.processRows = [environment.processRows[0]!];
    const inventoryEnvironment = Object.assign(environment, {
      claudeExecutable: async () => "/usr/local/bin/claude",
      claudeAgentInventory: async () => ({ kind: "success" as const, root: `${home}/.claude`, authoritative: true,
        startedAt: now.valueOf(), completedAt: now.valueOf(), rows: [{ id: "8e45ed2c", sessionId: id,
          kind: "background", cwd, pid: 42, state: "done", status: "idle", startedAt: now.valueOf() }] }),
    });
    const sessions = await new ClaudeProvider(inventoryEnvironment).discover();
    expect(sessions).toMatchObject([{ id, owner, canOpenOwner: false }]);
    expect(sessions[0]?.controlTarget).toBeUndefined();
  });

  it("does not fall through a Herdr pane to an ancestor GUI application", async () => {
    const { environment } = herdrFixture();
    environment.processRows[2] = { ...environment.processRows[2]!, parentPID: 7 };
    environment.processRows[4] = { pid: 7, parentPID: 1,
      command: "/Applications/Cursor.app/Contents/MacOS/Cursor", arguments: "Cursor" };
    const sessions = await new ClaudeProvider(environment).discover();
    expect(sessions).toMatchObject([{ owner: "Herdr", canOpenOwner: false }]);
    expect(sessions[0]?.controlTarget).toBeUndefined();
  });

  it("does not invent Apple Terminal when the sampled parent process is missing", async () => {
    const { environment } = herdrFixture();
    environment.processRows = [environment.processRows[0]!];
    const sessions = await new ClaudeProvider(environment).discover();
    expect(sessions).toMatchObject([{ owner: "Unknown", canOpenOwner: false }]);
    expect(sessions[0]?.controlTarget).toBeUndefined();
  });

  it("does not retain a background attach route when the current interactive host is unknown", async () => {
    const { environment } = herdrFixture();
    const id = "8e45ed2c-cd3b-4140-a8da-4614085a3536";
    environment.processRows = [environment.processRows[0]!];
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
      sessionId: id, cwd, kind: "interactive", status: "idle", name: "codes-6e",
    }));
    const inventoryEnvironment = Object.assign(environment, {
      claudeExecutable: async () => "/usr/local/bin/claude",
      claudeAgentInventory: async () => ({ kind: "success" as const, root: `${home}/.claude`, authoritative: true,
        startedAt: now.valueOf(), completedAt: now.valueOf(), rows: [{ id: "8e45ed2c", sessionId: id,
          kind: "background", cwd, state: "done", startedAt: now.valueOf() }] }),
    });
    const sessions = await new ClaudeProvider(inventoryEnvironment).discover();
    expect(sessions).toMatchObject([{ id, owner: "Unknown", canOpenOwner: false }]);
    expect(sessions[0]?.controlTarget).toBeUndefined();
  });

  it("rejects a retained Herdr route even when an old control target is present", async () => {
    const helper = new FakeNativeHelper();
    const row: DiscoveredProviderSession = { id: "retained-herdr", provider: "claude_code", cwd,
      owner: "Herdr", section: "ready", turnState: "ready", updatedAt: now.toISOString(),
      canOpenOwner: true, canEnterChat: true, controlTarget: { kind: "application", target: { pid: 7 } } };
    const repository = new SessionRepository([{ id: "claude_code", discover: async () => [row] }], { now: () => now });
    repository.setControls(new NativeSessionControls(helper));
    await repository.refresh();
    expect(await repository.focusSession(row.id)).toContain("Herdr");
    expect(helper.focusRequests).toEqual([]);
  });
});

describe("Claude Desktop turn reconciliation", () => {
  const user = (timestamp: string) => ({ type: "user", timestamp, message: { role: "user", content: "A prompt" } });
  const done = (timestamp: string) => ({
    type: "assistant", timestamp,
    message: { role: "assistant", stop_reason: "end_turn", content: [{ type: "text", text: "Done" }] },
  });

  it.each([false, true])("settles a completed turn without a Stop hook across Sessions and pills (chat opened: %s)", async (chatOpened) => {
    const fixture = claudeDesktopStateFixture();
    fixture.setTranscript([user("2026-08-22T07:58:00.000Z")]);
    await fixture.repository.refresh();
    fixture.hook("PostToolUse", "processing", "2026-08-22T07:58:30.000Z");
    fixture.expectPhase("working");
    if (chatOpened) {
      expect(await fixture.repository.chatOpened("claude-completion", "test-lease")).toBeUndefined();
    }

    fixture.setTranscript([
      user("2026-08-22T07:58:00.000Z"), done("2026-08-22T07:59:00.000Z"),
      { type: "custom-title", customTitle: "Renamed result" },
    ]);
    await fixture.repository.refresh();
    fixture.expectPhase("ready");
    expect(fixture.repository.current().sessions[0]?.updatedAt).toBe("2026-08-22T07:59:00.000Z");
    await fixture.repository.refresh();
    fixture.expectPhase("ready");
  });

  it.each([
    ["Notification", "notification"], ["SubagentStop", "processing"], ["FutureBookkeepingEvent", "unknown"],
  ])("keeps %s from reopening a completed parent turn", async (event, status) => {
    const fixture = claudeDesktopStateFixture();
    fixture.setTranscript([done("2026-08-22T07:59:00.000Z")]);
    await fixture.repository.refresh();
    fixture.hook("Stop", "waiting_for_input", "2026-08-22T07:59:01.000Z");
    const before = fixture.repository.current();
    fixture.hook(event, status, "2026-08-22T07:59:03.000Z");
    fixture.expectPhase("ready");
    expect(fixture.repository.current()).toEqual(before);
  });

  it("preserves a new turn and approval while the previous completion remains in the transcript", async () => {
    const fixture = claudeDesktopStateFixture();
    fixture.setTranscript([done("2026-08-22T07:57:00.000Z")]);
    await fixture.repository.refresh();
    fixture.hook("UserPromptSubmit", "processing", "2026-08-22T07:58:00.000Z");
    fixture.expectPhase("working");
    fixture.hook("Notification", "notification", "2026-08-22T07:58:01.000Z");
    await fixture.repository.refresh();
    fixture.expectPhase("working");
    fixture.hook("PermissionRequest", "waiting_for_approval", "2026-08-22T07:58:10.000Z");
    fixture.expectPhase("needs_you");
    fixture.hook("Notification", "notification", "2026-08-22T07:58:11.000Z");
    await fixture.repository.refresh();
    fixture.expectPhase("needs_you");
  });

  it("does not treat sidechain output or metadata as a new parent turn", async () => {
    const fixture = claudeDesktopStateFixture();
    fixture.setTranscript([
      done("2026-08-22T07:59:00.000Z"),
      { ...user("2026-08-22T07:59:10.000Z"), isMeta: true },
      { type: "assistant", isSidechain: true, timestamp: "2026-08-22T07:59:20.000Z", message: { stop_reason: "tool_use" } },
      { type: "last-prompt", timestamp: "2026-08-22T07:59:30.000Z" },
    ]);
    await fixture.repository.refresh();
    fixture.expectPhase("ready");
    expect(fixture.repository.current().sessions[0]?.updatedAt).toBe("2026-08-22T07:59:00.000Z");
  });

  it("drops older completion evidence when a newer main-thread record has no valid timestamp", async () => {
    const fixture = claudeDesktopStateFixture();
    fixture.setTranscript([done("2026-08-22T07:57:00.000Z"), user("invalid")]);
    await fixture.repository.refresh();
    expect(fixture.repository.current().sessions[0]?.sessionState?.turn).toBe("unknown");
  });

  it("does not let the previous Stop hook hide a newer transcript turn", async () => {
    const fixture = claudeDesktopStateFixture();
    fixture.setTranscript([done("2026-08-22T07:57:00.000Z")]);
    await fixture.repository.refresh();
    fixture.hook("Stop", "waiting_for_input", "2026-08-22T07:57:01.000Z");
    fixture.expectPhase("ready");
    fixture.setTranscript([done("2026-08-22T07:57:00.000Z"), user("2026-08-22T07:58:00.000Z")]);
    await fixture.repository.refresh();
    fixture.expectPhase("working");
    fixture.hook("SubagentStop", "processing", "2026-08-22T07:58:03.000Z");
    fixture.expectPhase("working");
  });
});

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

  it("keeps a retained Claude job searchable and opens it in its exact CLI session", async () => {
    const environment = new FixtureEnvironment();
    const sessionId = "69c752b0-5993-4a3b-a4da-2777293ac662";
    const jobId = "69c752b0";
    const executable = `${home}/.local/bin/claude`;
    environment.processRows = [
      { pid: 42, parentPID: 41, tty: "ttys001", command: `${home}/.local/share/claude/versions/2.1.285`, arguments: `${home}/.local/share/claude/versions/2.1.285 --session-id ${sessionId} --agent claude` },
      { pid: 41, parentPID: 40, command: `${home}/.local/share/claude/versions/2.1.285`, arguments: `--bg-pty-host /tmp/claude/pty/${jobId}.sock -- ${home}/.local/share/claude/versions/2.1.285 --session-id ${sessionId}` },
      { pid: 40, parentPID: 39, command: executable, arguments: `${executable} daemon run` },
      { pid: 39, parentPID: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
    ];
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
      sessionId, cwd, kind: "bg", entrypoint: "cli", status: "idle", jobId, name: jobId,
    }));
    environment.stamps.set(`${home}/.claude/sessions/42.json`, { modifiedAt: now, size: 100 });
    const repository = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    const helper = new FakeNativeHelper();
    const opened = vi.fn(async () => {});
    repository.setControls(new NativeSessionControls(
      helper, undefined, undefined, undefined, undefined, undefined, opened,
    ));
    await repository.refresh();
    repository.applyHook({ sessionId, cwd, tty: "ttys001", provider: "claude_code", event: "Stop", status: "idle", receivedAt: now.toISOString() });

    const presentation = menuPresentation(repository.current(), [], now.valueOf());
    expect(presentation.pills.some((pill) => pill.id === sessionId)).toBe(false);
    const pill = presentation.navigatorPills.find(value => value.id === sessionId);
    expect(pill).toMatchObject({ owner: "Ghostty", title: `Claude Code · ${jobId}` });
    const effects = vi.fn();
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId }, repository, effects);
    // A second Ghostty instance would take over Ghostty's AppleScript, so the
    // helper opens the attach window inside the running one.
    expect(helper.claudeAttachRequests).toEqual([{ cwd, executable, jobId }]);
    expect(opened).not.toHaveBeenCalled();
    expect(effects).not.toHaveBeenCalled();

    helper.openClaudeAttach = async () => { throw new Error("Ghostty could not open the window."); };
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId }, repository, effects);
    expect(opened).toHaveBeenCalledWith({ jobId, cwd, executable, application: "Ghostty" });
  });

  it("reopens the exact Claude background job instead of trusting an attached window", async () => {
    const environment = new FixtureEnvironment();
    const sessionId = "69c752b0-5993-4a3b-a4da-2777293ac662";
    const jobId = "69c752b0";
    const executable = `${home}/.local/bin/claude`;
    const ghostty = "/Applications/Ghostty.app/Contents/MacOS/ghostty";
    environment.processRows = [
      { pid: 42, parentPID: 41, tty: "ttys001", command: `${home}/.local/share/claude/versions/2.1.285`, arguments: `${home}/.local/share/claude/versions/2.1.285 --session-id ${sessionId} --agent claude` },
      { pid: 41, parentPID: 40, command: `${home}/.local/share/claude/versions/2.1.285`, arguments: `--bg-pty-host /tmp/claude/pty/${jobId}.sock -- ${home}/.local/share/claude/versions/2.1.285 --session-id ${sessionId}` },
      { pid: 40, parentPID: 39, command: executable, arguments: `${executable} daemon run` },
      { pid: 39, parentPID: 1, command: ghostty, arguments: "ghostty" },
      { pid: 62, parentPID: 61, tty: "ttys051", command: "claude", arguments: `claude attach ${jobId}` },
      { pid: 61, parentPID: 60, tty: "ttys051", command: "/usr/bin/login", arguments: `/usr/bin/login -flp user ${executable} attach ${jobId}` },
      { pid: 60, parentPID: 1, command: ghostty, arguments: `${ghostty} --working-directory=${cwd} -e ${executable} attach ${jobId}` },
    ];
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
      sessionId, cwd, kind: "bg", entrypoint: "cli", status: "idle", jobId, name: jobId,
    }));
    environment.stamps.set(`${home}/.claude/sessions/42.json`, { modifiedAt: now, size: 100 });
    const repository = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    const helper = new FakeNativeHelper();
    const opened = vi.fn(async () => {});
    repository.setControls(new NativeSessionControls(
      helper, undefined, undefined, undefined, undefined, undefined, opened,
    ));
    await repository.refresh();
    repository.applyHook({ sessionId, cwd, tty: "ttys001", provider: "claude_code", event: "Stop", status: "idle", receivedAt: now.toISOString() });
    const activate = () => activateMenuPill(
      { version: 1, type: "event", event: "activate_pill", sessionId }, repository, vi.fn(),
    );

    await activate();
    expect(helper.claudeAttachRequests).toEqual([{ cwd, executable, jobId }]);
    expect(helper.terminalFocusRequests).toEqual([]);
    expect(opened).not.toHaveBeenCalled();

    await activate();
    expect(helper.claudeAttachRequests).toEqual([{ cwd, executable, jobId }, { cwd, executable, jobId }]);
    expect(helper.terminalFocusRequests).toEqual([]);
    expect(opened).not.toHaveBeenCalled();
  });

  it("excludes a pre-warmed Claude daemon spare that has no job yet", async () => {
    const environment = new FixtureEnvironment();
    const sessionId = "62c740e7-e6b2-45e6-aa6c-2f064dbdfd72";
    const jobId = "62c740e7";
    const executable = `${home}/.local/bin/claude`;
    environment.processRows = [
      { pid: 42, parentPID: 41, tty: "ttys001", command: `${home}/.local/share/claude/versions/2.1.285`, arguments: `${home}/.local/share/claude/versions/2.1.285 --session-id ${sessionId} --agent claude --inherit-permission-mode auto` },
      { pid: 41, parentPID: 40, command: `${home}/.local/share/claude/versions/2.1.285`, arguments: `--bg-pty-host /tmp/claude/pty/${jobId}.sock -- ${home}/.local/share/claude/versions/2.1.285 --session-id ${sessionId}` },
      { pid: 40, parentPID: 39, command: executable, arguments: `${executable} daemon run` },
      { pid: 39, parentPID: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
    ];
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
      sessionId, cwd, kind: "bg", entrypoint: "cli", status: "idle", jobId, name: jobId, agent: "claude", spare: true,
    }));

    expect(await new ClaudeProvider(environment).discover()).toEqual([]);
  });

  it("drops hook-only sessions from pre-warmed Claude daemon spares", async () => {
    const environment = new FixtureEnvironment();
    const sessionId = "8601e33b-cc5a-4568-bccb-533338d12bfc";
    environment.processRows = [
      { pid: 42, parentPID: 41, tty: "ttys001", command: "claude", arguments: "claude bg-spare --bg-spare /tmp/claude/spare/8601e33b.claim.sock" },
      { pid: 41, parentPID: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
    ];
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({
      sessionId, cwd, kind: "bg", entrypoint: "cli", status: "idle", jobId: "8601e33b", name: "8601e33b", spare: true,
    }));
    const repository = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    const hook = { sessionId, cwd, tty: "ttys001", pid: 42, provider: "claude_code" as const, event: "SessionStart", status: "idle" };

    // The spare's first hook can arrive before discovery has read its record.
    repository.applyHook({ ...hook, receivedAt: now.toISOString() });
    await repository.refresh();
    expect(repository.current().sessions.map((session) => session.id)).not.toContain(sessionId);
    repository.applyHook({ ...hook, event: "Stop", receivedAt: new Date(now.valueOf() + 1_000).toISOString() });
    expect(repository.current().sessions.map((session) => session.id)).not.toContain(sessionId);
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

  it.each(["claude-desktop", "claude-desktop-3p"])("discovers %s conversations with real titles and a GUI click target", async (entrypoint) => {
    const environment = new FixtureEnvironment();
    const reads = vi.spyOn(environment, "readHeadTail");
    environment.processRows = [
      ...[42, 43].map(pid => ({ pid, parentPID: 8, command: `${home}/Library/Application Support/Claude-3p/claude-code/2.1.255/claude.app/Contents/MacOS/claude`, arguments: "claude" })),
      { pid: 8, parentPID: 7, command: "/Applications/Claude.app/Contents/Helpers/disclaimer", arguments: "disclaimer" },
      { pid: 7, parentPID: 1, command: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: "Claude" },
    ];
    environment.directories.set(`${home}/.claude/sessions`, ["42.json", "43.json"]);
    for (const [pid, title] of [[42, "Greeting"], [43, "Loaded skills in context"]] as const) {
      const metadata = `${home}/.claude/sessions/${pid}.json`;
      const transcript = `${home}/.claude/projects/-Users-me-Codes-agent-visor/claude-${pid}.jsonl`;
      environment.files.set(metadata, JSON.stringify({ sessionId: `claude-${pid}`, cwd, kind: "interactive", entrypoint, name: `codes-${pid}` }));
      environment.stamps.set(metadata, { modifiedAt: now, size: 100 });
      const body = [
        { type: "custom-title", customTitle: title },
        { type: "user", message: { content: "Hello" } },
        { type: "assistant", message: { content: [{ type: "text", text: "Done" }], stop_reason: "end_turn" } },
      ].map(value => JSON.stringify(value)).join("\n");
      environment.headTails.set(transcript, { head: body, tail: body });
      environment.stamps.set(transcript, { modifiedAt: now, size: body.length });
    }
    const repository = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    const focused = vi.fn(async () => {});
    repository.setControls({ focus: focused });
    await repository.refresh();
    const presentation = menuPresentation(repository.current(), [], now.valueOf());
    expect(presentation.pills.map(p => p.title).sort()).toEqual(["Greeting", "Loaded skills in context"]);
    expect(presentation.pills.every(p => p.phase === "ready")).toBe(true);
    const effects = vi.fn();
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: "claude-42" }, repository, effects);
    expect(focused).toHaveBeenCalledWith(expect.objectContaining({
      controlTarget: { kind: "application", target: { pid: 7, bundleIdentifier: "com.anthropic.claudefordesktop" } },
    }));
    expect(effects).not.toHaveBeenCalled();
    await repository.refresh();
    expect(reads).toHaveBeenCalledTimes(2);
  });

  it("does not mistake a worker or its arguments for the owning application", () => {
    expect(applicationTargetForProcess(42, [{
      pid: 42, parentPID: 1,
      command: `${home}/Library/Application Support/Claude-3p/claude-code/2.1.255/claude.app/Contents/MacOS/claude`,
      arguments: "claude --prompt /Applications/Claude.app/Contents/MacOS/Claude",
    }])).toBeUndefined();
  });

  it.each(["claude-desktop", "claude-desktop-3p"])("opens distinct %s conversations in the same app and uses their current Desktop titles", async (entrypoint) => {
    const environment = new FixtureEnvironment();
    const profile = entrypoint.endsWith("-3p") ? "Claude-3p" : "Claude";
    const root = `${home}/Library/Application Support/${profile}/claude-code-sessions`;
    const account = "11111111-1111-4111-8111-111111111111";
    const org = "22222222-2222-4222-8222-222222222222";
    const directory = `${root}/${account}/${org}`;
    const ids = ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"];
    const localIds = ["local_cccccccc-cccc-4ccc-8ccc-cccccccccccc", "local_dddddddd-dddd-4ddd-8ddd-dddddddddddd"];
    const titles = ["Renamed first conversation", "Second conversation"];
    environment.processRows = [
      ...[42, 43].map(pid => ({ pid, parentPID: 8, command: `${home}/Library/Application Support/${profile}/claude-code/2.1.255/claude.app/Contents/MacOS/claude`, arguments: "claude" })),
      { pid: 8, parentPID: 7, command: "/Applications/Claude.app/Contents/Helpers/disclaimer", arguments: "disclaimer" },
      { pid: 7, parentPID: 1, command: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: "Claude" },
    ];
    environment.directories.set(`${home}/.claude/sessions`, ["42.json", "43.json"]);
    environment.directories.set(root, [account]);
    environment.directories.set(`${root}/${account}`, [org]);
    environment.directories.set(directory, localIds.map(id => `${id}.json`));
    for (const [index, id] of ids.entries()) {
      environment.files.set(`${home}/.claude/sessions/${42 + index}.json`, JSON.stringify({ sessionId: id, cwd, kind: "interactive", entrypoint, status: "idle", name: "Old name" }));
      environment.files.set(`${directory}/${localIds[index]}.json`, JSON.stringify({ sessionId: localIds[index], cliSessionId: id, title: titles[index], isArchived: false }));
      environment.stamps.set(`${directory}/${localIds[index]}.json`, { modifiedAt: now, size: 200 });
    }
    const provider = new ClaudeProvider(environment);
    const repository = new SessionRepository([provider], { now: () => now });
    const helper = new FakeNativeHelper();
    const urls: string[] = [];
    repository.setControls(new NativeSessionControls(helper, undefined, undefined, async url => { urls.push(url); }));
    await repository.refresh();
    const effects = vi.fn();
    for (const id of ids) await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: id }, repository, effects);
    expect(urls).toEqual(localIds.map(id => `claude://claude.ai/epitaxy/${id}`));
    expect(helper.focusRequests).toEqual([]);
    expect(effects).not.toHaveBeenCalled();
    expect(menuPresentation(repository.current(), [], now.valueOf()).pills.map(p => p.title)).toEqual(titles);

    // Desktop renames and removals must not leave a cached destination behind.
    const first = `${directory}/${localIds[0]}.json`;
    environment.files.set(first, JSON.stringify({ sessionId: localIds[0], cliSessionId: ids[0], title: "Renamed again" }));
    environment.stamps.set(first, { modifiedAt: new Date(now.valueOf() + 1), size: 201 });
    expect((await provider.discover()).find(s => s.id === ids[0])?.title).toBe("Renamed again");
    environment.directories.set(directory, []);
    expect((await provider.discover()).every(s => s.controlTarget?.kind === "application")).toBe(true);
  });

  it("does not choose an archived, ambiguous, malformed, or different-profile Desktop destination", async () => {
    const environment = new FixtureEnvironment();
    const root = `${home}/Library/Application Support/Claude-3p/claude-code-sessions`;
    const account = "11111111-1111-4111-8111-111111111111";
    const org = "22222222-2222-4222-8222-222222222222";
    const directory = `${root}/${account}/${org}`;
    const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const localId = `local_${id}`;
    const file = `${directory}/${localId}.json`;
    environment.directories.set(root, [account, "../invalid"]);
    environment.directories.set(`${root}/${account}`, [org]);
    environment.directories.set(directory, [`${localId}.json`]);
    const valid = { sessionId: localId, cliSessionId: id, title: "Current name" };
    const catalog = new ClaudeDesktopSessions(environment);
    let revision = 0;
    const write = (value: unknown) => {
      environment.files.set(file, typeof value === "string" ? value : JSON.stringify(value));
      environment.stamps.set(file, { modifiedAt: new Date(now.valueOf() + revision++), size: 200 });
    };
    write(valid);
    expect((await catalog.read("Claude-3p")).get(id)?.title).toBe("Current name");
    expect((await catalog.read("Claude")).size).toBe(0);
    for (const invalid of [
      { ...valid, isArchived: true }, { ...valid, isArchived: "true" },
      { ...valid, sessionId: "local_other" }, { ...valid, cliSessionId: "../unsafe" },
      '{"sessionId":',
    ]) {
      write(invalid);
      expect((await catalog.read("Claude-3p")).size).toBe(0);
    }
    write(valid);
    const otherId = "local_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    environment.directories.set(directory, [`${localId}.json`, `${otherId}.json`]);
    environment.files.set(`${directory}/${otherId}.json`, JSON.stringify({ ...valid, sessionId: otherId }));
    environment.stamps.set(`${directory}/${otherId}.json`, { modifiedAt: now, size: 200 });
    expect((await catalog.read("Claude-3p")).size).toBe(0);
  });

  it.each([
    { status: undefined, records: [], section: "history", turnState: "unknown" },
    { status: undefined, records: [{ type: "assistant", message: { stop_reason: "end_turn" } }], section: "ready", turnState: "ready" },
    { status: undefined, records: [{ type: "assistant", message: { stop_reason: "end_turn" } }, { type: "assistant", message: { stop_reason: "tool_use", content: [{ type: "tool_use", name: "Bash" }] } }], section: "history", turnState: "unknown" },
    { status: undefined, records: [{ type: "assistant", message: { stop_reason: "end_turn" } }, { type: "user", message: { content: "Continue" } }], section: "history", turnState: "unknown" },
    { status: "busy", records: [{ type: "assistant", message: { stop_reason: "end_turn" } }], section: "working", turnState: "working" },
    { status: "idle", records: [], section: "ready", turnState: "ready" },
    { status: "unrecognized", records: [{ type: "assistant", message: { stop_reason: "end_turn" } }], section: "history", turnState: "unknown" },
  ])("keeps Claude state honest without a live status: $status / $turnState", async ({ status, records, section, turnState }) => {
    const environment = new FixtureEnvironment();
    environment.processRows = terminalProcesses.map(p => ({ ...p, tty: undefined }));
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({ sessionId: "claude-1", cwd, kind: "interactive", entrypoint: "claude-desktop-3p", status }));
    const transcript = `${home}/.claude/projects/-Users-me-Codes-agent-visor/claude-1.jsonl`;
    const body = records.map(value => JSON.stringify(value)).join("\n");
    environment.headTails.set(transcript, { head: body, tail: body });
    expect(await new ClaudeProvider(environment).discover()).toMatchObject([{ section, turnState }]);
  });

  it("does not revive a completed Claude turn when a later transcript write is partial", async () => {
    const environment = new FixtureEnvironment();
    environment.processRows = terminalProcesses.map(p => ({ ...p, tty: undefined }));
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({ sessionId: "claude-1", cwd, kind: "interactive", entrypoint: "claude-desktop" }));
    environment.headTails.set(`${home}/.claude/projects/-Users-me-Codes-agent-visor/claude-1.jsonl`, {
      head: JSON.stringify({ type: "assistant", timestamp: "2026-08-22T07:59:00.000Z", message: { stop_reason: "end_turn" } }),
      tail: '{"type":"assistant","message":{"content":',
    });
    expect(await new ClaudeProvider(environment).discover()).toMatchObject([{ section: "history", turnState: "unknown" }]);
  });

  it("does not enable terminal input from transcript completion alone", async () => {
    const environment = new FixtureEnvironment();
    environment.processRows = terminalProcesses;
    environment.directories.set(`${home}/.claude/sessions`, ["42.json"]);
    environment.files.set(`${home}/.claude/sessions/42.json`, JSON.stringify({ sessionId: "claude-1", cwd, kind: "interactive", entrypoint: "cli" }));
    const body = JSON.stringify({ type: "assistant", timestamp: "2026-08-22T07:59:00.000Z", message: { stop_reason: "end_turn" } });
    environment.headTails.set(`${home}/.claude/projects/-Users-me-Codes-agent-visor/claude-1.jsonl`, { head: body, tail: body });
    const repository = new SessionRepository([new ClaudeProvider(environment)]);
    await repository.refresh();
    expect(repository.current().sessions[0]?.sessionState?.turn).toBe("unknown");
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
      presence: { state: "open", evidence: "runtime" },
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

  it("presents a transcript-only Pi source record as Saved through the repository", async () => {
    const environment = new FixtureEnvironment();
    const root = `${home}/.pi/agent/sessions`;
    const project = `${root}/--Users-me-Codes-agent-visor--`;
    const transcript = `${project}/pi-history.jsonl`;
    const body = [
      { type: "session", id: "pi-history", cwd, timestamp: "2026-08-22T07:59:58.000Z" },
      { type: "message", id: "history-message", parentId: "root", role: "user", content: "Review history" },
    ].map((value) => JSON.stringify(value)).join("\n") + "\n";
    environment.directories.set(root, ["--Users-me-Codes-agent-visor--"]);
    environment.directories.set(project, ["pi-history.jsonl"]);
    environment.files.set(transcript, body);
    environment.headTails.set(transcript, { head: body, tail: body });
    environment.stamps.set(transcript, { modifiedAt: now, size: Buffer.byteLength(body) });
    environment.processRows = [];

    const repository = new SessionRepository([new PiProvider(environment)], { now: () => now });
    const snapshot = await repository.refresh();
    const record = snapshot.sessions[0];
    expect(record).toMatchObject({
      id: "pi-history",
      source: "Pi",
      section: "history",
      lifecycleStatus: "saved",
      presence: { state: "unknown", evidence: "catalog" },
      canOpenOwner: false,
      canEnterChat: true,
      sessionState: { conversation: "unknown", turn: "unknown", route: "unavailable" },
    });

    const presentation = menuPresentation(snapshot, [], now.valueOf());
    expect(presentation.navigatorPills).toEqual([
      expect.objectContaining({
        id: "pi-history",
        lifecycleStatus: "saved",
        inspector: expect.objectContaining({ status: "Saved" }),
        accessibilityLabel: expect.stringContaining(", Saved,"),
      }),
    ]);
    expect(presentation.pills.map(({ id }) => id)).not.toContain("pi-history");
  });

  it("keeps Pi history Saved when a mixed snapshot contains modern presence rows", async () => {
    const environment = new FixtureEnvironment();
    const root = `${home}/.pi/agent/sessions`;
    const project = `${root}/--Users-me-Codes-agent-visor--`;
    const transcript = `${project}/pi-mixed.jsonl`;
    const body = [
      { type: "session", id: "pi-mixed", cwd, timestamp: "2026-08-22T07:59:58.000Z" },
      { type: "message", id: "mixed-message", parentId: "root", role: "user", content: "Review history" },
    ].map((value) => JSON.stringify(value)).join("\n") + "\n";
    const piHistoryIDs = ["pi-mixed", ...Array.from({ length: 7 }, (_, index) => `pi-saved-${index}`)];
    environment.directories.set(root, ["--Users-me-Codes-agent-visor--"]);
    environment.directories.set(project, piHistoryIDs.map((id) => `${id}.jsonl`));
    environment.files.set(transcript, body);
    environment.headTails.set(transcript, { head: body, tail: body });
    environment.stamps.set(transcript, { modifiedAt: now, size: Buffer.byteLength(body) });
    for (const id of piHistoryIDs.slice(1)) {
      const historyBody = [
        { type: "session", id, cwd, timestamp: "2026-08-22T07:59:58.000Z" },
        { type: "message", id: `${id}-message`, parentId: "root", role: "user", content: "Saved fixture" },
      ].map((value) => JSON.stringify(value)).join("\n") + "\n";
      const historyPath = `${project}/${id}.jsonl`;
      environment.files.set(historyPath, historyBody);
      environment.headTails.set(historyPath, { head: historyBody, tail: historyBody });
      environment.stamps.set(historyPath, { modifiedAt: now, size: Buffer.byteLength(historyBody) });
    }
    environment.processRows = [];

    const modern: DiscoveredProviderSession = {
      id: "modern-open",
      provider: "claude_code",
      title: "Modern live fixture",
      subtitle: "Working",
      cwd,
      owner: "Ghostty",
      section: "working",
      updatedAt: now.toISOString(),
      canOpenOwner: true,
      canEnterChat: true,
      presence: { state: "open", evidence: "frontend", observedAt: now.toISOString() },
      conversationState: "open",
      turnState: "working",
    };

    type MixedProvider = "claude_code" | "codex" | "paseo";
    type MixedKind = "live" | "saved" | "closed" | "failed";
    type MixedRowProfile = {
      section: DiscoveredProviderSession["section"];
      canOpenOwner: boolean;
      ambientEligible: boolean;
      lifecycleStatus: NonNullable<DiscoveredProviderSession["lifecycleStatus"]>;
      presenceState: NonNullable<DiscoveredProviderSession["presence"]>["state"];
      presenceEvidence: NonNullable<DiscoveredProviderSession["presence"]>["evidence"];
      conversationState: NonNullable<DiscoveredProviderSession["conversationState"]>;
      turnState: NonNullable<DiscoveredProviderSession["turnState"]>;
      routeState: NonNullable<DiscoveredProviderSession["routeState"]>;
      failureAlert?: boolean;
    };
    const mixedProfiles: Record<MixedKind, MixedRowProfile> = {
      live: {
        section: "working",
        canOpenOwner: true,
        ambientEligible: true,
        lifecycleStatus: "working",
        presenceState: "open",
        presenceEvidence: "frontend",
        conversationState: "open",
        turnState: "working",
        routeState: "available",
      },
      saved: {
        section: "history",
        canOpenOwner: false,
        ambientEligible: false,
        lifecycleStatus: "saved",
        presenceState: "unknown",
        presenceEvidence: "catalog",
        conversationState: "unknown",
        turnState: "ready",
        routeState: "unavailable",
      },
      closed: {
        section: "history",
        canOpenOwner: false,
        ambientEligible: false,
        lifecycleStatus: "closed",
        presenceState: "closed",
        presenceEvidence: "authoritative_inventory",
        conversationState: "archived",
        turnState: "unknown",
        routeState: "unavailable",
      },
      failed: {
        section: "history",
        canOpenOwner: false,
        ambientEligible: true,
        lifecycleStatus: "unavailable",
        presenceState: "unknown",
        presenceEvidence: "unavailable",
        conversationState: "unknown",
        turnState: "unknown",
        routeState: "unavailable",
        failureAlert: true,
      },
    };
    const mixedOwners: Record<MixedProvider, string> = {
      claude_code: "Ghostty",
      codex: "Codex",
      paseo: "Paseo",
    };
    const livePresenceEvidence: Record<MixedProvider, "frontend" | "runtime"> = {
      claude_code: "frontend",
      codex: "frontend",
      paseo: "runtime",
    };
    const mixedRows = (
      provider: MixedProvider,
      count: number,
      offset: number,
      kind: MixedKind,
    ): DiscoveredProviderSession[] => {
      const profile = mixedProfiles[kind];
      return Array.from({ length: count }, (_, index) => ({
        ...modern,
        id: `${provider}-modern-${offset + index}`,
        provider,
        title: `${provider} catalog fixture ${offset + index}`,
        subtitle: `${provider} fixture remains searchable`,
        sourceProfile: `fixture-${provider}`,
        project: `fixture-project-${offset + index}`,
        cwd: `${home}/Codes/fixture-${offset + index}`,
        owner: mixedOwners[provider],
        section: profile.section,
        canOpenOwner: profile.canOpenOwner,
        ambientEligible: profile.ambientEligible,
        lifecycleStatus: profile.lifecycleStatus,
        presence: {
          state: profile.presenceState,
          evidence: kind === "live" ? livePresenceEvidence[provider] : profile.presenceEvidence,
          observedAt: now.toISOString(),
        },
        sessionState: {
          conversation: profile.conversationState,
          turn: profile.turnState,
          route: profile.routeState,
        },
        ...(profile.failureAlert ? { failureAlert: true } : {}),
      }));
    };
    // Keep the fixture close to the captured merged catalog size: eight real
    // Pi transcripts plus 151 mixed modern rows. The rows intentionally include
    // quiet catalog evidence, verified live evidence, confirmed closed records,
    // and one genuine failed observation so the healthy/failure split is tested
    // at realistic density instead of hiding in a tiny all-live sample.
    const claudeRows = [
      modern,
      ...mixedRows("claude_code", 34, 0, "live"),
      ...mixedRows("claude_code", 20, 34, "saved"),
      ...mixedRows("claude_code", 5, 54, "closed"),
    ];
    const codexRows = [
      ...mixedRows("codex", 26, 0, "live"),
      ...mixedRows("codex", 18, 26, "saved"),
      ...mixedRows("codex", 5, 44, "closed"),
      ...mixedRows("codex", 1, 49, "failed"),
    ];
    const paseoRows = [
      ...mixedRows("paseo", 20, 0, "live"),
      ...mixedRows("paseo", 21, 20, "saved"),
    ];
    const repository = new SessionRepository([
      new PiProvider(environment),
      { id: "claude_code", discover: async () => claudeRows },
      { id: "codex", discover: async () => codexRows },
      { id: "paseo", discover: async () => paseoRows },
    ], { now: () => now });
    const snapshot = await repository.refresh();
    expect(snapshot.sessions).toHaveLength(159);
    expect(snapshot.sessions.filter(({ presence }) => presence?.state === "unknown"
      && presence.evidence === "catalog")).toHaveLength(67);
    expect(snapshot.sessions.filter(({ presence }) => presence?.state === "unknown"
      && presence.evidence === "unavailable")).toHaveLength(1);
    expect(snapshot.sessions.filter(({ presence }) => presence?.state === "closed")).toHaveLength(10);
    const pi = snapshot.sessions.find(({ id }) => id === "pi-mixed");
    expect(pi).toMatchObject({
      presence: { state: "unknown", evidence: "catalog" },
      lifecycleStatus: "saved",
    });
    expect(snapshot.sessions.find(({ id }) => id === "codex-modern-0")).toMatchObject({
      sourceProfile: "fixture-codex",
      presence: { state: "open", evidence: "frontend" },
    });
    const presentation = menuPresentation(snapshot, [], now.valueOf());
    const saved = presentation.navigatorPills.filter(({ lifecycleStatus }) => lifecycleStatus === "saved");
    expect(saved).toHaveLength(67);
    expect(saved.every(({ inspector }) => !inspector.detailRows.some(({ label }) => label === "Presence"))).toBe(true);
    expect(saved.every(({ id }) => !presentation.pills.some((pill) => pill.id === id))).toBe(true);
    expect(presentation.navigatorPills.find(({ id }) => id === "pi-mixed"))
      .toMatchObject({ lifecycleStatus: "saved", inspector: { status: "Saved" } });
    expect(presentation.pills.map(({ id }) => id)).not.toContain("pi-mixed");
    expect(presentation.navigatorPills.find(({ id }) => id === "codex-modern-49"))
      .toMatchObject({ lifecycleStatus: "unavailable", inspector: { status: "Status unavailable" } });
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
    let settingsReads = 0;
    environment.codexSettingsCatalog = async () => {
      settingsReads += 1;
      return { models: [], permissionProfiles: [] };
    };
    const provider = new CodexProvider(environment);
    const sessions = await provider.discover();
    expect(settingsReads).toBe(0);
    await provider.chatSettings(sessions[0]!);
    await provider.chatSettings(sessions[0]!);
    expect(settingsReads).toBe(1);

    expect(sessions[0]).toMatchObject({
      id: "codex-1",
      title: "Codex title",
      provider: "codex",
      sessionClass: "interactive",
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
    expect((await new CodexProvider(environment).discover())[0]?.canEnterChat).toBe(true);
  });

  it("bounds and expires the lazy Codex settings CWD cache", async () => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(1_000);
    try {
      const environment = new FixtureEnvironment();
      let settingsReads = 0;
      const catalog = { models: [], permissionProfiles: [] };
      environment.codexSettingsCatalog = async () => {
        settingsReads += 1;
        return catalog;
      };
      const provider = new CodexProvider(environment);
      const session = (cwd: string): DiscoveredProviderSession => ({
        id: `codex-${cwd}`,
        provider: "codex",
        cwd,
        owner: "Codex",
        section: "history",
        updatedAt: now.toISOString(),
        canOpenOwner: true,
        canEnterChat: true,
        chatPath: `${cwd}/rollout.jsonl`,
        messageTransport: "codex_app_server",
      });

      await provider.chatSettings(session(`${home}/Codes/expired`));
      clock.mockReturnValue(61_001);
      await provider.chatSettings(session(`${home}/Codes/next`));
      await provider.chatSettings(session(`${home}/Codes/expired`));
      expect(settingsReads).toBe(3);

      clock.mockReturnValue(62_000);
      for (let index = 0; index < 65; index += 1) {
        await provider.chatSettings(session(`${home}/Codes/cache-${index}`));
      }
      expect(settingsReads).toBe(68);
      await provider.chatSettings(session(`${home}/Codes/cache-0`));
      expect(settingsReads).toBe(69);
    } finally {
      clock.mockRestore();
    }
  });

  it.each([120_000, 121_000, 720_000, 3_600_000, 24 * 3_600_000, 41 * 3_600_000])(
    "keeps an old unarchived Codex conversation distinct from archival after %i ms idle",
    async (ageMs) => {
      const directory = mkdtempSync(path.join(tmpdir(), "codex-history-chat-"));
      const rollout = path.join(directory, "rollout.jsonl");
      writeFileSync(rollout, `${JSON.stringify({
        type: "response_item",
        payload: {
          type: "message", id: "history-user", role: "user",
          content: [{ type: "input_text", text: "Existing conversation" }],
        },
      })}\n`);
      try {
        const environment = new FixtureEnvironment();
        const database = `${home}/.codex/sqlite/state_5.sqlite`;
        const updatedAt = new Date(now.valueOf() - ageMs);
        environment.stamps.set(database, { modifiedAt: now, size: 100 });
        environment.stamps.set(rollout, { modifiedAt: updatedAt, size: 100 });
        environment.sqliteRows.set(database, [{
          id: "history-codex", rollout_path: rollout, cwd, title: "Codex history",
          updated_at: updatedAt.valueOf() / 1_000, archived: 0, source: "vscode",
        }]);
        const repository = new SessionRepository([new CodexProvider(environment)], {
          now: () => now,
        });

        const snapshot = await repository.refresh();
        expect(snapshot.sessions).toMatchObject([{
          id: "history-codex", section: "history", canOpenOwner: true, canEnterChat: true,
        }]);
        const page = await repository.chatPage("history-codex");
        expect(page.items).toMatchObject([{ kind: "user", text: "Existing conversation" }]);
        expect(page.capabilities).toMatchObject({
          canSendText: false, canSendImages: false, canCancel: false,
          canApprove: false, canAnswer: false,
          unavailableReason: "provider_unavailable",
          readOnlyReason: "The conversation status is unavailable. Chat is read only until detection recovers.",
        });
        expect((await repository.refresh()).sessions).toEqual(snapshot.sessions);

        environment.stamps.delete(rollout);
        expect((await repository.refresh()).sessions).toEqual([]);
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    },
  );

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
      id: "ready-codex", section: "history", canOpenOwner: true, canEnterChat: true,
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
      id: "ready-codex", section: "history", canOpenOwner: true, canEnterChat: true,
    }]);

    environment.stamps.delete(rollout);
    expect((await repository.refresh()).sessions).toEqual([]);
  });

  it("keeps unarchived Codex conversations beyond the observed window", async () => {
    const environment = new FixtureEnvironment();
    const database = `${home}/.codex/sqlite/state_5.sqlite`;
    const recentRollout = `${home}/.codex/sessions/recent.jsonl`;
    const oldRollout = `${home}/.codex/sessions/old.jsonl`;
    environment.stamps.set(database, { modifiedAt: now, size: 100 });
    environment.stamps.set(recentRollout, {
      modifiedAt: new Date(now.valueOf() - 41 * 60 * 60 * 1_000),
      size: 100,
    });
    environment.stamps.set(oldRollout, {
      modifiedAt: new Date(now.valueOf() - 43 * 60 * 60 * 1_000),
      size: 100,
    });
    environment.sqliteRows.set(database, [
      {
        id: "recent-codex",
        rollout_path: recentRollout,
        cwd,
        title: "Recent Codex",
        updated_at: Math.floor((now.valueOf() - 41 * 60 * 60 * 1_000) / 1_000),
        archived: 0,
        source: "vscode",
      },
      {
        id: "old-codex",
        rollout_path: oldRollout,
        cwd,
        title: "Old Codex",
        updated_at: Math.floor((now.valueOf() - 43 * 60 * 60 * 1_000) / 1_000),
        archived: 0,
        source: "vscode",
      },
    ]);

    const sessions = await new CodexProvider(environment).discover();

    expect(sessions.map(({ id }) => id)).toEqual(["recent-codex", "old-codex"]);
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
      sessionClass: "automation",
      canOpenOwner: true,
      controlTarget: { kind: "url", url: "codex://threads/codex-exec" },
    }]);
  });

  it("classifies a live Codex CLI row as terminal-owned", async () => {
    const environment = new FixtureEnvironment();
    const database = `${home}/.codex/sqlite/state_5.sqlite`;
    const rollout = `${home}/.codex/sessions/2026/08/22/rollout-codex-cli.jsonl`;
    environment.stamps.set(database, { modifiedAt: now, size: 100 });
    environment.stamps.set(rollout, { modifiedAt: now, size: 100 });
    environment.sqliteRows.set(database, [{
      id: "codex-cli",
      rollout_path: rollout,
      cwd,
      title: "CLI task",
      updated_at: Math.floor(now.valueOf() / 1_000),
      archived: 0,
      source: "cli",
    }]);
    environment.processRows = [
      { pid: 60, parentPID: 7, tty: "ttys002", command: "/usr/local/bin/codex", arguments: "codex" },
      { pid: 7, parentPID: 1, tty: "ttys002", command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
    ];
    environment.cwdByPID.set(60, cwd);
    environment.starts.set(60, new Date("2026-08-22T07:59:00.000Z"));

    const provider = new CodexProvider(environment);
    provider.noteHook({ sessionId: "codex-cli", provider: "codex", cwd, pid: 60, tty: "/dev/ttys002",
      event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
    const sessions = await provider.discover();

    expect(sessions).toMatchObject([{
      id: "codex-cli",
      sessionClass: "terminal",
      owner: "Ghostty",
      controlTarget: { kind: "terminal", target: { tty: "ttys002" } },
    }]);
  });

  it.each([true, false])("routes a Cursor history pill only to an existing workspace (exists: %s)", async (exists) => {
    const environment = new FixtureEnvironment();
    const projectKey = "Users-me-Codes-agent-visor";
    const sessionsRoot = `${home}/.cursor/projects/${projectKey}/agent-transcripts`;
    const transcript = `${sessionsRoot}/cursor-history/cursor-history.jsonl`;
    environment.directories.set(`${home}/.cursor/projects`, [projectKey]);
    environment.directories.set(home, ["Codes"]);
    environment.directories.set(`${home}/Codes`, ["agent-visor"]);
    if (exists) environment.directories.set(cwd, []);
    environment.directories.set(sessionsRoot, ["cursor-history"]);
    environment.stamps.set(transcript, { modifiedAt: now, size: 100 });
    const body = JSON.stringify({ role: "user", message: { content: [{ type: "text", text: cwd }] } });
    environment.headTails.set(transcript, { head: body, tail: body });
    const opened = vi.fn(async () => {});
    const repository = new SessionRepository([new CursorProvider(environment)], { now: () => now });
    repository.setControls(new NativeSessionControls(
      new FakeNativeHelper(), undefined, undefined, undefined, undefined, undefined, undefined, opened,
    ));
    await repository.refresh();
    const snapshot = repository.current();
    expect(snapshot.sessions[0]).toMatchObject({ canOpenOwner: exists, canEnterChat: true });
    const presentation = menuPresentation(snapshot, [], now.valueOf());
    const effects = vi.fn();
    if (exists) {
      await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: "cursor-history" }, repository, effects);
      expect(opened).toHaveBeenCalledWith(cwd);
      expect(effects).not.toHaveBeenCalled();
      expect(presentation.pills[0]).toMatchObject({ owner: "Cursor", subtitle: "Cursor history · Opens workspace" });
    } else {
      expect(presentation.pills).toEqual([]);
      expect(presentation.navigatorPills).toHaveLength(1);
      await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: "cursor-history" }, repository, effects);
      expect(effects).toHaveBeenCalledWith({ type: "native_action", action: "open_chat", sessionId: "cursor-history" });
      expect(opened).not.toHaveBeenCalled();
    }
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
