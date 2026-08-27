export type DaemonConnection = {
  close(): void;
  send(data: string): boolean;
};

export type DaemonConnectionHandlers = {
  url: string;
  onDisconnect?: () => void;
  onMessage?: (data: string) => void;
  onOpen?: (connection: DaemonConnection) => void;
};

type DaemonSocket = Pick<
  WebSocket,
  "close" | "onclose" | "onerror" | "onmessage" | "onopen" | "readyState" | "send"
>;

export type DaemonConnectionEnvironment = {
  cancelScheduled?: (handle: ReturnType<typeof setTimeout>) => void;
  createSocket?: (url: string) => DaemonSocket;
  schedule?: (run: () => void, delay: number) => ReturnType<typeof setTimeout>;
};

// ponytail: this is one local renderer reconnecting to its child daemon. Add jitter only if
// Agent Visor supports multiple renderer windows that can create a reconnect burst.
const reconnectDelaysMs = [0, 250, 1_000, 5_000] as const;

export function connectDaemon(
  handlers: DaemonConnectionHandlers,
  environment: DaemonConnectionEnvironment = {},
): DaemonConnection {
  const createSocket = environment.createSocket ?? ((url) => new WebSocket(url));
  const schedule = environment.schedule ?? ((run, delay) => setTimeout(run, delay));
  const cancelScheduled = environment.cancelScheduled ?? ((handle) => clearTimeout(handle));
  let socket: DaemonSocket | undefined;
  let scheduled: ReturnType<typeof setTimeout> | undefined;
  let retryIndex = 0;
  let stopped = false;

  const connection: DaemonConnection = {
    close: () => {
      stopped = true;
      if (scheduled !== undefined) cancelScheduled(scheduled);
      scheduled = undefined;
      const current = socket;
      socket = undefined;
      if (!current) return;
      detach(current);
      current.close();
    },
    send: (data) => {
      if (socket?.readyState !== WebSocket.OPEN) return false;
      socket.send(data);
      return true;
    },
  };

  const reconnect = (current?: DaemonSocket) => {
    if (stopped || (current && current !== socket) || scheduled !== undefined) return;
    if (current) {
      detach(current);
      current.close();
      socket = undefined;
    }
    handlers.onDisconnect?.();
    const delay = reconnectDelaysMs[Math.min(retryIndex, reconnectDelaysMs.length - 1)]!;
    retryIndex += 1;
    scheduled = schedule(() => {
      scheduled = undefined;
      open();
    }, delay);
  };

  const open = () => {
    if (stopped) return;
    let current: DaemonSocket;
    try {
      current = createSocket(handlers.url);
    } catch {
      reconnect();
      return;
    }
    socket = current;
    current.onopen = () => {
      if (stopped || socket !== current) return;
      retryIndex = 0;
      handlers.onOpen?.(connection);
    };
    current.onmessage = (event) => {
      if (!stopped && socket === current) handlers.onMessage?.(String(event.data));
    };
    current.onerror = () => reconnect(current);
    current.onclose = () => reconnect(current);
  };

  open();
  return connection;
}

function detach(socket: DaemonSocket): void {
  socket.onclose = null;
  socket.onerror = null;
  socket.onmessage = null;
  socket.onopen = null;
}
