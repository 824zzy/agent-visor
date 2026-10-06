import { hookEventSchema, type HookEvent } from "@agent-visor/protocol";
import { chmod, lstat, mkdir, unlink } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
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

  const clients = new Set<net.Socket>();
  const preTools = new Map<string, { event: HookEvent; at: number }>();
  const server = net.createServer({ allowHalfOpen: true }, (socket) => {
    clients.add(socket);
    const chunks: Buffer[] = [];
    let size = 0;
    let handled = false;
    let unregisterResponder: (() => void) | undefined;
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
    socket.once("end", () => {
      tryHandle(true);
      if (unregisterResponder) socket.destroy();
    });
    socket.once("close", () => {
      clearTimeout(deadline);
      unregisterResponder?.();
      clients.delete(socket);
    });

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
      if (!parsed.success) {
        socket.end();
        return;
      }
      // PermissionRequest has no tool_use_id. Consume a unique exact match;
      // ambiguous calls stay in Claude's UI instead of guessing an owner.
      const event = parsed.data;
      for (const [key, entry] of preTools) {
        if (Date.now() - entry.at > 5 * 60_000
          || (entry.event.session_id === event.session_id && (["SessionEnd", "SessionStart", "UserPromptSubmit", "Stop", "StopFailure"].includes(event.event)
            || (["PostToolUse", "PostToolUseFailure"].includes(event.event) && entry.event.tool_use_id === event.tool_use_id)))) preTools.delete(key);
      }
      if (providerID(event.agent) === "claude_code") {
        if (event.event === "PreToolUse" && event.tool_use_id) {
          if (preTools.size >= 512) preTools.delete(preTools.keys().next().value!);
          preTools.set(JSON.stringify([event.session_id, event.tool_use_id]), { event, at: Date.now() });
        } else if (event.event === "PermissionRequest" && !event.tool_use_id) {
          const matches = [...preTools.entries()].filter(([, entry]) => entry.event.session_id === event.session_id
            && entry.event.cwd === event.cwd && entry.event.tool === event.tool
            && isDeepStrictEqual(entry.event.tool_input, event.tool_input));
          if (matches.length === 1) {
            event.tool_use_id = matches[0]![1].event.tool_use_id;
            preTools.delete(matches[0]![0]);
          }
        }
      }
      applyEvent(options.repository, event);
      const expectsResponse = expectsHookResponse(parsed.data);
      if (expectsResponse && parsed.data.tool_use_id) {
        clearTimeout(deadline);
        unregisterResponder = options.repository.registerHookResponder(
          parsed.data.session_id,
          parsed.data.tool_use_id,
          (response) => socket.end(JSON.stringify(response)),
        );
      } else {
        socket.end();
      }
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
      for (const client of clients) client.destroy();
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
    ...(event.session_file ? { sessionFile: event.session_file } : {}),
    ...(event.tool ? { tool: event.tool } : {}),
    ...(event.tool_input ? { toolInput: event.tool_input } : {}),
    ...(event.tool_use_id ? { toolUseId: event.tool_use_id } : {}),
    ...(event.permission_suggestions
      ? { permissionSuggestions: event.permission_suggestions } : {}),
    expectsResponse: expectsHookResponse(event),
  });
}

function expectsHookResponse(event: HookEvent): boolean {
  return providerID(event.agent) === "claude_code" && event.status === "waiting_for_approval"
    && (event.event === "PermissionRequest" || (event.event === "PreToolUse" && event.tool === "AskUserQuestion"));
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
