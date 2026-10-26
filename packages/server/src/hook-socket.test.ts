import { afterEach, describe, expect, it } from "vitest";
import { mkdtemp, rm, stat } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { sessionLifecyclePresentation } from "@agent-visor/protocol";
import { startHookSocket, type RunningHookSocket } from "./hook-socket.js";
import { SessionRepository } from "./sessions.js";

let root: string | undefined;
let running: RunningHookSocket | undefined;
const hooks = new Set<ChildProcess>();

afterEach(async () => {
  for (const hook of hooks) hook.kill();
  hooks.clear();
  await running?.close();
  if (root) await rm(root, { recursive: true, force: true });
  root = undefined;
  running = undefined;
});

describe("hook socket", () => {
  it("downgrades a disconnected hook question to last-known attention", () => {
    const repository = new SessionRepository([]);
    const receivedAt = new Date().toISOString();
    repository.applyHook({
      sessionId: "claude-question-disconnected",
      cwd: "/Users/me/Codes/agent-visor",
      provider: "claude_code",
      tty: "/dev/ttys001",
      event: "PreToolUse",
      status: "waiting_for_approval",
      expectsResponse: true,
      receivedAt,
      tool: "AskUserQuestion",
      toolUseId: "question-1",
      toolInput: { questions: [{ question: "Continue?" }] },
    });

    expect(repository.current().sessions[0]).toMatchObject({
      attention: { kind: "question", evidence: "current", observedAt: receivedAt },
    });
    const unregister = repository.registerHookResponder(
      "claude-question-disconnected", "question-1", () => undefined,
    );
    unregister();

    const snapshot = repository.current();
    expect(snapshot.sessions[0]).toMatchObject({
      attention: { kind: "question", evidence: "last_known", observedAt: receivedAt },
    });
    expect(sessionLifecyclePresentation(snapshot.sessions[0]!)).toMatchObject({
      status: "unavailable", label: "Status unavailable", tone: "neutral",
      attention: { evidence: "last_known", label: "Last known: Needs you", tone: "neutral" },
    });
  });

  it("answers the real Claude PreToolUse question in bypass mode after sibling activity", async () => {
    root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-hooks-"));
    const socketPath = path.join(root, "hooks.sock");
    const repository = new SessionRepository([]);
    running = await startHookSocket({ socketPath, repository });
    const output = pythonHook(socketPath, {
      session_id: "claude-question", cwd: root, hook_event_name: "PreToolUse",
      permission_mode: "bypassPermissions", tool_name: "AskUserQuestion", tool_use_id: "question-1",
      tool_input: { questions: [{ question: "Which strategy?", options: [{ label: "Minimal" }] }] },
    });
    await expect.poll(() => repository.pendingAction("claude-question")?.type).toBe("question");
    await send(socketPath, {
      session_id: "claude-question", cwd: root, event: "PostToolUse", status: "processing",
      agent: "claude", tty: "/dev/ttys999", tool: "Read", tool_use_id: "sibling",
    });
    expect(repository.current().sessions[0]?.section).toBe("needs_you");
    expect(await repository.chatAction({ type: "respond_chat", id: "skip", sessionId: "claude-question",
      toolUseId: "question-1", decision: "allow" })).toMatch(/answer/i);
    expect(await repository.chatAction({
      type: "respond_chat", id: "answer", sessionId: "claude-question",
      toolUseId: "question-1", decision: "answer", answers: { "Which strategy?": "Minimal" },
    })).toBeUndefined();
    expect(JSON.parse(await output)).toMatchObject({ hookSpecificOutput: {
      hookEventName: "PreToolUse", permissionDecision: "allow",
      updatedInput: { questions: [{ question: "Which strategy?" }], answers: { "Which strategy?": "Minimal" } },
    } });
    expect(repository.pendingAction("claude-question")).toBeUndefined();
  });
  it("validates a provider event and updates session state", async () => {
    root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-hooks-"));
    const socketPath = path.join(root, "hooks.sock");
    const repository = new SessionRepository([]);
    running = await startHookSocket({ socketPath, repository });

    await send(socketPath, {
      session_id: "auggie-1",
      cwd: "/Users/me/Codes/agent-visor",
      event: "PermissionRequest",
      status: "waiting_for_approval",
      agent: "auggie",
    });

    await expect.poll(() => repository.current().sessions.length).toBe(1);
    expect(repository.current().sessions[0]).toMatchObject({
      id: "auggie-1",
      source: "Auggie",
      section: "needs_you",
    });
    expect((await stat(socketPath)).mode & 0o777).toBe(0o600);
  });

  it("delivers a Claude answer larger than one socket read", async () => {
    root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-hooks-"));
    const socketPath = path.join(root, "hooks.sock");
    const repository = new SessionRepository([]);
    running = await startHookSocket({ socketPath, repository });
    const output = pythonHook(socketPath, { session_id: "large-answer", cwd: root, hook_event_name: "PreToolUse",
      tool_name: "AskUserQuestion", tool_use_id: "large", tool_input: { questions: [{ question: "Explain", options: [] }] } });
    await expect.poll(() => repository.pendingAction("large-answer")?.type).toBe("question");
    const answer = "a".repeat(9000);
    expect(await repository.chatAction({ type: "respond_chat", id: "large", sessionId: "large-answer",
      toolUseId: "large", decision: "answer", answers: { Explain: answer } })).toBeUndefined();
    expect(JSON.parse(await output).hookSpecificOutput.updatedInput.answers.Explain).toBe(answer);
  });

  it("correlates the real PermissionRequest without an ID only to an exact unique PreToolUse", async () => {
    root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-hooks-"));
    const socketPath = path.join(root, "hooks.sock");
    const repository = new SessionRepository([]);
    running = await startHookSocket({ socketPath, repository });
    await pythonHook(socketPath, { session_id: "permission", cwd: root, hook_event_name: "PreToolUse",
      tool_name: "Bash", tool_use_id: "exact", tool_input: { command: "true" } });
    const output = pythonHook(socketPath, { session_id: "permission", cwd: root, hook_event_name: "PermissionRequest",
      tool_name: "Bash", tool_input: { command: "true" } });
    await expect.poll(() => repository.pendingAction("permission")?.toolUseId).toBe("exact");
    expect(await repository.chatAction({ type: "respond_chat", id: "allow", sessionId: "permission",
      toolUseId: "exact", decision: "allow" })).toBeUndefined();
    expect(JSON.parse(await output)).toMatchObject({ hookSpecificOutput: { decision: { behavior: "allow" } } });
    // A consumed match, another session, or ambiguous identical calls must
    // fall back to Claude; none may borrow the old response authority.
    expect(await pythonHook(socketPath, { session_id: "permission", cwd: root, hook_event_name: "PermissionRequest",
      tool_name: "Bash", tool_input: { command: "true" } })).toBe("");
    for (const tool_use_id of ["first", "second"]) await pythonHook(socketPath, {
      session_id: "ambiguous", cwd: root, hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id,
      tool_input: { command: "true" },
    });
    expect(await pythonHook(socketPath, { session_id: "ambiguous", cwd: root, hook_event_name: "PermissionRequest",
      tool_name: "Bash", tool_input: { command: "true" } })).toBe("");
    expect(repository.pendingAction("ambiguous")).toBeUndefined();
  });

  it("keeps Claude permission sockets open for Chat responses", async () => {
    root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-hooks-"));
    const socketPath = path.join(root, "hooks.sock");
    const repository = new SessionRepository([]);
    running = await startHookSocket({ socketPath, repository });
    const response = new Promise<string>((resolve, reject) => {
      const socket = net.createConnection(socketPath, () => socket.write(JSON.stringify({
        session_id: "claude-1",
        cwd: "/Users/me/Codes/agent-visor",
        event: "PermissionRequest",
        status: "waiting_for_approval",
        agent: "claude",
        tool: "Bash",
        tool_use_id: "tool-1",
        tool_input: { command: "npm test" },
        permission_suggestions: [{ type: "addRules", rules: ["npm test"] }],
      })));
      const chunks: Buffer[] = [];
      socket.on("data", (chunk) => chunks.push(chunk));
      socket.once("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
      socket.once("error", reject);
    });

    await expect.poll(async () => (await repository.chatPage("claude-1")).pendingAction)
      .toMatchObject({ type: "approval", toolUseId: "tool-1", canPersist: true });
    const error = await repository.chatAction({
      type: "respond_chat",
      id: "response-1",
      sessionId: "claude-1",
      toolUseId: "tool-1",
      decision: "allow_always",
    });

    expect(error).toBeUndefined();
    expect(JSON.parse(await response)).toEqual({
      decision: "allow",
      updated_permissions: [{ type: "addRules", rules: ["npm test"] }],
    });
  });

  it("removes a Claude approval when its response socket disconnects", async () => {
    root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-hooks-"));
    const socketPath = path.join(root, "hooks.sock");
    const repository = new SessionRepository([]);
    running = await startHookSocket({ socketPath, repository });
    const socket = net.createConnection(socketPath, () => socket.write(JSON.stringify({
      session_id: "claude-disconnected",
      cwd: "/Users/me/Codes/agent-visor",
      event: "PermissionRequest",
      status: "waiting_for_approval",
      agent: "claude",
      pid: 42,
      tty: "/dev/ttys001",
      tool: "Bash",
      tool_use_id: "tool-disconnected",
      tool_input: { command: "npm test" },
    })));

    await expect.poll(() => repository.current().sessions[0]?.section).toBe("needs_you");
    socket.destroy();

    await expect.poll(() => repository.current().sessions).toEqual([]);
  });

  it("does not unlink an active hook owner", async () => {
    root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-hooks-"));
    const socketPath = path.join(root, "hooks.sock");
    const repository = new SessionRepository([]);
    running = await startHookSocket({ socketPath, repository });

    await expect(startHookSocket({ socketPath, repository })).rejects.toThrow(
      "Hook socket is already active",
    );
    await send(socketPath, {
      session_id: "pi-1",
      cwd: "/Users/me/Codes/agent-visor",
      event: "Stop",
      status: "idle",
      agent: "pi",
    });

    await expect.poll(() => repository.hookRecord("pi-1")?.event).toBe("Stop");
  });

  it("drops malformed and oversized events", async () => {
    root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-hooks-"));
    const socketPath = path.join(root, "hooks.sock");
    const repository = new SessionRepository([]);
    running = await startHookSocket({ socketPath, repository, maxPayloadBytes: 64 });

    await sendRaw(socketPath, Buffer.from("not-json"));
    await sendRaw(socketPath, Buffer.alloc(65, "x"));

    expect(repository.current().sessions).toEqual([]);
  });
});

function pythonHook(socketPath: string, input: unknown): Promise<string> {
  const child = spawn("python3", ["-c", `
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
hook.SOCKET_PATH = sys.argv[2]
hook.DECISION_TIMEOUT = 3
hook.get_tty = lambda: "/dev/ttys999"
hook.main()
`, path.resolve("../../AgentVisor/Resources/agent-visor-state.py"), socketPath]);
  hooks.add(child);
  child.stdin!.end(JSON.stringify(input));
  let output = "";
  child.stdout!.on("data", (value) => { output += value; });
  return new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => { hooks.delete(child); code === 0 ? resolve(output) : reject(new Error(`Hook exited ${code}`)); });
  });
}

async function send(socketPath: string, value: unknown): Promise<void> {
  await sendRaw(socketPath, Buffer.from(JSON.stringify(value)));
}

async function sendRaw(socketPath: string, value: Buffer): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const socket = net.createConnection(socketPath, () => socket.end(value));
    socket.once("close", () => resolve());
    socket.once("error", reject);
  });
}
