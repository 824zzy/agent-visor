import path from "node:path";
import { describe, expect, it } from "vitest";
import type { ProcessRecord, ProviderEnvironment, FileStamp } from "./environment.js";
import {
  type ClaudeAgentInventoryFailure,
  type ClaudeAgentInventoryResult,
  type ClaudeAgentInventoryRow,
  type ClaudeAgentInventorySuccess,
} from "./claude-agent-inventory.js";
import { ClaudeProvider } from "./claude.js";
import { activateMenuPill, menuPresentation } from "../menu.js";
import { FakeNativeHelper } from "../native-helper.js";
import { NativeSessionControls } from "../session-controls.js";
import { SessionRepository } from "../sessions.js";

const home = "/Users/me";
const cwd = home + "/Codes/agent-visor";
const now = new Date("2026-08-22T08:00:00.000Z");
const nowMs = now.valueOf();
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

describe("Claude agent-view integration", () => {
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

  it("shows no pills for an agent overview while retaining its background jobs in search", async () => {
    const environment = new FixtureEnvironment();
    addProcess(environment, 900, home + "/.local/bin/claude");
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
      .toEqual([blockedID, ccID]);
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

  it("demotes an old no-PID done job in the native menu while retaining Ready turn evidence", async () => {
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
      { id: old.sessionId, phase: "ready", attentionTier: "history" },
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
