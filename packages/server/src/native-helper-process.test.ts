import { EventEmitter } from "node:events";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import net, { type Socket } from "node:net";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NATIVE_HELPER_MAX_FRAME_BYTES, type SessionSnapshot } from "@agent-visor/protocol";
import { activateMenuPill } from "./menu.js";
import { NativeHelperProcess, type NativeHelperEvent } from "./native-helper.js";

const launch = vi.hoisted(() => ({ spawn: vi.fn() }));
vi.mock("node:child_process", () => ({ spawn: launch.spawn }));

type Request = { version: number; id: string; method: string; params?: unknown };
const target = { pid: 42, bundleIdentifier: "com.anthropic.claudefordesktop" };
const greeting: SessionSnapshot = {
  type: "session_snapshot", revision: 1, sessions: [{
    id: "greeting", title: "Greeting", subtitle: "Agent is working", source: "Claude Code",
    project: "Codes", owner: "Claude", cwd: "/repo", section: "working",
    updatedAt: "2026-09-09T20:00:00.000Z", canOpenOwner: true, canEnterChat: true,
  }],
};

function frame(value: unknown): Buffer {
  const body = Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4); header.writeUInt32BE(body.length);
  return Buffer.concat([header, body]);
}

function accepted(request: Request) {
  return { version: 1, id: request.id, ok: true, result: { type: "accepted" } };
}

describe("native helper framed connection", () => {
  let dataRoot: string;
  let helper: NativeHelperProcess | undefined;
  let server: net.Server;
  let peer: Socket;
  let requests: Request[];
  let respond: (request: Request) => void;

  beforeEach(async () => {
    dataRoot = await mkdtemp(path.join(os.tmpdir(), "av-helper-test-"));
    vi.stubEnv("AGENT_VISOR_DATA_DIR", dataRoot);
    requests = [];
    respond = request => peer.write(frame(accepted(request)));
    launch.spawn.mockImplementation((_executable, args: string[]) => {
      const child = Object.assign(new EventEmitter(), {
        exitCode: null as number | null, signalCode: null as string | null,
        stderr: new EventEmitter(),
        kill: vi.fn(() => { child.signalCode = "SIGTERM"; child.emit("exit"); return true; }),
      });
      server = net.createServer(socket => {
        peer = socket;
        let buffer = Buffer.alloc(0);
        socket.on("data", data => {
          buffer = Buffer.concat([buffer, data]);
          while (buffer.length >= 4 && buffer.length >= buffer.readUInt32BE(0) + 4) {
            const size = buffer.readUInt32BE(0);
            const request = JSON.parse(buffer.subarray(4, size + 4).toString()) as Request;
            buffer = buffer.subarray(size + 4);
            requests.push(request); respond(request);
          }
        });
        socket.on("error", () => undefined);
        socket.on("close", () => { child.exitCode = 0; child.emit("exit", 0); });
      });
      server.listen(args[args.indexOf("--socket") + 1]);
      return child;
    });
  });

  afterEach(async () => {
    respond = request => peer.write(frame(accepted(request)));
    await helper?.close().catch(() => undefined);
    peer?.destroy();
    if (server?.listening) await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(dataRoot, { recursive: true, force: true });
    vi.unstubAllEnvs();
  });

  it("opens a later native pill after a malformed reply, without an app-launch fallback", async () => {
    const effects: unknown[] = [];
    let activation: Promise<void> | undefined;
    helper = await NativeHelperProcess.start("/fixture/Helper.app/Contents/MacOS/helper", event => {
      if (event.event !== "activate_pill") return;
      activation = activateMenuPill(event, {
        current: () => greeting,
        focusSession: async () => {
          try { await helper!.focus(target); return undefined; }
          catch (error) { return (error as Error).message; }
        },
      }, effect => effects.push(effect));
    });
    respond = request => peer.write(frame(request.method === "accessibility_status"
      ? { version: 1, id: request.id, ok: true, result: { type: "accessibility_status", trusted: "invalid" } }
      : accepted(request)));
    await expect(helper.accessibilityStatus()).rejects.toThrow("invalid response");
    peer.write(frame({ version: 1, type: "event", event: "activate_pill", sessionId: "greeting" }));
    await vi.waitFor(() => expect(activation).toBeDefined());
    await activation;
    expect(effects).toEqual([]);
    expect(requests.filter(request => request.method === "focus")).toEqual([
      expect.objectContaining({ params: { target } }),
    ]);
    expect(helper.isAvailable()).toBe(true);
  });

  it("rejects only the matching invalid reply and keeps a coalesced concurrent reply", async () => {
    helper = await NativeHelperProcess.start("/fixture/Helper.app/Contents/MacOS/helper", () => undefined);
    respond = () => {
      if (requests.length !== 2) return;
      peer.write(Buffer.concat([
        frame({ version: 1, id: requests[0].id, ok: true, result: { type: "unexpected" } }),
        frame(accepted(requests[1])),
      ]));
    };
    const outcomes = await Promise.allSettled([helper.requestAccessibility(), helper.focus(target)]);
    expect(outcomes.map(outcome => outcome.status)).toEqual(["rejected", "fulfilled"]);
  });

  it("discards an invalid event and parses the following fragmented event", async () => {
    const events: NativeHelperEvent[] = [];
    helper = await NativeHelperProcess.start("/fixture/Helper.app/Contents/MacOS/helper", event => events.push(event));
    const valid = frame({ version: 1, type: "event", event: "activate_pill", sessionId: "greeting" });
    peer.write(Buffer.concat([frame({ version: 1, type: "event", event: "activate_pill", sessionId: null }), valid.subarray(0, 6)]));
    peer.write(valid.subarray(6));
    await vi.waitFor(() => expect(events).toEqual([{ version: 1, type: "event", event: "activate_pill", sessionId: "greeting" }]));
    await expect(helper.focus(target)).resolves.toBeUndefined();
  });

  it("fails an uncorrelatable reply once and never replays terminal input", async () => {
    helper = await NativeHelperProcess.start("/fixture/Helper.app/Contents/MacOS/helper", () => undefined);
    respond = request => peer.write(request.method === "send_terminal" ? frame(Buffer.from("{invalid")) : frame(accepted(request)));
    await expect(helper.sendTerminal({ application: "Terminal", tty: "ttys001", cwd: "/repo" }, "private prompt", true)).rejects.toThrow("invalid JSON");
    await expect(helper.focus(target)).resolves.toBeUndefined();
    expect(requests.filter(request => request.method === "send_terminal")).toHaveLength(1);
  });

  it("saves the first bounded diagnostic without payload strings or identifiers", async () => {
    helper = await NativeHelperProcess.start("/fixture/Helper.app/Contents/MacOS/helper", () => undefined);
    const secret = "PRIVATE_SESSION_TEXT_AND_TOKEN";
    respond = request => peer.write(frame({ version: 1, id: request.id, ok: true,
      result: { type: "accessibility_status", trusted: secret }, [secret]: secret.repeat(1000) }));
    await expect(helper.accessibilityStatus()).rejects.toThrow("invalid response");
    const diagnosticPath = path.join(dataRoot, "diagnostics", "native-helper-protocol-error.json");
    let first = "";
    await vi.waitFor(async () => { first = await readFile(diagnosticPath, "utf8"); expect(JSON.parse(first).kind).toBe("invalid_response"); });
    expect(first).not.toContain(secret);
    expect(first).not.toContain(requests[0].id);
    expect(Buffer.byteLength(first)).toBeLessThan(16_384);
    expect(first).toContain("trusted");
    respond = request => peer.write(frame({ version: 99, id: request.id, ok: true, result: { type: "accepted" } }));
    await expect(helper.focus(target)).rejects.toThrow("invalid response");
    expect(await readFile(diagnosticPath, "utf8")).toBe(first);
  });

  it("keeps oversized framing fatal and stops forwarding later events", async () => {
    const events: NativeHelperEvent[] = [];
    helper = await NativeHelperProcess.start("/fixture/Helper.app/Contents/MacOS/helper", event => events.push(event));
    respond = () => { const header = Buffer.alloc(4); header.writeUInt32BE(NATIVE_HELPER_MAX_FRAME_BYTES + 1); peer.write(header); };
    await expect(helper.focus(target)).rejects.toThrow("oversized frame");
    expect(helper.isAvailable()).toBe(false);
    await expect(helper.focus(target)).rejects.toThrow("oversized frame");
    expect(requests).toHaveLength(1);
    expect(events).toEqual([]);
  });
});
