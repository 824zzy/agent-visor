import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { ChatPendingAction, ClientMessage } from "@agent-visor/protocol";
import {
  acquireCodexRoute,
  activeCodexTurnDeliveryId,
  codexPendingAction,
  codexApprovalId,
  codexResponseFor,
  subscribeCodexRouteEvents,
  codexRouteStatus,
  closeCodexRoutes,
  hasActiveCodexTurn,
  readCodexSettingsCatalog,
  recoverCodexRoute,
  relinquishIdleCodexRoute,
  releaseCodexRoute,
  sendCodexTurn,
  stopCodexTurn,
  stopCodexTurns,
} from "./codex-turn.js";

const roots: string[] = [];
const originalEnvironment = new Map([
  ["CODEX_BINARY", process.env.CODEX_BINARY],
  ["AGENT_VISOR_CODEX_TEST_LOG", process.env.AGENT_VISOR_CODEX_TEST_LOG],
  ["AGENT_VISOR_CODEX_TEST_BEHAVIOR", process.env.AGENT_VISOR_CODEX_TEST_BEHAVIOR],
  ["AGENT_VISOR_VERSION", process.env.AGENT_VISOR_VERSION],
]);

afterEach(async () => {
  stopCodexTurns();
  await closeCodexRoutes();
  for (const [key, value] of originalEnvironment) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

type FakeSetup = { root: string; log: string };

async function fakeCodex(behavior = "complete"): Promise<FakeSetup> {
  const parent = path.resolve("build/test-codex-turn");
  await mkdir(parent, { recursive: true });
  const root = await mkdtemp(path.join(parent, "run-"));
  roots.push(root);
  const log = path.join(root, "requests.jsonl");
  const executable = path.join(root, "codex.cjs");
  await writeFile(executable, `#!/usr/bin/env node
const fs=require('node:fs'),readline=require('node:readline');
const log=process.env.AGENT_VISOR_CODEX_TEST_LOG;
const behavior=process.env.AGENT_VISOR_CODEX_TEST_BEHAVIOR || 'complete';
let turnNumber=0;
let delayedCloseKeepAlive;
let delayedCloseExit;
if(behavior==='delayed-close') {
  delayedCloseKeepAlive=setInterval(()=>{},1000);
  process.on('SIGTERM',()=>{
    if(delayedCloseExit) return;
    delayedCloseExit=setTimeout(()=>{
      clearInterval(delayedCloseKeepAlive);
      process.exit(0);
    },3000);
  });
}
function record(value){ fs.appendFileSync(log, JSON.stringify(value)+'\\n'); }
function send(value){ process.stdout.write(JSON.stringify(value)+'\\n'); }
function result(request, value){ send({id:request.id,result:value}); }
function error(request, message){ send({id:request.id,error:{code:-32000,message}}); }
function threadResult(request){ return {thread:{id:request.params.threadId,status:{type:behavior==='resume-active'?'active':'idle'}}}; }
readline.createInterface({input:process.stdin}).on('line',line=>{
  const request=JSON.parse(line); record(request);
  if(request.method==='initialize') return result(request,{});
  if(request.method==='thread/resume') {
    if(behavior==='owner-held') return error(request,'thread '+request.params.threadId+' already has an active writer');
    if(behavior==='resume-failure') return error(request,'Codex could not resume the thread');
    const reply=()=>result(request,threadResult(request));
    if(behavior==='child-exit') { reply(); return setTimeout(() => process.exit(17), 10); }
    return behavior==='resume-delayed' ? setTimeout(reply,50)
      : behavior==='currentness-delayed' ? setTimeout(reply,250) : reply();
  }
  if(request.method==='model/list') return result(request,{data:[{id:'gpt-6-astra',displayName:'GPT-6 Astra',description:'Fast model',isDefault:true,defaultReasoningEffort:'high',supportedReasoningEfforts:[{reasoningEffort:'low',description:'Short'},{reasoningEffort:'high',description:'Deep'}],inputModalities:['text','image']}]});
  if(request.method==='permissionProfile/list') return result(request,{data:[{id:':read-only',description:'No writes',allowed:true},{id:':danger-full-access',allowed:false}]});
  if(request.method==='turn/start') {
    const turnId='turn-'+(++turnNumber);
    const started={method:'turn/started',params:{threadId:request.params.threadId,turn:{id:turnId,status:'inProgress'}}};
    const completed={method:'turn/completed',params:{threadId:request.params.threadId,turn:{id:turnId,status:'completed'}}};
    const statusIdle={method:'thread/status/changed',params:{threadId:request.params.threadId,status:{type:'idle'}}};
    const approval={id:7,method:'item/commandExecution/requestApproval',params:{itemId:'same-command',command:'echo test'}};
    if(behavior==='start-owner-held') return error(request,'thread '+request.params.threadId+' already has an active writer');
    if(behavior==='fast-complete-before-ack') {
      send(started); send(statusIdle); send(completed);
      return setTimeout(()=>result(request,{turn:{id:turnId,status:'completed'}}),10);
    }
    if(behavior==='delta-burst-before-ack') {
      for(let index=0; index<100; index++) {
        send({method:'item/agentMessage/delta',params:{threadId:request.params.threadId,turnId:turnId,itemId:'assistant-'+index,delta:'x'}});
      }
      send({method:'item/started',params:{threadId:request.params.threadId,turnId:turnId,item:{id:'burst-user',type:'userMessage'}}});
      setTimeout(()=>send({method:'turn/completed',params:{threadId:request.params.threadId,turnId:turnId,turn:{id:turnId,status:'completed'}}}),20);
      return setTimeout(()=>result(request,{turn:{id:turnId,status:'inProgress'}}),10);
    }
    if(behavior==='stale-preack-events') {
      send({method:'turn/started',params:{threadId:request.params.threadId,turn:{id:'old-turn',status:'inProgress'}}});
      send({method:'item/started',params:{threadId:request.params.threadId,turnId:'old-turn',item:{id:'old-user',type:'userMessage'}}});
    }
    if(behavior==='started-before-response') send(started);
    if(behavior==='started-wrong-thread') send({method:'turn/started',params:{threadId:'other-thread',turn:{id:turnId,status:'inProgress'}}});
    if(behavior==='approval-before-response') send(approval);
    if(behavior==='transport-loss-before-id') return setTimeout(() => process.exit(17), 10);
    result(request,{turn:{id:turnId,status:'inProgress'}});
    if(behavior!=='started-before-response') setTimeout(()=>send(started),5);
    if(behavior==='approval') setTimeout(()=>send(approval),10);
    if(behavior==='stale-events') {
      setTimeout(()=>send({method:'turn/completed',params:{threadId:request.params.threadId,turn:{id:'old-turn',status:'completed'}}}),10);
      setTimeout(()=>send({method:'turn/completed',params:{turn:{id:turnId,status:'completed'}}}),15);
      setTimeout(()=>send({method:'turn/completed',params:{threadId:request.params.threadId,turn:{id:turnId,status:'completed'}}}),30);
    }
    if(behavior==='complete' || behavior==='started-before-response' || behavior==='started-wrong-thread') {
      setTimeout(()=>{ send(statusIdle); send(completed); },20);
    }
    if(behavior==='native-events') {
      setTimeout(()=>{
        send({method:'item/started',params:{threadId:request.params.threadId,turnId:turnId,item:{id:'native-user-1',type:'userMessage'},startedAtMs:1}});
        send({method:'item/agentMessage/delta',params:{threadId:request.params.threadId,turnId:turnId,itemId:'native-agent-1',delta:'hello'}});
        send({method:'item/completed',params:{threadId:request.params.threadId,turnId:turnId,item:{id:'native-user-1',type:'userMessage'},completedAtMs:2}});
        send(statusIdle); send(completed);
      },20);
    }
    if(behavior==='stale-preack-events') {
      setTimeout(()=>{
        send({method:'item/started',params:{threadId:request.params.threadId,turnId:turnId,item:{id:'current-user',type:'userMessage'}}});
        send({method:'item/completed',params:{threadId:request.params.threadId,turnId:turnId,item:{id:'current-user',type:'userMessage'}}});
        send(statusIdle); send(completed);
      },20);
    }
    if(behavior==='transport-loss') {
      setTimeout(() => process.exit(17), 10);
    }
    if(behavior==='transport-loss-before-id') {
      setTimeout(() => process.exit(17), 10);
    }
    return;
  }
  if(request.method==='turn/interrupt') {
    if(behavior==='interrupt-failure') return error(request,'interrupt rejected');
    result(request,{});
    send({method:'thread/status/changed',params:{threadId:request.params.threadId,status:{type:'idle'}}});
    send({method:'turn/completed',params:{threadId:request.params.threadId,turn:{id:request.params.turnId,status:'interrupted'}}});
  }
});
`, { mode: 0o700 });
  await chmod(executable, 0o700);
  process.env.CODEX_BINARY = executable;
  process.env.AGENT_VISOR_CODEX_TEST_LOG = log;
  process.env.AGENT_VISOR_CODEX_TEST_BEHAVIOR = behavior;
  return { root, log };
}

async function requests(log: string): Promise<Record<string, unknown>[]> {
  const value = await readFile(log, "utf8").catch(() => "");
  return value.trim() ? value.trim().split("\n").map((line) => JSON.parse(line)) : [];
}

describe("Codex turn delivery", () => {
  it("derives approval IDs from the complete non-sensitive owner identity", () => {
    const owner = {
      sessionId: "session-1",
      threadId: "thread-1",
      turnId: "turn-1",
      deliveryId: "delivery-1",
      requestId: "request-1",
      generation: 4,
      appServerRequestId: 7,
      appServerInstanceId: "process-a",
    };
    const approval = codexApprovalId(owner);

    expect(approval).toMatch(/^codex-approval-[a-f0-9]{64}$/);
    expect(codexApprovalId(owner)).toBe(approval);
    expect(codexApprovalId({ ...owner, appServerInstanceId: "process-b" })).not.toBe(approval);
    expect(codexApprovalId({ ...owner, threadId: "thread-2" })).not.toBe(approval);
    expect(codexApprovalId({ ...owner, deliveryId: "delivery-2" })).not.toBe(approval);
    expect(codexApprovalId({ ...owner, requestId: "request-2" })).not.toBe(approval);
    expect(codexApprovalId({ ...owner, generation: 5 })).not.toBe(approval);
    expect(codexApprovalId({ ...owner, appServerRequestId: "7" })).not.toBe(approval);
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
    })).toEqual({ id: 8, result: { permissions: {}, scope: "turn", strictAutoReview: false } });
    expect(codexPendingAction("unknown/request", {})).toBeUndefined();
  });

  it("deduplicates concurrent first acquires and does not report ready before resume", async () => {
    const { log } = await fakeCodex("resume-delayed");
    const opening = acquireCodexRoute("thread-open", true);
    expect(codexRouteStatus("thread-open")).toEqual({
      routeState: "unavailable", unavailableReason: "provider_unavailable",
    });
    const second = acquireCodexRoute("thread-open", true);
    expect(await Promise.all([opening, second])).toEqual([
      { routeState: "available", routeOwnership: "owned", turnState: "ready" },
      { routeState: "available", routeOwnership: "owned", turnState: "ready" },
    ]);
    expect(codexRouteStatus("thread-open")).toMatchObject({ routeState: "available", turnState: "ready" });
    const sent = await requests(log);
    expect(sent.filter((message) => message.method === "initialize")).toHaveLength(1);
    expect(sent.filter((message) => message.method === "thread/resume")).toHaveLength(1);
    expect(sent.find((message) => message.method === "thread/resume")?.params).toEqual({
      threadId: "thread-open", excludeTurns: true,
    });
    releaseCodexRoute("thread-open");
    releaseCodexRoute("thread-open");
  });

  it("preserves explicit thread cwd while keeping provider rollout configuration", async () => {
    const { log } = await fakeCodex("complete");
    await acquireCodexRoute("thread-context", true, { cwd: "/fixture/project" });
    const resume = (await requests(log)).find((message) => message.method === "thread/resume");
    expect(resume?.params).toEqual({
      threadId: "thread-context", excludeTurns: true,
      cwd: "/fixture/project",
    });
  });

  it("reuses one retained connection for sequential turns", async () => {
    const { log } = await fakeCodex("complete");
    await acquireCodexRoute("thread-reuse", true);
    await sendCodexTurn("thread-reuse", "first", [], undefined, "delivery-a");
    await new Promise((resolve) => setTimeout(resolve, 30));
    await sendCodexTurn("thread-reuse", "second", [], undefined, "delivery-b");
    const sent = await requests(log);
    expect(sent.filter((message) => message.method === "initialize")).toHaveLength(1);
    expect(sent.filter((message) => message.method === "thread/resume")).toHaveLength(1);
    expect(sent.filter((message) => message.method === "turn/start")).toHaveLength(2);
    releaseCodexRoute("thread-reuse");
  });

  it("holds a direct-send route through completion, then closes its idle child", async () => {
    await fakeCodex("complete");
    await sendCodexTurn("thread-direct-lease", "first", [], undefined, "delivery-direct");
    expect(codexRouteStatus("thread-direct-lease")).toMatchObject({
      routeState: "available", turnState: "working",
    });
    await expect.poll(() => codexRouteStatus("thread-direct-lease")).toMatchObject({
      routeState: "available", routeOwnership: "unverified", turnState: "ready",
      confirmedTerminal: true,
    });
  });

  it("publishes exact native item identities without retaining message content", async () => {
    await fakeCodex("native-events");
    const events: Array<Record<string, unknown>> = [];
    const unsubscribe = subscribeCodexRouteEvents((event) => {
      events.push(event as unknown as Record<string, unknown>);
    });
    try {
      await sendCodexTurn(
        "thread-native-events",
        "prompt that must not enter diagnostics",
        [],
        undefined,
        "delivery-native",
        "request-native",
      );
      await expect.poll(() => events.some((event) => event.type === "item_completed")).toBe(true);
      expect(events).toContainEqual(expect.objectContaining({
        type: "item_started",
        threadId: "thread-native-events",
        turnId: "turn-1",
        itemId: "native-user-1",
        itemType: "userMessage",
        deliveryId: "delivery-native",
        requestId: "request-native",
      }));
      expect(events).toContainEqual(expect.objectContaining({
        type: "agent_message_delta",
        itemId: "native-agent-1",
        deltaLength: 5,
      }));
      expect(events.find((event) => event.type === "agent_message_delta")).not.toHaveProperty("delta");
    } finally {
      unsubscribe();
    }
  });

  it("preserves a completed route when completion arrives before turn/start acknowledgement", async () => {
    await fakeCodex("fast-complete-before-ack");
    await expect(sendCodexTurn("thread-fast-complete", "finish quickly", [], undefined, "delivery-fast"))
      .resolves.toBeUndefined();
    await expect.poll(() => codexRouteStatus("thread-fast-complete")).toMatchObject({
      routeState: "available", routeOwnership: "unverified", turnState: "ready", confirmedTerminal: true,
    });
    expect(hasActiveCodexTurn("thread-fast-complete", "delivery-fast")).toBe(false);
  });

  it("normalizes an ownership rejection from turn/start and preserves no local route", async () => {
    await fakeCodex("start-owner-held");
    await expect(sendCodexTurn("thread-start-owner", "do not compete", [], undefined, "delivery-owner"))
      .rejects.toThrow("This conversation is owned by another Codex session. Continue there.");
    expect(codexRouteStatus("thread-start-owner").routeState).toBe("unavailable");
  });

  it("keeps an uncertain accepted turn unavailable after the app-server child exits", async () => {
    await fakeCodex("transport-loss");
    await expect(sendCodexTurn("thread-transport-loss", "may have started", [], undefined, "delivery-loss"))
      .resolves.toBeUndefined();
    await expect.poll(() => codexRouteStatus("thread-transport-loss").routeState).toBe("unavailable");
    expect(codexRouteStatus("thread-transport-loss")).toMatchObject({
      routeState: "unavailable", unavailableReason: "provider_unavailable", turnId: "turn-1",
    });
    await expect(sendCodexTurn("thread-transport-loss", "do not duplicate", [], undefined, "delivery-loss-2"))
      .rejects.toThrow("Codex message delivery is unavailable.");
    expect(recoverCodexRoute("thread-transport-loss", {
      turnState: "ready", turnId: "other-turn",
    })).toMatchObject({ recovered: false, reason: "identity_mismatch" });
    expect(recoverCodexRoute("thread-transport-loss", {
      turnState: "ready", turnId: "turn-1",
    })).toMatchObject({
      recovered: true,
      probe: {
        routeState: "available", routeOwnership: "unverified", turnState: "ready",
        turnId: "turn-1", confirmedTerminal: true,
      },
    });
    expect(codexRouteStatus("thread-transport-loss")).toMatchObject({
      routeState: "available", routeOwnership: "unverified", turnState: "ready",
    });
  });

  it("keeps a pre-ack transport loss unresolved when no turn identity was observed", async () => {
    await fakeCodex("transport-loss-before-id");
    await expect(sendCodexTurn("thread-preack-loss", "unknown", [], undefined, "delivery-preack-loss"))
      .rejects.toThrow("Codex");
    await expect.poll(() => codexRouteStatus("thread-preack-loss").routeState).toBe("unavailable");
    expect(codexRouteStatus("thread-preack-loss")).not.toHaveProperty("turnId");
    expect(recoverCodexRoute("thread-preack-loss", {
      turnState: "ready", turnId: "turn-1",
    })).toMatchObject({ recovered: false, reason: "identity_unavailable" });
    expect(codexRouteStatus("thread-preack-loss").routeState).toBe("unavailable");
  });

  it("ignores stale same-thread lifecycle notifications received before start acknowledgement", async () => {
    await fakeCodex("stale-preack-events");
    const events: Array<Record<string, unknown>> = [];
    const unsubscribe = subscribeCodexRouteEvents((event) => {
      events.push(event as unknown as Record<string, unknown>);
    });
    try {
      await sendCodexTurn("thread-stale-preack", "use current turn", [], undefined, "delivery-stale");
      await expect.poll(() => events.some((event) => event.itemId === "current-user")).toBe(true);
      expect(events.some((event) => event.turnId === "old-turn" || event.itemId === "old-user")).toBe(false);
      expect(events).toContainEqual(expect.objectContaining({
        type: "item_completed", turnId: "turn-1", itemId: "current-user",
      }));
    } finally {
      unsubscribe();
    }
  });

  it("keeps the native user identity when pre-ack delta bursts are discarded", async () => {
    await fakeCodex("delta-burst-before-ack");
    const events: Array<Record<string, unknown>> = [];
    const unsubscribe = subscribeCodexRouteEvents((event) => {
      events.push(event as unknown as Record<string, unknown>);
    });
    try {
      await sendCodexTurn("thread-delta-burst", "preserve the prompt identity", [], undefined, "delivery-burst");
      await expect.poll(() => events.some((event) => event.itemId === "burst-user")).toBe(true);
      expect(events).toContainEqual(expect.objectContaining({
        type: "item_started", itemId: "burst-user", itemType: "userMessage",
        turnId: "turn-1", deliveryId: "delivery-burst",
      }));
      expect(events.filter((event) => event.type === "agent_message_delta")).toHaveLength(0);
    } finally {
      unsubscribe();
    }
  });

  it("does not send while the resumed provider thread is already active", async () => {
    const { log } = await fakeCodex("resume-active");
    await expect(acquireCodexRoute("thread-external", true)).resolves.toMatchObject({
      routeState: "available", turnState: "working",
    });
    await expect(sendCodexTurn("thread-external", "compete", [], undefined, "delivery-external"))
      .rejects.toThrow("turn is still in progress");
    expect((await requests(log)).some((message) => message.method === "turn/start")).toBe(false);
  });

  it("rejects a second same-thread send immediately instead of queueing it", async () => {
    const { log } = await fakeCodex("approval");
    const first = sendCodexTurn("thread-busy", "first", [], undefined, "delivery-a");
    await expect.poll(async () => (await requests(log)).some((message) => message.method === "turn/start")).toBe(true);
    await first;
    await expect(sendCodexTurn("thread-busy", "second", [], undefined, "delivery-b"))
      .rejects.toThrow("turn is still in progress");
    expect((await requests(log)).filter((message) => message.method === "turn/start")).toHaveLength(1);
  });

  it("routes concurrent approvals across threads by complete owner identity", async () => {
    const { log } = await fakeCodex("approval");
    const approvals: { pending: ChatPendingAction; respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void> }[] = [];
    const registerAction = (_sessionId: string, pending: ChatPendingAction, respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>) => {
      approvals.push({ pending, respond });
      return () => undefined;
    };
    await Promise.all([
      sendCodexTurn("thread-a", "first", [], registerAction, "delivery-a", "request-a", 1),
      sendCodexTurn("thread-b", "second", [], registerAction, "delivery-b", "request-b", 2),
    ]);
    await expect.poll(() => approvals.length).toBe(2);
    const approvalIDs = approvals.map(({ pending }) => pending.approvalId);
    expect(new Set(approvalIDs).size).toBe(2);
    expect(approvalIDs.every((id) => id?.startsWith("codex-approval-") === true)).toBe(true);
    await Promise.all(approvals.map(({ respond, pending }) => respond({
      type: "respond_chat", id: `reply-${pending.approvalId}`, sessionId: "unused",
      toolUseId: pending.toolUseId, decision: "allow",
    })));
    await expect.poll(async () => (await requests(log)).filter((message) => message.id === 7)).toHaveLength(2);
  });

  it("queues an approval that arrives before the turn/start response", async () => {
    const { log } = await fakeCodex("approval-before-response");
    let pending: ChatPendingAction | undefined;
    let respondApproval: ((message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>) | undefined;
    const registerAction = (_sessionId: string, value: ChatPendingAction, respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>) => {
      pending = value;
      respondApproval = respond;
      return () => undefined;
    };
    await sendCodexTurn("thread-approval-race", "approve", [], registerAction, "delivery-approval-race");
    expect(pending?.approvalId).toMatch(/^codex-approval-/);
    await respondApproval!({
      type: "respond_chat", id: "reply-approval-race", sessionId: "unused",
      toolUseId: pending!.toolUseId, decision: "allow",
    });
    await expect.poll(async () => (await requests(log)).filter((message) => message.id === 7)).toHaveLength(1);
  });

  it("keeps accepted-turn Stop and approval routing after admission currentness expires", async () => {
    const { log } = await fakeCodex("approval");
    let current = true;
    let pending: ChatPendingAction | undefined;
    let respondApproval: ((message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>) | undefined;
    const registerAction = (_sessionId: string, value: ChatPendingAction, respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>) => {
      pending = value;
      respondApproval = respond;
      return () => undefined;
    };
    await sendCodexTurn(
      "thread-managed-lifetime", "continue", [], registerAction, "delivery-managed-lifetime",
      undefined, undefined, undefined, () => current,
    );
    current = false;
    await expect.poll(() => pending?.approvalId).toMatch(/^codex-approval-/);
    await respondApproval!({
      type: "respond_chat", id: "reply-managed-lifetime", sessionId: "unused",
      toolUseId: pending!.toolUseId, decision: "allow",
    });
    await expect(stopCodexTurn("thread-managed-lifetime", "delivery-managed-lifetime")).resolves.toBe(true);
    await expect.poll(async () => (await requests(log)).some((message) => message.method === "turn/interrupt")).toBe(true);
  });

  it("initializes, resumes the exact thread, and starts one text and image turn", async () => {
    const { log } = await fakeCodex("complete");
    process.env.AGENT_VISOR_VERSION = "2.7.0";
    await sendCodexTurn(
      "thread-input", "Fix it", ["/tmp/pixel.png"], undefined, undefined, undefined, undefined,
      { modelId: "gpt-6-astra", reasoningEffort: "high", permissionProfile: ":workspace" },
    );
    const messages = await requests(log);
    expect(messages.map((message) => message.method)).toEqual(["initialize", "initialized", "thread/resume", "turn/start"]);
    expect(messages[0]?.params).toEqual({
      clientInfo: { name: "agent-visor", version: "2.7.0" }, capabilities: { experimentalApi: true },
    });
    const resume = messages.find((message) => message.method === "thread/resume");
    const turnStart = messages.find((message) => message.method === "turn/start");
    expect(resume?.params).toMatchObject({ threadId: "thread-input", excludeTurns: true });
    expect(turnStart?.params).toMatchObject({
      threadId: "thread-input",
      input: [{ type: "text", text: "Fix it" }, { type: "localImage", path: "/tmp/pixel.png" }],
      model: "gpt-6-astra", effort: "high", permissions: ":workspace",
    });
  });

  it("reads the provider-owned model and permission catalogs through app-server", async () => {
    await fakeCodex("catalog");
    await expect(readCodexSettingsCatalog("/tmp/agent-visor-test-home", "/tmp/project")).resolves.toEqual({
      models: [{
        id: "gpt-6-astra", displayName: "GPT-6 Astra", description: "Fast model",
        reasoningEfforts: [{ value: "low", description: "Short" }, { value: "high", description: "Deep" }],
        defaultReasoningEffort: "high", supportsImages: true, isDefault: true,
      }],
      permissionProfiles: [
        { id: ":read-only", displayName: "Read only", description: "No writes", allowed: true },
        { id: ":danger-full-access", displayName: "Full access", allowed: false },
      ],
    });
  });

  it("rechecks currentness immediately before turn/start", async () => {
    const { log } = await fakeCodex("currentness-delayed");
    let current = true;
    const sending = sendCodexTurn("thread-currentness", "Do not race", [], undefined, "delivery-currentness", undefined, undefined, undefined, () => current);
    await expect.poll(async () => (await requests(log)).some((message) => message.method === "thread/resume")).toBe(true);
    current = false;
    await expect(sending).rejects.toThrow("no longer current");
    expect((await requests(log)).some((message) => message.method === "turn/start")).toBe(false);
  });

  it("waits for started/completed events and ignores stale or incomplete identities", async () => {
    const { log } = await fakeCodex("stale-events");
    await sendCodexTurn("thread-events", "Wait", [], undefined, "delivery-events");
    expect(hasActiveCodexTurn("thread-events", "delivery-events")).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(hasActiveCodexTurn("thread-events", "delivery-events")).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(hasActiveCodexTurn("thread-events", "delivery-events")).toBe(false);
  });

  it("interrupts the exact daemon-owned turn with the verified RPC shape", async () => {
    const { log } = await fakeCodex("approval");
    await sendCodexTurn("thread-cancel", "Stop this", [], undefined, "delivery-cancel");
    await expect(stopCodexTurn("other-thread", "delivery-cancel")).resolves.toBe(false);
    await expect(stopCodexTurn("thread-cancel", "wrong-delivery")).resolves.toBe(false);
    await expect(stopCodexTurn("thread-cancel", "delivery-cancel")).resolves.toBe(true);
    await expect(stopCodexTurn("thread-cancel", "delivery-cancel")).resolves.toBe(false);
    await expect.poll(async () => (await requests(log)).some((message) => message.method === "turn/interrupt")).toBe(true);
    const interrupt = (await requests(log)).find((message) => message.method === "turn/interrupt");
    expect(interrupt?.params).toEqual({ threadId: "thread-cancel", turnId: "turn-1" });
    await expect.poll(() => hasActiveCodexTurn("thread-cancel", "delivery-cancel")).toBe(false);
  });

  it("reports a provider interrupt rejection instead of claiming Stop succeeded", async () => {
    await fakeCodex("interrupt-failure");
    await sendCodexTurn("thread-cancel-failure", "Stop this", [], undefined, "delivery-cancel-failure");
    await expect(stopCodexTurn("thread-cancel-failure", "delivery-cancel-failure"))
      .rejects.toThrow("interrupt rejected");
    expect(codexRouteStatus("thread-cancel-failure").routeState).toBe("unavailable");
  });

  it("retains a busy route after its last chat reference is released", async () => {
    const { log } = await fakeCodex("approval");
    await acquireCodexRoute("thread-release", true);
    await sendCodexTurn("thread-release", "Keep working", [], undefined, "delivery-release");
    releaseCodexRoute("thread-release");
    expect(codexRouteStatus("thread-release")).toMatchObject({ routeState: "available", turnState: "working" });
    expect(activeCodexTurnDeliveryId("thread-release")).toBe("delivery-release");
    await expect(stopCodexTurn("thread-release", "delivery-release")).resolves.toBe(true);
    await expect.poll(() => codexRouteStatus("thread-release")).toMatchObject({
      routeState: "available", routeOwnership: "unverified", turnState: "ready",
      confirmedTerminal: true,
    });
    expect((await requests(log)).filter((message) => message.method === "turn/interrupt")).toHaveLength(1);
  });

  it("relinquishes every idle route reference only after the child exits", async () => {
    await fakeCodex("complete");
    await acquireCodexRoute("thread-owner-focus", true);
    await acquireCodexRoute("thread-owner-focus", true);
    await expect(relinquishIdleCodexRoute("thread-owner-focus")).resolves.toBe(true);
    expect(codexRouteStatus("thread-owner-focus").routeState).toBe("unavailable");
  });

  it("refuses owner relinquish while a turn is active", async () => {
    await fakeCodex("approval");
    await sendCodexTurn("thread-owner-busy", "keep", [], undefined, "delivery-owner-busy");
    await expect(relinquishIdleCodexRoute("thread-owner-busy")).resolves.toBe(false);
    expect(codexRouteStatus("thread-owner-busy")).toMatchObject({
      routeState: "available", turnState: "working",
    });
    await expect(stopCodexTurn("thread-owner-busy", "delivery-owner-busy")).resolves.toBe(true);
  });

  it("removes a route when its provider child exits unexpectedly", async () => {
    await fakeCodex("child-exit");
    await expect(acquireCodexRoute("thread-child-exit", true)).resolves.toMatchObject({
      routeState: "available", turnState: "ready",
    });
    await expect.poll(() => codexRouteStatus("thread-child-exit").routeState).toBe("unavailable");
  });

  it("keeps an unconfirmed owner release pending and blocks reacquisition", async () => {
    const { log } = await fakeCodex("delayed-close");
    await acquireCodexRoute("thread-closing", true);
    await expect(relinquishIdleCodexRoute("thread-closing")).resolves.toBe(false);
    expect(codexRouteStatus("thread-closing")).toEqual({
      routeState: "unavailable", unavailableReason: "provider_unavailable", releasePending: true,
    });
    const repeatedRelease = relinquishIdleCodexRoute("thread-closing");
    const reacquire = acquireCodexRoute("thread-closing", true);
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(codexRouteStatus("thread-closing")).toMatchObject({ releasePending: true });
    expect((await requests(log)).filter((message) => message.method === "initialize")).toHaveLength(1);
    await expect(repeatedRelease).resolves.toBe(true);
    await expect(reacquire).resolves.toMatchObject({ routeState: "available" });
    expect((await requests(log)).filter((message) => message.method === "initialize")).toHaveLength(2);
  });

  it("classifies owner-held, provider failures, and explicit binary unavailability", async () => {
    await fakeCodex("owner-held");
    await expect(acquireCodexRoute("thread-owner")).resolves.toEqual({
      routeState: "unavailable", unavailableReason: "owner_only", routeOwnership: "external",
    });
    await closeCodexRoutes();
    await fakeCodex("resume-failure");
    await expect(acquireCodexRoute("thread-failure")).resolves.toEqual({ routeState: "unavailable", unavailableReason: "provider_unavailable" });
    await closeCodexRoutes();
    process.env.CODEX_BINARY = path.join(path.resolve("build"), "missing-codex");
    await expect(acquireCodexRoute("thread-missing-binary")).resolves.toEqual({ routeState: "unavailable", unavailableReason: "provider_unavailable" });
  });

  it("closes a route on shutdown and leaves no available status", async () => {
    const { log } = await fakeCodex("complete");
    await acquireCodexRoute("thread-shutdown", true);
    await closeCodexRoutes();
    expect(codexRouteStatus("thread-shutdown").routeState).toBe("unavailable");
    expect((await requests(log)).some((message) => message.method === "initialize")).toBe(true);
  });
});
