import { expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { CodexProvider } from "./codex.js";
import { LiveProviderEnvironment, type ProcessRecord } from "./environment.js";
import { SessionRepository } from "../sessions.js";
import { activateMenuPill, nativeActionFor, menuPresentation } from "../menu.js";
import { NativeSessionControls } from "../session-controls.js";
import { FakeNativeHelper } from "../native-helper.js";
import { isCodexCliObservation } from "./codex-cli-observer.js";
import { processInstanceToken } from "./shared.js";

const now = new Date("2026-10-20T06:00:00Z");
const cwd = "/fixture/project";
const first = "11111111-1111-4111-8111-111111111111";
const second = "22222222-2222-4222-8222-222222222222";
const desktop = "33333333-3333-4333-8333-333333333333";

class Environment extends LiveProviderEnvironment {
  rows = [first, second, desktop].map((id, index) => ({ id, cwd,
    rollout_path: `/fixture/.codex/sessions/${id}.jsonl`, title: id, archived: 0,
    updated_at: now.valueOf() / 1000 + index, source: "vscode" }));
  running: ProcessRecord[] = [
    { pid: 42, parentPID: 7, tty: "ttys001", command: "/bin/codex", arguments: "codex" },
    { pid: 43, parentPID: 7, tty: "ttys002", command: "/bin/codex", arguments: "codex" },
    { pid: 7, parentPID: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
  ];
  extraRecords: unknown[] = [];
  constructor() { super("/fixture", { now: () => now }); }
  override async processes() { return this.running; }
  override async cwd() { return cwd; }
  override async processStartedAt() { return new Date(now.valueOf() - 1000); }
  override async read(_file: string, _maxBytes?: number) { return undefined; }
  override async directory(_directory: string) { return []; }
  override async stamp() { return { modifiedAt: now, size: 100 }; }
  override async sqlite(_database: string, query: string) {
    const id = /where id = '([^']+)'/.exec(query)?.[1];
    return id ? this.rows.filter(row => row.id === id) : this.rows;
  }
  override async herdrCodexSurface() { return undefined; }
  override async codexProcessHome() { return "/fixture/.codex"; }
  override async codexCliObservation(pid: number, home: string) {
    const raw = await this.read(`${home}/agent-visor/cli/${pid}.json`);
    const value: unknown = raw && JSON.parse(raw);
    return isCodexCliObservation(value) ? value : undefined;
  }
  override async scanLinePrefixes(file: string, _bytes: number, visit: (line: string) => void) {
    const id = file.split("/").at(-1)!.replace(".jsonl", "");
    visit(JSON.stringify({ type: "session_meta", payload: { id,
      originator: id === desktop ? "Codex Desktop" : "codex-tui" } }));
    visit(JSON.stringify({ type: "event_msg", timestamp: now.toISOString(), payload: { type: "task_complete" } }));
    this.extraRecords.forEach(record => visit(JSON.stringify(record)));
    return 100;
  }
}

class ModernEnvironment extends Environment {
  override readonly readCodexTuiBinding = async (pid: number) => pid === 42 ? {
    sessionIds: [first],
    origin: "http://127.0.0.1:43123",
    socketPath: "/fixture/app-server-control.sock",
    socketIdentity: "1:2:501",
    inventory: { loaded: [first], roots: [{ id: first, path: null }] },
  } : undefined;
}

it("uses exact CLI hook identities for two terminals in one cwd without stealing a Desktop session", async () => {
  const environment = new Environment();
  const repository = new SessionRepository([new CodexProvider(environment)], { now: () => now });
  const helper = new FakeNativeHelper();
  repository.setControls(new NativeSessionControls(helper));
  repository.applyHook({ provider: "codex", sessionId: first, cwd, pid: 43, tty: "/dev/ttys002",
    event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
  repository.applyHook({ provider: "codex", sessionId: second, cwd, pid: 42, tty: "/dev/ttys001",
    event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
  await repository.refresh();
  const effects: unknown[] = [];
  for (const sessionId of [first, second]) {
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId }, repository, effect => effects.push(effect));
  }
  expect(helper.terminalFocusRequests.map(target => target.pid)).toEqual([43, 42]);
  expect(helper.codexThreadRequests).toEqual([]);
  expect(repository.chatRecord(desktop)?.controlTarget).toEqual({ kind: "url", url: `codex://threads/${desktop}` });
  expect(effects).toEqual([]);
});

it("projects exact live CLI ownership as open while catalog-only Desktop rows stay unavailable", async () => {
  const environment = new Environment();
  const provider = new CodexProvider(environment);
  provider.noteHook({ provider: "codex", sessionId: first, cwd, pid: 42, tty: "/dev/ttys001",
    event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
  const repository = new SessionRepository([provider], { now: () => now });

  const snapshot = await repository.refresh();

  expect(snapshot.sessions.find(session => session.id === first)).toMatchObject({
    owner: "Ghostty",
    presence: { state: "open", evidence: "frontend" },
  });
  expect(repository.chatRecord(first)).toMatchObject({
    presence: { state: "open", evidence: "frontend" },
    controlTarget: { kind: "terminal", target: { pid: 42, cwd } },
  });
  expect(snapshot.sessions.find(session => session.id === desktop)).toMatchObject({
    presence: { state: "unknown", evidence: "catalog" },
  });
  expect(repository.chatRecord(desktop)).toMatchObject({
    presence: { state: "unknown", evidence: "catalog" },
    controlTarget: { kind: "url", url: `codex://threads/${desktop}` },
  });
});

it("uses the exact modern TUI binding as CLI ownership beside a background app-server", async () => {
  const environment = new ModernEnvironment();
  environment.running.push({ pid: 44, parentPID: 7, command: "/bin/codex",
    arguments: "codex app-server --managed-daemon" });
  const repository = new SessionRepository([new CodexProvider(environment)], { now: () => now });

  const snapshot = await repository.refresh();

  expect(snapshot.sessions.find(session => session.id === first)).toMatchObject({
    owner: "Ghostty",
    presence: { state: "open", evidence: "frontend" },
  });
  expect(repository.chatRecord(first)?.controlTarget).toMatchObject({
    kind: "terminal", target: { pid: 42, cwd },
  });
  expect(snapshot.sessions.find(session => session.id === desktop)).toMatchObject({
    presence: { state: "unknown", evidence: "catalog" },
  });
});

it("does not admit a catalog-only Desktop row into ambient pills", async () => {
  const environment = new Environment();
  const snapshot = await new SessionRepository([new CodexProvider(environment)], { now: () => now }).refresh();

  expect(snapshot.sessions.find(session => session.id === desktop)).toMatchObject({
    presence: { state: "unknown", evidence: "catalog" },
    ambientEligible: false,
  });
  expect(menuPresentation(snapshot, [], now.valueOf()).pills)
    .not.toContainEqual(expect.objectContaining({ id: desktop }));
});

it("keeps an exact live CLI identity unavailable when its catalog row is omitted", async () => {
  const environment = new Environment();
  const provider = new CodexProvider(environment);
  provider.noteHook({ provider: "codex", sessionId: first, cwd, pid: 42, tty: "/dev/ttys001",
    event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
  const repository = new SessionRepository([provider], { now: () => now });
  await repository.refresh();

  environment.rows = environment.rows.filter(row => row.id !== first);
  const snapshot = await repository.refresh();

  expect(snapshot.sessions).toContainEqual(expect.objectContaining({
    id: first,
    presence: expect.objectContaining({ state: "unknown", evidence: "unavailable" }),
  }));
  expect(repository.chatRecord(first)).toMatchObject({
    controlTarget: { kind: "terminal", target: { pid: 42, cwd } },
  });
  expect(snapshot.sessions).toContainEqual(expect.objectContaining({
    id: desktop,
    presence: expect.objectContaining({ state: "unknown", evidence: "unavailable" }),
  }));
});

it.each(["stale-pid", "wrong-tty", "wrong-home", "ambiguous"])("does not guess a CLI destination when identity is %s", async change => {
  const environment = new Environment();
  if (change === "stale-pid") environment.processStartedAt = async () => new Date(now.valueOf() + 1000);
  if (change === "wrong-home") environment.codexProcessHome = async () => "/fixture/copilot";
  const provider = new CodexProvider(environment);
  provider.noteHook({ provider: "codex", sessionId: first, cwd, pid: 42,
    tty: change === "wrong-tty" ? "/dev/ttys099" : "/dev/ttys001",
    event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
  if (change === "ambiguous") provider.noteHook({ provider: "codex", sessionId: first, cwd, pid: 43, tty: "/dev/ttys002",
    event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
  const repository = new SessionRepository([provider], { now: () => now });
  const helper = new FakeNativeHelper(); repository.setControls(new NativeSessionControls(helper));
  await repository.refresh();
  expect(repository.chatRecord(first)?.controlTarget).toBeUndefined();
  expect(await repository.focusSession(first)).toContain("Codex CLI terminal");
  expect(helper.terminalFocusRequests).toEqual([]);
});

it("keeps unanswered CLI questions yellow even when their exact terminal is unavailable", async () => {
  const environment = new Environment();
  environment.extraRecords = [
    { type: "event_msg", timestamp: now.toISOString(), payload: { type: "task_started", turn_id: "question-turn" } },
    { type: "response_item", timestamp: now.toISOString(), payload: { type: "function_call", name: "request_user_input_async",
      call_id: "question", arguments: JSON.stringify({ questions: [{ title: "Proceed?" }] }) } },
  ];
  const repository = new SessionRepository([new CodexProvider(environment)], { now: () => now });
  await repository.refresh();
  expect(repository.current().sessions.find(session => session.id === first)).toMatchObject({ section: "needs_you", canOpenOwner: false });
});

it("closes observed CLI history when the process exits while its catalog row remains", async () => {
  const directory = mkdtempSync(path.join(tmpdir(), "agent-visor-codex-history-close-"));
  try {
    const environment = new Environment();
    const provider = new CodexProvider(environment);
    provider.noteHook({ provider: "codex", sessionId: first, cwd, pid: 42, tty: "/dev/ttys001",
      event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
    const repository = new SessionRepository([provider], {
      now: () => now,
      retainedHistoryPath: path.join(directory, "retained-history.json"),
    });

    await repository.refresh();
    expect(repository.historyPage().total).toBe(0);

    environment.running = environment.running.filter((process) => process.pid !== 42);
    const snapshot = await repository.refresh();

    expect(repository.chatRecord(first)).toMatchObject({
      owner: "Codex CLI",
      canOpenOwner: false,
      historyIdentity: { verified: true, current: false },
    });
    expect(snapshot.sessions).toContainEqual(expect.objectContaining({
      id: first,
      owner: "Codex CLI",
      canOpenOwner: false,
      sessionClass: "terminal",
    }));
    expect(repository.historyPage()).toMatchObject({
      total: 1,
      sessions: [expect.objectContaining({ id: first, source: "Codex", owner: "Ghostty" })],
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

it("reconstructs durable CLI provenance without restoring a Desktop route", async () => {
  const directory = mkdtempSync(path.join(tmpdir(), "agent-visor-codex-history-restart-"));
  try {
    const historyPath = path.join(directory, "retained-history.json");
    const environment = new Environment();
    const firstProvider = new CodexProvider(environment);
    firstProvider.noteHook({ provider: "codex", sessionId: first, cwd, pid: 42, tty: "/dev/ttys001",
      event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
    const firstRepository = new SessionRepository([firstProvider], { now: () => now, retainedHistoryPath: historyPath });
    await firstRepository.refresh();

    environment.running = [];
    const repository = new SessionRepository([new CodexProvider(environment)], {
      now: () => now,
      retainedHistoryPath: historyPath,
    });
    const snapshot = await repository.refresh();
    const session = snapshot.sessions.find(({ id }) => id === first);
    expect(session).toMatchObject({
      owner: "Codex CLI",
      canOpenOwner: false,
      sessionClass: "terminal",
      canEnterChat: true,
    });
    expect(repository.chatRecord(first)).toMatchObject({
      owner: "Codex CLI",
      canOpenOwner: false,
      historyIdentity: { verified: true, current: false },
    });
    expect(repository.chatRecord(first)?.controlTarget).toBeUndefined();
    expect(menuPresentation(snapshot, [], now.valueOf()).pills).not.toContainEqual(expect.objectContaining({ id: first }));
    expect(nativeActionFor({ version: 1, type: "event", event: "activate_pill", sessionId: first }, snapshot))
      .toEqual({ type: "native_action", action: "open_chat", sessionId: first });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

it("revalidates CLI identity when the same terminal switches conversations before a click", async () => {
  const environment = new Environment();
  const provider = new CodexProvider(environment);
  const repository = new SessionRepository([provider], { now: () => now });
  const helper = new FakeNativeHelper();
  repository.setControls(new NativeSessionControls(helper));
  const hook = { provider: "codex" as const, cwd, pid: 42, tty: "/dev/ttys001",
    event: "SessionStart", status: "idle", receivedAt: now.toISOString() };
  repository.applyHook({ ...hook, sessionId: first });
  await repository.refresh();
  provider.noteHook({ ...hook, sessionId: second });
  expect(await repository.focusSession(first)).toBeTypeOf("string");
  expect(helper.terminalFocusRequests).toEqual([]);
});


it("recovers a resumed CLI from its observer record after restart without routing its same-name Desktop peer", async () => {
  const environment = new Environment();
  environment.scanLinePrefixes = async (file, _bytes, visit) => {
    const id = file.split("/").at(-1)!.replace(".jsonl", "");
    visit(JSON.stringify({ type: "session_meta", payload: { id, originator: "Codex Desktop" } }));
    visit(JSON.stringify({ type: "event_msg", timestamp: now.toISOString(), payload: { type: "task_complete" } }));
    return 100;
  };
  environment.rows.forEach(row => { row.title = "AR"; row.cwd = "/fixture/Agent Room"; });
  const observation = { version: 1, sessionId: first, pid: 42, tty: "ttys001", cwd: "/fixture/Agent Room",
    home: "/fixture/.codex", observedAt: now.toISOString(),
    processStartToken: processInstanceToken(42, new Date(now.valueOf() - 1000)),
    sessionFile: `/fixture/.codex/sessions/${first}.jsonl`, ended: false };
  environment.directory = async directory => directory === "/fixture/.codex/agent-visor/cli" ? ["42.json"] : [];
  environment.read = async file => file === "/fixture/.codex/agent-visor/cli/42.json" ? JSON.stringify(observation) : undefined;
  for (let boot = 0; boot < 2; boot++) {
    const repository = new SessionRepository([new CodexProvider(environment)], { now: () => now });
    const helper = new FakeNativeHelper(); repository.setControls(new NativeSessionControls(helper));
    for (let refresh = 0; refresh < 2; refresh++) await repository.refresh();
    expect(repository.chatRecord(first)?.controlTarget).toMatchObject({ kind: "terminal", target: { pid: 42, cwd } });
    expect(repository.chatRecord(first)?.sessionClass).toBe("terminal");
    expect(repository.chatRecord(first)?.historyIdentity).toMatchObject({
      verified: true,
      canonicalId: `codex:native:${first}`,
      configHome: "/fixture/.codex",
    });
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: first }, repository, () => {});
    expect(helper.terminalFocusRequests.map(target => target.pid)).toEqual([42]);
    expect(helper.codexThreadRequests).toEqual([]);
    expect(repository.chatRecord(desktop)?.controlTarget).toEqual({ kind: "url", url: `codex://threads/${desktop}` });
  }
});


it.each(["host-lost", "pid-reused", "ended", "observer-lost", "wrong-transcript"])("keeps a known Desktop-origin CLI unavailable instead of stealing its route (%s)", async change => {
  const environment = new Environment();
  environment.scanLinePrefixes = async (file, _bytes, visit) => {
    const id = file.split("/").at(-1)!.replace(".jsonl", "");
    visit(JSON.stringify({ type: "session_meta", payload: { id, originator: "Codex Desktop" } }));
    return 100;
  };
  const observation = { version: 1, sessionId: first, pid: 42, tty: "ttys001", cwd, home: "/fixture/.codex",
    processStartToken: processInstanceToken(42, new Date(now.valueOf() - 1000)), observedAt: now.toISOString(), ended: false, sessionFile: `/fixture/.codex/sessions/${first}.jsonl` };
  environment.directory = async directory => directory === "/fixture/.codex/agent-visor/cli" ? ["42.json"] : [];
  environment.read = async file => file.endsWith("/cli/42.json") ? JSON.stringify(observation) : undefined;
  const repository = new SessionRepository([new CodexProvider(environment)], { now: () => now });
  const helper = new FakeNativeHelper(); repository.setControls(new NativeSessionControls(helper));
  await repository.refresh();
  expect(repository.chatRecord(first)?.controlTarget?.kind).toBe("terminal");
  if (change === "host-lost") environment.running = environment.running.filter(process => process.pid !== 42);
  if (change === "pid-reused") environment.processStartedAt = async () => new Date(now.valueOf() + 1000);
  if (change === "ended") observation.ended = true;
  if (change === "observer-lost") environment.read = async () => undefined;
  if (change === "wrong-transcript") observation.sessionFile = `/fixture/.codex/sessions/${second}.jsonl`;
  await repository.refresh();
  expect(repository.chatRecord(first)?.controlTarget).toBeUndefined();
  expect(await repository.focusSession(first)).toContain("Codex CLI terminal");
  expect(helper.codexThreadRequests).toEqual([]);
  expect(helper.terminalFocusRequests).toEqual([]);
  expect(repository.chatRecord(desktop)?.controlTarget?.kind).toBe("url");
});


it.each(["working", "question", "async-question"])("restores a CLI's %s attention from its transcript after daemon restart", async state => {
  const environment = new Environment();
  environment.extraRecords = [
    { type: "event_msg", timestamp: now.toISOString(), payload: { type: "task_started", turn_id: "cli-turn" } },
    ...(state === "working" ? [] : [{ type: "response_item", timestamp: now.toISOString(), payload: {
      type: "function_call", name: state === "question" ? "request_user_input" : "request_user_input_async",
      call_id: "question", arguments: JSON.stringify({ questions: [{ title: "Proceed?" }] }) } }]),
  ];
  environment.rows[0]!.source = "cli";
  const observation = { version: 1, sessionId: first, pid: 42, tty: "ttys001", cwd, home: "/fixture/.codex",
    processStartToken: processInstanceToken(42, new Date(now.valueOf() - 1000)), observedAt: now.toISOString(), ended: false };
  environment.directory = async directory => directory === "/fixture/.codex/agent-visor/cli" ? ["42.json"] : [];
  environment.read = async file => file.endsWith("/cli/42.json") ? JSON.stringify(observation) : undefined;
  const repository = new SessionRepository([new CodexProvider(environment)], { now: () => now });
  await repository.refresh();
  expect(repository.current().sessions.find(session => session.id === first)).toMatchObject({
    section: state === "working" ? "working" : "needs_you", canOpenOwner: true,
  });
});


it("does not authorize a CLI route from generic JSON after the secure observer reader rejected it", async () => {
  const environment = new Environment();
  const observation = { version: 1, sessionId: first, pid: 42, tty: "ttys001", cwd, home: "/fixture/.codex",
    processStartToken: processInstanceToken(42, new Date(now.valueOf() - 1000)), observedAt: now.toISOString(), ended: false };
  environment.directory = async directory => directory === "/fixture/.codex/agent-visor/cli" ? ["42.json"] : [];
  environment.read = async file => file.endsWith("/cli/42.json") ? JSON.stringify(observation) : undefined;
  environment.codexCliObservation = async () => undefined;
  const repository = new SessionRepository([new CodexProvider(environment)], { now: () => now });
  await repository.refresh();
  expect(repository.chatRecord(first)?.controlTarget).toBeUndefined();
});

class ExplicitlyUnsupportedModernEnvironment extends Environment {
  override readonly readCodexTuiBinding = async () => undefined;
  override readonly codexTuiTransportCapability = async () => "unsupported" as const;
}

class UnknownModernEnvironment extends Environment {
  override readonly readCodexTuiBinding = async () => undefined;
}

it("keeps the exact legacy CLI route when modern transport absence is explicitly proven", async () => {
  const environment = new ExplicitlyUnsupportedModernEnvironment();
  const provider = new CodexProvider(environment);
  provider.noteHook({ provider: "codex", sessionId: first, cwd, pid: 42, tty: "ttys001",
    event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
  const repository = new SessionRepository([provider], { now: () => now });
  await repository.refresh();
  expect(repository.chatRecord(first)?.controlTarget).toMatchObject({
    kind: "terminal", target: { pid: 42, cwd },
  });
});

it("does not fall back to a legacy observer when modern transport probing is unknown", async () => {
  const environment = new UnknownModernEnvironment();
  const provider = new CodexProvider(environment);
  provider.noteHook({ provider: "codex", sessionId: first, cwd, pid: 42, tty: "ttys001",
    event: "SessionStart", status: "idle", receivedAt: now.toISOString() });
  const repository = new SessionRepository([provider], { now: () => now });
  await repository.refresh();
  expect(repository.chatRecord(first)?.controlTarget).toBeUndefined();
});
