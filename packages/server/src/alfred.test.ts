import { execFile } from "node:child_process";
import { chmod, lstat, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { SessionSnapshot, SessionSummary } from "@agent-visor/protocol";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { alfredResults, startAlfredSocket } from "./alfred.js";

const execute = promisify(execFile);
const workflowRoot = fileURLToPath(new URL("../../../integrations/alfred/", import.meta.url));
let root: string;
let running: Awaited<ReturnType<typeof startAlfredSocket>> | undefined;

beforeEach(async () => { root = await mkdtemp(path.join(os.tmpdir(), "av-alfred-")); });
afterEach(async () => { await running?.close(); running = undefined; await rm(root, { recursive: true, force: true }); });

function session(overrides: Partial<SessionSummary> = {}): SessionSummary {
  return {
    id: "cursor:one", title: "Fix the session browser", subtitle: "Private transcript preview",
    project: "agent-visor", cwd: "/Users/test/agent-visor", source: "Cursor", owner: "Cursor",
    section: "working", updatedAt: "2026-09-07T20:00:00.000Z", canOpenOwner: true,
    canEnterChat: true, ...overrides,
  };
}

function snapshot(sessions = [session()]): SessionSnapshot {
  return { type: "session_snapshot", revision: 1, sessions };
}

async function request(socketPath: string, value: unknown, split = false): Promise<any> {
  return await new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    const chunks: Buffer[] = [];
    socket.once("error", reject);
    socket.setTimeout(3_000, () => { socket.destroy(); reject(new Error("Socket test timed out")); });
    socket.on("data", (chunk) => chunks.push(chunk));
    socket.once("end", () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); } catch (error) { reject(error); }
    });
    socket.once("connect", () => {
      const encoded = JSON.stringify(value) + "\n";
      if (split) {
        socket.write(encoded.slice(0, 7));
        setImmediate(() => socket.write(encoded.slice(7)));
      } else socket.write(encoded);
    });
  });
}

describe("Alfred session search", () => {
  it("finds words across title, source, project and path without searching transcript previews", () => {
    expect(alfredResults(snapshot(), "CURSOR visor browser").items[0]?.arg).toBe("cursor:one");
    expect(alfredResults(snapshot(), "Users/test").items[0]?.arg).toBe("cursor:one");
    expect(alfredResults(snapshot(), "Private transcript").items[0]?.valid).toBe(false);
    expect(JSON.stringify(alfredResults(snapshot(), ""))).not.toContain("Private transcript preview");
  });

  it("ranks title matches before metadata matches, then preserves attention and recency", () => {
    const sessions = [
      session({ id: "metadata", title: "Something else", project: "browser", section: "needs_you" }),
      session({ id: "older", section: "ready", updatedAt: "2026-09-06T20:00:00.000Z" }),
      session({ id: "working" }),
      session({ id: "seen", section: "ready", attentionTier: "acknowledged_ready" }),
      session({ id: "newer", section: "ready" }),
    ];
    expect(alfredResults(snapshot(sessions), "browser").items.map((item) => item.arg))
      .toEqual(["newer", "older", "working", "seen", "metadata"]);
  });

  it("preserves exact IDs for duplicate and Unicode titles and disables missing owners", () => {
    const results = alfredResults(snapshot([
      session({ id: "cursor:first", title: "修复 🪟" }),
      session({ id: "cursor:second", title: "修复 🪟", canOpenOwner: false }),
    ]), "修复");
    expect(results.items.map((item) => [item.arg, item.valid]))
      .toEqual([["cursor:first", true], ["cursor:second", false]]);
  });

  it("bounds result count and visible metadata and distinguishes empty from unmatched lists", () => {
    const results = alfredResults(snapshot(Array.from({ length: 110 }, (_, index) => session({
      id: String(index), title: "x".repeat(5_000), cwd: "p".repeat(10_000),
    }))), "");
    expect(results.items).toHaveLength(101);
    expect(results.items[0]?.title.length).toBe(512);
    expect(results.items[0]?.subtitle.length).toBe(2_048);
    expect(results.items[100]?.title).toBe("10 more matching sessions");
    expect(alfredResults(snapshot([]), "").items[0]?.title).toBe("No agent sessions yet");
    expect(alfredResults(snapshot(), "missing").items[0]?.title).toBe("No matching agent sessions");
  });
});

describe("private Alfred socket and packaged client", () => {
  it("rejects overlong macOS socket paths before Node can silently truncate them", async () => {
    await expect(startAlfredSocket({ socketPath: path.join(root, "x".repeat(104), "s.sock"),
      source: { current: () => snapshot(), focusSession: async () => undefined },
    })).rejects.toThrow("too long");
  });

  it("searches fragmented requests without navigation, then routes the exact selected ID", async () => {
    const focusSession = vi.fn(async () => undefined);
    const socketPath = path.join(root, "alfred", "s.sock");
    running = await startAlfredSocket({ socketPath, source: { current: () => snapshot(), focusSession } });
    expect((await lstat(path.dirname(socketPath))).mode & 0o777).toBe(0o700);
    expect((await lstat(socketPath)).mode & 0o777).toBe(0o600);
    expect((await request(socketPath, { action: "search", query: "visor" }, true)).items[0].arg).toBe("cursor:one");
    expect(focusSession).not.toHaveBeenCalled();
    expect(await request(socketPath, { action: "focus", sessionId: "cursor:one" })).toEqual({ ok: true });
    expect(focusSession).toHaveBeenCalledExactlyOnceWith("cursor:one");
  });

  it("rejects stale or unavailable owners, extra arguments and unsupported actions", async () => {
    let current = snapshot();
    const focusSession = vi.fn(async () => undefined);
    const socketPath = path.join(root, "alfred", "s.sock");
    running = await startAlfredSocket({ socketPath, source: { current: () => current, focusSession } });
    current = snapshot([session({ canOpenOwner: false })]);
    for (const value of [
      { action: "focus", sessionId: "missing" }, { action: "focus", sessionId: "cursor:one" },
      { action: "search", query: "", token: "extra" }, { action: "delete", sessionId: "cursor:one" },
      { action: "search", query: "x".repeat(257) },
    ]) expect((await request(socketPath, value)).error).toBeTruthy();
    expect(focusSession).not.toHaveBeenCalled();
  });

  it("keeps a running socket intact when another instance tries to start", async () => {
    const socketPath = path.join(root, "alfred", "s.sock");
    const options = { socketPath, source: { current: () => snapshot(), focusSession: async () => undefined } };
    running = await startAlfredSocket(options);
    await expect(startAlfredSocket(options)).rejects.toThrow("already active");
    expect((await request(socketPath, { action: "search", query: "" })).items[0].valid).toBe(true);
  });

  it("refuses to replace regular files or use a shared directory", async () => {
    const socketPath = path.join(root, "alfred", "s.sock");
    await mkdir(path.dirname(socketPath), { mode: 0o700 });
    await writeFile(socketPath, "keep this");
    const options = { socketPath, source: { current: () => snapshot(), focusSession: async () => undefined } };
    await expect(startAlfredSocket(options)).rejects.toThrow("unsafe");
    expect(await readFile(socketPath, "utf8")).toBe("keep this");
    await chmod(path.dirname(socketPath), 0o755);
    await expect(startAlfredSocket(options)).rejects.toThrow("private");
  });

  it("executes the actual Python client for Unicode queries and literal shell metacharacters", async () => {
    const id = 'cursor:$(touch NEVER_CREATE);`echo nope`';
    const focusSession = vi.fn(async () => undefined);
    const socketPath = path.join(root, "alfred", "s.sock");
    running = await startAlfredSocket({ socketPath, source: {
      current: () => snapshot([session({ id, title: "修复 session" })]), focusSession,
    } });
    const run = (action: string, value: string) => execute("/usr/bin/python3", [
      path.join(workflowRoot, "agent_visor.py"), action, value,
    ], { env: { ...process.env, agent_visor_data_dir: root } });
    const search = await run("search", "修复");
    expect(JSON.parse(search.stdout).items[0].arg).toBe(id);
    expect((await run("focus", id)).stdout).toBe("");
    expect(focusSession).toHaveBeenCalledExactlyOnceWith(id);
  });

  it("surfaces real focus failures and missing app support without false success", async () => {
    const socketPath = path.join(root, "alfred", "s.sock");
    running = await startAlfredSocket({ socketPath, source: {
      current: () => snapshot(), focusSession: async () => "The terminal is no longer running.",
    } });
    const run = (action: string, dataRoot = root) => execute("/usr/bin/python3", [
      path.join(workflowRoot, "agent_visor.py"), action, "cursor:one",
    ], { env: { ...process.env, agent_visor_data_dir: dataRoot } });
    expect((await run("focus")).stdout).toContain("terminal is no longer running");
    const missing = JSON.parse((await run("search", path.join(root, "missing"))).stdout);
    expect(missing.items[0]).toMatchObject({ valid: false, title: "Agent Visor session search unavailable" });
  });

  it("builds an importable archive with argv-based scripts and no bundled user data", async () => {
    const output = path.join(root, "Agent-Visor-Sessions.alfredworkflow");
    await execute("/usr/bin/python3", [path.join(workflowRoot, "build_workflow.py"), output]);
    const checked = await execute("/usr/bin/python3", ["-c", `
import json, plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    config=plistlib.loads(archive.read('info.plist'))
    print(json.dumps({'files': sorted(archive.namelist()), 'keyword': config['objects'][0]['config']['keyword'],
                      'args': [o['config'].get('scriptargtype') for o in config['objects'][:2]],
                      'configured': config['userconfigurationconfig'][0]['variable']}))
`, output]);
    expect(JSON.parse(checked.stdout)).toEqual({
      files: ["README.md", "agent_visor.py", "icon.png", "info.plist"], keyword: "av", args: [1, 1],
      configured: "agent_visor_data_dir",
    });
  });
});
