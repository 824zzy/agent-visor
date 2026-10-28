import { createServer, type Socket } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { HerdrClient, type HerdrProcessContext } from "./herdr.js";
import { processInstanceToken } from "./shared.js";
import { ClaudeProvider } from "./claude.js";
import { FakeNativeHelper } from "../native-helper.js";
import { NativeSessionControls } from "../session-controls.js";
import { SessionRepository } from "../sessions.js";
import { activateMenuPill, menuPresentation } from "../menu.js";

const now = new Date("2026-10-20T03:00:00Z");
const ids = ["5118cfe0-3f5b-418e-8bf1-5260f6747f39", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"];
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanups.splice(0).reverse()) await close(); });

/** External Herdr socket with two panes and one client; leases are exclusive. */
async function fixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), "av-herdr-nav-"));
  const socketPath = path.join(root, "api.sock");
  const contexts: HerdrProcessContext[] = ids.map((sessionId, i) => ({
    provider: "claude_code", pid: 42 + i, processStartToken: processInstanceToken(42 + i, now)!,
    sessionId, cwd: "/fixture/Codes", serverPID: 10, serverProcessStartToken: processInstanceToken(10, now)!,
    socketPath, paneId: `w1:p${7 + i}`,
  }));
  const targets = contexts.map(context => ({ boot_id: "boot-one", pane_id: context.paneId,
    terminal_id: `terminal-${context.pid}`, process: { pid: context.pid, start: 1792465200000123 }, session: null }));
  const client = { client: { boot_id: "boot-one", client_id: 1, generation: 1 }, presentation_capable: true,
    binding_capable: true, surface_active: true, projection_revision: 4,
    local_process: { pid: 70, start: 1792465200000111 }, pane_id: "w1:p1", terminal_id: "original-terminal",
    binding: null as null | { nonce: string; state: string }, applied_navigation: null as unknown };
  const requests: string[] = [];
  const rejected: string[] = [];
  const observations = { releasedBindingRead: false };
  const peers = new Set<Socket>();
  const server = createServer(socket => {
    peers.add(socket); socket.on("close", () => peers.delete(socket));
    let input = ""; socket.setEncoding("utf8"); socket.on("data", chunk => {
      input += chunk; if (!input.includes("\n")) return;
      const request = JSON.parse(input.slice(0, input.indexOf("\n")));
      requests.push(request.method);
      const deny = (code: string) => {
        rejected.push(request.method); socket.end(JSON.stringify({ id: request.id, error: { code } }) + "\n");
      };
      const { method, params } = request;
      if (method === "client.get" && client.binding?.state === "released") observations.releasedBindingRead = true;
      if (method === "client.bind_begin") {
        if (client.binding?.state === "applied" && client.binding.nonce !== params.nonce) return deny("binding_busy");
        client.binding = { nonce: params.nonce, state: "applied" };
      }
      if (method === "client.bind_end") {
        if (client.binding?.nonce !== params.nonce) return deny("binding_mismatch");
        client.binding.state = "released";
      }
      const target = targets.find(target => target.pane_id === params.pane_id);
      if (method === "client.focus_exclusive") {
        if (!target) return deny("target_missing");
        client.pane_id = target.pane_id; client.terminal_id = target.terminal_id;
        client.applied_navigation = { projection: { client: client.client, navigation_id: params.navigation_id,
          minimum_projection_revision: 5, target }, projection_revision: 5, surface_revision: 9 };
      }
      const result = method === "client.focus_exclusive"
        ? { status: "accepted", client: client.client, navigation_id: params.navigation_id, minimum_projection_revision: 5 }
        : method.startsWith("client.bind_") ? { status: "accepted" }
        : method === "client.target" ? { target }
        : method === "client.list" ? { boot_id: "boot-one", view_revision: 2, clients: [client], unclassified_connections: 0 }
        : { view_revision: 2, client };
      socket.end(JSON.stringify({ id: request.id, result }) + "\n");
    });
  });
  await new Promise<void>(resolve => server.listen(socketPath, resolve));
  cleanups.push(async () => {
    for (const socket of peers) socket.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  const herdr = new HerdrClient(async pid => structuredClone(contexts.find(context => context.pid === pid)));
  const routes = await Promise.all(contexts.map(context => herdr.resolve(context.pid, context.sessionId, context.cwd)));
  expect(routes.every(Boolean)).toBe(true);
  const focused: string[] = [];
  const native = {
    ghosttyBindingStatus: async () => true,
    resolveGhosttyBinding: async (nonce: string) => ({ applicationPID: 900,
      processStartToken: processInstanceToken(900, now)!, windowId: "window", tabId: "tab", terminalId: "outer-herdr", nonce }),
    prepareGhosttyBinding: async () => {},
    focusGhosttyBinding: async () => { focused.push(client.terminal_id); },
  };
  return { root, contexts, routes: routes.map(route => route!), herdr, native, focused, client, requests, rejected, observations };
}

it("opens a second session while the same Herdr client is being prepared in the background", async () => {
  const f = await fixture();
  let began!: () => void; let release!: () => void;
  const entered = new Promise<void>(resolve => { began = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const native = { ...f.native, resolveGhosttyBinding: async (nonce: string) => {
    began(); await gate; return f.native.resolveGhosttyBinding(nonce);
  } };
  const preparation = f.herdr.prepare(f.routes[0]!, native);
  await entered;
  const click = f.herdr.focus(f.routes[1]!, native).then(() => "focused", error => error.message);
  // Let a cold click reach the exclusive-lease boundary while preparation holds it.
  await new Promise(resolve => setImmediate(resolve));
  release();
  try {
    expect(await click).toBe("focused");
    await preparation;
    expect(f.focused).toEqual(["terminal-43"]);
    expect(f.rejected).toEqual([]);
    expect(f.client.binding?.state).toBe("released");
  } finally { release(); await Promise.allSettled([preparation, click]); }
});

it("reports an unverified route without claiming that Herdr needs an update", async () => {
  const f = await fixture();
  f.client.binding = { nonce: "f".repeat(32), state: "applied" };
  await expect(f.herdr.focus(f.routes[0]!, f.native)).rejects.toThrow(
    "Exact Herdr navigation is unavailable. Agent Visor could not verify the existing session window.",
  );
  expect(f.focused).toEqual([]);
  expect(f.client.terminal_id).toBe("original-terminal");
});

it("reuses the exact binding completed while a same-session click was queued", async () => {
  const f = await fixture();
  let began!: () => void; let release!: () => void;
  const entered = new Promise<void>(resolve => { began = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const native = { ...f.native, resolveGhosttyBinding: async (nonce: string) => {
    began(); await gate; return f.native.resolveGhosttyBinding(nonce);
  } };
  const preparation = f.herdr.prepare(f.routes[0]!, native);
  await entered;
  const click = f.herdr.focus(f.routes[0]!, native);
  release();
  await Promise.all([preparation, click]);
  expect(f.focused).toEqual(["terminal-42"]);
  expect(f.requests.filter(method => method === "client.bind_begin")).toHaveLength(1);
  expect(f.rejected).toEqual([]);
});

it("recovers with a guarded lease when newly completed preparation fails native verification", async () => {
  const f = await fixture();
  let began!: () => void; let release!: () => void; let checks = 0;
  const entered = new Promise<void>(resolve => { began = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const native = { ...f.native, resolveGhosttyBinding: async (nonce: string) => {
    began(); await gate; return f.native.resolveGhosttyBinding(nonce);
  }, prepareGhosttyBinding: async () => { if (++checks === 2) throw new Error("Fixture helper restarted"); } };
  const preparation = f.herdr.prepare(f.routes[0]!, native);
  await entered;
  const click = f.herdr.focus(f.routes[0]!, native);
  release();
  await Promise.all([preparation, click]);
  expect(f.focused).toEqual(["terminal-42"]);
  expect(f.requests.filter(method => method === "client.bind_begin")).toHaveLength(2);
  expect(f.client.binding?.state).toBe("released");
  expect(f.rejected).toEqual([]);
});

it("discards native preparation that completes after its session is forgotten", async () => {
  const f = await fixture();
  let began!: () => void; let release!: () => void;
  const entered = new Promise<void>(resolve => { began = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const helper = new FakeNativeHelper();
  Object.assign(helper, f.native, { prepareGhosttyBinding: async () => { began(); await gate; } });
  let preparation!: Promise<string>;
  const controls = new NativeSessionControls(helper, f.root, undefined, undefined, undefined,
    undefined, undefined, undefined, undefined,
    (target, isCurrent) => f.herdr.focus(target, helper, isCurrent), (target, isCurrent) => {
      const pending = f.herdr.prepare(target, helper, isCurrent);
      preparation = pending.then(() => "prepared", () => "discarded"); return pending;
    });
  controls.reconcile({ id: ids[0]!, provider: "claude_code", cwd: "/fixture/Codes", owner: "Herdr",
    section: "ready", updatedAt: now.toISOString(), canOpenOwner: true, canEnterChat: true,
    controlTarget: { kind: "herdr_surface", target: f.routes[0]! } });
  await entered;
  controls.forget(ids[0]!); release();
  expect(await preparation).toBe("discarded");
  expect(f.client.binding?.state).toBe("released");
  expect(f.focused).toEqual([]);
  const before = f.requests.filter(method => method === "client.bind_begin").length;
  await f.herdr.focus(f.routes[0]!, helper);
  expect(f.requests.filter(method => method === "client.bind_begin")).toHaveLength(before + 1);
});

it("discards preparation invalidated immediately after the released-binding readback", async () => {
  const f = await fixture(); let current = true; let scheduled = false;
  const isCurrent = () => {
    if (f.observations.releasedBindingRead && !scheduled) {
      scheduled = true; queueMicrotask(() => { current = false; });
    }
    return current;
  };
  await expect(f.herdr.prepare(f.routes[0]!, f.native, isCurrent)).rejects.toThrow("Exact Herdr navigation");
  expect(f.client.binding?.state).toBe("released");
  expect(f.focused).toEqual([]);
  await f.herdr.focus(f.routes[0]!, f.native);
  expect(f.requests.filter(method => method === "client.bind_begin")).toHaveLength(2);
});

it("drops a forgotten session's queued preparation before it acquires a shared binding", async () => {
  const f = await fixture();
  let began!: () => void; let release!: () => void; let admitted!: () => void;
  const entered = new Promise<void>(resolve => { began = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const queued = new Promise<void>(resolve => { admitted = resolve; });
  const helper = new FakeNativeHelper();
  Object.assign(helper, f.native, { resolveGhosttyBinding: async (nonce: string) => {
    began(); await gate; return f.native.resolveGhosttyBinding(nonce);
  } });
  const pending: Promise<void>[] = [];
  const controls = new NativeSessionControls(helper, f.root, undefined, undefined, undefined,
    undefined, undefined, undefined, undefined,
    (target, isCurrent) => f.herdr.focus(target, helper, isCurrent), (target, isCurrent) => {
      const preparation = f.herdr.prepare(target, helper, isCurrent); pending.push(preparation);
      if (target.sessionId === ids[1]) admitted(); return preparation;
    });
  cleanups.push(async () => { release(); await Promise.allSettled(pending); });
  const session = (index: number) => ({ id: ids[index]!, provider: "claude_code" as const,
    cwd: "/fixture/Codes", owner: "Herdr", section: "ready" as const, updatedAt: now.toISOString(),
    canOpenOwner: true, canEnterChat: true, controlTarget: { kind: "herdr_surface" as const, target: f.routes[index]! } });
  controls.reconcile(session(0)); await entered;
  controls.reconcile(session(1)); await queued;
  controls.forget(ids[1]!); release();
  await Promise.allSettled(pending);
  expect(f.requests.filter(method => method === "client.bind_begin")).toHaveLength(1);
  expect(f.client.binding?.state).toBe("released");
  await f.herdr.focus(f.routes[0]!, helper);
  expect(f.focused).toEqual(["terminal-42"]);
  expect(f.rejected).toEqual([]);
});

it("keeps replacement preparation current when a forgotten instance settles late", async () => {
  const f = await fixture();
  let began!: () => void; let release!: () => void; let replaced!: () => void;
  const entered = new Promise<void>(resolve => { began = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const replacement = new Promise<void>(resolve => { replaced = resolve; });
  const helper = new FakeNativeHelper(); let first = true;
  Object.assign(helper, f.native, { prepareGhosttyBinding: async () => {
    if (first) { first = false; began(); await gate; }
  } });
  const outcomes: Promise<string>[] = [];
  const controls = new NativeSessionControls(helper, f.root, undefined, undefined, undefined,
    undefined, undefined, undefined, undefined,
    (target, isCurrent) => f.herdr.focus(target, helper, isCurrent), (target, isCurrent) => {
      const pending = f.herdr.prepare(target, helper, isCurrent);
      outcomes.push(pending.then(() => "prepared", () => "discarded"));
      if (outcomes.length === 2) replaced(); return pending;
    });
  cleanups.push(async () => { release(); await Promise.allSettled(outcomes); });
  const session = { id: ids[0]!, provider: "claude_code" as const, cwd: "/fixture/Codes", owner: "Herdr",
    section: "ready" as const, updatedAt: now.toISOString(), canOpenOwner: true, canEnterChat: true,
    controlTarget: { kind: "herdr_surface" as const, target: f.routes[0]! } };
  controls.reconcile(session); await entered;
  controls.forget(session.id); controls.reconcile(session); release();
  await replacement;
  expect(await Promise.all(outcomes)).toEqual(["discarded", "prepared"]);
  await f.herdr.focus(f.routes[0]!, helper);
  expect(f.focused).toEqual(["terminal-42"]);
  expect(f.requests.filter(method => method === "client.bind_begin")).toHaveLength(2);
});

it("keeps a prepared click independent of another pane's background binding", async () => {
  const f = await fixture();
  await f.herdr.prepare(f.routes[0]!, f.native);
  let began!: () => void; let release!: () => void; let focused!: () => void;
  const entered = new Promise<void>(resolve => { began = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const arrived = new Promise<void>(resolve => { focused = resolve; });
  const native = { ...f.native, resolveGhosttyBinding: async (nonce: string) => {
    began(); await gate; return f.native.resolveGhosttyBinding(nonce);
  }, focusGhosttyBinding: async () => { await f.native.focusGhosttyBinding(); focused(); } };
  const background = f.herdr.prepare(f.routes[1]!, native);
  await entered;
  const click = f.herdr.focus(f.routes[0]!, native);
  // Also release on the runner's timeout if a regression queues this warm click.
  cleanups.push(async () => { release(); await Promise.allSettled([background, click]); });
  try {
    await Promise.race([arrived, click]);
    expect(f.focused).toEqual(["terminal-42"]);
  } finally { release(); await Promise.allSettled([background, click]); }
  expect(f.rejected).toEqual([]);
});

it("discovers two Claude pills and opens each exact pane on cold and prepared clicks", async () => {
  const f = await fixture();
  const records = JSON.stringify({ type: "assistant", timestamp: "2026-10-20T02:59:00Z",
    message: { role: "assistant", stop_reason: "end_turn", content: [{ type: "text", text: "Done" }] } }) + "\n";
  const environment = {
    home: "/fixture", observedWindowMs: 42 * 60 * 60 * 1000, now: () => now,
    processes: async () => [...f.contexts.map(context => ({ pid: context.pid, parentPID: 10,
      tty: `ttys0${context.pid}`, command: "/usr/local/bin/claude", arguments: "claude" })),
      { pid: 10, parentPID: 1, command: "/usr/local/bin/herdr", arguments: "herdr server" }],
    cwd: async () => "/fixture/Codes", processStartedAt: async () => now,
    directory: async (value: string) => value.endsWith("/.claude/sessions") ? ["42.json", "43.json"] : [],
    isDirectory: async () => true, stamp: async () => ({ modifiedAt: now, size: 512 }),
    read: async (value: string) => {
      const context = f.contexts.find(context => value.endsWith(`/sessions/${context.pid}.json`));
      return context ? JSON.stringify({ pid: context.pid, sessionId: context.sessionId,
        cwd: context.cwd, kind: "interactive", status: "idle", name: `Herdr ${context.pid}` }) : undefined;
    },
    readHeadTail: async () => ({ head: records, tail: records }), scanLinePrefixes: async () => 0,
    sqlite: async () => [], herdrSurface: f.herdr.resolve.bind(f.herdr),
  };
  const repository = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
  await repository.refresh();
  const helper = new FakeNativeHelper(); Object.assign(helper, f.native);
  repository.setControls(new NativeSessionControls(helper, f.root, undefined, undefined, undefined,
    undefined, undefined, undefined, undefined,
    (target, isCurrent) => f.herdr.focus(target, helper, isCurrent),
    (target, isCurrent) => f.herdr.prepare(target, helper, isCurrent)));
  expect(menuPresentation(repository.current(), [], now.valueOf()).pills.map(pill => pill.id))
    .toEqual(expect.arrayContaining(ids));
  const effects: unknown[] = [];
  const click = async (sessionId: string) => activateMenuPill(
    { version: 1, type: "event", event: "activate_pill", sessionId }, repository, effect => effects.push(effect));
  await click(ids[0]!);
  expect(f.client.terminal_id).toBe("terminal-42");
  expect(repository.current().sessions.find(row => row.id === ids[0])?.completionUnseen).toBeUndefined();
  expect(repository.current().sessions.find(row => row.id === ids[1])?.completionUnseen).toBe(true);
  await click(ids[1]!);
  const coldLeases = f.requests.filter(method => method === "client.bind_begin").length;
  expect(coldLeases).toBe(2);
  await click(ids[0]!); await click(ids[1]!);
  expect(f.focused).toEqual(["terminal-42", "terminal-43", "terminal-42", "terminal-43"]);
  expect(f.requests.filter(method => method === "client.bind_begin")).toHaveLength(coldLeases);
  expect(repository.current().sessions.every(row => !row.completionUnseen)).toBe(true);
  expect(f.rejected).toEqual([]); expect(effects).toEqual([]);
});
