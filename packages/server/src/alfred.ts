import type { SessionSnapshot, SessionSummary } from "@agent-visor/protocol";
import { chmod, lstat, mkdir, unlink } from "node:fs/promises";
import net from "node:net";
import path from "node:path";

type SessionSource = {
  current(): SessionSnapshot;
  focusSession(id: string): Promise<string | undefined>;
};

export type AlfredItem = {
  uid?: string;
  title: string;
  subtitle: string;
  arg?: string;
  valid: boolean;
};

const tiers = ["needs_you", "ready", "working", "acknowledged_ready", "history"];
const labels: Record<string, string> = {
  needs_you: "Needs you", ready: "Ready", working: "Working", history: "Recent",
};

/** Only session summaries enter Alfred; conversation bodies and runtime credentials stay private. */
export function alfredResults(snapshot: SessionSnapshot, query: string) {
  const words = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  const matches = snapshot.sessions.filter((session) => {
    const text = [session.title, session.project, session.source, session.owner, session.cwd]
      .join(" ").toLocaleLowerCase();
    return words.every((word) => text.includes(word));
  }).sort((left, right) => {
    const rank = (session: SessionSummary) => (
      words.every((word) => session.title.toLocaleLowerCase().includes(word)) ? 0 : 1
    );
    return rank(left) - rank(right)
      || tiers.indexOf(left.attentionTier ?? left.section) - tiers.indexOf(right.attentionTier ?? right.section)
      || right.updatedAt.localeCompare(left.updatedAt)
      || left.id.localeCompare(right.id);
  });
  const items: AlfredItem[] = matches.slice(0, 100).map((session) => ({
    uid: session.id,
    title: session.title.slice(0, 512),
    subtitle: [
      labels[session.section], session.source, session.project,
      session.canOpenOwner ? `Open ${session.owner}` : "Original app unavailable",
      session.cwd,
    ].join(" · ").slice(0, 2_048),
    arg: session.id,
    valid: session.canOpenOwner,
  }));
  if (!items.length) items.push({
    title: words.length ? "No matching agent sessions" : "No agent sessions yet",
    subtitle: words.length ? "Try a title, project, agent, or folder name." : "Open a session in a supported agent app.",
    valid: false,
  });
  if (matches.length > 100) items.push({
    title: `${matches.length - 100} more matching sessions`,
    subtitle: "Keep typing to narrow the results.",
    valid: false,
  });
  return { items, skipknowledge: true, rerun: 2 };
}

/** A private, one-request-per-connection interface with only search and owner navigation. */
export async function startAlfredSocket(options: { socketPath: string; source: SessionSource }) {
  // macOS sun_path includes a trailing NUL; Node may otherwise bind a silently truncated path.
  if (Buffer.byteLength(options.socketPath) > 103) {
    throw new Error("The data folder path is too long for the Alfred session socket.");
  }
  const directory = path.dirname(options.socketPath);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const parent = await lstat(directory);
  if (!parent.isDirectory() || parent.uid !== process.getuid?.() || (parent.mode & 0o077) !== 0) {
    throw new Error("The Alfred socket directory must be private to the current user.");
  }
  await removeStaleSocket(options.socketPath);

  const clients = new Set<net.Socket>();
  const server = net.createServer((socket) => {
    if (clients.size >= 16) { socket.destroy(); return; }
    clients.add(socket);
    let buffer = Buffer.alloc(0);
    let handled = false;
    const deadline = setTimeout(() => socket.destroy(), 1_000);
    socket.on("error", () => socket.destroy());
    socket.once("close", () => { clearTimeout(deadline); clients.delete(socket); });
    socket.on("data", (chunk: Buffer) => {
      if (handled) return;
      if (buffer.length + chunk.length > 8_192) { socket.destroy(); return; }
      buffer = Buffer.concat([buffer, chunk]);
      const end = buffer.indexOf(10);
      if (end < 0) return;
      handled = true;
      clearTimeout(deadline);
      socket.setTimeout(20_000, () => socket.destroy());
      void respond(buffer.subarray(0, end)).catch(() => {
        socket.end(JSON.stringify({ error: "Agent Visor could not complete this request." }));
      });
    });

    async function respond(data: Buffer): Promise<void> {
      const request: unknown = JSON.parse(data.toString("utf8"));
      if (!isRequest(request)) {
        socket.end(JSON.stringify({ error: "Invalid session search request." }));
        return;
      }
      if (request.action === "search") {
        socket.end(JSON.stringify(alfredResults(options.source.current(), request.query)));
        return;
      }
      const selected = options.source.current().sessions.find((session) => session.id === request.sessionId);
      if (!selected?.canOpenOwner) {
        socket.end(JSON.stringify({ error: "The original app for this session is no longer available. Search again." }));
        return;
      }
      // Reuse the same exact-owner navigation and Ready acknowledgment as the Sessions browser.
      const error = await options.source.focusSession(request.sessionId);
      socket.end(JSON.stringify(error ? { error } : { ok: true }));
    }
  });
  server.on("error", () => {}); // Startup errors reject below; later client errors must not crash the daemon.
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.socketPath, () => { server.removeListener("error", reject); resolve(); });
  });
  try {
    await chmod(options.socketPath, 0o600);
  } catch (error) {
    for (const client of clients) client.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    throw error;
  }
  return {
    close: async () => {
      for (const client of clients) client.destroy();
      await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    },
  };
}

function isRequest(value: unknown): value is
  | { action: "search"; query: string }
  | { action: "focus"; sessionId: string } {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const object = value as Record<string, unknown>;
  if (Object.keys(object).length !== 2) return false;
  return (object.action === "search" && typeof object.query === "string" && object.query.length <= 256)
    || (object.action === "focus" && typeof object.sessionId === "string"
      && object.sessionId.length > 0 && object.sessionId.length <= 2_048);
}

async function removeStaleSocket(socketPath: string): Promise<void> {
  let existing;
  try { existing = await lstat(socketPath); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
  if (!existing.isSocket() || existing.uid !== process.getuid?.()) {
    throw new Error("Refusing to replace an unsafe Alfred socket.");
  }
  const stale = await new Promise<boolean>((resolve) => {
    const probe = net.createConnection(socketPath);
    probe.once("connect", () => { probe.destroy(); resolve(false); });
    probe.once("error", (error: NodeJS.ErrnoException) => {
      probe.destroy(); resolve(error.code === "ECONNREFUSED" || error.code === "ENOENT");
    });
    probe.setTimeout(300, () => { probe.destroy(); resolve(false); });
  });
  if (!stale) throw new Error("An Alfred session search socket is already active.");
  await unlink(socketPath);
}
