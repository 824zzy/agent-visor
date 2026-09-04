import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { ChatPendingAction } from "@agent-visor/protocol";
import {
  codexPendingAction,
  codexApprovalId,
  codexResponseFor,
  activeCodexTurnDeliveryId,
  hasActiveCodexTurn,
  sendCodexTurn,
  stopCodexTurn,
  stopCodexTurns,
} from "./codex-turn.js";

const roots: string[] = [];
const originalBinary = process.env.CODEX_BINARY;
const originalVersion = process.env.AGENT_VISOR_VERSION;

afterEach(async () => {
  stopCodexTurns();
  if (originalBinary === undefined) delete process.env.CODEX_BINARY;
  else process.env.CODEX_BINARY = originalBinary;
  if (originalVersion === undefined) delete process.env.AGENT_VISOR_VERSION;
  else process.env.AGENT_VISOR_VERSION = originalVersion;
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("Codex turn delivery", () => {
  it("derives approval IDs from the complete non-sensitive owner identity", () => {
    const owner = {
      sessionId: "session-1",
      threadId: "thread-1",
      turnId: "turn-1",
      deliveryId: "delivery-1",
      requestId: "request-1",
      appServerRequestId: 7,
      appServerInstanceId: "process-a",
    };
    const approval = codexApprovalId(owner);

    expect(approval).toMatch(/^codex-approval-[a-f0-9]{64}$/);
    expect(codexApprovalId(owner)).toBe(approval);
    expect(codexApprovalId({ ...owner, appServerInstanceId: "process-b" })).not.toBe(approval);
    expect(codexApprovalId({ ...owner, deliveryId: "delivery-2" })).not.toBe(approval);
    expect(codexApprovalId({ ...owner, appServerRequestId: "7" })).not.toBe(approval);
    // The digest must not expose a prompt or other provider payload.
    expect(approval).not.toContain("Fix");
  });

  it("maps approval and question requests without guessing provider vocabulary", () => {
    expect(codexPendingAction("item/commandExecution/requestApproval", {
      itemId: "command-1", command: "npm test",
    })).toMatchObject({ type: "approval", toolUseId: "codex-command-1", toolName: "Command" });
    expect(codexResponseFor(7, "item/commandExecution/requestApproval", {}, {
      type: "respond_chat", id: "reply-1", sessionId: "thread-1",
      toolUseId: "codex-command-1", decision: "allow_always",
    })).toEqual({ id: 7, result: { decision: "acceptForSession" } });
    expect(codexResponseFor(8, "item/permissions/requestApproval", {
      permissions: { network: { enabled: true } },
    }, {
      type: "respond_chat", id: "reply-2", sessionId: "thread-1",
      toolUseId: "codex-permissions", decision: "deny",
    })).toEqual({
      id: 8,
      result: { permissions: {}, scope: "turn", strictAutoReview: false },
    });
    expect(codexPendingAction("unknown/request", {})).toBeUndefined();
  });

  it("routes concurrent app-server approvals by process and delivery owner, not JSON-RPC id", async () => {
    const parent = path.resolve("build/test-codex-turn");
    await mkdir(parent, { recursive: true });
    const root = await mkdtemp(path.join(parent, "run-"));
    roots.push(root);
    const executable = path.join(root, "codex.cjs");
    await writeFile(executable, `#!/usr/bin/env node
const readline=require('node:readline');
readline.createInterface({input:process.stdin}).on('line',line=>{
  const m=JSON.parse(line);
  if(m.id) {
    process.stdout.write(JSON.stringify({id:m.id,result:m.id===3?{turn:{id:'turn-'+process.pid}}:{}})+'\\n');
    if(m.id===3) setTimeout(()=>process.stdout.write(JSON.stringify({id:41,method:'item/commandExecution/requestApproval',params:{itemId:'same-command',command:'echo test'}})+'\\n'),10);
  }
});
`, { mode: 0o700 });
    await chmod(executable, 0o700);
    process.env.CODEX_BINARY = executable;

    const approvals: ChatPendingAction[] = [];
    const registerAction = (_sessionId: string, pending: ChatPendingAction) => {
      approvals.push(pending);
      return () => undefined;
    };
    await Promise.all([
      sendCodexTurn("thread-shared", "first", [], registerAction, "delivery-a", "request-a"),
      sendCodexTurn("thread-shared", "second", [], registerAction, "delivery-b", "request-b"),
    ]);
    await expect.poll(() => approvals.length).toBe(2);

    const approvalIDs = approvals.map((pending) => pending.approvalId);
    expect(approvalIDs.every((id) => typeof id === "string")).toBe(true);
    expect(new Set(approvalIDs).size).toBe(2);
    expect(approvalIDs.every((id) => id?.startsWith("codex-approval-") === true)).toBe(true);
    // The approval ID is an opaque owner digest, never a command or prompt.
    expect(approvalIDs.join(" ")).not.toContain("echo");
  });

  it("initializes, resumes the exact thread, and starts one text and image turn", async () => {
    const parent = path.resolve("build/test-codex-turn");
    await mkdir(parent, { recursive: true });
    const root = await mkdtemp(path.join(parent, "run-"));
    roots.push(root);
    const log = path.join(root, "requests.jsonl");
    const executable = path.join(root, "codex.cjs");
    await writeFile(executable, `#!/usr/bin/env node
const fs=require('node:fs'),readline=require('node:readline');
const log=process.env.AGENT_VISOR_CODEX_TEST_LOG;
readline.createInterface({input:process.stdin}).on('line',line=>{
  fs.appendFileSync(log,line+'\\n');
  const m=JSON.parse(line);
  if(m.id) {
    process.stdout.write(JSON.stringify({id:m.id,result:m.id===3?{turn:{id:'turn-1'}}:{}})+'\\n');
    if(m.id===3) process.stdout.write(JSON.stringify({method:'turn/completed',params:{}})+'\\n');
  }
});
`, { mode: 0o700 });
    await chmod(executable, 0o700);
    process.env.CODEX_BINARY = executable;
    process.env.AGENT_VISOR_CODEX_TEST_LOG = log;
    process.env.AGENT_VISOR_VERSION = "2.7.0";

    await sendCodexTurn("019f3931-ec11-7f31-8400-1c8624aa9e4d", "Fix it", ["/tmp/pixel.png"]);

    const messages = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    expect(messages.map((message) => message.method)).toEqual([
      "initialize", "initialized", "thread/resume", "turn/start",
    ]);
    expect(messages[0].params.clientInfo).toEqual({ name: "agent-visor", version: "2.7.0" });
    expect(messages[2].params.threadId).toBe("019f3931-ec11-7f31-8400-1c8624aa9e4d");
    expect(messages[3].params.input).toEqual([
      { type: "text", text: "Fix it" },
      { type: "localImage", path: "/tmp/pixel.png" },
    ]);
  });

  it("interrupts only the daemon-owned turn for the requested thread", async () => {
    const parent = path.resolve("build/test-codex-turn");
    await mkdir(parent, { recursive: true });
    const root = await mkdtemp(path.join(parent, "run-"));
    roots.push(root);
    const log = path.join(root, "requests.jsonl");
    const executable = path.join(root, "codex.cjs");
    await writeFile(executable, `#!/usr/bin/env node
const fs=require('node:fs'),readline=require('node:readline');
const log=process.env.AGENT_VISOR_CODEX_TEST_LOG;
readline.createInterface({input:process.stdin}).on('line',line=>{
  fs.appendFileSync(log,line+'\\n');
  const m=JSON.parse(line);
  if(m.id===1) process.stdout.write(JSON.stringify({id:1,result:{}})+'\\n');
  if(m.id===2) process.stdout.write(JSON.stringify({id:2,result:{}})+'\\n');
  if(m.id===3) process.stdout.write(JSON.stringify({id:3,result:{turn:{id:'turn-1'}}})+'\\n');
  if(m.method==='turn/interrupt') {
    process.stdout.write(JSON.stringify({id:m.id,result:{}})+'\\n');
    process.stdout.write(JSON.stringify({method:'turn/completed',params:{turnId:'turn-1'}})+'\\n');
  }
});
`, { mode: 0o700 });
    await chmod(executable, 0o700);
    process.env.CODEX_BINARY = executable;
    process.env.AGENT_VISOR_CODEX_TEST_LOG = log;

    await sendCodexTurn("thread-cancel", "Stop this", [], undefined, "delivery-a");
    await sendCodexTurn("thread-cancel", "Leave this", [], undefined, "delivery-b");
    expect(hasActiveCodexTurn("thread-cancel", "delivery-a")).toBe(true);
    expect(hasActiveCodexTurn("thread-cancel", "delivery-b")).toBe(true);
    // The renderer follows the newest submitted delivery, so capability and
    // Stop target use the same newest-live policy when A and B overlap.
    expect(activeCodexTurnDeliveryId("thread-cancel")).toBe("delivery-b");
    expect(stopCodexTurn("other-thread", "delivery-a")).toBe(false);
    expect(stopCodexTurn("thread-cancel", "wrong-delivery")).toBe(false);
    expect(stopCodexTurn("thread-cancel", "delivery-b")).toBe(true);
    expect(stopCodexTurn("thread-cancel", "delivery-b")).toBe(true);
    expect(hasActiveCodexTurn("thread-cancel", "delivery-a")).toBe(true);

    await new Promise((resolve) => setTimeout(resolve, 25));
    const messages = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    expect(messages.filter((message) => message.method === "turn/interrupt")).toHaveLength(1);
    expect(messages.find((message) => message.method === "turn/interrupt")?.params).toEqual({
      threadId: "thread-cancel", expectedTurnId: "turn-1",
    });
    expect(hasActiveCodexTurn("thread-cancel", "delivery-b")).toBe(false);
    expect(hasActiveCodexTurn("thread-cancel", "delivery-a")).toBe(true);
    expect(activeCodexTurnDeliveryId("thread-cancel")).toBe("delivery-a");
    expect(stopCodexTurn("thread-cancel", "delivery-a")).toBe(true);
  });

  it("does not advertise a Codex delivery during the startup turn-id gap", async () => {
    const parent = path.resolve("build/test-codex-turn");
    await mkdir(parent, { recursive: true });
    const root = await mkdtemp(path.join(parent, "run-"));
    roots.push(root);
    const log = path.join(root, "requests.jsonl");
    const executable = path.join(root, "codex.cjs");
    await writeFile(executable, `#!/usr/bin/env node
const fs=require('node:fs'),readline=require('node:readline');
const log=process.env.AGENT_VISOR_CODEX_TEST_LOG;
readline.createInterface({input:process.stdin}).on('line',line=>{
  fs.appendFileSync(log,line+'\\n');
  const m=JSON.parse(line);
  if(m.id===1) process.stdout.write(JSON.stringify({id:1,result:{}})+'\\n');
  if(m.id===2) process.stdout.write(JSON.stringify({id:2,result:{}})+'\\n');
  if(m.id===3) setTimeout(()=>process.stdout.write(JSON.stringify({id:3,result:{turn:{id:'turn-started-late'}}})+'\\n'),500);
  if(m.method==='turn/interrupt') process.stdout.write(JSON.stringify({id:m.id,result:{}})+'\\n');
});
`, { mode: 0o700 });
    await chmod(executable, 0o700);
    process.env.CODEX_BINARY = executable;
    process.env.AGENT_VISOR_CODEX_TEST_LOG = log;

    const sending = sendCodexTurn("thread-startup", "Wait", [], undefined, "delivery-startup");
    await expect.poll(async () => (await readFile(log, "utf8")).includes('"method":"turn/start"')).toBe(true);
    expect(hasActiveCodexTurn("thread-startup", "delivery-startup")).toBe(false);
    expect(stopCodexTurn("thread-startup", "delivery-startup")).toBe(false);
    await sending;
    expect(hasActiveCodexTurn("thread-startup", "delivery-startup")).toBe(true);
    expect(stopCodexTurn("thread-startup", "delivery-startup")).toBe(true);
  });
});
