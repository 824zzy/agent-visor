import { expect, it } from "vitest";
import { CodexProvider } from "./codex.js";
import { LiveProviderEnvironment, type ProcessRecord } from "./environment.js";
import { SessionRepository } from "../sessions.js";
import { activateMenuPill } from "../menu.js";
import { NativeSessionControls } from "../session-controls.js";
import { FakeNativeHelper } from "../native-helper.js";

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
  override async read() { return undefined; }
  override async directory() { return []; }
  override async stamp() { return { modifiedAt: now, size: 100 }; }
  override async sqlite(_database: string, query: string) {
    const id = /where id = '([^']+)'/.exec(query)?.[1];
    return id ? this.rows.filter(row => row.id === id) : this.rows;
  }
  override async herdrCodexSurface() { return undefined; }
  override async codexProcessHome() { return "/fixture/.codex"; }
  override async scanLinePrefixes(file: string, _bytes: number, visit: (line: string) => void) {
    const id = file.split("/").at(-1)!.replace(".jsonl", "");
    visit(JSON.stringify({ type: "session_meta", payload: { id,
      originator: id === desktop ? "Codex Desktop" : "codex-tui" } }));
    visit(JSON.stringify({ type: "event_msg", timestamp: now.toISOString(), payload: { type: "task_complete" } }));
    this.extraRecords.forEach(record => visit(JSON.stringify(record)));
    return 100;
  }
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
