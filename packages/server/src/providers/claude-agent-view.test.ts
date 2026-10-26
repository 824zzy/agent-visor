import { mkdtempSync, rmSync } from "node:fs";
import path from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import type { ProcessRecord, ProviderEnvironment, FileStamp, GhosttyTerminalView } from "./environment.js";
import {
  ClaudeAgentInventory,
  type ClaudeAgentInventoryFailure,
  type ClaudeAgentInventoryResult,
  type ClaudeAgentInventoryRow,
  type ClaudeAgentInventorySuccess,
} from "./claude-agent-inventory.js";
import { ClaudeProvider } from "./claude.js";
import { processInstanceToken } from "./shared.js";
import { activateMenuPill, menuPresentation } from "../menu.js";
import { FakeNativeHelper } from "../native-helper.js";
import { NativeSessionControls } from "../session-controls.js";
import { SessionRepository } from "../sessions.js";
import { PaseoProvider } from "./paseo.js";
import { alfredResults } from "../alfred.js";
import type { ProcessResult } from "../machine.js";

const home = "/Users/me";
const cwd = home + "/Codes/agent-visor";
const now = new Date("2026-08-22T08:00:00.000Z");
const nowMs = now.valueOf();
const ghosttyInstance = processInstanceToken(7, now)!;
const executable = home + "/.local/bin/claude";
const managerID = "fa6ddf2e-efba-45cc-90c2-579e461c3ffa";
const ccID = "8e45ed2c-cd3b-4140-a8da-4614085a3536";
const blockedID = "64b38993-2cbf-4720-a3b3-1b2b402ad5b7";

class FixtureEnvironment implements ProviderEnvironment {
  readonly home = home;
  readonly observedWindowMs = 42 * 60 * 60 * 1_000;
  processRows: ProcessRecord[] = [];
  directories = new Map<string, string[]>();
  files = new Map<string, string>();
  stamps = new Map<string, FileStamp>();
  headTails = new Map<string, { head: string; tail: string }>();
  starts = new Map<number, Date>();
  inventory: ClaudeAgentInventoryResult = inventorySuccess([]);
  clock = now;
  executable: string | undefined = executable;
  ghosttyViews: GhosttyTerminalView[] = [];

  now(): Date { return this.clock; }
  async processes(): Promise<ProcessRecord[]> { return this.processRows; }
  async cwd(_pid: number): Promise<string | undefined> { return undefined; }
  async processStartedAt(pid: number): Promise<Date | undefined> { return this.starts.get(pid); }
  async directory(directory: string): Promise<string[]> { return this.directories.get(directory) ?? []; }
  async isDirectory(directory: string): Promise<boolean> { return this.directories.has(directory); }
  async stamp(file: string): Promise<FileStamp | undefined> { return this.stamps.get(file); }
  async read(file: string): Promise<string | undefined> { return this.files.get(file); }
  async readHeadTail(file: string): Promise<{ head: string; tail: string } | undefined> {
    return this.headTails.get(file);
  }
  async scanLinePrefixes(
    _file: string,
    _prefixBytes: number,
    _visit: (line: string) => void,
    startAt = 0,
  ): Promise<number> { return startAt; }
  async sqlite(_database: string, _sql: string): Promise<unknown[]> { return []; }
  async claudeAgentInventory(): Promise<ClaudeAgentInventoryResult> { return this.inventory; }
  async claudeExecutable(): Promise<string | undefined> { return this.executable; }
  ghosttyTerminalViews: ProviderEnvironment["ghosttyTerminalViews"] = async () => this.ghosttyViews;
}

function inventorySuccess(
  rows: readonly ClaudeAgentInventoryRow[],
  authoritative = true,
  completedAt = nowMs,
): ClaudeAgentInventorySuccess {
  return {
    kind: "success",
    root: path.join(home, ".claude"),
    rows,
    startedAt: completedAt,
    completedAt,
    freshness: authoritative ? "fresh" : "stale",
    authoritative,
  };
}

function inventoryFailure(lastGood: ClaudeAgentInventorySuccess): ClaudeAgentInventoryFailure {
  return {
    kind: "failure",
    root: path.join(home, ".claude"),
    reason: "process_failed",
    startedAt: lastGood.completedAt + 1,
    completedAt: lastGood.completedAt + 1,
    lastGood,
  };
}

function backgroundRow(
  id: string,
  sessionId: string,
  state: string,
  overrides: Partial<ClaudeAgentInventoryRow> = {},
): ClaudeAgentInventoryRow {
  return {
    id,
    sessionId,
    kind: "background",
    cwd,
    startedAt: nowMs,
    state,
    status: "idle",
    ...overrides,
  };
}

function addProcess(
  environment: FixtureEnvironment,
  pid: number,
  command: string,
  arguments_ = "claude",
): void {
  environment.processRows.push({
    pid,
    parentPID: 7,
    tty: "ttys001",
    command,
    arguments: arguments_,
  });
  environment.starts.set(pid, now);
  if (!environment.processRows.some((process) => process.pid === 7)) {
    environment.starts.set(7, now);
    environment.processRows.push({
      pid: 7,
      parentPID: 1,
      command: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
      arguments: "ghostty",
    });
  }
}

function addMetadata(
  environment: FixtureEnvironment,
  pid: number,
  metadata: Record<string, unknown>,
): void {
  const directory = path.join(home, ".claude", "sessions");
  const filename = String(pid) + ".json";
  const file = path.join(directory, filename);
  const raw = JSON.stringify(metadata);
  const existing = environment.directories.get(directory) ?? [];
  environment.directories.set(directory, [...existing, filename]);
  environment.files.set(file, raw);
  environment.stamps.set(file, { modifiedAt: now, size: raw.length });
}

function repository(environment: FixtureEnvironment): SessionRepository {
  return new SessionRepository([new ClaudeProvider(environment)], { now: () => environment.now() });
}

function completedIdleFixture() {
  const environment = new FixtureEnvironment();
  addProcess(environment, 900, executable);
  addMetadata(environment, 900, {
    sessionId: managerID, cwd, kind: "interactive", status: "idle", parkedJobId: "8e45ed2c",
  });
  const row = backgroundRow("8e45ed2c", ccID, "working", { name: "ccx-thinking-block-sneha", status: "idle" });
  environment.inventory = inventorySuccess([row]);
  environment.ghosttyViews = [{ applicationPID: 7, processStartToken: ghosttyInstance,
    terminalId: "current", title: row.name!, cwd, viewMode: "conversation" }];
  const transcript = home + "/.claude/projects/-Users-me-Codes-agent-visor/" + ccID + ".jsonl";
  const completedAt = new Date(nowMs - 40 * 60_000).toISOString();
  const tail = JSON.stringify({ type: "system", subtype: "turn_duration", timestamp: completedAt });
  environment.headTails.set(transcript, { head: "", tail });
  environment.stamps.set(transcript, { size: tail.length, modifiedAt: new Date(completedAt) });
  return { environment, row, transcript, tail, completedAt };
}

function cachedResumeFixture() {
  const environment = new FixtureEnvironment();
  addProcess(environment, 900, executable);
  addMetadata(environment, 900, { sessionId: ccID, cwd, kind: "interactive", status: "idle", name: "ccx-thinking-block-sneha" });
  const row = backgroundRow("64b38993", blockedID, "stopped", { name: "ccx-thinking-block-sneha" });
  const lineagePath = path.join(home, ".claude/jobs/64b38993/state.json");
  const lineage = { state: "stopped", sessionId: blockedID, resumeSessionId: ccID, interactiveLineage: true, cwd };
  environment.files.set(lineagePath, JSON.stringify(lineage));
  const success: ProcessResult = { status: "success", stdout: JSON.stringify([row]), stderr: "", exitCode: 0 };
  let command: ProcessResult | Promise<ProcessResult> = success;
  const cache = new ClaudeAgentInventory({ home, configDir: "", now: () => environment.now(),
    resolveExecutable: async () => executable, run: async () => command });
  environment.claudeAgentInventory = () => cache.read();
  return { environment, cache, success, source: repository(environment), lineagePath, lineage,
    setCommand(value: ProcessResult | Promise<ProcessResult>) { command = value; } };
}

describe("Claude agent-view integration", () => {
  it("publishes frontend presence for a uniquely matched Claude terminal and closed presence for an authoritative stop", async () => {
    const fixture = completedIdleFixture();
    const source = repository(fixture.environment);
    const live = await source.refresh();
    expect(live.sessions[0]).toMatchObject({
      id: ccID,
      presence: {
        state: "open",
        evidence: "frontend",
      },
      sessionState: { conversation: "open", turn: "ready" },
    });

    fixture.environment.processRows = [];
    fixture.environment.directories.set(path.join(home, ".claude", "sessions"), []);
    fixture.environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "stopped", { name: "ccx-thinking-block-sneha" }),
    ]);
    const closed = await source.refresh();
    expect(closed.sessions[0]).toMatchObject({
      id: ccID,
      presence: {
        state: "closed",
        evidence: "authoritative_inventory",
      },
    });
    expect(menuPresentation(closed, [], fixture.environment.clock.valueOf()).pills).toEqual([]);
  });

  it("keeps a retained unavailable row when real Claude discovery returns empty during an inventory outage", async () => {
    const directory = mkdtempSync(path.join(tmpdir(), "agent-visor-claude-inventory-outage-"));
    const historyPath = path.join(directory, "retained-history.json");
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, {
      sessionId: ccID,
      cwd,
      kind: "interactive",
      status: "idle",
    });
    try {
      const active = new SessionRepository([new ClaudeProvider(environment)], { retainedHistoryPath: historyPath });
      expect((await active.refresh()).sessions).toContainEqual(expect.objectContaining({ id: ccID }));

      environment.inventory = inventoryFailure(inventorySuccess([]));
      const afterRestart = new SessionRepository([new ClaudeProvider(environment)], { retainedHistoryPath: historyPath });
      expect((await afterRestart.refresh()).sessions).toContainEqual(expect.objectContaining({ id: ccID }));

      environment.processRows = [];
      expect((await afterRestart.refresh()).sessions).toContainEqual(expect.objectContaining({
        id: ccID,
        presence: expect.objectContaining({ state: "unknown", evidence: "unavailable" }),
        lifecycleStatus: "unavailable",
        ambientEligible: true,
      }));
      expect(afterRestart.historyPage()).toMatchObject({
        total: 1,
        sessions: [expect.objectContaining({
          id: ccID,
          section: "history",
          subtitle: "Terminal state unavailable",
        })],
      });
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("keeps one resumed conversation across pending inventory refresh cycles", async () => {
    const f = cachedResumeFixture();
    expect(alfredResults(await f.source.refresh(), "ccx-thinking-block-sneha").items.map(item => item.uid)).toEqual([ccID]);
    let complete!: (result: ProcessResult) => void;
    f.setCommand(new Promise(resolve => { complete = resolve; }));
    for (let cycle = 0; cycle < 2; cycle++) {
      f.environment.clock = new Date(f.environment.clock.valueOf() + 3_100);
      const snapshot = await f.source.refresh();
      expect(alfredResults(snapshot, "ccx-thinking-block-sneha").items.map(item => item.uid)).toEqual([ccID]);
      expect(menuPresentation(snapshot, [], f.environment.clock.valueOf()).pills.map(pill => pill.id)).toEqual([ccID]);
    }
    expect(f.source.applyHook({ sessionId: blockedID, provider: "claude_code", cwd,
      event: "Stop", status: "idle", receivedAt: f.environment.clock.toISOString() }).sessions.map(session => session.id)).toEqual([ccID]);
    const waiting = f.source.applyHook({ sessionId: ccID, provider: "claude_code", cwd,
      event: "PreToolUse", status: "waiting_for_approval", receivedAt: f.environment.clock.toISOString(),
      tool: "AskUserQuestion", toolUseId: "cached-question", expectsResponse: true,
      toolInput: { questions: [{ question: "Continue?" }] } });
    expect(waiting.sessions).toMatchObject([{ id: ccID, section: "needs_you" }]);
    const refreshed = f.cache.refreshNow();
    complete(f.success);
    await refreshed;
    expect(alfredResults(await f.source.refresh(), "ccx-thinking-block-sneha").items.map(item => item.uid)).toEqual([ccID]);
  });

  it.each(["failed-read", "unsupported-read", "expired-authority", "changed-lineage", "missing-lineage",
    "restarted-job", "missing-route", "parked-overview", "unverified-process"])("rechecks resume identity during a cached refresh (%s)", async reason => {
    const f = cachedResumeFixture();
    expect((await f.source.refresh()).sessions.map(session => session.id)).toEqual([ccID]);
    let complete!: (result: ProcessResult) => void;
    f.setCommand(new Promise(resolve => { complete = resolve; }));
    f.environment.clock = new Date(nowMs + 3_100);
    expect((await f.source.refresh()).sessions.map(session => session.id)).toEqual([ccID]);
    const pending = f.cache.refreshNow();
    try {
      if (reason === "failed-read" || reason === "unsupported-read") {
        complete({ status: "failed", stdout: "", stderr: reason === "unsupported-read" ? "unknown command 'agents'" : "failed", exitCode: 1 });
        await pending;
      }
      if (reason === "expired-authority") f.environment.clock = new Date(nowMs + 31_000);
      if (reason === "changed-lineage") f.environment.files.set(f.lineagePath,
        JSON.stringify({ ...f.lineage, resumeSessionId: managerID }));
      if (reason === "missing-lineage") f.environment.files.delete(f.lineagePath);
      if (reason === "restarted-job") f.environment.files.set(f.lineagePath,
        JSON.stringify({ ...f.lineage, state: "working" }));
      if (reason === "missing-route") f.environment.processRows = [];
      if (reason === "parked-overview") f.environment.files.set(path.join(home, ".claude/sessions/900.json"),
        JSON.stringify({ sessionId: ccID, cwd, kind: "interactive", status: "idle", parkedJobId: "64b38993" }));
      if (reason === "unverified-process") f.environment.starts.delete(900);
      const snapshot = await f.source.refresh();
      expect(alfredResults(snapshot, "ccx-thinking-block-sneha").items.map(item => item.uid)).toContain(blockedID);
      if (reason === "parked-overview") expect(menuPresentation(snapshot, [], f.environment.clock.valueOf()).pills).toEqual([]);
    } finally {
      complete(f.success);
      await pending;
    }
  });

  it("recovers canonical resume identity after a failed cache refresh succeeds", async () => {
    const f = cachedResumeFixture();
    expect((await f.source.refresh()).sessions.map(session => session.id)).toEqual([ccID]);
    f.setCommand({ status: "failed", stdout: "", stderr: "failed", exitCode: 1 });
    await f.cache.refreshNow();
    expect((await f.source.refresh()).sessions.map(session => session.id).sort()).toEqual([ccID, blockedID].sort());
    f.setCommand(f.success);
    await f.cache.refreshNow();
    expect((await f.source.refresh()).sessions.map(session => session.id)).toEqual([ccID]);
  });

  it("publishes only the verified conversation when a stopped job explicitly resumes it", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, { sessionId: ccID, cwd, kind: "interactive", status: "idle", name: "ccx-thinking-block-sneha" });
    environment.inventory = inventorySuccess([backgroundRow("64b38993", blockedID, "stopped", { name: "ccx-thinking-block-sneha" })]);
    environment.files.set(path.join(home, ".claude/jobs/64b38993/state.json"), JSON.stringify({
      state: "stopped", sessionId: blockedID, resumeSessionId: ccID, interactiveLineage: true, cwd,
    }));
    const source = repository(environment);
    const snapshot = await source.refresh();
    expect(alfredResults(snapshot, "ccx-thinking-block-sneha").items.map(item => item.uid)).toEqual([ccID]);
    expect(menuPresentation(snapshot, [], nowMs).pills.map(pill => pill.id)).toEqual([ccID]);
  });

  it("does not suppress the live conversation when a job's resume ID equals its own ID", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, { sessionId: ccID, cwd, kind: "interactive", status: "idle", name: "Current conversation" });
    environment.inventory = inventorySuccess([backgroundRow("8e45ed2c", ccID, "stopped", { name: "Current conversation" })]);
    environment.files.set(path.join(home, ".claude/jobs/8e45ed2c/state.json"), JSON.stringify({
      state: "stopped", sessionId: ccID, resumeSessionId: ccID, interactiveLineage: true, cwd,
    }));
    const source = repository(environment);
    const snapshot = await source.refresh();
    expect(snapshot.sessions.map(session => session.id)).toEqual([ccID]);
    expect(alfredResults(snapshot, "Current conversation").items[0]).toMatchObject({ uid: ccID, valid: true });
    const waiting = source.applyHook({ sessionId: ccID, provider: "claude_code", cwd,
      event: "PreToolUse", status: "waiting_for_approval", receivedAt: now.toISOString(),
      tool: "AskUserQuestion", toolUseId: "current-question", expectsResponse: true,
      toolInput: { questions: [{ question: "Continue?" }] } });
    expect(waiting.sessions[0]?.section).toBe("needs_you");
  });

  it.each(["missing-lineage", "invalid-json", "other-job", "other-resume", "other-cwd", "no-interactive-lineage",
    "saved-job-running", "inventory-job-running", "busy-inventory", "waiting-inventory", "stale-inventory", "failed-inventory", "live-worker", "unverified-terminal",
    "application-only", "parked-overview", "missing-process"])("retains the historical job without a verified distinct resume relationship (%s)", async reason => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    const metadata = { sessionId: ccID, cwd, kind: "interactive", status: "idle", name: "ccx-thinking-block-sneha",
      ...(reason === "parked-overview" ? { parkedJobId: "64b38993" } : {}) };
    addMetadata(environment, 900, metadata);
    const row = backgroundRow("64b38993", blockedID, reason === "inventory-job-running" ? "working" : "stopped",
      { name: "ccx-thinking-block-sneha", status: reason === "busy-inventory" ? "busy" : "idle",
        ...(reason === "waiting-inventory" ? { waitingFor: "approval" } : {}) });
    const inventory = inventorySuccess([row], reason !== "stale-inventory");
    environment.inventory = reason === "failed-inventory" ? inventoryFailure(inventory) : inventory;
    const saved = { state: reason === "saved-job-running" ? "working" : "stopped",
      sessionId: reason === "other-job" ? managerID : blockedID,
      resumeSessionId: reason === "other-resume" ? managerID : ccID,
      interactiveLineage: reason !== "no-interactive-lineage", cwd: reason === "other-cwd" ? home + "/Other" : cwd };
    if (reason !== "missing-lineage") environment.files.set(path.join(home, ".claude/jobs/64b38993/state.json"),
      reason === "invalid-json" ? "{broken" : JSON.stringify(saved));
    if (reason === "live-worker") {
      addProcess(environment, 901, executable);
      addMetadata(environment, 901, { sessionId: blockedID, cwd, kind: "bg", jobId: "64b38993", status: "busy" });
    }
    if (reason === "unverified-terminal") environment.starts.delete(900);
    if (reason === "application-only") Object.assign(environment.processRows.find(process => process.pid === 7)!, {
      command: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: "Claude" });
    if (reason === "missing-process") environment.processRows = [];
    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions.map(session => session.id)).toContain(blockedID);
    if (!["parked-overview", "missing-process"].includes(reason)) {
      expect(alfredResults(snapshot, "ccx-thinking-block-sneha").items.map(item => item.uid).sort())
        .toEqual([ccID, blockedID].sort());
    }
    if (reason === "parked-overview") expect(menuPresentation(snapshot, [], nowMs).pills).toEqual([]);
  });

  it("reconciles resume lineage across hooks, closed terminals, and provider restart", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, { sessionId: ccID, cwd, kind: "interactive", status: "idle", name: "New title" });
    environment.inventory = inventorySuccess([backgroundRow("64b38993", blockedID, "stopped", { name: "Old title" })]);
    environment.files.set(path.join(home, ".claude/jobs/64b38993/state.json"), JSON.stringify({
      state: "stopped", sessionId: blockedID, resumeSessionId: ccID, interactiveLineage: true, cwd,
    }));
    const source = repository(environment);
    expect((await source.refresh()).sessions.map(session => session.id)).toEqual([ccID]);
    expect(source.applyHook({ sessionId: blockedID, provider: "claude_code", cwd,
      event: "Stop", status: "idle", receivedAt: now.toISOString() }).sessions.map(session => session.id)).toEqual([ccID]);
    const waiting = source.applyHook({ sessionId: ccID, provider: "claude_code", cwd,
      event: "PreToolUse", status: "waiting_for_approval", receivedAt: now.toISOString(),
      tool: "AskUserQuestion", toolUseId: "resume-question", expectsResponse: true,
      toolInput: { questions: [{ question: "Continue?" }] } });
    expect(waiting.sessions).toMatchObject([{ id: ccID, section: "needs_you" }]);
    environment.processRows = [];
    expect((await source.refresh()).sessions.find(session => session.id === blockedID)?.section).toBe("history");
    addProcess(environment, 900, executable);
    expect((await repository(environment).refresh()).sessions.map(session => session.id)).toEqual([ccID]);
  });

  it("opens a prepared interactive conversation while unrelated inventory reads are unavailable", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, { sessionId: ccID, cwd, kind: "interactive", status: "idle", name: "Direct conversation" });
    const source = repository(environment);
    const helper = new FakeNativeHelper();
    source.setControls(new NativeSessionControls(helper));
    await source.refresh();
    await Promise.resolve();
    expect(helper.terminalPreparationRequests).toMatchObject([{ pid: 900, tty: "ttys001", cwd }]);
    expect(helper.terminalFocusRequests).toEqual([]);

    // The clicked process metadata remains readable. A list-wide filesystem
    // outage must not hold up an already discovered exact terminal route.
    environment.directory = async () => { throw new Error("Unrelated inventory unavailable"); };
    const effects: unknown[] = [];
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: ccID }, source,
      effect => effects.push(effect));
    expect(effects).toEqual([]);
    expect(helper.terminalFocusRequests).toMatchObject([{ pid: 900, tty: "ttys001", cwd }]);
  });

  it.each([
    { state: "blocked", status: undefined },
    { state: "working", status: undefined },
    { state: "blocked", status: "future-status" },
    { state: "blocked", status: "exited" },
  ])("moves a stale unverified $state/$status job to History without forgetting its conversation", async ({ state, status }) => {
    const environment = new FixtureEnvironment();
    environment.inventory = inventorySuccess([backgroundRow("8e45ed2c", ccID, state, {
      name: "Retained conversation", startedAt: nowMs - 8 * 24 * 60 * 60_000, status,
    })]);

    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions).toMatchObject([{ id: ccID, section: "history", attentionTier: "history",
      sessionState: { turn: "unknown" }, canOpenOwner: true, canEnterChat: true }]);
    expect(menuPresentation(snapshot, [], nowMs).pills).toEqual([]);
  });

  it.each(["question", "approval"] as const)("keeps a real unanswered %s yellow when its old job is otherwise unverified", async type => {
    const environment = new FixtureEnvironment();
    environment.inventory = inventorySuccess([backgroundRow("8e45ed2c", ccID, "blocked", {
      startedAt: nowMs - 8 * 24 * 60 * 60_000, status: undefined,
    })]);
    const source = repository(environment);
    expect((await source.refresh()).sessions[0]?.section).toBe("history");
    source.registerExternalAction(ccID, type === "question" ? {
      type, toolUseId: "unanswered-question", questions: [{ id: "confirm", question: "Continue?", choices: ["Yes"], multiple: false }],
    } : {
      type, toolUseId: "unanswered-approval", toolName: "Bash", input: { command: "echo fixture" }, canPersist: false,
    }, async () => { throw new Error("Discovery must not answer the user's request"); });

    environment.clock = new Date(nowMs + 3 * 24 * 60 * 60_000);
    environment.inventory = inventorySuccess(environment.inventory.kind === "success" ? environment.inventory.rows : [], true,
      environment.clock.valueOf());
    const snapshot = await source.refresh();
    expect(snapshot.sessions).toMatchObject([{ id: ccID, section: "needs_you", attentionTier: "needs_you",
      sessionState: { turn: "needs_you" } }]);
    expect(source.pendingActions(ccID)).toMatchObject([{ type }]);
    expect(menuPresentation(snapshot, [], environment.clock.valueOf()).navigatorPills).toMatchObject([{ id: ccID, phase: "needs_you" }]);
    expect(menuPresentation(snapshot, [], environment.clock.valueOf()).pills).toEqual([]);
  });

  it.each(["blocked", "working"])("keeps an old %s job orange when its current worker reports busy", async state => {
    const environment = new FixtureEnvironment();
    environment.inventory = inventorySuccess([backgroundRow("8e45ed2c", ccID, state, {
      startedAt: nowMs - 3 * 24 * 60 * 60_000, status: "busy",
    })]);
    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions).toMatchObject([{ id: ccID, section: "working", attentionTier: "working",
      sessionState: { turn: "working" } }]);
    expect(menuPresentation(snapshot, [], nowMs).navigatorPills).toMatchObject([{ id: ccID, phase: "working" }]);
  });

  it.each(["approval", "input"])("keeps an old job yellow when fresh inventory confirms it is waiting for %s", async waitingFor => {
    const environment = new FixtureEnvironment();
    environment.inventory = inventorySuccess([backgroundRow("8e45ed2c", ccID, "blocked", {
      startedAt: nowMs - 3 * 24 * 60 * 60_000, status: undefined, waitingFor,
    })]);
    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions).toMatchObject([{ id: ccID, section: "needs_you", attentionTier: "needs_you",
      sessionState: { turn: "needs_you" } }]);
    expect(menuPresentation(snapshot, [], nowMs).navigatorPills).toMatchObject([{ id: ccID, phase: "needs_you" }]);
  });

  it.each(["bg", "interactive"])("keeps an old blocked job orange when matching live %s worker metadata reports busy", async kind => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, { sessionId: ccID, jobId: "8e45ed2c", cwd,
      kind, entrypoint: "cli", status: "busy" });
    environment.inventory = inventorySuccess([backgroundRow("8e45ed2c", ccID, "blocked", {
      startedAt: nowMs - 3 * 24 * 60 * 60_000, status: undefined,
    })]);
    expect((await repository(environment).refresh()).sessions).toMatchObject([
      { id: ccID, section: "working", sessionState: { turn: "working" } },
    ]);
  });

  it("moves an unverified job to History after the observed window despite fresh catalog reads and restart", async () => {
    const environment = new FixtureEnvironment();
    const row = backgroundRow("8e45ed2c", ccID, "blocked", {
      startedAt: nowMs - environment.observedWindowMs, status: undefined,
    });
    environment.inventory = inventorySuccess([row]);
    const source = repository(environment);
    expect((await source.refresh()).sessions[0]?.section).toBe("needs_you");

    environment.clock = new Date(nowMs + 1);
    environment.inventory = inventorySuccess([row], true, environment.clock.valueOf());
    const snapshot = await source.refresh();
    expect(snapshot.sessions).toMatchObject([{ id: ccID, section: "history",
      updatedAt: new Date(row.startedAt).toISOString(), sessionState: { turn: "unknown" } }]);
    expect((await repository(environment).refresh()).sessions).toMatchObject([
      { id: ccID, section: "history", updatedAt: new Date(row.startedAt).toISOString() },
    ]);
  });

  it.each([
    { command: executable, section: "working", turn: "working" },
    { command: "/usr/bin/python3", section: "history", turn: "unknown" },
  ])("verifies an old job's worker PID instead of trusting a PID reused by $command", async ({ command, section, turn }) => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, command);
    environment.inventory = inventorySuccess([backgroundRow("8e45ed2c", ccID, "working", {
      startedAt: nowMs - 3 * 24 * 60 * 60_000, status: undefined, pid: 900,
    })]);
    expect((await repository(environment).refresh()).sessions).toMatchObject([
      { id: ccID, section, sessionState: { turn } },
    ]);
  });

  it.each([
    { tool: "Bash", type: "approval", input: { command: "echo fixture" } },
    { tool: "AskUserQuestion", type: "question", input: { questions: [{ question: "Continue?", options: ["Yes"] }] } },
  ])("keeps an unanswered $type hook yellow over a stale unverified job", async ({ tool, type, input }) => {
    const environment = new FixtureEnvironment();
    environment.inventory = inventorySuccess([backgroundRow("8e45ed2c", ccID, "blocked", {
      startedAt: nowMs - 8 * 24 * 60 * 60_000, status: undefined,
    })]);
    const source = repository(environment);
    await source.refresh();
    source.applyHook({ sessionId: ccID, cwd, provider: "claude_code", event: "PermissionRequest",
      status: "waiting_for_approval", expectsResponse: true, receivedAt: now.toISOString(),
      tool, toolUseId: "unanswered-hook", toolInput: input });
    expect((await source.refresh()).sessions).toMatchObject([
      { id: ccID, section: "needs_you", sessionState: { turn: "needs_you" } },
    ]);
    expect(source.pendingActions(ccID)).toMatchObject([{ type }]);
  });

  it("retains the exact open route for a History job without reviving an overview pill", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 950, executable, "claude attach 8e45ed2c");
    environment.inventory = inventorySuccess([backgroundRow("8e45ed2c", ccID, "blocked", {
      startedAt: nowMs - 3 * 24 * 60 * 60_000, status: undefined,
    })]);
    const source = repository(environment);
    const helper = new FakeNativeHelper();
    source.setControls(new NativeSessionControls(helper));
    const snapshot = await source.refresh();
    expect(snapshot.sessions[0]?.section).toBe("history");
    expect(menuPresentation(snapshot, [], nowMs).pills).toEqual([]);
    const effects: unknown[] = [];
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: ccID }, source,
      effect => effects.push(effect));
    expect(effects).toEqual([]);
    expect(helper.claudeAttachRequests).toEqual([{ cwd, executable, jobId: "8e45ed2c" }]);
    expect(helper.terminalSendRequests).toEqual([]);
    expect(menuPresentation(source.current(), [], nowMs).pills).toEqual([]);
  });

  it.each([true, false])("keeps completed background Claude pills gray after bookkeeping writes (semantic activity: %s)", async (semanticActivity) => {
    const { environment, row, transcript, completedAt } = completedIdleFixture();
    const startedAt = "2026-08-22T06:30:00.000Z";
    environment.inventory = inventorySuccess([{ ...row, state: "done", startedAt: Date.parse(startedAt) }]);
    environment.headTails.set(transcript, {
      head: semanticActivity ? JSON.stringify({ type: "assistant", timestamp: completedAt, message: { stop_reason: "end_turn" } }) : "",
      tail: JSON.stringify({ type: "system", subtype: "informational", timestamp: now.toISOString() }),
    });
    const source = repository(environment);
    await source.refresh();
    const before = menuPresentation(source.current(), [], nowMs).pills[0];
    expect(before).toMatchObject({
      id: ccID, inactive: true, attentionTier: "history",
      inspector: { activityAt: semanticActivity ? completedAt : startedAt },
    });
    environment.stamps.set(transcript, { modifiedAt: now, size: 100 });
    await source.refresh();
    expect(menuPresentation(source.current(), [], nowMs).pills[0]).toEqual(before);
    expect(source.current().sessions[0]?.completionUnseen).not.toBe(true);
    expect(menuPresentation(await repository(environment).refresh(), [], nowMs).pills[0]).toEqual(before);
  });

  it("shows a completed idle blocked conversation as Ready when no action is waiting", async () => {
    const { environment, row, completedAt } = completedIdleFixture();
    environment.inventory = inventorySuccess([{ ...row, state: "blocked" }]);
    const source = repository(environment);

    const snapshot = await source.refresh();
    expect(snapshot.sessions).toMatchObject([{ id: ccID, section: "ready", updatedAt: completedAt,
      sessionState: { turn: "ready" }, claudePresence: "conversation" }]);
    expect(menuPresentation(snapshot, [], nowMs).pills).toMatchObject([{ id: ccID, phase: "ready" }]);
  });

  it("turns a completed blocked conversation orange when its worker becomes busy without a waiting action", async () => {
    const { environment, row } = completedIdleFixture();
    environment.inventory = inventorySuccess([{ ...row, state: "blocked" }]);
    const source = repository(environment);
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toMatchObject([{ phase: "ready" }]);

    environment.clock = new Date(nowMs + 1_000);
    environment.inventory = inventorySuccess([{ ...row, state: "blocked", status: "busy" }], true, nowMs + 1_000);
    const busy = await source.refresh();
    expect(menuPresentation(busy, [], environment.clock.valueOf()).pills).toMatchObject([{ id: ccID, phase: "working" }]);
  });

  it("shows a completed idle conversation as Ready while its background worker remains running", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", status: "idle", parkedJobId: "8e45ed2c",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "working", { name: "ccx-thinking-block-sneha", status: "idle" }),
    ]);
    environment.ghosttyViews = [{ applicationPID: 7, processStartToken: ghosttyInstance,
      terminalId: "current", title: "ccx-thinking-block-sneha", cwd, viewMode: "conversation" }];
    const completedAt = new Date(nowMs - 40 * 60_000).toISOString();
    const transcript = home + "/.claude/projects/-Users-me-Codes-agent-visor/" + ccID + ".jsonl";
    const tail = JSON.stringify({ type: "system", subtype: "turn_duration", timestamp: completedAt });
    environment.headTails.set(transcript, { head: "", tail });
    environment.stamps.set(transcript, { size: tail.length, modifiedAt: new Date(completedAt) });

    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions).toMatchObject([{ id: ccID, section: "ready", updatedAt: completedAt,
      sessionState: { turn: "ready" }, claudePresence: "conversation" }]);
    expect(menuPresentation(snapshot, [], nowMs).pills).toMatchObject([
      { id: ccID, phase: "ready", title: "ccx-thinking-block-sneha" },
    ]);
  });

  it("keeps a newly busy turn orange even before its older completion disappears from the transcript", async () => {
    const { environment, row } = completedIdleFixture();
    const source = repository(environment);
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toMatchObject([{ phase: "ready" }]);
    environment.inventory = inventorySuccess([{ ...row, status: "busy" }], true, nowMs + 1_000);
    environment.clock = new Date(nowMs + 1_000);
    const busy = await source.refresh();
    expect(busy.sessions).toMatchObject([{ id: ccID, section: "working", sessionState: { turn: "working" } }]);
    expect(menuPresentation(busy, [], nowMs + 1_000).pills).toMatchObject([{ id: ccID, phase: "working" }]);
  });

  it("invalidates the older completion when a new prompt arrives while the inventory still says idle", async () => {
    const { environment, transcript, tail } = completedIdleFixture();
    const source = repository(environment);
    await source.refresh();
    const next = tail + "\n" + JSON.stringify({ type: "user", timestamp: now.toISOString(), message: { content: "Next task" } });
    environment.headTails.set(transcript, { head: tail, tail: next });
    environment.stamps.set(transcript, { size: next.length, modifiedAt: now });
    const started = await source.refresh();
    expect(menuPresentation(started, [], nowMs).pills).toMatchObject([{ id: ccID, phase: "working" }]);
  });

  it.each([
    { waitingFor: "approval", status: "idle" },
    { waitingFor: "input", status: "idle" },
    { waitingFor: "approval", status: "busy" },
    { waitingFor: "input", status: "busy" },
  ])("keeps a $status blocked $waitingFor request yellow despite an older completed turn", async ({ waitingFor, status }) => {
    const { environment, row } = completedIdleFixture();
    environment.inventory = inventorySuccess([{ ...row, state: "blocked", status, waitingFor }]);
    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions).toMatchObject([{ id: ccID, section: "needs_you", sessionState: { turn: "needs_you" } }]);
    expect(menuPresentation(snapshot, [], nowMs).pills).toMatchObject([{ id: ccID, phase: "needs_you" }]);
  });

  it.each([
    { type: "question", state: "working" },
    { type: "approval", state: "working" },
    { type: "question", state: "blocked" },
    { type: "approval", state: "blocked" },
  ] as const)("keeps a registered pending $type yellow across an idle $state inventory refresh", async ({ type, state }) => {
    const { environment, row } = completedIdleFixture();
    environment.inventory = inventorySuccess([{ ...row, state }]);
    const source = repository(environment);
    await source.refresh();
    source.registerExternalAction(ccID, type === "question" ? {
      type, toolUseId: "current-question", questions: [{ id: "confirm", question: "Continue?", choices: ["Yes"], multiple: false }],
    } : {
      type, toolUseId: "current-approval", toolName: "Bash", input: { command: "echo fixture" }, canPersist: false,
    }, async () => { throw new Error("Status checks must not answer a pending action"); });
    const snapshot = await source.refresh();
    expect(menuPresentation(snapshot, [], nowMs).pills).toMatchObject([{ id: ccID, phase: "needs_you" }]);
    expect(source.pendingActions(ccID)).toMatchObject([{ type }]);
    environment.inventory = inventorySuccess([{ ...row, state, status: "busy" }]);
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toMatchObject([{ id: ccID, phase: "needs_you" }]);
  });

  it.each([
    { tool: "Bash", type: "approval", input: { command: "echo fixture" } },
    { tool: "AskUserQuestion", type: "question", input: { questions: [{ question: "Continue?", options: ["Yes"] }] } },
  ])("retains a real $type hook over completed idle and busy blocked inventory refreshes", async ({ tool, type, input }) => {
    const { environment, row } = completedIdleFixture();
    environment.inventory = inventorySuccess([{ ...row, state: "blocked" }]);
    const source = repository(environment);
    await source.refresh();
    source.applyHook({ sessionId: ccID, cwd, provider: "claude_code", event: "PermissionRequest",
      status: "waiting_for_approval", expectsResponse: true, receivedAt: now.toISOString(),
      tool, toolUseId: "pending-tool", toolInput: input });
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toMatchObject([{ id: ccID, phase: "needs_you" }]);
    expect(source.pendingActions(ccID)).toMatchObject([{ type }]);
    environment.inventory = inventorySuccess([{ ...row, state: "blocked", status: "busy" }]);
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toMatchObject([{ id: ccID, phase: "needs_you" }]);
  });

  it.each(["working", "blocked"])("does not preserve Ready from old completed %s evidence when the inventory loses authority", async (state) => {
    const { environment, row } = completedIdleFixture();
    environment.inventory = inventorySuccess([{ ...row, state }]);
    const source = repository(environment);
    await source.refresh();
    environment.inventory = inventoryFailure(inventorySuccess([{ ...row, state }], false, nowMs + 31_000));
    environment.clock = new Date(nowMs + 31_000);
    expect((await source.refresh()).sessions).toMatchObject([{
      id: ccID,
      section: "history",
      presence: { state: "unknown", evidence: "unavailable" },
      lifecycleStatus: "unavailable",
    }]);
    expect(menuPresentation(source.current(), [], environment.clock.valueOf()).pills).toMatchObject([{
      id: ccID,
      lifecycleStatus: "unavailable",
      inspector: { status: "Status unavailable" },
    }]);
  });

  it.each(["working", "blocked"])("keeps an idle completed %s conversation out of pills when its surface returns to overview", async (state) => {
    const { environment, row } = completedIdleFixture();
    environment.inventory = inventorySuccess([{ ...row, state }]);
    const source = repository(environment);
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toHaveLength(1);
    environment.ghosttyViews[0]!.viewMode = "overview";
    const overview = await source.refresh();
    expect(overview.sessions).toMatchObject([{ id: ccID, section: "ready", ambientEligible: false }]);
    expect(menuPresentation(overview, [], nowMs).pills).toEqual([]);
  });

  it.each([
    { scenario: "missing transcript", tail: "" },
    { scenario: "new tool work", tail: JSON.stringify({ type: "assistant", timestamp: now.toISOString(),
      message: { stop_reason: "tool_use" } }) },
    { scenario: "new user input", tail: JSON.stringify({ type: "user", timestamp: now.toISOString(),
      message: { content: "Next task" } }) },
    { scenario: "missing completion timestamp", tail: JSON.stringify({ type: "system", subtype: "turn_duration" }) },
    { scenario: "invalid completion timestamp", tail: JSON.stringify({ type: "system", subtype: "turn_duration", timestamp: "invalid" }) },
    { scenario: "future completion timestamp", tail: JSON.stringify({ type: "system", subtype: "turn_duration",
      timestamp: new Date(nowMs + 30_000).toISOString() }) },
  ])("does not invent Ready for an idle blocked job with $scenario", async ({ tail }) => {
    const { environment, row, transcript, tail: completed } = completedIdleFixture();
    environment.inventory = inventorySuccess([{ ...row, state: "blocked" }]);
    environment.headTails.set(transcript, { head: completed, tail });
    environment.stamps.set(transcript, { size: tail.length, modifiedAt: now });
    const snapshot = await repository(environment).refresh();
    expect(menuPresentation(snapshot, [], nowMs).pills).toMatchObject([{ id: ccID, phase: "needs_you" }]);
  });

  it("keeps an unfamiliar blocked worker status yellow despite an older completion", async () => {
    const { environment, row } = completedIdleFixture();
    environment.inventory = inventorySuccess([{ ...row, state: "blocked", status: "future-status" }]);
    const snapshot = await repository(environment).refresh();
    expect(menuPresentation(snapshot, [], nowMs).pills).toMatchObject([{ id: ccID, phase: "needs_you" }]);
  });

  it("publishes one Paseo-owned conversation while an alias remains in the native overview inventory", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable, "claude");
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "blocked", { name: "Old native title" }),
    ]);
    environment.ghosttyViews = [{ applicationPID: 7, processStartToken: ghosttyInstance,
      terminalId: "overview", title: "✳ 1 awaiting input · claude agents", cwd }];
    const paseo = new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: {}, agents: [{
        id: "paseo_agent", provider: "claude", title: "Paseo conversation", cwd,
        status: "running", updatedAt: now.toISOString(), runtimeInfo: { sessionId: ccID },
      }],
    }) });
    const source = new SessionRepository([new ClaudeProvider(environment), paseo], { now: () => now });
    expect((await source.refresh()).sessions).toMatchObject([
      { title: "Paseo conversation", owner: "Paseo", section: "working" },
    ]);
    expect(menuPresentation(source.current(), [], nowMs).pills).toMatchObject([
      { title: "Paseo conversation", owner: "Paseo" },
    ]);
    // A late native permission hook must not resurrect the duplicate or its overview pill.
    source.applyHook({ sessionId: ccID, provider: "claude_code", cwd,
      event: "PermissionRequest", status: "waiting_for_approval", receivedAt: now.toISOString() });
    expect(source.current().sessions).toHaveLength(1);
  });
  it("restores and focuses only the parent when a child-panel read confirms its conversation", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "working", { name: "ccx-thinking-block-sneha", status: "busy" }),
      backgroundRow("64b38993", blockedID, "done", { name: "another retained conversation" }),
    ]);
    const view: GhosttyTerminalView = { applicationPID: 7, processStartToken: ghosttyInstance,
      terminalId: "manual", title: "ccx-thinking-block-sneha", cwd };
    environment.ghosttyViews = [view];
    const source = repository(environment);
    const helper = new FakeNativeHelper();
    source.setControls(new NativeSessionControls(helper));
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);

    // The native child-panel read supplies the same exact conversation route.
    // Retained background jobs do not gain pills from that observation.
    view.viewMode = "conversation";
    const snapshot = await source.refresh();
    expect(menuPresentation(snapshot, [], nowMs).pills).toMatchObject([
      { id: ccID, title: "ccx-thinking-block-sneha", phase: "working" },
    ]);
    expect(menuPresentation(snapshot, [], nowMs).pills).toHaveLength(1);
    expect(await source.focusSession(ccID)).toBeUndefined();
    expect(helper.ghosttyTerminalFocusRequests).toMatchObject([{
      terminalId: "manual", applicationPID: 7, processStartToken: ghosttyInstance, cwd, viewMode: "conversation",
    }]);
    expect(helper.claudeAttachRequests).toEqual([]);
    view.viewMode = "overview";
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);
    const restarted = repository(environment);
    expect(menuPresentation(await restarted.refresh(), [], nowMs).pills).toEqual([]);
    view.viewMode = "conversation";
    expect(menuPresentation(await restarted.refresh(), [], nowMs).pills.map(pill => pill.id)).toEqual([ccID]);
  });

  it("restores a plain-title conversation and exact click across restart while hiding its stale title in overview", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "working", { name: "ccx-thinking-block-sneha", status: "busy" }),
    ]);
    const view: GhosttyTerminalView = {
      applicationPID: 7, processStartToken: ghosttyInstance, terminalId: "manual",
      title: "ccx-thinking-block-sneha", cwd, viewMode: "conversation",
    };
    environment.ghosttyViews = [view];
    for (let restart = 0; restart < 2; restart++) {
      const source = repository(environment);
      const helper = new FakeNativeHelper();
      source.setControls(new NativeSessionControls(helper));
      const snapshot = await source.refresh();
      expect(menuPresentation(snapshot, [], nowMs).pills.map(p => p.id)).toEqual([ccID]);
      expect(await source.focusSession(ccID)).toBeUndefined();
      expect(helper.ghosttyTerminalFocusRequests).toMatchObject([{ terminalId: "manual", viewMode: "conversation" }]);
      expect(helper.claudeAttachRequests).toEqual([]);
      // Title suppression leaves the name unchanged. Fresh view evidence wins
      // even if the surface has previously been marked title-enabled.
      view.viewMode = "overview";
      view.titleUpdatesEnabled = true;
      expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);
      source.applyHook({ sessionId: ccID, provider: "claude_code", cwd,
        event: "PermissionRequest", status: "waiting_for_approval", receivedAt: now.toISOString() });
      expect(menuPresentation(source.current(), [], nowMs).pills).toEqual([]);
      view.viewMode = "conversation";
      delete view.titleUpdatesEnabled;
    }
  });

  it("keeps a title-suppressed stale name hidden and drops revoked title trust", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable, "claude attach 8e45ed2c");
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "blocked", { name: "ccx-plg-manifest" }),
    ]);
    const view: GhosttyTerminalView = {
      applicationPID: 7, processStartToken: ghosttyInstance, terminalId: "suppressed",
      title: "ccx-plg-manifest", cwd,
    };
    environment.ghosttyViews = [view];
    const source = repository(environment);
    // Captured suppressed frontend leaves this title unchanged on detaching.
    for (let stage = 0; stage < 2; stage++) {
      const snapshot = await source.refresh();
      expect(menuPresentation(snapshot, [], nowMs).pills).toEqual([]);
      expect(snapshot.sessions.map(({ id }) => id)).toEqual([ccID]);
    }
    view.titleUpdatesEnabled = true;
    expect(menuPresentation(await source.refresh(), [], nowMs).pills.map(({ id }) => id)).toEqual([ccID]);
    delete view.titleUpdatesEnabled;
    // A previously verified eligible pill survives title-read uncertainty as a
    // neutral unavailable result; revoked title trust must not erase it or
    // claim the conversation is closed.
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toMatchObject([{
      id: ccID,
      lifecycleStatus: "unavailable",
      inspector: { status: "Status unavailable" },
    }]);
  });

  it("never guesses between duplicate plain-title jobs in a title-enabled terminal", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "working", { name: "same name" }),
      backgroundRow("64b38993", blockedID, "done", { name: "same name" }),
    ]);
    environment.ghosttyViews = [{
      applicationPID: 7, processStartToken: ghosttyInstance, terminalId: "owned",
      title: "same name", cwd, titleUpdatesEnabled: true,
    }];
    expect(menuPresentation(await repository(environment).refresh(), [], nowMs).pills).toEqual([]);
  });

  it("restores one plain-title conversation from a title-enabled client and clears it in overview", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable, "claude attach 8e45ed2c");
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "blocked", { name: "ccx-plg-manifest" }),
      backgroundRow("64b38993", blockedID, "done", { name: "other job" }),
    ]);
    environment.ghosttyViews = [{
      applicationPID: 7, processStartToken: ghosttyInstance, terminalId: "title-enabled",
      title: "1 awaiting input · claude agents", cwd, titleUpdatesEnabled: true,
    }];
    const source = repository(environment);
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);
    // Captured CLI 2.1.296 return title has no activity prefix.
    environment.ghosttyViews[0]!.title = "ccx-plg-manifest";
    expect(menuPresentation(await source.refresh(), [], nowMs).pills.map(({ id }) => id)).toEqual([ccID]);
    const helper = new FakeNativeHelper();
    source.setControls(new NativeSessionControls(helper));
    expect(await source.focusSession(ccID)).toBeUndefined();
    expect(helper.ghosttyTerminalFocusRequests).toMatchObject([
      { terminalId: "title-enabled", title: "ccx-plg-manifest", titleUpdatesEnabled: true },
    ]);
    expect(helper.claudeAttachRequests).toEqual([]);
    environment.ghosttyViews[0]!.title = "1 awaiting input · claude agents";
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);
  });

  it("shows a standalone attached conversation without an interactive metadata record", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable, "claude attach 8e45ed2c");
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "working", { name: "ccx-plg-manifest", status: "busy" }),
      backgroundRow("64b38993", blockedID, "working", { name: "other job", status: "busy" }),
    ]);
    environment.ghosttyViews = [{
      applicationPID: 7, processStartToken: ghosttyInstance, terminalId: "standalone",
      title: "◐ ccx-plg-manifest", cwd,
    }];
    const source = repository(environment);
    expect(menuPresentation(await source.refresh(), [], nowMs).pills.map(({ id }) => id)).toEqual([ccID]);
    environment.ghosttyViews[0]!.title = "2 awaiting input · claude agents";
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);
  });

  it.each([executable, home + "/.local/share/claude/versions/2.1.296"])(
    "keeps one canonical unavailable pill across multiple terminals when inventory authority expires (%s)", async (command) => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, command);
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", status: "idle", parkedJobId: "8e45ed2c",
    });
    const inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "working", { name: "ccx-plg-manifest", status: "busy" }),
    ]);
    environment.inventory = inventory;
    environment.ghosttyViews = ["Codes", "claude agents", "◐ ccx-plg-manifest", "✳ ccx-plg-manifest"]
      .map((title, index) => ({ applicationPID: 7, processStartToken: ghosttyInstance, terminalId: `surface-${index}`, title, cwd }));
    const source = repository(environment);
    for (const views of [environment.ghosttyViews, [...environment.ghosttyViews].reverse()]) {
      environment.ghosttyViews = views;
      const snapshot = await source.refresh();
      expect(snapshot.sessions).toHaveLength(1);
      expect(snapshot.sessions[0]?.claudePresence).toBe("conversation");
      expect(menuPresentation(snapshot, [], nowMs).pills.map(({ id }) => id)).toEqual([ccID]);
    }
    environment.inventory = inventoryFailure(inventorySuccess(inventory.rows, false));
    const stale = await source.refresh();
    expect(menuPresentation(stale, [], nowMs).pills).toMatchObject([{
      id: ccID,
      lifecycleStatus: "unavailable",
      inspector: { status: "Status unavailable" },
    }]);
    expect(stale.sessions[0]?.claudePresence).toBe("inventory_unavailable");
    environment.inventory = inventory;
    environment.ghosttyTerminalViews = undefined;
    const unavailable = await source.refresh();
    expect(menuPresentation(unavailable, [], nowMs).pills).toMatchObject([{
      id: ccID,
      lifecycleStatus: "unavailable",
      inspector: { status: "Status unavailable" },
    }]);
    expect(unavailable.sessions[0]?.claudePresence).toBe("reader_unavailable");
  });

  it("rejects a terminal observation from a reused Ghostty process before exposing a pill or focus route", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    environment.processRows.find(({ pid }) => pid === 7)!.processStartToken = "replacement-instance";
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", status: "idle", parkedJobId: "8e45ed2c",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "working", { name: "ccx-plg-manifest", status: "busy" }),
    ]);
    environment.ghosttyViews = [{
      applicationPID: 7, processStartToken: "old-instance", terminalId: "surface-a", title: "◐ ccx-plg-manifest", cwd,
    }];
    const source = repository(environment);
    const snapshot = await source.refresh();
    expect(menuPresentation(snapshot, [], nowMs).pills).toEqual([]);
    expect(snapshot.sessions[0]).toMatchObject({ claudePresence: "process_changed", section: "working" });
    const helper = new FakeNativeHelper();
    const reattachments: Array<{ jobId: string }> = [];
    source.setControls(new NativeSessionControls(
      helper, undefined, undefined, undefined, undefined, undefined,
      async (target) => { reattachments.push(target); },
    ));
    expect(await source.focusSession(ccID)).toBeUndefined();
    expect(helper.ghosttyTerminalFocusRequests).toEqual([]);
    expect(reattachments).toMatchObject([{ jobId: "8e45ed2c" }]);
  });

  it("explains an unidentified terminal without changing the canonical working session", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable, "claude attach 8e45ed2c");
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", status: "idle", parkedJobId: "8e45ed2c",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "working", { name: "ccx-plg-manifest", status: "busy" }),
    ]);
    environment.ghosttyViews = [{
      applicationPID: 7, processStartToken: ghosttyInstance, terminalId: "surface-a", title: "Codes", cwd,
    }];

    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions).toHaveLength(1);
    expect(snapshot.sessions[0]).toMatchObject({
      id: ccID, title: "ccx-plg-manifest", section: "working",
      sessionState: { turn: "working" }, ambientEligible: false,
      claudePresence: "unrecognized_title", canOpenOwner: true,
    });
    const menu = menuPresentation(snapshot, [], nowMs);
    expect(menu.pills).toEqual([]);
    expect(menu.navigatorPills.map(({ id }) => id)).toEqual([ccID]);
  });

  it("does not reattach an older selection after a newer click wins during failed surface focus", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, { sessionId: managerID, cwd, kind: "interactive", status: "idle", parkedJobId: "0a06da15" });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "blocked", { name: "ccx-cleanup" }),
      backgroundRow("64b38993", blockedID, "done", { name: "cc-misc" }),
    ]);
    environment.ghosttyViews = [{ applicationPID: 7, processStartToken: ghosttyInstance, terminalId: "surface-a", title: "✳ ccx-cleanup", cwd }];
    const helper = new FakeNativeHelper();
    let failFirst!: () => void;
    let started!: () => void;
    const firstStarted = new Promise<void>((resolve) => { started = resolve; });
    helper.focusGhosttyTerminal = async (target) => {
      if (target.title === "✳ ccx-cleanup") {
        started();
        await new Promise<void>((_resolve, reject) => { failFirst = () => reject(new Error("surface changed")); });
      }
    };
    const source = repository(environment);
    await source.refresh();
    source.setControls(new NativeSessionControls(helper));
    const first = source.focusSession(ccID);
    await firstStarted;
    environment.ghosttyViews[0]!.title = "✳ cc-misc";
    expect(await source.focusSession(blockedID)).toBeUndefined();
    failFirst();
    expect(await first).toBeUndefined();
    expect(helper.claudeAttachRequests).toEqual([]);
  });

  it("shows the attached conversation while its frontend retains a different parked identity", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", status: "idle",
      name: "codes-ef", parkedJobId: "0a06da15",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "blocked", { name: "ccx-cleanup" }),
      backgroundRow("64b38993", blockedID, "done", { name: "cc-misc" }),
    ]);
    environment.ghosttyViews = [{
      applicationPID: 7, processStartToken: ghosttyInstance,
      terminalId: "048c93af-0c77-4f8c-b6b0-313257df61ae",
      title: "✳ ccx-cleanup", cwd,
    }];
    const source = repository(environment);
    const snapshot = await source.refresh();
    expect(menuPresentation(snapshot, [], nowMs).pills.map(({ id }) => id)).toEqual([ccID]);
    expect(snapshot.sessions.find(({ id }) => id === ccID)?.claudePresence).toBe("conversation");
    expect(snapshot.sessions.find(({ id }) => id === blockedID)?.ambientEligible).toBe(false);
    expect(snapshot.sessions.some(({ id }) => id === managerID)).toBe(false);
    const helper = new FakeNativeHelper();
    const reattachments: Array<{ jobId: string }> = [];
    source.setControls(new NativeSessionControls(
      helper, undefined, undefined, undefined, undefined, undefined,
      async (target) => { reattachments.push(target); },
    ));
    expect(await source.focusSession(ccID)).toBeUndefined();
    expect(helper.claudeAttachRequests).toHaveLength(0);
    expect(helper.ghosttyTerminalFocusRequests).toEqual(environment.ghosttyViews);

    // Neither the host UUID nor its parked job changes during this roundtrip.
    environment.ghosttyViews[0]!.title = "1 awaiting input · claude agents";
    const overview = await source.refresh();
    expect(menuPresentation(overview, [], nowMs).pills).toEqual([]);
    expect(overview.sessions.map(({ claudePresence }) => claudePresence)).toEqual(["overview", "overview"]);
    environment.ghosttyViews[0]!.title = "◐ cc-misc";
    const switched = await source.refresh();
    expect(menuPresentation(switched, [], nowMs).pills.map(({ id }) => id)).toEqual([blockedID]);
    expect(switched.sessions.find(({ id }) => id === ccID)?.claudePresence).toBe("not_displayed");
    // A stale click selects its canonical job; it cannot focus the other view.
    expect(await source.focusSession(ccID)).toBeUndefined();
    expect(helper.ghosttyTerminalFocusRequests).toHaveLength(1);
    expect(reattachments).toMatchObject([{ cwd, executable, jobId: "8e45ed2c" }]);
    environment.ghosttyViews = [];
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);
  });

  it("does not guess a displayed job from ambiguous names, another directory, or a failed view read", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", status: "idle", parkedJobId: "0a06da15",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "blocked", { name: "ccx-cleanup" }),
      backgroundRow("64b38993", blockedID, "done", { name: "ccx-cleanup" }),
    ]);
    environment.ghosttyViews = [{
      applicationPID: 7, processStartToken: ghosttyInstance, terminalId: "surface-a",
      title: "✳ ccx-cleanup", cwd,
    }];
    const source = repository(environment);
    const ambiguous = await source.refresh();
    expect(menuPresentation(ambiguous, [], nowMs).pills).toEqual([]);
    expect(ambiguous.sessions.map(({ claudePresence }) => claudePresence)).toEqual(["ambiguous_title", "ambiguous_title"]);
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "blocked", { name: "ccx-cleanup" }),
    ]);
    environment.ghosttyViews[0]!.cwd = home + "/another-project";
    const unrelated = await source.refresh();
    expect(menuPresentation(unrelated, [], nowMs).pills).toEqual([]);
    expect(unrelated.sessions[0]?.claudePresence).toBe("not_displayed");
    environment.ghosttyTerminalViews = async () => { throw new Error("permission unavailable"); };
    const failed = await source.refresh();
    expect(menuPresentation(failed, [], nowMs).pills).toEqual([]);
    expect(failed.sessions[0]?.claudePresence).toBe("read_failed");
  });

  it("reports a failed presence read and recovers exactly one working pill when conversation titles return", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", status: "idle", parkedJobId: "64b38993",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "working", { name: "ccx-plg-manifest", status: "busy" }),
      backgroundRow("64b38993", blockedID, "done", { name: "cc-misc" }),
    ]);
    const reports: unknown[] = [];
    const source = new SessionRepository([new ClaudeProvider(environment, report => reports.push(report))], { now: () => now });
    environment.ghosttyTerminalViews = async () => { throw new Error("secret-bearing native error"); };
    const failed = await source.refresh();
    expect(menuPresentation(failed, [], nowMs).pills).toEqual([]);
    expect(failed.sessions.find(({ id }) => id === ccID)).toMatchObject({
      claudePresence: "read_failed", sessionState: { turn: "working" },
    });
    expect(reports.at(-1)).toEqual({
      status: "read_failed", parkedApplications: 1, terminalViews: 0,
      conversationTitles: 0, overviewTitles: 0, unrecognizedTitles: 0, matchedConversations: 0,
    });

    // Disabled terminal titles retain the shell title; never guess a job from it.
    environment.ghosttyTerminalViews = async () => environment.ghosttyViews;
    environment.ghosttyViews = [{ applicationPID: 7, processStartToken: ghosttyInstance, terminalId: "surface-a", title: "Codes", cwd }];
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);
    expect(reports.at(-1)).toMatchObject({ status: "read_succeeded", unrecognizedTitles: 1, matchedConversations: 0 });

    environment.ghosttyViews[0]!.title = "◐ ccx-plg-manifest";
    const snapshot = await source.refresh();
    expect(menuPresentation(snapshot, [], nowMs).pills.map(({ id, phase }) => ({ id, phase }))).toEqual([{ id: ccID, phase: "working" }]);
    expect(snapshot.sessions.find(({ id }) => id === ccID)?.claudePresence).toBe("conversation");
    expect(snapshot.sessions.find(({ id }) => id === blockedID)?.ambientEligible).toBe(false);
    expect(reports.at(-1)).toMatchObject({ status: "read_succeeded", conversationTitles: 1, matchedConversations: 1 });

    environment.ghosttyViews[0]!.title = "1 awaiting input · claude agents";
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);
    expect(reports.at(-1)).toMatchObject({ status: "read_succeeded", overviewTitles: 1, unrecognizedTitles: 0, matchedConversations: 0 });
    expect(JSON.stringify(reports)).not.toMatch(/secret-bearing|Codes|ccx-plg-manifest|cc-misc|surface-a/);
  });

  it("shows a native versioned Claude conversation once and retains its exact terminal click route", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, home + "/.local/share/claude/versions/2.1.296");
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", name: "AV smoke test",
    });
    const source = repository(environment);
    const snapshot = await source.refresh();
    expect(menuPresentation(snapshot, [], nowMs).pills).toMatchObject([
      { id: managerID, title: "AV smoke test", phase: "ready" },
    ]);
    expect(snapshot.sessions).toHaveLength(1);
    const helper = new FakeNativeHelper();
    source.setControls(new NativeSessionControls(helper));
    const effects: unknown[] = [];
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: managerID },
      source, (effect) => effects.push(effect));
    expect(effects).toEqual([]);
    expect(helper.terminalFocusRequests).toMatchObject([{ pid: 900, tty: "ttys001" }]);
    expect(helper.claudeAttachRequests).toEqual([]);
  });

  it("does not mistake an unrelated version-numbered executable for Claude", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, home + "/Codes/2.1.296");
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli", status: "idle",
    });
    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions).toEqual([]);
    expect(menuPresentation(snapshot, [], nowMs).pills).toEqual([]);
  });

  it("shows only the open interactive conversation when retained background jobs share its workspace", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", name: "codes-ac",
    });
    const states = ["done", "blocked", "working", "stopped", "failed"];
    environment.inventory = inventorySuccess(states.map((state, index) => {
      const id = `aabbccd${index}`;
      return backgroundRow(id, `${id}-cd3b-4140-a8da-4614085a3536`, state);
    }));
    const source = repository(environment);
    const snapshot = await source.refresh();
    const presentation = menuPresentation(snapshot, [], nowMs);

    expect(snapshot.sessions).toHaveLength(6);
    expect(presentation.pills.map(({ id }) => id)).toEqual([managerID]);
    expect(presentation.navigatorPills).toHaveLength(6);
    expect(presentation.navigatorPills.filter((pill) => pill.defaultOverflowEligible)
      .map(({ id }) => id)).toEqual([managerID]);
    // A background prompt does not establish a visible terminal attachment.
    const started = source.applyHook({
      sessionId: "aabbccd0-cd3b-4140-a8da-4614085a3536", cwd,
      provider: "claude_code", event: "UserPromptSubmit", status: "processing",
      receivedAt: new Date(nowMs + 1_000).toISOString(),
    });
    expect(menuPresentation(started, [], nowMs + 1_000).pills.map(({ id }) => id))
      .toEqual([managerID]);
  });

  it.each([executable, home + "/.local/share/claude/versions/2.1.296"])(
    "shows no pills for an agent overview while retaining its background jobs in search (%s)", async (command) => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, command);
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", name: "codes-b8", parkedJobId: "64b38993",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "done", { name: "cc-misc" }),
      backgroundRow("64b38993", blockedID, "blocked", { waitingFor: "approval" }),
    ]);

    const snapshot = await repository(environment).refresh();
    const presentation = menuPresentation(snapshot, [], nowMs);

    expect(snapshot.sessions.map((session) => session.id).sort()).toEqual([blockedID, ccID]);
    expect(presentation.pills).toEqual([]);
    expect(presentation.navigatorPills.map(({ id }) => id).sort()).toEqual([blockedID, ccID]);
    expect(presentation.navigatorPills.every((pill) => !pill.defaultOverflowEligible)).toBe(true);
  });

  it("uses current interactive identity for a background pill and drops it when the UI closes or switches", async () => {
    const environment = new FixtureEnvironment();
    // Launch argv can stay on this job after the UI switches conversations.
    addProcess(environment, 900, executable, "claude attach 8e45ed2c");
    addMetadata(environment, 900, {
      sessionId: ccID, cwd, kind: "interactive", entrypoint: "cli", status: "idle",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "done", { name: "cc-misc" }),
      backgroundRow("64b38993", blockedID, "blocked"),
    ]);
    const source = repository(environment);
    const attached = await source.refresh();
    expect(attached.sessions.filter(({ id }) => id === ccID)).toHaveLength(1);
    expect(menuPresentation(attached, [], nowMs).pills).toMatchObject([
      { id: ccID, title: "cc-misc", phase: "ready" },
    ]);
    expect(attached.sessions.find(({ id }) => id === ccID)?.ambientEligible).toBe(true);
    expect(attached.sessions.find(({ id }) => id === ccID)?.claudePresence).toBe("interactive");

    const helper = new FakeNativeHelper();
    source.setControls(new NativeSessionControls(helper));
    const effects: unknown[] = [];
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: ccID },
      source, (effect) => effects.push(effect));
    expect(effects).toEqual([]);
    expect(helper.terminalFocusRequests).toMatchObject([{ pid: 900, tty: "ttys001" }]);
    expect(helper.claudeAttachRequests).toEqual([]);

    addMetadata(environment, 900, {
      sessionId: blockedID, cwd, kind: "interactive", entrypoint: "cli", status: "idle",
    });
    const switched = await source.refresh();
    expect(menuPresentation(switched, [], nowMs).pills.map(({ id }) => id)).toEqual([blockedID]);
    expect(switched.sessions.find(({ id }) => id === ccID)?.ambientEligible).toBe(false);

    // Keeping Visor Chat open must not keep a source UI pill alive.
    await source.chatOpened(blockedID, "visibility-chat");
    environment.processRows = [];
    const closed = await source.refresh();
    expect(closed.sessions).toHaveLength(2);
    expect(menuPresentation(closed, [], nowMs).pills).toEqual([]);
    expect(menuPresentation(closed, [], nowMs).navigatorPills).toHaveLength(2);
  });

  it("keeps separate genuinely open conversations in the same workspace", async () => {
    const environment = new FixtureEnvironment();
    for (const [pid, sessionId] of [[900, ccID], [901, blockedID]] as const) {
      addProcess(environment, pid, executable);
      addMetadata(environment, pid, {
        sessionId, cwd, kind: "interactive", entrypoint: "cli", status: "idle",
      });
    }
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "done", { name: "cc-misc" }),
      backgroundRow("64b38993", blockedID, "working", { name: "cc-av" }),
    ]);
    const snapshot = await repository(environment).refresh();
    expect(menuPresentation(snapshot, [], nowMs).pills.map(({ id }) => id))
      .toEqual([ccID, blockedID]);
  });

  it("does not let an overview suppress a conversation open in another terminal", async () => {
    const environment = new FixtureEnvironment();
    for (const pid of [900, 901]) addProcess(environment, pid, executable);
    addMetadata(environment, 900, {
      sessionId: ccID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", parkedJobId: "8e45ed2c",
    });
    addMetadata(environment, 901, {
      sessionId: ccID, cwd, kind: "interactive", entrypoint: "cli", status: "idle",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "done", { name: "cc-misc" }),
    ]);
    const source = repository(environment);
    await source.refresh();
    const started = source.applyHook({
      sessionId: ccID, cwd, provider: "claude_code", event: "UserPromptSubmit",
      status: "processing", receivedAt: new Date(nowMs + 1_000).toISOString(),
    });
    expect(menuPresentation(started, [], nowMs + 1_000).pills).toMatchObject([
      { id: ccID, title: "cc-misc", phase: "working" },
    ]);
    const helper = new FakeNativeHelper();
    source.setControls(new NativeSessionControls(helper));
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: ccID },
      source, () => undefined);
    expect(helper.terminalFocusRequests).toMatchObject([{ pid: 901 }]);
    expect(helper.claudeAttachRequests).toEqual([]);
  });

  it("removes an opened host conversation's pill when its terminal enters the overview", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", name: "codes-b8",
    });
    const source = repository(environment);
    await source.refresh();
    await source.chatOpened(managerID, "host-chat");
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", name: "codes-b8", parkedJobId: "64b38993",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("64b38993", blockedID, "working"),
    ]);
    const overview = await source.refresh();
    expect(menuPresentation(overview, [], nowMs).pills).toEqual([]);
    expect(menuPresentation(overview, [], nowMs).navigatorPills
      .filter((pill) => pill.defaultOverflowEligible)).toEqual([]);
    const effects: unknown[] = [];
    const helper = new FakeNativeHelper();
    source.setControls(new NativeSessionControls(helper));
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: managerID },
      source, (effect) => effects.push(effect));
    expect(helper.terminalFocusRequests).toEqual([]);
    expect(effects).toMatchObject([{ type: "native_effect", action: "session_focus_failed" }]);
  });

  it("tracks overview to conversation to overview without duplicate pills or stale clicks", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable, "claude attach 8e45ed2c");
    const overviewMetadata = {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", name: "codes-b8", parkedJobId: "8e45ed2c",
    };
    addMetadata(environment, 900, overviewMetadata);
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "done", { name: "cc-misc" }),
      backgroundRow("64b38993", blockedID, "blocked"),
    ]);
    const source = repository(environment);
    const helper = new FakeNativeHelper();
    source.setControls(new NativeSessionControls(helper));
    expect(menuPresentation(await source.refresh(), [], nowMs).pills).toEqual([]);

    addMetadata(environment, 900, {
      sessionId: ccID, cwd, kind: "interactive", entrypoint: "cli", status: "idle",
    });
    const entered = await source.refresh();
    expect(entered.sessions.filter(({ id }) => id === ccID)).toHaveLength(1);
    expect(menuPresentation(entered, [], nowMs).pills).toMatchObject([
      { id: ccID, title: "cc-misc", phase: "ready" },
    ]);
    await source.chatOpened(ccID, "overview-transition-chat");
    expect(await source.focusSession(ccID)).toBeUndefined();
    expect(helper.terminalFocusRequests).toMatchObject([{ pid: 900 }]);

    // A click can race the next ambient refresh. Fresh source navigation
    // must attach the selected job, never focus the terminal's overview.
    addMetadata(environment, 900, overviewMetadata);
    expect(await source.focusSession(ccID)).toBeUndefined();
    expect(helper.terminalFocusRequests).toHaveLength(1);
    expect(helper.claudeAttachRequests).toMatchObject([{ jobId: "8e45ed2c" }]);
    const returned = await source.refresh();
    expect(menuPresentation(returned, [], nowMs).pills).toEqual([]);
    expect(returned.sessions.filter(({ id }) => id === ccID)).toHaveLength(1);
    expect(menuPresentation(returned, [], nowMs).navigatorPills
      .every((pill) => !pill.defaultOverflowEligible)).toBe(true);
    const delayed = source.applyHook({
      sessionId: managerID, cwd, provider: "claude_code", event: "Stop",
      status: "idle", tty: "ttys001", receivedAt: new Date(nowMs + 1_000).toISOString(),
    });
    expect(menuPresentation(delayed, [], nowMs + 1_000).pills).toEqual([]);
  });

  it.each([
    ["empty", inventorySuccess([])],
    ["unknown", inventorySuccess([backgroundRow("64b38993", blockedID, "future")])],
    ["stale", inventoryFailure(inventorySuccess([backgroundRow("64b38993", blockedID, "done")], false))],
    ["failed", { kind: "failure", root: home + "/.claude", reason: "timed_out", startedAt: nowMs, completedAt: nowMs }],
    ["unsupported", { kind: "unsupported", root: home + "/.claude", reason: "command_unavailable", startedAt: nowMs, completedAt: nowMs }],
    ["config root", { kind: "unsupported", root: home + "/.claude", reason: "config_root", startedAt: nowMs, completedAt: nowMs }],
  ] satisfies [string, ClaudeAgentInventoryResult][])(
    "does not turn an overview into a conversation when inventory is %s", async (_label, inventory) => {
      const environment = new FixtureEnvironment();
      addProcess(environment, 900, executable);
      addMetadata(environment, 900, {
        sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
        status: "idle", parkedJobId: "64b38993",
      });
      environment.inventory = inventory;
      const source = repository(environment);
      await source.refresh();
      const delayed = source.applyHook({
        sessionId: managerID, cwd, provider: "claude_code", event: "UserPromptSubmit",
        status: "processing", tty: "ttys001", receivedAt: new Date(nowMs + 1_000).toISOString(),
      });
      expect(delayed.sessions.some(({ id }) => id === managerID)).toBe(false);
      expect(menuPresentation(delayed, [], nowMs + 1_000).pills).toEqual([]);
      expect(menuPresentation(delayed, [], nowMs + 1_000).navigatorPills
        .every((pill) => !pill.defaultOverflowEligible)).toBe(true);
    },
  );

  it("does not recreate an overview pill from a hook while its metadata is unreadable", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable);
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", parkedJobId: "64b38993",
    });
    const source = repository(environment);
    await source.refresh();
    environment.files.delete(path.join(home, ".claude/sessions/900.json"));
    await source.refresh();
    const delayed = source.applyHook({
      sessionId: managerID, cwd, provider: "claude_code", event: "Stop",
      status: "idle", tty: "ttys001", receivedAt: new Date(nowMs + 1_000).toISOString(),
    });
    expect(menuPresentation(delayed, [], nowMs + 1_000).pills).toEqual([]);
    expect(menuPresentation(delayed, [], nowMs + 1_000).navigatorPills
      .every((pill) => !pill.defaultOverflowEligible)).toBe(true);
    // Positive current conversation metadata restores eligibility, even after
    // a process restart. Suppression must not be sticky by PID or session ID.
    environment.starts.set(900, new Date(nowMs + 2_000));
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", name: "new conversation",
    });
    expect(menuPresentation(await source.refresh(), [], nowMs + 2_000).pills).toMatchObject([
      { id: managerID, title: "new conversation", phase: "ready" },
    ]);
  });

  it("does not treat a matching attach command without current session metadata as an open conversation", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, executable, "claude attach 8e45ed2c");
    environment.inventory = inventorySuccess([
      backgroundRow("8e45ed2c", ccID, "done"),
    ]);
    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions[0]?.canOpenOwner).toBe(true);
    expect(menuPresentation(snapshot, [], nowMs).pills).toEqual([]);
  });

  it("keeps an unknown inventory row searchable without restoring an overview pill", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, home + "/.local/bin/claude");
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", name: "codes-b8", parkedJobId: "64b38993",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("64b38993", blockedID, "future"),
    ]);

    const snapshot = await repository(environment).refresh();
    const background = snapshot.sessions.find((session) => session.id === blockedID);

    expect(background).toMatchObject({ id: blockedID, canOpenOwner: false });
    expect(background?.controlTarget).toBeUndefined();
    expect(snapshot.sessions.some((session) => session.id === managerID)).toBe(false);
    expect(menuPresentation(snapshot, [], nowMs).pills).toEqual([]);
  });

  it("discovers a claimed spare without launch flags, keeps a no-PID job, and separates same-CWD jobs", async () => {
    const environment = new FixtureEnvironment();
    const claimedID = "aabbccdd-cd3b-4140-a8da-4614085a3536";
    const claimedJob = "aabbccdd";
    const doneID = "bbccddee-cd3b-4140-a8da-4614085a3536";
    addProcess(environment, 901, home + "/.local/share/claude/versions/2.1.285", "claude bg-spare --bg-spare /tmp/spare.sock");
    addMetadata(environment, 901, {
      sessionId: claimedID, cwd, kind: "bg", entrypoint: "cli",
      status: "idle", jobId: claimedJob,
    });
    environment.inventory = inventorySuccess([
      backgroundRow(claimedJob, claimedID, "working", { name: "cc-misc" }),
      backgroundRow("bbccddee", doneID, "done"),
    ]);

    const snapshot = await repository(environment).refresh();
    const pills = menuPresentation(snapshot, [], nowMs).pills;

    expect(snapshot.sessions).toHaveLength(2);
    expect(new Set(snapshot.sessions.map((session) => session.cwd))).toEqual(new Set([cwd]));
    expect(snapshot.sessions.map((session) => session.id)).toEqual(
      expect.arrayContaining([claimedID, doneID]),
    );
    expect(pills).toEqual([]);
    expect(menuPresentation(snapshot, [], nowMs).navigatorPills).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: claimedID, title: "cc-misc", phase: "working", defaultOverflowEligible: false }),
      expect.objectContaining({ id: doneID, phase: "ready", defaultOverflowEligible: false }),
    ]));
  });

  it("retains Ready turn evidence for an old no-PID done job when presence is unavailable", async () => {
    const environment = new FixtureEnvironment();
    const old = backgroundRow("0a0b0c0d", "0a0b0c0d-cd3b-4140-a8da-4614085a3536", "done", {
      startedAt: nowMs - 2 * 60 * 60 * 1_000,
      name: "old done job",
    });
    const recent = backgroundRow("1a1b1c1d", "1a1b1c1d-cd3b-4140-a8da-4614085a3536", "done", {
      startedAt: nowMs - 10 * 60 * 1_000,
      name: "recent done job",
    });
    environment.inventory = inventorySuccess([old, recent]);

    const snapshot = await repository(environment).refresh();
    expect(snapshot.sessions).toEqual(expect.arrayContaining([
      expect.objectContaining({
        id: old.sessionId,
        section: "ready",
        sessionState: expect.objectContaining({ turn: "ready" }),
      }),
    ]));
    expect(menuPresentation(snapshot, [], nowMs).navigatorPills.map(({ id, phase, attentionTier }) => ({
      id, phase, attentionTier,
    }))).toEqual([
      { id: recent.sessionId, phase: "ready", attentionTier: "ready" },
      // Missing PID/frontend evidence is Status unavailable, not affirmative
      // History. Keep the provider's explicit Ready turn fact intact.
      { id: old.sessionId, phase: "ready", attentionTier: "ready" },
    ]);
  });

  it.each(["working", "blocked", "done"] as const)(
    "does not let a delayed Claude Stop/idle hook override canonical %s state or renew activity",
    async (state) => {
      const environment = new FixtureEnvironment();
      const row = backgroundRow("8e45ed2c", ccID, state, {
        name: "cc-misc",
        startedAt: nowMs - 2 * 60 * 60 * 1_000,
      });
      environment.inventory = inventorySuccess([row], true, nowMs);
      const source = repository(environment);
      const before = await source.refresh();
      const canonical = before.sessions[0];
      const expectedSection = state === "working" ? "working"
        : state === "blocked" ? "needs_you" : "ready";
      expect(canonical).toMatchObject({
        id: ccID,
        section: expectedSection,
      });

      const receivedAt = new Date(nowMs + 1_000).toISOString();
      const staleActivityAt = new Date(nowMs - 2 * 60 * 60 * 1_000).toISOString();
      const after = source.applyHook({
        sessionId: ccID,
        cwd,
        provider: "claude_code",
        event: "Stop",
        status: "idle",
        receivedAt,
        activityAt: staleActivityAt,
      });

      expect(after.sessions[0]).toMatchObject({
        id: ccID,
        section: canonical?.section,
        subtitle: canonical?.subtitle,
        sessionState: canonical?.sessionState,
        updatedAt: canonical?.updatedAt,
      });
    },
  );

  it("rejects a Claude lifecycle hook received no later than the canonical inventory observation",
    async () => {
      const environment = new FixtureEnvironment();
      const row = backgroundRow("8e45ed2c", ccID, "working", { name: "cc-misc" });
      environment.inventory = inventorySuccess([row], true, nowMs);
      const source = repository(environment);
      await source.refresh();

      const stale = source.applyHook({
        sessionId: ccID,
        cwd,
        provider: "claude_code",
        event: "Stop",
        status: "idle",
        receivedAt: new Date(nowMs).toISOString(),
      });
      expect(stale.sessions[0]).toMatchObject({
        id: ccID,
        section: "working",
        sessionState: { turn: "working" },
      });
    });

  it("keeps authoritative inventory canonical across a delayed Stop with newer activity", async () => {
    const environment = new FixtureEnvironment();
    const row = backgroundRow("8e45ed2c", ccID, "working", { name: "cc-misc" });
    environment.inventory = inventorySuccess([row], true, nowMs);
    const source = repository(environment);
    await source.refresh();

    const receivedAt = new Date(nowMs + 1_000).toISOString();
    const activityAt = new Date(nowMs + 2_000).toISOString();
    const settled = source.applyHook({
      sessionId: ccID,
      cwd,
      provider: "claude_code",
      event: "Stop",
      status: "idle",
      receivedAt,
      activityAt,
    });
    expect(settled.sessions[0]).toMatchObject({
      id: ccID,
      section: "working",
      sessionState: { turn: "working" },
      updatedAt: new Date(nowMs).toISOString(),
    });
  });

  it("retains a fresh start and approval bridge when a delayed Stop is rejected", async () => {
    const environment = new FixtureEnvironment();
    const row = backgroundRow("8e45ed2c", ccID, "done", { name: "cc-misc" });
    environment.inventory = inventorySuccess([row], true, nowMs);
    const source = repository(environment);
    const initial = await source.refresh();
    expect(initial.sessions[0]).toMatchObject({ id: ccID, section: "ready" });

    const startAt = new Date(nowMs + 1_000).toISOString();
    const working = source.applyHook({
      sessionId: ccID, cwd, provider: "claude_code", event: "UserPromptSubmit",
      status: "processing", receivedAt: startAt,
    });
    expect(working.sessions[0]).toMatchObject({
      id: ccID, section: "working", updatedAt: startAt,
    });

    const afterLateStop = source.applyHook({
      sessionId: ccID, cwd, provider: "claude_code", event: "Stop", status: "idle",
      receivedAt: new Date(nowMs + 2_000).toISOString(),
    });
    expect(afterLateStop.sessions[0]).toMatchObject({
      id: ccID, section: "working", updatedAt: startAt,
    });

    const approvalAt = new Date(nowMs + 3_000).toISOString();
    const approval = source.applyHook({
      sessionId: ccID, cwd, provider: "claude_code", event: "PermissionRequest",
      status: "waiting_for_input", expectsResponse: true, receivedAt: approvalAt,
    });
    expect(approval.sessions[0]).toMatchObject({
      id: ccID, section: "needs_you", updatedAt: approvalAt,
    });

    const afterApprovalStop = source.applyHook({
      sessionId: ccID, cwd, provider: "claude_code", event: "Stop", status: "idle",
      receivedAt: new Date(nowMs + 4_000).toISOString(),
    });
    expect(afterApprovalStop.sessions[0]).toMatchObject({
      id: ccID, section: "needs_you", updatedAt: approvalAt,
    });

    environment.inventory = inventorySuccess([row], true, nowMs + 5_000);
    expect((await source.refresh()).sessions[0]).toMatchObject({
      id: ccID, section: "ready", updatedAt: row.startedAt
        ? new Date(row.startedAt).toISOString() : undefined,
    });
  });

  it("does not let a stale inventory hook reopen a finished job forever", async () => {
    const environment = new FixtureEnvironment();
    const row = backgroundRow("8e45ed2c", ccID, "done", { name: "cc-misc" });
    environment.inventory = inventorySuccess([row], true);
    const source = repository(environment);

    // This hook was emitted before the inventory fetch that established the
    // completed state. It must remain historical evidence after the cached
    // inventory loses authority; stale identity is not fresh activity.
    source.applyHook({
      sessionId: ccID, cwd, provider: "claude_code", event: "UserPromptSubmit",
      status: "processing", receivedAt: new Date(nowMs - 1_000).toISOString(),
    });
    expect((await source.refresh()).sessions).toMatchObject([
      { id: ccID, section: "ready" },
    ]);

    environment.inventory = inventoryFailure(inventorySuccess([row], false, nowMs + 2_000));
    const stale = await source.refresh();
    expect(stale.sessions).toMatchObject([
      { id: ccID, section: "history" },
    ]);

    // A genuinely newer lifecycle signal is independent evidence and may
    // bridge the stale inventory until the next authoritative refresh.
    source.applyHook({
      sessionId: ccID, cwd, provider: "claude_code", event: "UserPromptSubmit",
      status: "processing", receivedAt: new Date(nowMs + 3_000).toISOString(),
    });
    expect(source.current().sessions).toMatchObject([{ id: ccID, section: "working" }]);
  });

  it("does not invent a conversation pill when an overview's inventory becomes empty", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, home + "/.local/bin/claude");
    addMetadata(environment, 900, {
      sessionId: managerID, cwd, kind: "interactive", entrypoint: "cli",
      status: "idle", name: "codes-b8", parkedJobId: "64b38993",
    });
    environment.inventory = inventorySuccess([
      backgroundRow("64b38993", blockedID, "working"),
    ]);
    const source = repository(environment);

    expect((await source.refresh()).sessions.map((session) => session.id)).toEqual([blockedID]);

    environment.inventory = inventorySuccess([]);
    const returned = await source.refresh();
    expect(returned.sessions).toEqual([]);
    expect(menuPresentation(returned, [], nowMs).pills).toEqual([]);
  });

  it("retains removed conversation tombstones across refreshes and clears them on interactive reuse", async () => {
    const environment = new FixtureEnvironment();
    const provider = new ClaudeProvider(environment);
    const source = new SessionRepository([provider], { now: () => environment.now() });
    const row = backgroundRow("8e45ed2c", ccID, "done", { name: "cc-misc" });
    environment.inventory = inventorySuccess([row]);
    await source.refresh();

    environment.inventory = inventorySuccess([]);
    await source.refresh();
    expect(provider.hiddenSessionIds()).toContain(ccID);

    source.applyHook({
      sessionId: ccID, cwd, provider: "claude_code", event: "UserPromptSubmit",
      status: "processing", tty: "ttys001", receivedAt: new Date(nowMs + 1_000).toISOString(),
    });
    expect(source.current().sessions.some((session) => session.id === ccID)).toBe(false);

    await source.refresh();
    expect(provider.hiddenSessionIds()).toContain(ccID);

    addProcess(environment, 901, home + "/.local/bin/claude");
    addMetadata(environment, 901, {
      sessionId: ccID, cwd, kind: "interactive", entrypoint: "cli", status: "idle",
    });
    const interactive = await source.refresh();
    expect(interactive.sessions).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: ccID, canOpenOwner: true }),
    ]));
    expect(provider.hiddenSessionIds()).not.toContain(ccID);
  });

  it("keeps seven-day menu visibility based on activity and preserves separate same-CWD history", async () => {
    const environment = new FixtureEnvironment();
    const old = backgroundRow("0a0b0c0d", "0a0b0c0d-cd3b-4140-a8da-4614085a3536", "done", {
      startedAt: nowMs - 8 * 24 * 60 * 60 * 1_000,
      name: "older",
    });
    const recent = backgroundRow("1a1b1c1d", "1a1b1c1d-cd3b-4140-a8da-4614085a3536", "done", {
      startedAt: nowMs - 24 * 60 * 60 * 1_000,
      name: "recent",
    });
    environment.inventory = inventorySuccess([old, recent]);

    const source = repository(environment);
    const snapshot = await source.refresh();
    const pills = menuPresentation(snapshot, [], nowMs).pills;

    expect(snapshot.sessions.map((session) => session.id)).toEqual([
      recent.sessionId, old.sessionId,
    ]);
    expect(pills).toEqual([]);
    expect(menuPresentation(snapshot, [], nowMs).navigatorPills.map((pill) => pill.title)).toEqual(["recent"]);
  });

  it("keeps a failure present at startup in History without an ambient pill", async () => {
    const environment = new FixtureEnvironment();
    const failed = backgroundRow("c3d7c7a4", "c3d7c7a4-cd3b-4140-a8da-4614085a3536", "failed", {
      name: "cc-av",
    });
    environment.inventory = inventorySuccess([failed]);

    const source = repository(environment);
    const snapshot = await source.refresh();
    const presentation = menuPresentation(snapshot, [], nowMs);

    expect(snapshot.sessions).toMatchObject([{
      id: failed.sessionId,
      section: "history",
      failureAlert: false,
    }]);
    expect(presentation.pills).not.toContainEqual(expect.objectContaining({ id: failed.sessionId }));
    expect(presentation.navigatorPills).toContainEqual(expect.objectContaining({ id: failed.sessionId }));
  });

  it("alerts on a watched failure, dismisses it into History, and re-alerts after new work", async () => {
    const environment = new FixtureEnvironment();
    const failed = backgroundRow("c3d7c7a4", "c3d7c7a4-cd3b-4140-a8da-4614085a3536", "failed", {
      name: "cc-av",
    });
    const working = { ...failed, state: "working" };
    const source = repository(environment);

    environment.inventory = inventorySuccess([working]);
    expect((await source.refresh()).sessions).toMatchObject([{
      id: failed.sessionId, section: "working",
    }]);

    environment.inventory = inventorySuccess([failed]);
    const alerted = await source.refresh();
    expect(alerted.sessions).toMatchObject([{
      id: failed.sessionId,
      section: "needs_you",
      failureAlert: true,
    }]);
    expect(menuPresentation(alerted, [], nowMs).navigatorPills).toContainEqual(
      expect.objectContaining({ id: failed.sessionId, phase: "needs_you", failureAlert: true, defaultOverflowEligible: false }),
    );

    await expect(source.chatOpened(failed.sessionId, "failure-lease")).resolves.toBeUndefined();
    source.acknowledgeFailure(failed.sessionId);
    expect(source.current().sessions).toMatchObject([{
      id: failed.sessionId,
      section: "history",
      failureAlert: false,
    }]);
    expect(menuPresentation(source.current(), [], nowMs).pills).not.toContainEqual(
      expect.objectContaining({ id: failed.sessionId }),
    );

    expect((await source.refresh()).sessions).toMatchObject([{
      id: failed.sessionId, section: "history", failureAlert: false,
    }]);

    environment.inventory = inventorySuccess([working]);
    expect((await source.refresh()).sessions).toMatchObject([{
      id: failed.sessionId, section: "working",
    }]);
    environment.inventory = inventorySuccess([failed]);
    expect((await source.refresh()).sessions).toMatchObject([{
      id: failed.sessionId, section: "needs_you", failureAlert: true,
    }]);
  });

  it("keeps a failed row terminal until fresh inventory proves new work", async () => {
    const environment = new FixtureEnvironment();
    const failed = backgroundRow("c3d7c7a4", "c3d7c7a4-cd3b-4140-a8da-4614085a3536", "failed", {
      name: "cc-av",
    });
    const working = { ...failed, state: "working" };
    const source = repository(environment);

    environment.inventory = inventorySuccess([working]);
    await source.refresh();
    environment.inventory = inventorySuccess([failed], true, nowMs + 500);
    const initial = await source.refresh();
    expect(initial.sessions).toMatchObject([{
      id: failed.sessionId, section: "needs_you", failureAlert: true,
    }]);

    const processing = source.applyHook({
      sessionId: failed.sessionId, cwd, provider: "claude_code", event: "UserPromptSubmit",
      status: "processing", tty: "ttys001", receivedAt: new Date(nowMs + 1_000).toISOString(),
    });
    expect(processing.sessions).toMatchObject([{
      id: failed.sessionId, section: "needs_you", failureAlert: true,
    }]);

    const ready = source.applyHook({
      sessionId: failed.sessionId, cwd, provider: "claude_code", event: "Stop",
      status: "idle", tty: "ttys001", receivedAt: new Date(nowMs + 2_000).toISOString(),
    });
    expect(ready.sessions).toMatchObject([{
      id: failed.sessionId, section: "needs_you", failureAlert: true,
    }]);

    environment.inventory = inventorySuccess([working], true, nowMs + 3_000);
    const refreshed = await source.refresh();
    expect(refreshed.sessions).toMatchObject([{
      id: failed.sessionId, section: "working",
    }]);
    expect(refreshed.sessions[0]?.failureAlert).toBeUndefined();
  });

  it("re-alerts a failure after a complete catalog removes and reintroduces the job", async () => {
    const environment = new FixtureEnvironment();
    const failed = backgroundRow("c3d7c7a4", "c3d7c7a4-cd3b-4140-a8da-4614085a3536", "failed", {
      name: "cc-av",
    });
    const source = repository(environment);

    environment.inventory = inventorySuccess([failed]);
    await source.refresh();
    environment.inventory = inventorySuccess([]);
    expect((await source.refresh()).sessions).toEqual([]);

    environment.inventory = inventorySuccess([failed], true, nowMs + 1_000);
    expect((await source.refresh()).sessions).toMatchObject([{
      id: failed.sessionId, section: "needs_you", failureAlert: true,
    }]);
  });

  it("does not promote an old failure during an inventory outage or after provider restart", async () => {
    const environment = new FixtureEnvironment();
    const failed = backgroundRow("c3d7c7a4", "c3d7c7a4-cd3b-4140-a8da-4614085a3536", "failed", {
      name: "cc-av",
    });
    environment.inventory = inventorySuccess([failed]);
    const source = repository(environment);
    await source.refresh();

    environment.inventory = inventoryFailure(inventorySuccess([failed], false, nowMs + 1_000));
    const outage = await source.refresh();
    expect(outage.sessions).toMatchObject([{
      id: failed.sessionId, section: "history", failureAlert: false,
    }]);
    expect(menuPresentation(outage, [], nowMs).pills).not.toContainEqual(
      expect.objectContaining({ id: failed.sessionId }),
    );

    const restarted = repository(environment);
    const afterRestart = await restarted.refresh();
    expect(afterRestart.sessions).toMatchObject([{
      id: failed.sessionId, section: "history", failureAlert: false,
    }]);
    expect(menuPresentation(afterRestart, [], nowMs).pills).not.toContainEqual(
      expect.objectContaining({ id: failed.sessionId }),
    );
  });
});
