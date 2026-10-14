import path from "node:path";
import os from "node:os";
import { createServer, type Socket } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { afterEach, describe, expect, it } from "vitest";
import { ClaudeProvider } from "./claude.js";
import type { ProviderEnvironment, ProcessRecord } from "./environment.js";
import { SessionRepository } from "../sessions.js";
import { activateMenuPill, menuPresentation } from "../menu.js";
import { CmuxClient, type CmuxProcessContext } from "./cmux.js";
import { processInstanceToken } from "./shared.js";
import { NativeSessionControls } from "../session-controls.js";
import { FakeNativeHelper } from "../native-helper.js";

const home = "/Users/cmux-fixture";
const cwd = home + "/Codes";
const sessionID = "5118cfe0-3f5b-418e-8bf1-5260f6747f39";
const now = new Date("2026-10-14T06:00:00Z");
const workspaceId = "c3bf5c17-9b31-4384-810c-0fa5509cc500";
const surfaceId = "28f17344-f0e3-4a45-ba74-e2ed0f6480ac";
const windowId = "083c6191-d777-49c4-9648-579651345dad";
const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close(); });

async function socketFixture(options: {
  onIdentify?: (context: CmuxProcessContext, count: number) => void;
  invalid?: "missing" | "different_surface" | "browser" | "denied" | "wrong_request" | "oversized" | "timeout";
  wrongFocus?: boolean;
  settlingReads?: number;
} = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "av-cmux-"));
  const socketPath = path.join(root, "cmux.sock");
  const context: CmuxProcessContext = { pid: 100, processStartToken: processInstanceToken(100, now)!,
    applicationPID: 7, applicationProcessStartToken: processInstanceToken(7, now)!,
    sessionId: sessionID, cwd, socketPath, workspaceId, surfaceId };
  const requests: Array<{ method: string; params: Record<string, unknown> }> = [];
  const caller = { window_id: windowId, workspace_id: workspaceId, surface_id: surfaceId, surface_type: "terminal" };
  let focused: unknown = null;
  let reads = 0;
  let focusReads = 0;
  const peers = new Set<Socket>();
  const server = createServer(socket => {
    peers.add(socket); socket.on("close", () => peers.delete(socket));
    let input = "";
    socket.setEncoding("utf8"); socket.on("data", chunk => {
      input += chunk;
      while (input.includes("\n")) {
        const end = input.indexOf("\n"); const request = JSON.parse(input.slice(0, end)); input = input.slice(end + 1);
        requests.push({ method: request.method, params: request.params });
        if (request.method === "system.identify") options.onIdentify?.(context, ++reads);
        if (request.method === "surface.focus") focused = options.wrongFocus ? { ...caller, surface_id: windowId } : caller;
        const reportedCaller = options.invalid === "missing" ? null
          : options.invalid === "different_surface" ? { ...caller, surface_id: windowId }
          : options.invalid === "browser" ? { ...caller, surface_type: "browser" } : caller;
        const reportedFocus = request.method === "system.identify" && focused && ++focusReads <= (options.settlingReads ?? 0)
          ? { ...caller, surface_id: windowId } : focused;
        const result = request.method === "system.identify"
          ? { socket_path: socketPath, bundle_identifier: "com.cmuxterm.app", caller: reportedCaller, focused: reportedFocus }
          : caller;
        if (options.invalid === "timeout") continue;
        socket.write(options.invalid === "denied" ? "ERROR: Access denied\n"
          : options.invalid === "oversized" ? "x".repeat(65_537) + "\n"
          : JSON.stringify({ id: options.invalid === "wrong_request" ? "another-request" : request.id, ok: true, result }) + "\n");
      }
    });
  });
  await new Promise<void>(resolve => server.listen(socketPath, resolve));
  cleanup.push(async () => {
    for (const socket of peers) socket.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  return { context, requests, caller, socketPath, client: new CmuxClient(async () => structuredClone(context), 100) };
}

class CmuxEnvironment implements ProviderEnvironment {
  readonly home = home;
  readonly observedWindowMs = 42 * 60 * 60 * 1_000;
  metadata = { pid: 100, sessionId: sessionID, cwd, kind: "interactive", status: "idle",
    name: "ccx-thinking-block-sneha", procStart: now.toISOString() };
  processRows: ProcessRecord[] = [
    { pid: 7, parentPID: 1, command: "/Applications/cmux.app/Contents/MacOS/cmux", arguments: "cmux" },
    { pid: 50, parentPID: 7, command: "/bin/zsh", arguments: "zsh", tty: "ttys002" },
    { pid: 100, parentPID: 50, command: home + "/.local/bin/claude", arguments: "claude", tty: "ttys002" },
  ];
  now() { return now; }
  async processes() { return this.processRows; }
  async processesFresh() { return this.processRows; }
  async cwd() { return cwd; }
  async processStartedAt() { return now; }
  async directory(value: string) { return value === path.join(home, ".claude/sessions") ? ["100.json"] : []; }
  async isDirectory() { return true; }
  async stamp(value: string) {
    return value.endsWith("/sessions/100.json") ? { modifiedAt: now, size: 512 } : undefined;
  }
  async read(value: string) { return value.endsWith("/sessions/100.json") ? JSON.stringify(this.metadata) : undefined; }
  async readHeadTail() { return undefined; }
  async scanLinePrefixes(_file: string, _bytes: number, _visit: (line: string) => void, start = 0) { return start; }
  async sqlite() { return []; }
  cmuxSurface?: CmuxClient["resolve"];
}

describe("cmux Claude source integration", () => {
  it("recognizes the cmux owner without advertising an Apple Terminal input route", async () => {
    const source = new SessionRepository([new ClaudeProvider(new CmuxEnvironment())], { now: () => now });
    const snapshot = await source.refresh();

    expect(snapshot.sessions).toMatchObject([{ id: sessionID, owner: "cmux",
      sessionState: { turn: "ready", route: "unavailable" } }]);
    expect(menuPresentation(snapshot, [], now.valueOf()).pills).toMatchObject([{ id: sessionID, phase: "ready" }]);
  });

  it("gives the parent pill an exact cmux surface focus without terminal input or attachment", async () => {
    const { client, requests } = await socketFixture();
    const environment = new CmuxEnvironment();
    environment.cmuxSurface = client.resolve.bind(client);
    const helper = new FakeNativeHelper();
    // The helper is an OS boundary. The real cmux client uses a local socket fixture.
    const controls = new NativeSessionControls(helper, undefined, undefined, undefined, undefined, undefined,
      undefined, undefined, client.focus.bind(client));
    const source = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    source.setControls(controls);
    const snapshot = await source.refresh();
    expect(snapshot.sessions).toMatchObject([{ id: sessionID, owner: "cmux", canOpenOwner: true }]);
    expect(menuPresentation(snapshot, [], now.valueOf()).pills).toMatchObject([{ id: sessionID, phase: "ready" }]);
    const effects: unknown[] = [];
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: sessionID }, source,
      effect => effects.push(effect));
    expect(effects).toEqual([]);
    expect(requests.filter(r => r.method !== "system.identify")).toEqual([
      { method: "surface.focus", params: { window_id: windowId, workspace_id: workspaceId, surface_id: surfaceId } },
    ]);
    expect(helper.terminalFocusRequests).toEqual([]);
    expect(helper.terminalSendRequests).toEqual([]);
    expect(helper.claudeAttachRequests).toEqual([]);
  });

  it("accepts exact focus after cmux's workspace selection settles without repeating the focus request", async () => {
    const { client, requests } = await socketFixture({ settlingReads: 2 });
    const environment = new CmuxEnvironment(); environment.cmuxSurface = client.resolve.bind(client);
    const helper = new FakeNativeHelper();
    const source = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    source.setControls(new NativeSessionControls(helper, undefined, undefined, undefined,
      undefined, undefined, undefined, undefined, client.focus.bind(client)));
    expect(menuPresentation(await source.refresh(), [], now.valueOf()).pills)
      .toMatchObject([{ id: sessionID, phase: "ready", owner: "cmux" }]);

    const effects: unknown[] = [];
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: sessionID }, source,
      effect => effects.push(effect));
    expect(effects).toEqual([]);
    expect(requests.filter(r => r.method === "surface.focus")).toEqual([
      { method: "surface.focus", params: { window_id: windowId, workspace_id: workspaceId, surface_id: surfaceId } },
    ]);
    expect(helper.terminalFocusRequests).toEqual([]);
    expect(helper.terminalSendRequests).toEqual([]);
    expect(helper.claudeAttachRequests).toEqual([]);
  });

  it("binds UTC Claude process metadata to the same live process before resolving its surface", async () => {
    const { socketPath } = await socketFixture();
    const environment = new CmuxEnvironment();
    const client = new CmuxClient(undefined, 750, {
      run: async (_program, args) => ({ status: "success", stderr: "", exitCode: 0,
        stdout: args.includes("command=")
          ? `claude CMUX_SOCKET_PATH=${socketPath} CMUX_WORKSPACE_ID=${workspaceId} CMUX_SURFACE_ID=${surfaceId} PRIVATE_TOKEN=never-print-me`
          : "7 1 Wed Oct 14 06:00:00 2026 /Applications/cmux.app/Contents/MacOS/cmux\n50 7 Wed Oct 14 06:00:00 2026 /bin/zsh\n100 50 Wed Oct 14 06:00:00 2026 /Users/cmux-fixture/.local/bin/claude" }),
      readMetadata: async () => JSON.stringify({ ...environment.metadata, procStart: "Wed Oct 14 06:00:00 2026" }),
    });
    environment.cmuxSurface = client.resolve.bind(client);
    const source = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    expect((await source.refresh()).sessions).toMatchObject([{ id: sessionID, owner: "cmux", canOpenOwner: true }]);
  });

  it("does not focus after the same Claude process switches conversation during the last identity read", async () => {
    const { client, requests } = await socketFixture({ onIdentify(context, count) {
      if (count === 3) context.sessionId = "b6a00a15-70ff-4955-99b8-0cbd5db48ae4";
    } });
    const environment = new CmuxEnvironment();
    environment.cmuxSurface = client.resolve.bind(client);
    const source = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    source.setControls(new NativeSessionControls(new FakeNativeHelper(), undefined, undefined, undefined,
      undefined, undefined, undefined, undefined, client.focus.bind(client)));
    await source.refresh();

    expect(await source.focusSession(sessionID)).toContain("changed");
    expect(requests.filter(r => r.method === "surface.focus")).toEqual([]);
  });

  it.each(["missing", "different_surface", "browser", "denied", "wrong_request", "oversized", "timeout"] as const)(
    "does not advertise a guessed focus route for a %s cmux response", async invalid => {
      const { client, requests } = await socketFixture({ invalid });
      const environment = new CmuxEnvironment(); environment.cmuxSurface = client.resolve.bind(client);
      const helper = new FakeNativeHelper();
      const source = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
      source.setControls(new NativeSessionControls(helper, undefined, undefined, undefined,
        undefined, undefined, undefined, undefined, client.focus.bind(client)));
      expect((await source.refresh()).sessions).toMatchObject([{ owner: "cmux", canOpenOwner: false }]);
      expect(await source.focusSession(sessionID)).toContain("unavailable");
      expect(requests.filter(r => r.method === "surface.focus")).toEqual([]);
      expect(helper.terminalFocusRequests).toEqual([]);
      expect(helper.claudeAttachRequests).toEqual([]);
    },
  );

  it("does not report success when cmux focuses a different surface", async () => {
    const { client } = await socketFixture({ wrongFocus: true });
    const environment = new CmuxEnvironment(); environment.cmuxSurface = client.resolve.bind(client);
    const source = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    source.setControls(new NativeSessionControls(new FakeNativeHelper(), undefined, undefined, undefined,
      undefined, undefined, undefined, undefined, client.focus.bind(client)));
    await source.refresh();
    expect(await source.focusSession(sessionID)).toContain("could not be focused");
  });

  it("does not create a pill for a parked cmux agent overview", async () => {
    const { client, requests } = await socketFixture();
    const environment = new CmuxEnvironment(); environment.cmuxSurface = client.resolve.bind(client);
    Object.assign(environment.metadata, { parkedJobId: "9dd37798" });
    const source = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
    expect(menuPresentation(await source.refresh(), [], now.valueOf()).pills).toEqual([]);
    expect(requests).toEqual([]);
  });

  it("recovers the same exact cmux surface after an Agent Visor restart without saved title trust", async () => {
    const { client } = await socketFixture();
    const environment = new CmuxEnvironment(); environment.cmuxSurface = client.resolve.bind(client);
    for (let i = 0; i < 2; i++) {
      const source = new SessionRepository([new ClaudeProvider(environment)], { now: () => now });
      expect(menuPresentation(await source.refresh(), [], now.valueOf()).pills).toMatchObject([{ id: sessionID, owner: "cmux" }]);
    }
  });
});
