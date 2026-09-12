import { describe, expect, it } from "vitest";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { menuPresentation } from "../menu.js";
import { SessionRepository } from "../sessions.js";
import { CodexProvider } from "./codex.js";
import { LiveProviderEnvironment, type ProcessRecord } from "./environment.js";

const sessionId = "codex-desktop";
const cwd = "/fixture/project";
const rollout = "/fixture/.codex/session.jsonl";

class StatusEnvironment extends LiveProviderEnvironment {
  clock = Date.parse("2026-08-30T21:45:25.000Z");
  content = "";
  modifiedAt = this.clock;
  unavailable = false;
  terminal = false;
  title = "Desktop task";

  constructor() { super("/fixture"); }
  override now() { return new Date(this.clock); }
  override async processes(): Promise<ProcessRecord[]> {
    return this.terminal ? [{ pid: 42, parentPID: 1, tty: "ttys001", command: "codex", arguments: "codex" }] : [];
  }
  override async cwd() { return cwd; }
  override async processStartedAt() { return new Date(0); }
  override async stamp(file: string) {
    if (file === "/fixture/.codex/state_5.sqlite") {
      return { modifiedAt: this.now(), size: 100 };
    }
    return file === rollout
      ? { modifiedAt: new Date(this.modifiedAt), size: Buffer.byteLength(this.content) }
      : undefined;
  }
  override async read() { return undefined; }
  override async sqlite() {
    return [{ id: sessionId, cwd, rollout_path: rollout, title: this.title,
      updated_at: this.modifiedAt / 1_000, archived: 0, source: this.terminal ? "cli" : "vscode" }];
  }
  override async scanLinePrefixes(
    _file: string, prefixBytes: number, visit: (line: string) => void, startAt = 0,
  ) {
    if (this.unavailable) return startAt;
    const bytes = Buffer.from(this.content);
    let offset = startAt;
    for (;;) {
      const end = bytes.indexOf(0x0a, offset);
      if (end < 0) return offset;
      visit(bytes.subarray(offset, Math.min(end, offset + prefixBytes)).toString("utf8"));
      offset = end + 1;
    }
  }
  append(type: string, turnId: string) {
    this.clock += 1_000;
    this.modifiedAt = this.clock;
    this.content += JSON.stringify({ type: "event_msg", timestamp: this.now().toISOString(),
      payload: { type, turn_id: turnId } }) + "\n";
  }
}

function setup() {
  const environment = new StatusEnvironment();
  const repository = new SessionRepository([new CodexProvider(environment)], {
    now: () => environment.now(),
  });
  const hook = (event: string, status: string) => {
    environment.clock += 1;
    return repository.applyHook({ sessionId, provider: "codex", cwd,
      event, status, receivedAt: environment.now().toISOString() });
  };
  return { environment, repository, hook };
}

describe("Codex desktop lifecycle status", () => {
  const metadata = (originator: string, id = sessionId) => JSON.stringify({
    timestamp: "2026-08-30T21:45:25.000Z", type: "session_meta",
    payload: { id, originator, source: "vscode", base_instructions: { text: "x".repeat(20_000) } },
  }) + "\n";

  it("keeps Agent Room sessions searchable but out of pills and default overflow", async () => {
    const { environment, repository } = setup();
    environment.title = "hi\n\nInstruction author: local:fixture";
    environment.content = metadata("Agent Room");
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    const snapshot = await repository.refresh();
    expect(snapshot.sessions).toMatchObject([{
      id: sessionId, title: "hi", sessionClass: "interactive", managedBy: "Agent Room",
      section: "ready", subtitle: "Managed by Agent Room · Ready to continue",
      canOpenOwner: true, canEnterChat: true,
    }]);
    const presentation = menuPresentation(snapshot, [], environment.clock);
    expect(presentation.pills).toEqual([]);
    expect(presentation.navigatorPills).toMatchObject([{
      id: sessionId, defaultOverflowEligible: false,
    }]);
    expect(await new CodexProvider(environment).resolve(sessionId)).toMatchObject({ managedBy: "Agent Room" });
  });

  it("restores pill visibility when a later client record identifies direct Codex use", async () => {
    const { environment, repository } = setup();
    environment.content = metadata("Agent Room");
    environment.append("task_started", "turn-1");
    expect(menuPresentation(await repository.refresh(), [], environment.clock).pills).toEqual([]);
    environment.content += metadata("Codex Desktop");
    environment.modifiedAt += 1;
    const snapshot = await repository.refresh();
    expect(snapshot.sessions[0]?.managedBy).toBeUndefined();
    expect(snapshot.sessions[0]?.subtitle).toBe("Agent is working");
    expect(menuPresentation(snapshot, [], environment.clock).pills.map(({ id }) => id)).toEqual([sessionId]);
  });

  it.each([
    "", metadata("Codex Desktop"), metadata("Unknown client"),
    metadata("Agent Room", "another-session"),
    JSON.stringify({ type: "response_item", payload: { text: metadata("Agent Room") } }) + "\n",
  ])("does not hide sessions without matching Agent Room metadata (%#)", async (content) => {
    const { environment, repository } = setup();
    environment.title = "hi";
    environment.content = content;
    environment.append("task_started", "turn-1");
    const snapshot = await repository.refresh();
    expect(snapshot.sessions[0]?.managedBy).toBeUndefined();
    expect(menuPresentation(snapshot, [], environment.clock).pills.map(({ id }) => id)).toEqual([sessionId]);
  });

  it("classifies metadata-only sessions and waits for complete client records", async () => {
    const { environment, repository } = setup();
    environment.content = metadata("Agent Room");
    expect((await repository.refresh()).sessions[0]).toMatchObject({
      managedBy: "Agent Room", section: "history",
    });
    const direct = metadata("Codex Desktop");
    environment.content += direct.slice(0, -1);
    expect((await repository.refresh()).sessions[0]?.managedBy).toBe("Agent Room");
    environment.content += "\n";
    expect((await repository.refresh()).sessions[0]?.managedBy).toBeUndefined();
    // Replacing/truncating the transcript must not reuse the old client identity.
    environment.content = "";
    environment.append("task_started", "new-turn");
    expect(menuPresentation(await repository.refresh(), [], environment.clock).pills.map(({ id }) => id)).toEqual([sessionId]);
  });

  it("reads real UTF-8 transcript deltas across oversized content and partial writes", async () => {
    const directory = mkdtempSync(path.join(tmpdir(), "codex-status-"));
    const codex = path.join(directory, ".codex");
    mkdirSync(codex);
    const file = path.join(codex, "rollout.jsonl");
    const clock = new Date("2026-08-30T21:45:30Z");
    const record = (type: string, timestamp: string) => JSON.stringify({ timestamp,
      ordinal: 5, type: "event_msg", payload: { type, turn_id: "turn-1" } });
    writeFileSync(path.join(codex, "state_5.sqlite"), "fixture");
    writeFileSync(file, record("task_started", "2026-08-30T21:45:26Z") + "\n");
    const environment = new LiveProviderEnvironment(directory, { now: () => clock });
    environment.processes = async () => [];
    environment.sqlite = async () => [{ id: sessionId, cwd, rollout_path: file, title: "Disk task",
      updated_at: clock.valueOf() / 1_000, archived: 0, source: "vscode" }];
    const repository = new SessionRepository([new CodexProvider(environment)]);
    try {
      expect((await repository.refresh()).sessions[0]?.section).toBe("working");
      appendFileSync(file, JSON.stringify({ type: "response_item", payload: { type: "message",
        content: "中文🙂 task_complete turn_aborted ".repeat(20_000) } }) + "\n");
      const completion = record("task_complete", "2026-08-30T21:45:28Z") + "\n";
      appendFileSync(file, completion.slice(0, -10));
      expect((await repository.refresh()).sessions[0]?.section).toBe("working");
      appendFileSync(file, completion.slice(-10));
      expect((await repository.refresh()).sessions[0]?.section).toBe("ready");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("advances the session revision for content flushed during an unchanged turn", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    const first = await repository.refresh();
    const firstRevision = first.sessions[0]?.stateRevision;
    expect(firstRevision).toBeTypeOf("number");

    // No lifecycle marker changes here. A late response row still changes the
    // rollout stamp, which must wake Chat so an early empty native refresh is
    // not held until turn completion.
    environment.clock += 1_000;
    environment.modifiedAt = environment.clock;
    environment.content += JSON.stringify({ type: "response_item", payload: {
      type: "message", content: "late row",
    } }) + "\n";
    const second = await repository.refresh();
    expect(second.sessions[0]?.stateRevision).toBeGreaterThan(firstRevision);
    expect(second.sessions[0]?.sessionState).toMatchObject({
      route: "waiting", turn: "working",
    });
  });

  it.each([null, "", "x".repeat(257)])("rejects an invalid explicit terminal identity (%s)", async (turnId) => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    await repository.refresh();
    environment.clock += 1_000;
    environment.modifiedAt = environment.clock;
    environment.content += JSON.stringify({ timestamp: environment.now().toISOString(), type: "event_msg",
      payload: { type: "task_complete", turn_id: turnId } }) + "\n";
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
  });

  it("does not change hook-owned Codex CLI status", async () => {
    const { environment, repository, hook } = setup();
    environment.terminal = true;
    environment.append("task_started", "turn-1");
    await repository.refresh();

    expect(hook("Stop", "waiting_for_input").sessions[0]?.section).toBe("ready");
    expect((await repository.refresh()).sessions[0]?.section).toBe("ready");
  });

  it("waits for a complete line and then consumes an appended terminal marker", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    await repository.refresh();
    environment.clock += 1_000;
    environment.modifiedAt = environment.clock;
    const completion = JSON.stringify({ timestamp: environment.now().toISOString(),
      type: "event_msg", payload: { type: "task_complete", turn_id: "turn-1" } }) + "\n";
    environment.content += completion.slice(0, -10);
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");

    environment.content += completion.slice(-10);
    expect((await repository.refresh()).sessions[0]?.section).toBe("ready");
  });

  it("reconstructs status after restart and resets a truncated transcript", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    await repository.refresh();
    const restarted = new SessionRepository([new CodexProvider(environment)]);
    expect((await restarted.refresh()).sessions[0]?.section).toBe("ready");

    environment.content = "";
    environment.append("task_started", "turn-new");
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
  });

  it("does not carry an approval from a previous turn into a new turn", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-1");
    await repository.refresh();
    hook("PermissionRequest", "waiting_for_approval");
    environment.append("turn_aborted", "turn-1");
    environment.append("task_started", "turn-2");
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
    expect(hook("PermissionRequest", "waiting_for_approval").sessions[0]?.section).toBe("needs_you");
    expect(hook("PostToolUse", "processing").sessions[0]?.section).toBe("working");
  });

  it("recognizes completion when Codex embeds a large final answer in the boundary row", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    await repository.refresh();
    environment.clock += 1_000;
    environment.modifiedAt = environment.clock;
    environment.content += JSON.stringify({ timestamp: environment.now().toISOString(),
      type: "event_msg", payload: { type: "task_complete", turn_id: "turn-1",
        last_agent_message: "Long answer. ".repeat(10_000) } }) + "\n";

    expect((await repository.refresh()).sessions[0]?.section).toBe("ready");
  });

  it("keeps known transcript truth through a failed read and recovers on retry", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    await repository.refresh();
    hook("PostToolUse", "processing");
    environment.append("task_started", "turn-2");
    environment.unavailable = true;

    expect((await repository.refresh()).sessions[0]?.section).toBe("ready");

    environment.unavailable = false;
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
  });

  it("moves a dormant completed task to Recent after the stale ceiling but keeps Open Chat", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    await repository.refresh();
    hook("Stop", "waiting_for_input");
    environment.clock += 41 * 60 * 60 * 1_000;

    const snapshot = await repository.refresh();

    expect(snapshot.sessions).toMatchObject([{
      id: sessionId,
      section: "history",
      sessionState: { conversation: "open", turn: "ready" },
      canEnterChat: true,
    }]);
    expect(menuPresentation(snapshot, [], environment.clock).pills).toMatchObject([{
      id: sessionId,
      phase: "history",
    }]);
  });

  it("keeps a completed task Ready while it is still within the stale ceiling", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    environment.clock += 29 * 60_000;

    expect((await repository.refresh()).sessions[0]).toMatchObject({ section: "ready", sessionState: { turn: "ready" } });
  });

  it("does not keep a dead turn Working once its transcript has been quiet past the stale ceiling", async () => {
    // A thread whose process died right after task_started never writes a
    // completion marker. Months later it must not read as "Agent is working".
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");

    environment.clock += 65 * 24 * 60 * 60_000;

    const [session] = (await repository.refresh()).sessions;
    expect(session).toMatchObject({ id: sessionId, section: "history", canEnterChat: true });
    expect(session?.sessionState?.turn).not.toBe("working");
  });

  it("keeps a live turn Working while its transcript keeps changing", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    for (let step = 0; step < 6; step += 1) {
      // Two hours of streaming writes, none of them a lifecycle marker.
      environment.clock += 20 * 60_000;
      environment.modifiedAt = environment.clock;
      environment.content += JSON.stringify({ type: "event_msg",
        timestamp: environment.now().toISOString(), payload: { type: "token_count" } }) + "\n";
    }

    expect((await repository.refresh()).sessions[0]).toMatchObject({ section: "working", sessionState: { turn: "working" } });
  });

  it("does not revive a completed turn from a duplicate start marker", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    await repository.refresh();
    environment.append("task_started", "turn-1");

    expect((await repository.refresh()).sessions[0]?.section).toBe("ready");
  });

  it.each(["task_complete", "turn_aborted"])(
    "keeps %s Ready despite late tool hooks, and a new turn Working despite late Stop/idle hooks",
    async (completion) => {
      const { environment, repository, hook } = setup();
      environment.append("task_started", "turn-1");
      environment.append(completion, "turn-1");
      await repository.refresh();
      expect(hook("PostToolUse", "processing").sessions[0]?.section).toBe("ready");

      environment.append("task_started", "turn-2");
      expect((await repository.refresh()).sessions[0]?.section).toBe("working");
      expect(hook("Stop", "waiting_for_input").sessions[0]?.section).toBe("working");
      expect(hook("SessionStart", "idle").sessions[0]?.section).toBe("working");
    },
  );

  it("recovers a new turn from a stale Ready hook without receiving UserPromptSubmit", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    await repository.refresh();
    hook("Stop", "waiting_for_input");

    environment.append("task_started", "turn-2");

    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
  });

  it("preserves an approval hook while its turn runs, but clears it on completion", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-1");
    await repository.refresh();

    expect(hook("PermissionRequest", "waiting_for_approval").sessions[0]?.section).toBe("needs_you");
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");

    environment.append("task_complete", "turn-1");
    expect((await repository.refresh()).sessions[0]?.section).toBe("ready");
  });

  it("does not let an older turn's completion finish the new turn", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-old");
    environment.append("task_complete", "turn-old");
    await repository.refresh();
    hook("Stop", "waiting_for_input");
    environment.append("task_started", "turn-new");
    environment.append("task_complete", "turn-old");

    const snapshot = await repository.refresh();

    expect(snapshot.sessions[0]?.section).toBe("working");
    expect(menuPresentation(snapshot, [], environment.clock).pills[0]?.phase).toBe("working");
  });

  it("clears Running after Codex records an interrupted turn without a Stop hook", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-1");
    await repository.refresh();
    hook("UserPromptSubmit", "processing");
    environment.append("turn_aborted", "turn-1");

    const snapshot = await repository.refresh();

    expect(snapshot.sessions).toMatchObject([{ id: sessionId, section: "ready",
      canOpenOwner: true, canEnterChat: true }]);
    expect(menuPresentation(snapshot, [], environment.clock).pills).toMatchObject([{ id: sessionId, phase: "ready" }]);
  });
});
