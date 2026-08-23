import { afterEach, describe, expect, it } from "vitest";
import { mkdtemp, rm, stat } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { startHookSocket, type RunningHookSocket } from "./hook-socket.js";
import { SessionRepository } from "./sessions.js";

let root: string | undefined;
let running: RunningHookSocket | undefined;

afterEach(async () => {
  await running?.close();
  if (root) await rm(root, { recursive: true, force: true });
  root = undefined;
  running = undefined;
});

describe("hook socket", () => {
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

    await expect.poll(() => repository.current().sessions.length).toBe(1);
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
