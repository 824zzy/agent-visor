import { createServer, type Socket } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { afterEach, expect, it } from "vitest";
import { HerdrClient, type HerdrProcessContext } from "./herdr.js";
import { processInstanceToken } from "./shared.js";
import { ClaudeProvider } from "./claude.js";
import { SessionRepository } from "../sessions.js";
import { activateMenuPill, menuPresentation } from "../menu.js";
import { NativeSessionControls } from "../session-controls.js";
import { FakeNativeHelper } from "../native-helper.js";

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
  return { context, target, client, catalog, requests, herdr: new HerdrClient(async () => structuredClone(context)) };
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

it("binds live discovery to current process instances and Claude per-PID metadata", async () => {
  const f = await fixture();
  const processTable = [
    "42 20 Tue Oct 20 03:00:00 2026 /usr/local/bin/claude",
    "20 10 Tue Oct 20 03:00:00 2026 /bin/zsh",
    "10 1 Tue Oct 20 03:00:00 2026 /Users/me/.local/bin/herdr",
  ].join("\n");
  const system = {
    run: async (_executable: string, args: readonly string[]) => ({ status: "success" as const, exitCode: 0, stderr: "",
      stdout: args.includes("pid=,ppid=,lstart=,comm=") ? processTable
        : `claude TERM_PROGRAM=herdr HERDR_PANE_ID=w1:p7 HERDR_SOCKET_PATH=${f.context.socketPath}` }),
    readClaudeMetadata: async () => JSON.stringify({ pid: 42, sessionId, cwd: "/fixture/Codes",
      kind: "interactive", procStart: "Tue Oct 20 03:00:00 2026" }),
  };
  const live = new HerdrClient(undefined, 400, system);
  expect(await live.resolve(42, sessionId, "/fixture/Codes")).toMatchObject({
    pid: 42, serverPID: 10, processStartToken: f.context.processStartToken, target: f.target,
  });
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
  { fail: false, reparented: false }, { fail: true, reparented: false },
  { fail: false, reparented: true }, { fail: true, reparented: true },
])("opens the codes-6e pill and acknowledges only successful navigation (native failure: $fail, reparented: $reparented)", async ({ fail, reparented }) => {
  const f = await fixture();
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
      pid: 42, sessionId, cwd: "/fixture/Codes", kind: "interactive", status: "idle", name: "codes-6e",
    }) : undefined,
    readHeadTail: async () => ({ head: records, tail: records }),
    scanLinePrefixes: async () => 0, sqlite: async () => [],
    herdrSurface: f.herdr.resolve.bind(f.herdr),
  };
  const helper = new FakeNativeHelper();
  const focused: string[] = [];
  Object.assign(helper, { ghosttyBindingStatus: async () => true,
    resolveGhosttyBinding: async (nonce: string) => ({ applicationPID: 900, processStartToken: processInstanceToken(900, now)!,
      windowId: "window-seven", tabId: "tab-client", terminalId: "outer-client", nonce }),
    focusGhosttyBinding: async () => { if (fail) throw new Error("Fixture native focus failed"); focused.push("outer-client"); } });
  const repository = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
  repository.setControls(new NativeSessionControls(helper, undefined, undefined, undefined, undefined,
    undefined, undefined, undefined, undefined, (target, isCurrent) => f.herdr.focus(target, helper, isCurrent)));
  await repository.refresh();
  expect(repository.current().sessions).toMatchObject([{ id: sessionId, owner: "Herdr", canOpenOwner: true, completionUnseen: true }]);
  expect(menuPresentation(repository.current(), [], now.valueOf()).pills).toMatchObject([{ id: sessionId, title: "codes-6e" }]);
  const effects: unknown[] = [];
  await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId }, repository, effect => effects.push(effect));
  expect(focused).toEqual(fail ? [] : ["outer-client"]);
  if (fail) {
    expect(effects).toMatchObject([{ type: "native_effect", action: "session_focus_failed" }]);
    expect(repository.current().sessions[0]?.completionUnseen).toBe(true);
  } else {
    expect(effects).toEqual([]);
    expect(repository.current().sessions[0]?.completionUnseen).toBeUndefined();
  }
  expect(f.client.binding?.state).toBe("released");
  expect(helper.terminalFocusRequests).toEqual([]);
  expect(helper.claudeAttachRequests).toEqual([]);
});
