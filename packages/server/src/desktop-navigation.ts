import { randomUUID } from "node:crypto";

type OpenSessionURL = { type: "native_action"; action: "open_session_url"; url: string; requestId: string };

/** An IPC write is not a successful URL launch. Wait for the host's result. */
export class DesktopSessionNavigation {
  private readonly pending = new Map<string, (ok: boolean) => void>();
  private closed = false;
  constructor(private readonly send: (message: OpenSessionURL) => void, private readonly deadlineMs = 5_000) {}

  open(url: string): Promise<void> {
    if (this.closed || this.pending.size >= 16) return Promise.reject(new Error("The desktop is unavailable for session navigation."));
    return new Promise((resolve, reject) => {
      const requestId = randomUUID();
      const finish = (ok: boolean) => {
        if (!this.pending.delete(requestId)) return;
        clearTimeout(timer);
        if (ok) resolve(); else reject(new Error("The original session could not be opened."));
      };
      const timer = setTimeout(() => finish(false), this.deadlineMs);
      this.pending.set(requestId, finish);
      try { this.send({ type: "native_action", action: "open_session_url", url, requestId }); }
      catch { finish(false); }
    });
  }

  receive(value: unknown): void {
    if (typeof value !== "object" || value === null) return;
    const message = value as Record<string, unknown>;
    if (message.type === "session_url_result" && typeof message.requestId === "string" && typeof message.ok === "boolean") {
      this.pending.get(message.requestId)?.(message.ok);
    }
  }

  close(): void {
    this.closed = true;
    for (const finish of this.pending.values()) finish(false);
  }
}
