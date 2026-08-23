import { hookEventSchema, type HookEvent } from "@agent-visor/protocol";
import { chmod, lstat, mkdir, unlink } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import type { ProviderID, SessionRepository } from "./sessions.js";

export type RunningHookSocket = {
  close(): Promise<void>;
};

export async function startHookSocket(options: {
  socketPath: string;
  repository: SessionRepository;
  maxPayloadBytes?: number;
}): Promise<RunningHookSocket> {
  const maxPayloadBytes = options.maxPayloadBytes ?? 1_048_576;
  await mkdir(path.dirname(options.socketPath), { recursive: true, mode: 0o700 });
  await removeOwnedSocket(options.socketPath);

  const server = net.createServer((socket) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let handled = false;
    const deadline = setTimeout(() => socket.destroy(), 500);

    socket.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > maxPayloadBytes) {
        socket.destroy();
        return;
      }
      chunks.push(chunk);
      tryHandle(false);
    });
    socket.once("end", () => tryHandle(true));
    socket.once("close", () => clearTimeout(deadline));

    function tryHandle(final: boolean): void {
      if (handled) return;
      let value: unknown;
      try { value = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
      catch {
        if (final) socket.destroy();
        return;
      }
      handled = true;
      const parsed = hookEventSchema.safeParse(value);
      if (parsed.success) applyEvent(options.repository, parsed.data);
      socket.end();
    }
  });

  await new Promise<void>((resolve, reject) => {
    server.once("listening", resolve);
    server.once("error", reject);
    server.listen(options.socketPath);
  });
  await chmod(options.socketPath, 0o600);

  return {
    close: async () => {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => error ? reject(error) : resolve());
      });
      await unlink(options.socketPath).catch(() => undefined);
    },
  };
}

function applyEvent(repository: SessionRepository, event: HookEvent): void {
  const provider = providerID(event.agent);
  repository.applyHook({
    sessionId: event.session_id,
    cwd: event.cwd,
    provider,
    event: event.event,
    status: event.status,
    receivedAt: new Date().toISOString(),
    ...(event.pid === undefined ? {} : { pid: event.pid }),
    ...(event.tty ? { tty: event.tty } : {}),
    ...(event.is_idle === undefined ? {} : { isIdle: event.is_idle }),
    expectsResponse: event.event === "PermissionRequest"
      && event.status === "waiting_for_approval"
      && provider === "claude_code",
  });
}

function providerID(value: HookEvent["agent"]): Exclude<ProviderID, "zed"> {
  return value === "claude" || value === undefined ? "claude_code" : value;
}

async function removeOwnedSocket(socketPath: string): Promise<void> {
  try {
    const existing = await lstat(socketPath);
    if (!existing.isSocket() || existing.uid !== process.getuid?.()) {
      throw new Error(`Refusing to replace unsafe hook socket: ${socketPath}`);
    }
    if (await socketIsActive(socketPath)) {
      throw new Error(`Hook socket is already active: ${socketPath}`);
    }
    await unlink(socketPath);
  } catch (error) {
    if (isMissing(error)) return;
    throw error;
  }
}

async function socketIsActive(socketPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    const done = (active: boolean) => {
      socket.destroy();
      resolve(active);
    };
    socket.setTimeout(100, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

function isMissing(error: unknown): boolean {
  return typeof error === "object" && error !== null
    && "code" in error && error.code === "ENOENT";
}
