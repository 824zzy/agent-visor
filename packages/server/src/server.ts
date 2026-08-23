import { WebSocket, WebSocketServer } from "ws";
import {
  PROTOCOL_VERSION,
  clientMessageSchema,
  sessionSnapshotSchema,
  type ServerMessage,
  type SessionSnapshot,
} from "@agent-visor/protocol";
import type { SessionSnapshotSource } from "./sessions.js";

export type RunningServer = {
  url: string;
  close: () => Promise<void>;
};

export async function startServer(options: {
  port: number;
  token: string;
} & (
  | { snapshot: SessionSnapshot; source?: never }
  | { source: SessionSnapshotSource; snapshot?: never }
)): Promise<RunningServer> {
  if (options.token.length < 32) {
    throw new Error("The Agent Visor daemon token must contain at least 32 characters.");
  }
  const source = options.source ?? fixedSource(sessionSnapshotSchema.parse(options.snapshot));
  const subscribers = new Set<WebSocket>();
  const server = new WebSocketServer({
    host: "127.0.0.1",
    port: options.port,
    verifyClient: ({ req }, done) => {
      const request = new URL(req.url ?? "/", "ws://127.0.0.1");
      done(request.searchParams.get("token") === options.token, 401, "Unauthorized");
    },
  });

  const unsubscribe = source.subscribe((snapshot) => {
    for (const socket of subscribers) {
      if (socket.readyState === WebSocket.OPEN) send(socket, snapshot);
    }
  });

  server.on("connection", (socket) => {
    send(socket, { type: "hello", protocolVersion: PROTOCOL_VERSION });
    socket.once("close", () => subscribers.delete(socket));

    socket.on("message", (data) => {
      let value: unknown;
      try {
        value = JSON.parse(data.toString());
      } catch {
        return;
      }

      const parsed = clientMessageSchema.safeParse(value);
      if (!parsed.success) return;

      if (parsed.data.type === "health") {
        send(socket, { type: "health", status: "ok" });
      } else {
        subscribers.add(socket);
        send(socket, source.current());
      }
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("listening", resolve);
    server.once("error", reject);
  });

  const address = server.address();
  if (typeof address === "string" || address === null) {
    await closeServer(server);
    throw new Error("The Agent Visor daemon did not receive a TCP port.");
  }

  return {
    url: `ws://127.0.0.1:${address.port}?token=${encodeURIComponent(options.token)}`,
    close: async () => {
      unsubscribe();
      await closeServer(server);
    },
  };
}

function fixedSource(snapshot: SessionSnapshot): SessionSnapshotSource {
  return {
    current: () => structuredClone(snapshot),
    subscribe: () => () => undefined,
  };
}

function send(socket: { send(data: string): void }, message: ServerMessage): void {
  socket.send(JSON.stringify(message));
}

async function closeServer(server: WebSocketServer): Promise<void> {
  for (const client of server.clients) client.terminate();
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}
