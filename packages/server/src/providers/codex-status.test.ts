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
  append(type: string, turnId?: string) {
    this.clock += 1_000;
    this.modifiedAt = this.clock;
    this.content += JSON.stringify({ type: "event_msg", timestamp: this.now().toISOString(),
      payload: { type, ...(turnId ? { turn_id: turnId } : {}) } }) + "\n";
  }
  response(payload: Record<string, unknown>) {
    this.clock += 1_000;
    this.modifiedAt = this.clock;
    this.content += JSON.stringify({ type: "response_item", timestamp: this.now().toISOString(), payload }) + "\n";
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
  it.each(["task_complete", "turn_aborted"])(
    "clears async question attention when its owning turn emits %s", async (event) => {
      const { environment, repository } = setup();
      environment.append("task_started", "owning-turn");
      environment.response({ type: "function_call", name: "request_user_input_async", call_id: "finished-question",
        arguments: JSON.stringify({ questions: [{ title: "Which option?" }] }) });
      environment.response({ type: "function_call_output", call_id: "finished-question", output: '{"accepted":true}' });
      expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
      environment.append(event, "owning-turn");
      const snapshot = await repository.refresh();
      expect(snapshot.sessions[0]?.section).toBe("ready");
      expect(menuPresentation(snapshot, [], environment.clock).pills[0]?.phase).toBe("ready");
    },
  );

  it("clears replaced async questions without letting duplicate starts or late terminal events clear a current question", async () => {
    const { environment, repository } = setup();
    const ask = (callId: string) => environment.response({ type: "function_call", name: "request_user_input_async", call_id: callId,
      arguments: JSON.stringify({ questions: [{ title: "Which option?" }] }) });
    environment.append("task_started", "turn-1");
    ask("old-question");
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    environment.append("task_started", "turn-1");
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    environment.append("task_started", "turn-2");
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
    ask("current-question");
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    environment.append("task_complete", "turn-1");
    environment.append("turn_aborted", "turn-1");
    const snapshot = await repository.refresh();
    expect(snapshot.sessions[0]?.section).toBe("needs_you");
    expect(menuPresentation(snapshot, [], environment.clock).pills[0]?.phase).toBe("needs_you");
    environment.append("task_complete", "turn-2");
    expect((await repository.refresh()).sessions[0]?.section).toBe("ready");
  });

  it.each(["request_user_input", "request_user_input_async"])(
    "does not resurrect a late %s belonging to a previous turn", async (name) => {
      const { environment, repository } = setup();
      environment.append("task_started", "previous-turn");
      environment.append("task_complete", "previous-turn");
      environment.append("task_started", "current-turn");
      const question = (turnId: string, callId: string) => environment.response({ type: "function_call", name, call_id: callId,
        arguments: JSON.stringify({ questions: [{ title: "Which option?" }] }),
        internal_chat_message_metadata_passthrough: { turn_id: turnId },
      });
      question("previous-turn", "late-old-question");
      expect((await repository.refresh()).sessions[0]?.section).toBe("working");
      question("current-turn", "current-question");
      expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    },
  );

  it("does not resurrect cold historical questions or let old requests hide a new active question", async () => {
    const { environment, repository } = setup();
    for (let index = 0; index < 40; index += 1) {
      environment.append("task_started", `old-turn-${index}`);
      environment.response({ type: "function_call", name: "request_user_input_async", call_id: `old-question-${index}`,
        arguments: JSON.stringify({ questions: [{ title: "Old question?" }] }) });
      environment.append("task_complete", `old-turn-${index}`);
    }
    environment.clock += 24 * 60 * 60_000;
    expect((await repository.refresh()).sessions[0]?.section).toBe("history");
    environment.append("task_started", "active-turn");
    environment.response({ type: "function_call", name: "request_user_input_async", call_id: "active-question",
      arguments: JSON.stringify({ questions: [{ title: "Current question?" }] }) });
    const questionAt = environment.now().toISOString();
    const snapshot = await repository.refresh();
    expect(snapshot.sessions[0]).toMatchObject({ section: "needs_you", updatedAt: questionAt });
    expect(menuPresentation(snapshot, [], environment.clock).pills[0]?.phase).toBe("needs_you");
    const cold = new SessionRepository([new CodexProvider(environment)], { now: () => environment.now() });
    expect((await cold.refresh()).sessions[0]).toMatchObject({ section: "needs_you", updatedAt: questionAt });
  });

  it.each(["request_user_input_async", "functions.request_user_input_async"])(
    "keeps an unanswered %s yellow after its delivery acknowledgment", async (name) => {
      const { environment, repository } = setup();
      environment.append("task_started", "turn-1");
      environment.response({ type: "function_call", name, call_id: "async-question",
        arguments: JSON.stringify({ questions: [{ title: "Which option?", options: ["A", "B"] }] }) });
      environment.response({ type: "function_call_output", call_id: "async-question", output: '{"accepted":true}' });
      const snapshot = await repository.refresh();
      expect(snapshot.sessions[0]).toMatchObject({ section: "needs_you", subtitle: "Answer required in Codex" });
      expect(menuPresentation(snapshot, [], environment.clock).pills[0]?.phase).toBe("needs_you");
    },
  );

  it("keeps active async attention across background work and waiting until its exact user reply", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-1");
    environment.response({ type: "function_call", name: "request_user_input_async", call_id: "async-question",
      arguments: JSON.stringify({ questions: [{ title: "Which option?" }] }) });
    const questionAt = environment.now().toISOString();
    environment.response({ type: "function_call_output", call_id: "async-question", output: '{"accepted":true}' });
    environment.response({ type: "custom_tool_call_output", call_id: "sibling", output: "done" });
    expect((await repository.refresh()).sessions[0]).toMatchObject({ section: "needs_you", updatedAt: questionAt });
    environment.clock += 2 * 60 * 60_000;
    let snapshot = await repository.refresh();
    expect(snapshot.sessions[0]).toMatchObject({ section: "needs_you", updatedAt: questionAt });
    expect(menuPresentation(snapshot, [], environment.clock).pills[0]?.phase).toBe("needs_you");
    expect(hook("PostToolUse", "processing").sessions[0]?.section).toBe("needs_you");
    const reply = (callId: string) => environment.response({ type: "message", role: "user", content: [{
      type: "input_text", text: `<send_user_message_question_reply>${JSON.stringify([{
        questionItemId: JSON.stringify(["request_user_input_async", callId, 0]), answer: "A",
      }])}</send_user_message_question_reply>`,
    }] });
    environment.response({ type: "message", role: "user", content: [{ type: "input_text", text: "Keep working." }] });
    reply("another-call");
    snapshot = await repository.refresh();
    expect(snapshot.sessions[0]).toMatchObject({ section: "needs_you", updatedAt: questionAt });
    reply("async-question");
    environment.response({ type: "function_call_output", call_id: "resumed-work", output: "working" });
    snapshot = await repository.refresh();
    expect(snapshot.sessions[0]?.section).toBe("working");
    expect(menuPresentation(snapshot, [], environment.clock).pills[0]?.phase).toBe("working");
  });

  it("does not leave yellow attention for an async question whose delivery was rejected", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.response({ type: "function_call", name: "request_user_input_async", call_id: "rejected",
      arguments: JSON.stringify({ questions: [{ title: "Which option?" }] }) });
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    environment.response({ type: "function_call_output", call_id: "rejected", output: '{"accepted":false}' });
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
  });

  it("resolves only replied async items and ignores malformed or quoted reply content", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.response({ type: "function_call", name: "request_user_input_async", call_id: "two-questions",
      arguments: JSON.stringify({ questions: [{ title: "First?" }, { title: "Second?" }] }) });
    const item = (index: number) => ({ questionItemId: JSON.stringify(["request_user_input_async", "two-questions", index]), answer: "A" });
    const envelope = (items: unknown[]) => `<send_user_message_question_reply>${JSON.stringify(items)}</send_user_message_question_reply>`;
    const message = (text: string, role = "user") => environment.response({ type: "message", role, content: [{ type: "input_text", text }] });
    message(envelope([item(0), item(1)]), "assistant");
    message(`Please explain this example: ${envelope([item(0), item(1)])}`);
    message(envelope([{ ...item(0), questionItemId: JSON.stringify(["request_user_input", "two-questions", 0]) }, item(99)]));
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    message(envelope([item(0)]));
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    message(envelope([{ questionItemId: "not-json", answer: "A" }, item(1)]));
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
    environment.append("task_complete", "turn-1");
    const snapshot = await repository.refresh();
    expect(snapshot.sessions[0]?.section).toBe("ready");
    expect(menuPresentation(snapshot, [], environment.clock).pills[0]?.phase).toBe("ready");
  });

  it.each(["not-json", JSON.stringify({ questions: [] }), JSON.stringify({ questions: [null] }),
    JSON.stringify({ questions: [{ title: "" }] }), JSON.stringify({ questions: ["not-a-question"] }),
  ])("does not invent question attention for malformed async arguments (%#)", async (args) => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.response({ type: "function_call", name: "request_user_input_async", call_id: "invalid", arguments: args });
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
  });

  it("clears an async question after a large exact reply without treating large sibling output as an answer", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.response({ type: "function_call", name: "request_user_input_async", call_id: "large-reply",
      arguments: JSON.stringify({ questions: [{ title: "Explain?" }] }) });
    const reply = `<send_user_message_question_reply>${JSON.stringify([{
      questionItemId: JSON.stringify(["request_user_input_async", "large-reply", 0]), answer: "中文🙂".repeat(3_000),
    }])}</send_user_message_question_reply>`;
    environment.response({ type: "function_call_output", call_id: "sibling", output: reply });
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    environment.response({ type: "message", role: "user", content: [{ type: "input_text", text: reply }] });
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
  });

  it("accepts the source client's single-object async reply format", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.response({ type: "function_call", name: "request_user_input_async", call_id: "single-reply",
      arguments: JSON.stringify({ questions: [{ title: "Which option?" }] }) });
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    environment.response({ type: "message", role: "user", content: [{ type: "input_text",
      text: `<send_user_message_question_reply>${JSON.stringify({
        questionItemId: JSON.stringify(["request_user_input_async", "single-reply", 0]), question: "Which option?", answer: "A",
      })}</send_user_message_question_reply>`,
    }] });
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
  });

  it("does not acknowledge another conversation with the same async call ID", async () => {
    const { environment, repository } = setup();
    const other = new StatusEnvironment();
    const otherId = "another-codex-thread";
    const otherFile = "/fixture/.codex/other.jsonl";
    const stamp = environment.stamp.bind(environment);
    const scan = environment.scanLinePrefixes.bind(environment);
    environment.stamp = (file) => file === otherFile ? other.stamp(rollout) : stamp(file);
    environment.scanLinePrefixes = (file, limit, visit, startAt) => file === otherFile
      ? other.scanLinePrefixes(rollout, limit, visit, startAt) : scan(file, limit, visit, startAt);
    environment.sqlite = async () => [{ id: sessionId, cwd, rollout_path: rollout, title: "First", updated_at: environment.clock / 1000, archived: 0, source: "vscode" },
      { id: otherId, cwd, rollout_path: otherFile, title: "Second", updated_at: other.clock / 1000, archived: 0, source: "vscode" }];
    for (const source of [environment, other]) {
      source.append("task_started", "turn-1");
      source.response({ type: "function_call", name: "request_user_input_async", call_id: "same-call",
        arguments: JSON.stringify({ questions: [{ title: "Which option?" }] }) });
    }
    expect((await repository.refresh()).sessions.map((session) => session.section)).toEqual(["needs_you", "needs_you"]);
    environment.response({ type: "message", role: "user", content: [{ type: "input_text",
      text: `<send_user_message_question_reply>${JSON.stringify([{
        questionItemId: JSON.stringify(["request_user_input_async", "same-call", 0]), answer: "A",
      }])}</send_user_message_question_reply>`,
    }] });
    const snapshot = await repository.refresh();
    expect(snapshot.sessions.find((session) => session.id === sessionId)?.section).toBe("working");
    expect(snapshot.sessions.find((session) => session.id === otherId)?.section).toBe("needs_you");
  });

  it("waits for a complete large reply on disk and restores async attention after a cold read", async () => {
    const directory = mkdtempSync(path.join(tmpdir(), "codex-async-status-"));
    const codex = path.join(directory, ".codex");
    mkdirSync(codex);
    const file = path.join(codex, "rollout.jsonl");
    const clock = new Date("2026-08-30T21:45:30Z");
    const event = (type: string, payload: Record<string, unknown>) => JSON.stringify({ timestamp: clock.toISOString(), type, payload }) + "\n";
    writeFileSync(path.join(codex, "state_5.sqlite"), "fixture");
    writeFileSync(file, event("event_msg", { type: "task_started", turn_id: "turn-1" })
      + event("response_item", { type: "function_call", name: "request_user_input_async", call_id: "disk-question",
        arguments: JSON.stringify({ questions: [{ title: "Explain?" }] }) })
      + event("response_item", { type: "function_call_output", call_id: "disk-question", output: '{"accepted":true}' }));
    const environment = new LiveProviderEnvironment(directory, { now: () => clock });
    environment.processes = async () => [];
    environment.sqlite = async () => [{ id: sessionId, cwd, rollout_path: file, title: "Disk question",
      updated_at: clock.valueOf() / 1_000, archived: 0, source: "vscode" }];
    const repository = new SessionRepository([new CodexProvider(environment)], { now: () => clock });
    try {
      expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
      const coldPending = new SessionRepository([new CodexProvider(environment)], { now: () => clock });
      expect((await coldPending.refresh()).sessions[0]?.section).toBe("needs_you");
      const reply = event("response_item", { type: "message", role: "user", content: [{ type: "input_text",
        text: `<send_user_message_question_reply>${JSON.stringify([{
          questionItemId: JSON.stringify(["request_user_input_async", "disk-question", 0]), answer: "中文🙂".repeat(3_000),
        }])}</send_user_message_question_reply>`,
      }] });
      appendFileSync(file, reply.slice(0, -2));
      expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
      appendFileSync(file, reply.slice(-2));
      expect((await repository.refresh()).sessions[0]?.section).toBe("working");
      const cold = new SessionRepository([new CodexProvider(environment)], { now: () => clock });
      expect((await cold.refresh()).sessions[0]?.section).toBe("working");
      appendFileSync(file, event("event_msg", { type: "task_complete", turn_id: "turn-1" }));
      expect((await repository.refresh()).sessions[0]?.section).toBe("ready");
      expect((await cold.refresh()).sessions[0]?.section).toBe("ready");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("keeps a native question Needs you until its exact output or turn boundary", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-1");
    const response = (payload: Record<string, unknown>) => {
      environment.clock += 1000;
      environment.modifiedAt = environment.clock;
      environment.content += JSON.stringify({ type: "response_item", timestamp: environment.now().toISOString(), payload }) + "\n";
    };
    response({ type: "function_call", name: "request_user_input", call_id: "question-1", arguments: "{}" });
    response({ type: "function_call_output", call_id: "unrelated", output: "done" });
    expect((await repository.refresh()).sessions[0]).toMatchObject({ section: "needs_you", sessionState: { turn: "needs_you" } });
    expect(hook("PostToolUse", "processing").sessions[0]?.section).toBe("needs_you");
    environment.clock += 2 * 60 * 60_000;
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    response({ type: "function_call_output", call_id: "question-1", output: "answer" });
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
    response({ type: "function_call", name: "request_user_input", call_id: "question-2", arguments: "{}" });
    environment.append("task_complete", "turn-1");
    expect((await repository.refresh()).sessions[0]?.section).toBe("ready");
  });

  it("detects a question even when adjacent records have the same timestamp", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn");
    environment.content += JSON.stringify({ type: "response_item", timestamp: environment.now().toISOString(),
      payload: { type: "function_call", name: "request_user_input", call_id: "question", arguments: "{}" } }) + "\n";
    expect((await repository.refresh()).sessions[0]?.section).toBe("needs_you");
    environment.content += JSON.stringify({ type: "response_item", timestamp: environment.now().toISOString(),
      payload: { type: "function_call_output", call_id: "question", output: "answer" } }) + "\n";
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
  });
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

  it("keeps an observed unopened completion Ready beyond the stale ceiling with Open Chat", async () => {
    const { environment, repository, hook } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    await repository.refresh();
    hook("Stop", "waiting_for_input");
    environment.clock += 41 * 60 * 60 * 1_000;

    const snapshot = await repository.refresh();

    expect(snapshot.sessions).toMatchObject([{
      id: sessionId,
      section: "ready",
      completionUnseen: true,
      sessionState: { conversation: "open", turn: "ready" },
      canEnterChat: true,
    }]);
    expect(menuPresentation(snapshot, [], environment.clock).pills).toMatchObject([{
      id: sessionId,
      phase: "ready",
    }]);
  });

  it("keeps a completed task Ready while it is still within the stale ceiling", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    environment.clock += 29 * 60_000;

    expect((await repository.refresh()).sessions[0]).toMatchObject({ section: "ready", sessionState: { turn: "ready" } });
  });

  it("keeps an old completion Recent when opening it writes settings but no new turn", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    const completedAt = environment.now().toISOString();
    environment.clock += 2 * 24 * 60 * 60_000;
    expect((await repository.refresh()).sessions[0]?.section).toBe("history");

    environment.append("thread_settings_applied");
    const snapshot = await repository.refresh();
    expect(snapshot.sessions[0]).toMatchObject({
      section: "history", updatedAt: completedAt,
      sessionState: { conversation: "open", turn: "ready" },
      canOpenOwner: true, canEnterChat: true,
    });
    expect(menuPresentation(snapshot, [], environment.clock).pills).toMatchObject([{
      id: sessionId, phase: "history", attentionTier: "history",
    }]);
    const restarted = new SessionRepository([new CodexProvider(environment)]);
    expect((await restarted.refresh()).sessions[0]?.section).toBe("history");

    environment.append("task_started", "new-turn");
    expect((await repository.refresh()).sessions[0]?.section).toBe("working");
    environment.append("task_complete", "new-turn");
    expect(menuPresentation(await repository.refresh(), [], environment.clock).pills).toMatchObject([{
      id: sessionId, phase: "ready", attentionTier: "ready", inspector: { activityAt: environment.now().toISOString() },
    }]);
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

  it.each([
    ["settings", { type: "event_msg", payload: { type: "thread_settings_applied" } }],
    ["client metadata", { type: "session_meta", payload: { id: sessionId, originator: "Codex Desktop" } }],
    ["context", { type: "turn_context", payload: { cwd } }],
    ["instructions", { type: "response_item", payload: { type: "message", role: "developer", content: "Instructions" } }],
    ["unknown event", { type: "event_msg", payload: { type: "future_metadata" } }],
    ["another turn's progress", { type: "event_msg", payload: { type: "token_count", turn_id: "other-turn" } }],
  ])("does not revive a dormant start marker from %s", async (_label, record) => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    await repository.refresh();
    environment.clock += 2 * 24 * 60 * 60_000;
    expect((await repository.refresh()).sessions[0]?.section).toBe("history");

    environment.modifiedAt = environment.clock;
    environment.content += JSON.stringify({ timestamp: environment.now().toISOString(), ...record }) + "\n";
    const snapshot = await repository.refresh();
    expect(snapshot.sessions[0]?.section).toBe("history");
    expect(snapshot.sessions[0]?.sessionState?.turn).not.toBe("working");
    expect(menuPresentation(snapshot, [], environment.clock).pills[0]?.phase).toBe("history");
  });

  it("keeps an opened completion seen across settings writes and observes a later completion", async () => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    environment.append("task_complete", "turn-1");
    await repository.refresh();
    repository.acknowledgeReady(sessionId);
    const completionAt = environment.now().toISOString();
    environment.clock += 10 * 60_000;
    environment.append("thread_settings_applied");
    expect(menuPresentation(await repository.refresh(), [], environment.clock).pills).toMatchObject([{
      id: sessionId, phase: "ready", attentionTier: "acknowledged_ready", inspector: { activityAt: completionAt },
    }]);

    environment.append("task_started", "turn-2");
    environment.append("task_complete", "turn-2");
    expect(menuPresentation(await repository.refresh(), [], environment.clock).pills).toMatchObject([{
      id: sessionId, phase: "ready", attentionTier: "ready", inspector: { activityAt: environment.now().toISOString() },
    }]);
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

  it.each([
    { type: "event_msg", payload: { type: "agent_message", message: "Streaming answer. ".repeat(2_000) } },
    { type: "response_item", payload: { type: "custom_tool_call_output", call_id: "call-1", output: "Tool output. ".repeat(2_000) } },
  ])("keeps a long turn Working through oversized $type progress records", async (progress) => {
    const { environment, repository } = setup();
    environment.append("task_started", "turn-1");
    await repository.refresh();
    environment.clock += 45 * 60_000;
    environment.modifiedAt = environment.clock;
    environment.content += JSON.stringify({ timestamp: environment.now().toISOString(), ...progress }) + "\n";

    expect((await repository.refresh()).sessions[0]).toMatchObject({
      section: "working", sessionState: { turn: "working" },
    });
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
