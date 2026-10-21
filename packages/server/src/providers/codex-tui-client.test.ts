import { createServer } from "node:http";
import { chmod, mkdir, mkdtemp, rm, writeFile, rename } from "node:fs/promises";
import path from "node:path";
import { WebSocketServer } from "ws";
import { afterEach, expect, it } from "vitest";
import { readCodexTuiBinding } from "./codex-tui-client.js";
import type { runProcess } from "../machine.js";

const cli = "01a15c34-b525-7c00-a316-ca593fd2a167";
const desktop = "01a062fa-8f19-75b3-87ad-8b4d41aa9e57";
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanups.splice(0).reverse()) await close(); });
async function fixture() {
  const home = await mkdtemp("/tmp/av-tui-");
  const directory = path.join(home, "app-server-control"); await mkdir(directory, { mode: 0o700 });
  const socketPath = path.join(directory, "app-server-control.sock");
  await mkdir(path.join(home, "sessions"));
  await writeFile(path.join(home, "sessions", "cli.jsonl"), "fixture");
  await writeFile(path.join(home, "sessions", "desktop.jsonl"), "fixture");
  const metadata = new Map<string, unknown>([cli, desktop].map((id, index) => [id,
    { id, parentThreadId: null, ephemeral: false, source: "vscode", path: path.join(home, "sessions", index ? "desktop.jsonl" : "cli.jsonl") }]));
  const server = createServer(); const ws = new WebSocketServer({ server });
  const methods: string[] = [];
  const state = { listening: "p42\nn127.0.0.1:60119\n", loaded: [cli, desktop], nextCursor: null as string | null,
    statuses: new Map<string, unknown[]>([[cli, [{ name: "codex_tui", httpOrigin: "http://127.0.0.1:60119", runtimeStatus: "connected" }]], [desktop, []]]) };
  ws.on("connection", peer => peer.on("message", bytes => {
    const m = JSON.parse(bytes.toString()); methods.push(m.method);
    if (m.id === undefined) return;
    const result = m.method === "initialize" ? { userAgent: "fixture" }
      : m.method === "thread/loaded/list" ? { data: state.loaded, nextCursor: state.nextCursor }
      : m.method === "thread/read" ? { thread: metadata.get(m.params.threadId) }
      : m.method === "mcpServerStatus/list" ? { data: state.statuses.get(m.params.threadId) ?? [], nextCursor: null } : {};
    peer.send(JSON.stringify({ id: m.id, result }));
  }));
  await new Promise<void>(resolve => server.listen(socketPath, resolve)); await chmod(socketPath, 0o600);
  cleanups.push(async () => { for (const peer of ws.clients) peer.terminate(); await new Promise<void>(resolve => ws.close(() => resolve()));
    await new Promise<void>(resolve => server.close(() => resolve())); await rm(home, { recursive: true, force: true }); });
  const run: typeof runProcess = async () => ({ status: "success", stdout: state.listening, stderr: "", exitCode: 0 });
  return { home, state, methods, run, metadata };
}

it("links a detached CLI thread to its listening frontend while keeping its same-name Desktop parent separate", async () => {
  const f = await fixture();
  expect(await readCodexTuiBinding(42, f.home, f.run)).toMatchObject({ sessionIds: [cli], origin: "http://127.0.0.1:60119" });
  expect(f.methods.every(method => ["initialize", "initialized", "thread/loaded/list", "thread/read", "mcpServerStatus/list"].includes(method))).toBe(true);
});

it.each(["disconnected", "missing-origin", "remote-origin", "different-port", "incomplete"])("does not grant a route from %s client metadata", async reason => {
  const f = await fixture();
  f.state.statuses.set(cli, [{ name: "codex_tui", httpOrigin: reason === "missing-origin" ? null
    : reason === "remote-origin" ? "http://example.com:60119" : reason === "different-port" ? "http://127.0.0.1:60120"
    : "http://127.0.0.1:60119", runtimeStatus: reason === "disconnected" ? "disconnected" : "connected" }]);
  if (reason === "incomplete") f.state.nextCursor = "more";
  expect(await readCodexTuiBinding(42, f.home, f.run)).toMatchObject({ sessionIds: [] });
});

it("reports all attached threads instead of selecting one by name or recency", async () => {
  const f = await fixture(); f.state.statuses.set(desktop, f.state.statuses.get(cli)!);
  expect((await readCodexTuiBinding(42, f.home, f.run))?.sessionIds).toEqual([desktop, cli].sort());
});

it("rereads client metadata after a thread switch instead of retaining an old binding", async () => {
  const f = await fixture();
  expect((await readCodexTuiBinding(42, f.home, f.run))?.sessionIds).toEqual([cli]);
  f.state.statuses.set(desktop, f.state.statuses.get(cli)!); f.state.statuses.set(cli, []);
  expect((await readCodexTuiBinding(42, f.home, f.run))?.sessionIds).toEqual([desktop]);
});

it("discards a binding when the listening process changes during the read", async () => {
  const f = await fixture(); let calls = 0;
  const run: typeof runProcess = async (...args) => { if (++calls === 2) f.state.listening = "p42\nn127.0.0.1:60120\n"; return f.run(...args); };
  expect((await readCodexTuiBinding(42, f.home, run))?.sessionIds).toEqual([]);
});

it("does not trust a socket writable by other users", async () => {
  const f = await fixture(); await chmod(path.join(f.home, "app-server-control", "app-server-control.sock"), 0o666);
  expect(await readCodexTuiBinding(42, f.home, f.run)).toBeUndefined(); expect(f.methods).toEqual([]);
});


it("ignores inherited subagent transports and unmaterialized startup drafts when identifying the CLI root", async () => {
  const f = await fixture();
  const child = "11111111-1111-4111-8111-111111111111", draft = "22222222-2222-4222-8222-222222222222";
  f.state.loaded.push(child, draft);
  f.state.statuses.set(child, f.state.statuses.get(cli)!); f.state.statuses.set(draft, f.state.statuses.get(cli)!);
  f.metadata.set(child, { id: child, parentThreadId: cli, ephemeral: false, source: { subAgent: {} }, path: path.join(f.home, "sessions/cli.jsonl") });
  f.metadata.set(draft, { id: draft, parentThreadId: null, ephemeral: false, source: "vscode", path: path.join(f.home, "sessions/not-written.jsonl") });
  expect((await readCodexTuiBinding(42, f.home, f.run))?.sessionIds).toEqual([cli]);
});


it.each(["missing-socket", "multiple-listeners", "read-failure"])("does not grant a client identity from %s", async reason => {
  const f = await fixture();
  if (reason === "missing-socket") await rename(path.join(f.home, "app-server-control/app-server-control.sock"), path.join(f.home, "off.sock"));
  if (reason === "multiple-listeners") f.state.listening += "n127.0.0.1:60120\n";
  const run: typeof runProcess = reason === "read-failure" ? async () => ({ status: "timed_out", stdout: "", stderr: "" }) : f.run;
  expect(await readCodexTuiBinding(42, f.home, run)).toBeUndefined();
});


it("does not grant an identity when no TUI listener exists", async () => {
  const f = await fixture();
  const run: typeof runProcess = async () => ({ status: "failed", exitCode: 1, stdout: "", stderr: "" });
  expect(await readCodexTuiBinding(42, f.home, run)).toBeUndefined();
  expect(f.methods).toEqual([]);
});
