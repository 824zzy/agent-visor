import { createServer, type Socket } from "node:net";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { afterEach, expect, it } from "vitest";
import { HerdrClient, type HerdrProcessContext, type HerdrSystem } from "./herdr.js";
import { processInstanceToken } from "./shared.js";
import { ClaudeProvider } from "./claude.js";
import { PaseoProvider } from "./paseo.js";
import { CodexProvider } from "./codex.js";
import { SessionRepository } from "../sessions.js";
import { activateMenuPill, menuPresentation } from "../menu.js";
import { NativeSessionControls } from "../session-controls.js";
import { FakeNativeHelper } from "../native-helper.js";
import { NavigationDiagnostics } from "../navigation-diagnostics.js";
import { alfredResults } from "../alfred.js";

const now = new Date("2026-10-20T03:00:00Z");
const sessionId = "5118cfe0-3f5b-418e-8bf1-5260f6747f39";
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanups.splice(0).reverse()) await close(); });

async function fixture(beforeReply?: (method: string, socket: Socket) => void) {
  const root = await mkdtemp(path.join(os.tmpdir(), "av-hnav-"));
  const socketPath = path.join(root, "api.sock");
  const context: HerdrProcessContext = { provider: "claude_code", pid: 42,
    processStartToken: processInstanceToken(42, now)!, sessionId, cwd: "/fixture/Codes",
    serverPID: 10, serverProcessStartToken: processInstanceToken(10, now)!, socketPath, paneId: "w1:p7" };
  const target = { boot_id: "boot-one", pane_id: "w1:p7", terminal_id: "terminal-seven",
    process: { pid: 42, start: 1792465200000123 }, session: null as unknown };
  const client = { client: { boot_id: "boot-one", client_id: 1, generation: 1 }, presentation_capable: true,
    binding_capable: true, surface_active: true, projection_revision: 4,
    local_process: { pid: 70, start: 1792465200000111 }, pane_id: "w1:p1", terminal_id: "terminal-one",
    binding: null as null | { nonce: string; state: string },
    pending_navigation: null, applied_navigation: null as unknown };
  const requests: Array<{ method: string; params: Record<string, unknown> }> = [];
  const clients = [client];
  const catalog = { boot_id: "boot-one", view_revision: 2, clients, unclassified_connections: 0 };
  const peers = new Set<Socket>();
  let contextEnabled = true;
  const server = createServer(socket => {
    peers.add(socket); socket.on("close", () => peers.delete(socket));
    let input = ""; socket.setEncoding("utf8"); socket.on("data", chunk => {
      input += chunk;
      if (!input.includes("\n")) return;
      const request = JSON.parse(input.slice(0, input.indexOf("\n")));
      requests.push({ method: request.method, params: request.params });
      if (request.method === "client.bind_begin") client.binding = { nonce: request.params.nonce, state: "applied" };
      if (request.method === "client.bind_end") client.binding = { nonce: request.params.nonce, state: "released" };
      if (request.method === "client.focus_exclusive") {
        client.pane_id = target.pane_id; client.terminal_id = target.terminal_id;
        client.applied_navigation = { projection: { client: client.client, navigation_id: request.params.navigation_id,
          minimum_projection_revision: 5, target }, projection_revision: 5, surface_revision: 9 };
      }
      const result = request.method === "client.focus_exclusive"
        ? { status: "accepted", client: client.client, navigation_id: request.params.navigation_id, minimum_projection_revision: 5 }
        : request.method.startsWith("client.bind_") ? { status: "accepted" }
        : request.method === "client.target" ? { target }
        : request.method === "client.list" ? catalog
        : { view_revision: 2, client };
      beforeReply?.(request.method, socket);
      socket.end(JSON.stringify({ id: request.id, result }) + "\n");
    });
  });
  await new Promise<void>(resolve => server.listen(socketPath, resolve));
  cleanups.push(async () => {
    for (const socket of peers) socket.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  return { context, target, client, catalog, requests, disableContext: () => { contextEnabled = false; },
    herdr: new HerdrClient(async () => contextEnabled ? structuredClone(context) : undefined) };
}

function nativeHost() {
  const focused: unknown[] = [];
  return {
    focused,
    ghosttyBindingStatus: async () => true,
    resolveGhosttyBinding: async (nonce: string) => ({ applicationPID: 900,
      processStartToken: processInstanceToken(900, now)!, windowId: "window-seven",
      tabId: "tab-client", terminalId: "outer-client", nonce }),
    focusGhosttyBinding: async (binding: unknown) => { focused.push(binding); },
  };
}

it("prepares a Herdr surface without selecting it and focuses without a click-time title lease or process inventory", async () => {
  const f = await fixture();
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  const prepared: unknown[] = [];
  const native = { ...nativeHost(), prepareGhosttyBinding: async (binding: unknown, processes: unknown) => {
    prepared.push({ binding, processes });
  } };
  await f.herdr.prepare(target, native);
  expect(prepared).toHaveLength(1);
  expect(native.focused).toEqual([]);
  expect(f.client.terminal_id).toBe("terminal-one");
  expect(f.client.binding?.state).toBe("released");
  const beforeClick = f.requests.length;
  f.disableContext();
  const diagnostics = new NavigationDiagnostics(path.dirname(f.context.socketPath));
  await diagnostics.run(sessionId, "standard", () => f.herdr.focus(target, native));
  await diagnostics.flush();
  const trace = await readFile(path.join(path.dirname(f.context.socketPath), "diagnostics/pill-navigation.jsonl"), "utf8");
  const stages = trace.trim().split("\n").map(line => JSON.parse(line).stage);
  expect(stages).toContain("route_prepared");
  expect(stages).toContain("herdr_readback");
  expect(stages).toContain("herdr_rpc_request");
  expect(stages).toContain("herdr_rpc_response");
  expect(stages).toContain("process_validated");
  expect(stages).not.toContain("route_recovery");
  expect(native.focused).toHaveLength(1);
  expect(f.client.terminal_id).toBe("terminal-seven");
  expect(f.requests.slice(beforeClick).some(request => request.method.startsWith("client.bind_"))).toBe(false);
});

it("keeps exact discovery available while its own background preparation is applying a title lease", async () => {
  const f = await fixture();
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  let started!: () => void; let release!: () => void;
  const reading = new Promise<void>(resolve => { started = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const host = nativeHost();
  const native = { ...host, prepareGhosttyBinding: async () => {}, resolveGhosttyBinding: async (nonce: string) => {
    started(); await gate; return host.resolveGhosttyBinding(nonce);
  } };
  const preparing = f.herdr.prepare(target, native);
  await reading;
  try {
    expect(await f.herdr.resolve(42, sessionId, "/fixture/Codes")).toMatchObject({ paneId: "w1:p7", sessionId });
    expect(native.focused).toEqual([]);
  } finally { release(); await preparing; }
  expect(f.client.binding?.state).toBe("released");
});

it("rebuilds a lost helper capability once so later clicks use the prepared route again", async () => {
  const f = await fixture();
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  const capabilities = new Set<string>();
  const host = nativeHost();
  const native = { ...host, prepareGhosttyBinding: async (binding: { nonce: string }) => {
    if (!capabilities.has(binding.nonce) && f.client.binding?.state !== "applied") throw new Error("helper restarted");
    capabilities.add(binding.nonce);
  } };
  await f.herdr.prepare(target, native);
  capabilities.clear();
  await f.herdr.focus(target, native);
  expect(f.client.binding?.state).toBe("released");
  const beforeNextClick = f.requests.length;
  f.disableContext();
  await f.herdr.focus(target, native);
  expect(native.focused).toHaveLength(2);
  expect(f.requests.slice(beforeNextClick).some(request => request.method.startsWith("client.bind_"))).toBe(false);
});

it("bounds queued background preparation while native metadata is unavailable", async () => {
  const f = await fixture();
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  let started!: () => void; let release!: () => void;
  const reading = new Promise<void>(resolve => { started = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const host = nativeHost();
  const native = { ...host, prepareGhosttyBinding: async () => {}, resolveGhosttyBinding: async (nonce: string) => {
    started(); await gate; return host.resolveGhosttyBinding(nonce);
  } };
  const pending = Array.from({ length: 32 }, () => f.herdr.prepare(target, native));
  await reading;
  const overflow = f.herdr.prepare(target, native);
  try {
    expect(await Promise.race([overflow.then(() => "accepted", () => "rejected"),
      new Promise(resolve => setTimeout(() => resolve("queued"), 20))])).toBe("rejected");
    expect(native.focused).toEqual([]);
  } finally { release(); await Promise.allSettled([...pending, overflow]); }
});


it.each(["native", "observer", "tui"])("opens a resumed CLI in its exact Herdr pane despite a different catalog cwd and Desktop history (%s identity)", async identity => {
  const f = await fixture();
  Object.assign(f.context, { provider: "codex", codexHome: "/fixture/.codex" });
  f.target.session = identity === "native" ? { agent: "codex", kind: "id", value: sessionId } : null;
  const observation = { version: 1 as const, sessionId, pid: 42, tty: "ttys023", cwd: "/fixture/Agent Room",
    home: "/fixture/.codex", processStartToken: f.context.processStartToken, observedAt: now.toISOString(), ended: false };
  const herdr = new HerdrClient(async () => structuredClone(f.context), 400,
    { readCodexObservation: async () => identity === "observer" ? observation : undefined,
      ...(identity === "tui" ? { readCodexTuiBinding: async () => ({ sessionIds: [sessionId],
        origin: "http://127.0.0.1:60119", socketPath: "/fixture/codex.sock", socketIdentity: "fixture" }) } : {}),
    } as unknown as HerdrSystem);
  const records = [
    { type: "session_meta", payload: { id: sessionId, originator: "Codex Desktop", source: "vscode" } },
    { type: "event_msg", timestamp: now.toISOString(), payload: { type: "task_complete", turn_id: "done" } },
  ].map(record => JSON.stringify(record)).join("\n") + "\n";
  const environment = {
    home: "/fixture", observedWindowMs: 42 * 60 * 60 * 1000, now: () => now,
    processes: async () => [
      { pid: 42, parentPID: 10, tty: "ttys023", command: "/usr/local/bin/codex", arguments: "codex" },
      { pid: 10, parentPID: 1, command: "/usr/local/bin/herdr", arguments: "herdr server" },
    ],
    cwd: async () => "/fixture/Codes", processStartedAt: async () => now,
    directory: async () => [], isDirectory: async () => false,
    stamp: async () => ({ modifiedAt: now, size: Buffer.byteLength(records) }),
    read: async () => undefined, readHeadTail: async () => ({ head: records, tail: records }),
    scanLinePrefixes: async (_file: string, _bytes: number, visit: (line: string) => void) => {
      records.trim().split("\n").forEach(visit); return Buffer.byteLength(records);
    },
    sqlite: async () => [{ id: sessionId, cwd: "/fixture/Agent Room", rollout_path: "/fixture/rollout.jsonl",
      title: "AR", updated_at: now.valueOf() / 1000, archived: 0, source: "vscode" },
      ...(identity === "tui" ? [{ id: "11111111-1111-4111-8111-111111111111", cwd: "/fixture/Agent Room",
        rollout_path: "/fixture/parent.jsonl", title: "AR", updated_at: now.valueOf() / 1000, archived: 0, source: "vscode" }] : [])],
    herdrCodexSurface: async (pid: number, cwd: string) => herdr.resolveCodex(pid, cwd, "/fixture/.codex"),
  };
  const helper = new FakeNativeHelper();
  const native = nativeHost(); Object.assign(helper, native);
  const repository = new SessionRepository([new CodexProvider(environment)], { now: () => now });
  repository.setControls(new NativeSessionControls(helper, undefined, undefined, undefined, undefined,
    undefined, undefined, undefined, undefined, (target, isCurrent) => herdr.focus(target, helper, isCurrent),
    target => herdr.prepare(target, helper)));
  await repository.refresh();
  repository.applyHook({ sessionId, provider: "codex", cwd: "/fixture/Codes", event: "Stop",
    status: "waiting_for_input", receivedAt: now.toISOString() });
  const effects: unknown[] = [];
  const diagnostics = new NavigationDiagnostics(path.dirname(f.context.socketPath));
  await diagnostics.run(sessionId, "standard", () => activateMenuPill(
    { version: 1, type: "event", event: "activate_pill", sessionId }, repository, effect => effects.push(effect),
  ));
  await diagnostics.flush();
  const trace = await readFile(path.join(path.dirname(f.context.socketPath), "diagnostics/pill-navigation.jsonl"), "utf8");
  expect(trace.split("\n").filter(Boolean).map(line => JSON.parse(line))).toContainEqual(expect.objectContaining({
    stage: "target", targetKind: "herdr_surface",
  }));
  expect(repository.current().sessions.find(row => row.id === sessionId)).toMatchObject({ owner: "Herdr", canOpenOwner: true });
  if (identity === "tui") {
    expect(repository.current().sessions.filter(row => row.title === "AR")).toHaveLength(2);
    expect(repository.current().sessions.find(row => row.id !== sessionId)?.owner).not.toBe("Herdr");
    const restarted = new SessionRepository([new CodexProvider(environment)], { now: () => now });
    await restarted.refresh();
    expect(restarted.current().sessions.find(row => row.id === sessionId)).toMatchObject({ owner: "Herdr", canOpenOwner: true });
  }
  expect(native.focused).toHaveLength(1);
  expect(helper.codexThreadRequests).toEqual([]);
  expect(helper.terminalFocusRequests).toEqual([]);
  expect(effects).toEqual([]);
});

it("discovers the current Codex thread from the host without guessing from cwd or source", async () => {
  const f = await fixture();
  Object.assign(f.context, { provider: "codex", codexHome: "/fixture/.codex" });
  f.target.session = { agent: "codex", kind: "id", value: sessionId };
  const target = await f.herdr.resolveCodex(42, "/fixture/Codes", "/fixture/.codex");
  expect(target).toMatchObject({ provider: "codex", sessionId, pid: 42, paneId: "w1:p7" });
  expect(f.requests.every(request => ["client.target", "client.list"].includes(request.method))).toBe(true);
});

it.each(["wrong-home", "missing-session", "wrong-provider", "replaced-process", "second-client"])("does not bind an unverifiable Codex frontend (%s)", async change => {
  const f = await fixture();
  Object.assign(f.context, { provider: "codex", codexHome: "/fixture/.codex" });
  f.target.session = { agent: "codex", kind: "id", value: sessionId };
  if (change === "wrong-home") f.context.codexHome = "/fixture/copilot";
  if (change === "missing-session") f.target.session = null;
  if (change === "wrong-provider") f.target.session = { agent: "claude", kind: "id", value: sessionId };
  if (change === "replaced-process") f.target.process.pid = 99;
  if (change === "second-client") f.catalog.clients.push(structuredClone(f.client));
  expect(await f.herdr.resolveCodex(42, "/fixture/Codes", "/fixture/.codex")).toBeUndefined();
  expect(f.requests.some(request => request.method.startsWith("client.bind"))).toBe(false);
});

it.each(["valid", "duplicate-child", "wrong-wrapper-start"])("validates an npm Codex frontend wrapper (%s)", async change => {
  const f = await fixture();
  f.target.process.pid = 41;
  f.target.session = { agent: "codex", kind: "id", value: sessionId };
  if (change === "wrong-wrapper-start") f.target.process.start += 1_000_000;
  const processTable = [
    "42 41 Tue Oct 20 03:00:00 2026 /usr/local/bin/codex",
    "41 10 Tue Oct 20 03:00:00 2026 node",
    "10 1 Tue Oct 20 03:00:00 2026 /usr/local/bin/herdr",
    ...(change === "duplicate-child" ? ["43 41 Tue Oct 20 03:00:00 2026 /usr/local/bin/codex"] : []),
  ].join("\n");
  const system = {
    run: async (_executable: string, args: readonly string[]) => ({ status: "success" as const, exitCode: 0, stderr: "",
      stdout: args.includes("pid=,ppid=,lstart=,comm=") ? processTable
        : `codex HERDR_PANE_ID=w1:p7 HERDR_SOCKET_PATH=${f.context.socketPath} CODEX_HOME=/fixture/.codex` }),
    readClaudeMetadata: async () => undefined,
  };
  const client = new HerdrClient(undefined, 400, system);
  const target = await client.resolveCodex(42, "/fixture/Codes", "/fixture/.codex");
  if (change !== "valid") { expect(target).toBeUndefined(); return; }
  expect(target).toMatchObject({ provider: "codex", pid: 42, target: { process: { pid: 41 } } });
  await expect(client.focus(target!, nativeHost())).resolves.toBeUndefined();
});

it.each(["second-client", "unknown-client", "unsupported"])("does not admit an unsafe client catalog: %s", async reason => {
  const f = await fixture();
  if (reason === "second-client") f.catalog.clients.push(structuredClone(f.client));
  if (reason === "unknown-client") f.catalog.unclassified_connections = 1;
  if (reason === "unsupported") f.client.binding_capable = false;
  expect(await f.herdr.resolve(42, sessionId, "/fixture/Codes")).toBeUndefined();
  expect(f.requests.some(({ method }) => method.startsWith("client.bind"))).toBe(false);
});

it.each(["pending", "applied"])("does not advertise a client with a foreign %s title lease", async state => {
  const f = await fixture();
  f.client.binding = { nonce: "b".repeat(32), state };
  expect(await f.herdr.resolve(42, sessionId, "/fixture/Codes")).toBeUndefined();
});

it("does not advertise a malformed released title lease", async () => {
  const f = await fixture();
  f.client.binding = { nonce: "invalid", state: "released" };
  expect(await f.herdr.resolve(42, sessionId, "/fixture/Codes")).toBeUndefined();
});

it("requires native access before emitting any title marker", async () => {
  const f = await fixture();
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  const native = { ...nativeHost(), ghosttyBindingStatus: async () => false };
  await expect(f.herdr.focus(target, native)).rejects.toThrow("Automation access");
  expect(native.focused).toEqual([]);
  expect(f.requests.map(({ method }) => method)).toEqual(["client.target", "client.list"]);
});

it("releases an admitted title lease even if its response was lost", async () => {
  const f = await fixture((method, socket) => { if (method === "client.bind_begin") socket.destroy(); });
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  const native = nativeHost();
  await expect(f.herdr.focus(target, native)).rejects.toThrow("Exact Herdr navigation");
  expect(native.focused).toEqual([]);
  expect(f.client.binding?.state).toBe("released");
});

it("releases the title lease when a newer click supersedes native resolution", async () => {
  const f = await fixture();
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  let current = true;
  const native = nativeHost();
  const resolve = native.resolveGhosttyBinding;
  native.resolveGhosttyBinding = async nonce => { current = false; return resolve(nonce); };
  await expect(f.herdr.focus(target, native, () => current)).rejects.toThrow("Exact Herdr navigation");
  expect(native.focused).toEqual([]);
  expect(f.client.binding?.state).toBe("released");
  expect(f.requests.some(({ method }) => method === "client.focus_exclusive")).toBe(false);
});

it("compares structured identities independently of JSON property order", async () => {
  const f = await fixture();
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  const native = nativeHost();
  const resolve = native.resolveGhosttyBinding;
  native.resolveGhosttyBinding = async nonce => {
    const { boot_id, client_id, generation } = f.client.client;
    f.client.client = { generation, client_id, boot_id };
    return resolve(nonce);
  };
  await expect(f.herdr.focus(target, native)).resolves.toBeUndefined();
  expect(native.focused).toHaveLength(1);
});

it.each(["pane-replaced", "client-replaced", "second-client"])("revalidates after native resolution: %s", async change => {
  const f = await fixture();
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  const native = nativeHost();
  const resolve = native.resolveGhosttyBinding;
  native.resolveGhosttyBinding = async nonce => {
    if (change === "pane-replaced") f.target.process.start++;
    if (change === "client-replaced") f.client.client.generation++;
    if (change === "second-client") f.catalog.clients.push(structuredClone(f.client));
    return resolve(nonce);
  };
  await expect(f.herdr.focus(target, native)).rejects.toThrow("Exact Herdr navigation");
  expect(native.focused).toEqual([]);
  expect(f.requests.some(({ method }) => method === "client.focus_exclusive")).toBe(false);
  expect(f.client.binding?.state).toBe("released");
});

it("discovers the exact detached Herdr pane without selecting a client or emitting a marker", async () => {
  const f = await fixture();
  const resolved = await f.herdr.resolve(42, sessionId, "/fixture/Codes");
  expect(resolved).toMatchObject({ socketPath: f.context.socketPath, paneId: "w1:p7", sessionId,
    target: f.target, client: f.client.client });
  expect(f.requests.map(({ method }) => method)).toEqual(["client.target", "client.list"]);
});

it("selects the exact pane and native surface, then releases the marker before reporting success", async () => {
  const f = await fixture();
  const target = (await f.herdr.resolve(42, sessionId, "/fixture/Codes"))!;
  const focused: unknown[] = [];
  const native = {
    ghosttyBindingStatus: async () => true,
    resolveGhosttyBinding: async (nonce: string) => ({ applicationPID: 900,
      processStartToken: processInstanceToken(900, now)!, windowId: "window-seven",
      tabId: "tab-client", terminalId: "outer-client", nonce }),
    focusGhosttyBinding: async (binding: unknown) => { focused.push(binding); },
  };
  await expect(f.herdr.focus(target, native)).resolves.toBeUndefined();
  expect(focused).toMatchObject([{ applicationPID: 900, windowId: "window-seven", terminalId: "outer-client" }]);
  expect(f.client.binding?.state).toBe("released");
  expect(f.requests.filter(({ method }) => !["client.target", "client.list", "client.get"].includes(method))
    .map(({ method }) => method)).toEqual(["client.bind_begin", "client.focus_exclusive", "client.bind_end"]);
});

it("rejects contradictory native conversation identity rather than routing by pane name", async () => {
  const f = await fixture();
  f.target.session = { source: "integration", agent: "claude", kind: "id",
    value: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" };
  expect(await f.herdr.resolve(42, sessionId, "/fixture/Codes")).toBeUndefined();
  expect(f.requests.every(({ method }) => method === "client.target")).toBe(true);
});

it.each([
  ...["w1:p7", "w1:pA", "w1:pB", "w1:pC", "wA:p0", "w0:p11", "w11:pZ"]
    .map(paneId => ({ paneId, allowed: true })),
  ...["w1:pI", "wI:pC", "w1:pC:extra", "w1:pc", "w1:p", "w1/pC"]
    .map(paneId => ({ paneId, allowed: false })),
])("binds live discovery for $paneId to current process instances and Claude per-PID metadata (allowed: $allowed)", async ({ paneId, allowed }) => {
  const f = await fixture();
  f.context.paneId = paneId;
  f.target.pane_id = paneId;
  const processTable = [
    "42 20 Tue Oct 20 03:00:00 2026 /usr/local/bin/claude",
    "20 10 Tue Oct 20 03:00:00 2026 /bin/zsh",
    "10 1 Tue Oct 20 03:00:00 2026 /Users/me/.local/bin/herdr",
  ].join("\n");
  const system = {
    run: async (_executable: string, args: readonly string[]) => ({ status: "success" as const, exitCode: 0, stderr: "",
      stdout: args.includes("pid=,ppid=,lstart=,comm=") ? processTable
        : `claude TERM_PROGRAM=herdr HERDR_PANE_ID=${paneId} HERDR_SOCKET_PATH=${f.context.socketPath}` }),
    readClaudeMetadata: async () => JSON.stringify({ pid: 42, sessionId, cwd: "/fixture/Codes",
      kind: "interactive", procStart: "Tue Oct 20 03:00:00 2026" }),
  };
  const live = new HerdrClient(undefined, 400, system);
  const resolved = await live.resolve(42, sessionId, "/fixture/Codes");
  if (!allowed) {
    expect(resolved).toBeUndefined();
    expect(f.requests).toEqual([]);
    return;
  }
  expect(resolved).toMatchObject({
    pid: 42, serverPID: 10, processStartToken: f.context.processStartToken, target: f.target,
  });
});

it.each([
  "w1:pI", "w1:pL", "w1:pO", "w1:pU", "wI:pC", "w1:pc", "w1:p", "w:pC",
  "w1/pC", "w1:pC:extra", " w1:pC", "w1:pC\n", `w1:p${"A".repeat(128)}`,
])("rejects malformed Herdr pane references %j before contacting the server", async (paneId) => {
  const f = await fixture();
  f.context.paneId = paneId;
  f.target.pane_id = paneId;
  expect(await f.herdr.resolve(42, sessionId, "/fixture/Codes")).toBeUndefined();
  expect(f.requests).toEqual([]);
});

it.each([
  { label: "one current server", owners: "p10\nf4\n", allowed: true },
  { label: "multiple owners", owners: "p10\np20\n", allowed: false },
  { label: "non-Herdr owner", owners: "p20\n", allowed: false },
  { label: "missing process", owners: "p99\n", allowed: false },
  { label: "no owner", owners: "", allowed: false },
])("rediscovers a preserved Claude pane after handoff reparents its shell ($label)", async ({ owners, allowed }) => {
  const f = await fixture();
  const processTable = [
    "42 20 Tue Oct 20 03:00:00 2026 /usr/local/bin/claude",
    "20 1 Tue Oct 20 03:00:00 2026 /bin/zsh",
    "10 1 Tue Oct 20 03:00:00 2026 /Users/me/.local/bin/herdr",
  ].join("\n");
  const system = {
    run: async (executable: string, args: readonly string[]) => ({ status: "success" as const, exitCode: 0, stderr: "",
      stdout: args.includes("pid=,ppid=,lstart=,comm=") ? processTable
        : executable.endsWith("/lsof") ? owners
        : `claude HERDR_PANE_ID=w1:p7 HERDR_SOCKET_PATH=${f.context.socketPath}` }),
    readClaudeMetadata: async () => JSON.stringify({ pid: 42, sessionId, cwd: "/fixture/Codes",
      kind: "interactive", procStart: "Tue Oct 20 03:00:00 2026" }),
  };
  const resolved = await new HerdrClient(undefined, 400, system).resolve(42, sessionId, "/fixture/Codes");
  if (allowed) expect(resolved).toMatchObject({ serverPID: 10, target: f.target, client: f.client.client });
  else {
    expect(resolved).toBeUndefined();
    expect(f.requests).toEqual([]);
  }
});

it.each([
  { fail: false, reparented: false, paneId: "w1:p7", title: "codes-6e" },
  { fail: true, reparented: false, paneId: "w1:p7", title: "codes-6e" },
  { fail: false, reparented: true, paneId: "w1:p7", title: "codes-6e" },
  { fail: true, reparented: true, paneId: "w1:p7", title: "codes-6e" },
  { fail: false, reparented: false, paneId: "w1:pC", title: "ccx-deployment-improvement" },
  { fail: true, reparented: true, paneId: "w1:pC", title: "ccx-deployment-improvement" },
  { fail: false, reparented: false, paneId: "w1:pC", title: "ccx-deployment-improvement", paseoStatus: "idle" },
  { fail: false, reparented: false, paneId: "w1:p7", title: "ccx-thinking-block-sneha", lineage: true },
  { fail: true, reparented: false, paneId: "w1:p7", title: "ccx-thinking-block-sneha", lineage: true },
])("opens the $title pill in $paneId and acknowledges only successful navigation (native failure: $fail, reparented: $reparented, Paseo: $paseoStatus, lineage: $lineage)", async ({ fail, reparented, paneId, title, paseoStatus, lineage }) => {
  const f = await fixture();
  f.context.paneId = paneId;
  f.target.pane_id = paneId;
  const home = "/fixture";
  const records = JSON.stringify({ type: "assistant", timestamp: "2026-10-20T02:59:00Z",
    message: { role: "assistant", stop_reason: "end_turn", content: [{ type: "text", text: "Done" }] } }) + "\n";
  const environment = {
    home, observedWindowMs: 42 * 60 * 60 * 1000, now: () => now,
    processes: async () => [
      { pid: 42, parentPID: reparented ? 1 : 10, tty: "ttys023", command: "/usr/local/bin/claude", arguments: "claude" },
      { pid: 10, parentPID: 1, command: "/Users/me/.local/bin/herdr", arguments: "herdr server" },
    ],
    cwd: async () => "/fixture/Codes", processStartedAt: async () => now,
    directory: async (value: string) => value.endsWith("/.claude/sessions") ? ["42.json"] : [],
    isDirectory: async () => true,
    stamp: async () => ({ modifiedAt: now, size: 512 }),
    read: async (value: string) => value.endsWith("/sessions/42.json") ? JSON.stringify({
      pid: 42, sessionId, cwd: "/fixture/Codes", kind: "interactive", status: "idle", name: title,
    }) : lineage && value.endsWith("/jobs/9dd37798/state.json") ? JSON.stringify({
      state: "stopped", sessionId: "9dd37798-3563-4b95-9cd6-6ea3400e780f",
      resumeSessionId: sessionId, interactiveLineage: true, cwd: "/fixture/Codes",
    }) : undefined,
    ...(lineage ? { claudeAgentInventory: async () => ({ kind: "success" as const, root: "/fixture/.claude",
      startedAt: now.valueOf(), completedAt: now.valueOf(), freshness: "fresh" as const, authoritative: true,
      rows: [{ id: "9dd37798", sessionId: "9dd37798-3563-4b95-9cd6-6ea3400e780f",
        kind: "background", state: "stopped", name: title, cwd: "/fixture/Codes", startedAt: now.valueOf() }],
    }) } : {}),
    readHeadTail: async () => ({ head: records, tail: records }),
    scanLinePrefixes: async () => 0, sqlite: async () => [],
    herdrSurface: f.herdr.resolve.bind(f.herdr),
  };
  const helper = new FakeNativeHelper();
  const focused: string[] = [];
  Object.assign(helper, { ghosttyBindingStatus: async () => true,
    resolveGhosttyBinding: async (nonce: string) => ({ applicationPID: 900, processStartToken: processInstanceToken(900, now)!,
      windowId: "window-seven", tabId: "tab-client", terminalId: "outer-client", nonce }),
    focusGhosttyBinding: async (binding: { terminalId: string }) => {
      if (fail) throw new Error("Fixture native focus failed"); focused.push(binding.terminalId);
    } });
  const paseo = new PaseoProvider({ read: async () => ({ serverId: "srv_local",
    providers: { "claude-copilot": "claude" }, agents: paseoStatus ? [{
      id: "28a801ab-3b50-46ca-829c-783c202b79c4", provider: "claude-copilot", title: "Old Paseo copy",
      cwd: "/fixture/Codes", status: paseoStatus, updatedAt: now.toISOString(),
      requiresAttention: false, pendingPermissions: [], persistence: { sessionId },
    }] : [],
  }) });
  const repository = new SessionRepository([paseo, new ClaudeProvider(environment)], { now: () => now });
  repository.setControls(new NativeSessionControls(helper, undefined, undefined, undefined, undefined,
    undefined, undefined, undefined, undefined, (target, isCurrent) => f.herdr.focus(target, helper, isCurrent)));
  await repository.refresh();
  expect(repository.current().sessions).toMatchObject([{ id: sessionId, owner: "Herdr", canOpenOwner: true, completionUnseen: true }]);
  expect(menuPresentation(repository.current(), [], now.valueOf()).pills).toMatchObject([{ id: sessionId, title }]);
  if (lineage) expect(alfredResults(repository.current(), title).items.map(item => item.uid)).toEqual([sessionId]);
  const effects: unknown[] = [];
  await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId }, repository, effect => effects.push(effect));
  expect(focused).toEqual(fail ? [] : ["outer-client"]);
  if (fail) {
    expect(effects).toMatchObject([{ type: "native_effect", action: "session_focus_failed" }]);
    expect(repository.current().sessions[0]?.completionUnseen).toBe(true);
  } else {
    expect(effects).toEqual([]);
    expect(f.client.pane_id).toBe(paneId);
    expect(f.client.terminal_id).toBe("terminal-seven");
    expect(repository.current().sessions[0]?.completionUnseen).toBeUndefined();
  }
  expect(f.client.binding?.state).toBe("released");
  expect(helper.terminalFocusRequests).toEqual([]);
  expect(helper.claudeAttachRequests).toEqual([]);
});


it("recovers exact Herdr navigation from a process-bound observer when the host omits its Codex session", async () => {
  const f = await fixture();
  Object.assign(f.context, { provider: "codex", codexHome: "/fixture/.codex" });
  let observation = { version: 1 as const, sessionId, pid: 42, tty: "ttys023", cwd: "/fixture/Agent Room",
    home: "/fixture/.codex", processStartToken: f.context.processStartToken, observedAt: now.toISOString(), ended: false };
  const system = { readCodexObservation: async () => observation } as unknown as HerdrSystem;
  const herdr = new HerdrClient(async () => structuredClone(f.context), 400, system);
  const route = await herdr.resolveCodex(42, "/fixture/Codes", "/fixture/.codex");
  expect(route).toMatchObject({ sessionId, pid: 42, paneId: "w1:p7" });
  const host = { ...nativeHost(), prepareGhosttyBinding: async () => {} };
  await herdr.prepare(route!, host);
  await herdr.focus(route!, host);
  expect(host.focused).toHaveLength(1);
  observation = { ...observation, sessionId: "22222222-2222-4222-8222-222222222222" };
  const before = f.requests.filter(request => request.method === "client.focus_exclusive").length;
  await expect(herdr.focus(route!, host)).rejects.toThrow();
  expect(f.requests.filter(request => request.method === "client.focus_exclusive")).toHaveLength(before);
});


it.each(["missing", "wrong-start", "ended", "wrong-home", "future", "pre-launch", "native-start-mismatch"])("refuses an unsafe observer route when Herdr has no native session (%s)", async change => {
  const f = await fixture();
  Object.assign(f.context, { provider: "codex", codexHome: "/fixture/.codex" });
  const observation = { version: 1 as const, sessionId, pid: 42, tty: "ttys023", cwd: "/fixture/Agent Room",
    home: "/fixture/.codex", processStartToken: f.context.processStartToken, observedAt: now.toISOString(), ended: false };
  if (change === "wrong-start") observation.processStartToken = processInstanceToken(42, new Date(now.valueOf() - 1000))!;
  if (change === "ended") observation.ended = true;
  if (change === "wrong-home") observation.home = "/fixture/copilot";
  if (change === "future") observation.observedAt = "2100-01-01T00:00:00Z";
  if (change === "pre-launch") observation.observedAt = new Date(now.valueOf() - 1000).toISOString();
  if (change === "native-start-mismatch") f.target.process.start += 1_000_000;
  const herdr = new HerdrClient(async () => structuredClone(f.context), 400,
    { readCodexObservation: async () => change === "missing" ? undefined : observation } as unknown as HerdrSystem);
  expect(await herdr.resolveCodex(42, "/fixture/Codes", "/fixture/.codex")).toBeUndefined();
  expect(f.requests.some(request => request.method.startsWith("client.bind") || request.method === "client.focus_exclusive")).toBe(false);
});

it("never replaces a conflicting host identity with an observer identity", async () => {
  const f = await fixture();
  Object.assign(f.context, { provider: "codex", codexHome: "/fixture/.codex" });
  f.target.session = { agent: "claude", kind: "id", value: sessionId };
  const herdr = new HerdrClient(async () => structuredClone(f.context), 400,
    { readCodexObservation: async () => ({ sessionId, pid: 42, home: "/fixture/.codex",
      processStartToken: f.context.processStartToken, observedAt: now.toISOString(), ended: false }) } as unknown as HerdrSystem);
  expect(await herdr.resolveCodex(42, "/fixture/Codes", "/fixture/.codex")).toBeUndefined();
});


it("rejects a missing Herdr session field even when an observer record exists", async () => {
  const f = await fixture();
  Object.assign(f.context, { provider: "codex", codexHome: "/fixture/.codex" });
  f.target.session = undefined;
  const observation = { version: 1 as const, sessionId, pid: 42, tty: "ttys023", cwd: "/fixture/Codes",
    home: "/fixture/.codex", processStartToken: f.context.processStartToken, observedAt: now.toISOString(), ended: false };
  const herdr = new HerdrClient(async () => structuredClone(f.context), 400,
    { readCodexObservation: async () => observation } as unknown as HerdrSystem);
  expect(await herdr.resolveCodex(42, "/fixture/Codes", "/fixture/.codex")).toBeUndefined();
});

it.each(["switched", "ambiguous", "disconnected", "unavailable"])("rejects prepared CLI focus when its detached client is %s", async change => {
  const f = await fixture(); Object.assign(f.context, { provider: "codex", codexHome: "/fixture/.codex" });
  const binding = { sessionIds: [sessionId], origin: "http://127.0.0.1:60119", socketPath: "/fixture/codex.sock", socketIdentity: "fixture" };
  let unavailable = false;
  const herdr = new HerdrClient(async () => structuredClone(f.context), 400,
    { readCodexTuiBinding: async () => unavailable ? undefined : structuredClone(binding),
      readCodexObservation: async () => ({ version: 1, sessionId, pid: 42, tty: "ttys023", cwd: f.context.cwd,
        home: f.context.codexHome, processStartToken: f.context.processStartToken, observedAt: now.toISOString(), ended: false }),
    } as unknown as HerdrSystem);
  const target = (await herdr.resolveCodex(42, "/fixture/Codes", "/fixture/.codex"))!;
  const native = { ...nativeHost(), prepareGhosttyBinding: async () => {} };
  await herdr.prepare(target, native);
  unavailable = change === "unavailable";
  binding.sessionIds = change === "switched" ? ["11111111-1111-4111-8111-111111111111"]
    : change === "ambiguous" ? [sessionId, "11111111-1111-4111-8111-111111111111"] : [];
  const before = f.requests.length;
  await expect(herdr.focus(target, native)).rejects.toThrow("Exact Herdr navigation is unavailable");
  expect(native.focused).toEqual([]);
  expect(f.requests.slice(before).some(request => request.method === "client.focus_exclusive")).toBe(false);
});
