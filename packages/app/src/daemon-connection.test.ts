import { describe, expect, it } from "vitest";
import { connectDaemon } from "./daemon-connection.js";

class FakeSocket {
  readonly sent: string[] = [];
  readyState: number = WebSocket.CONNECTING;
  onclose: ((event: CloseEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onopen: ((event: Event) => void) | null = null;

  close(): void {
    this.readyState = WebSocket.CLOSED;
  }

  disconnect(): void {
    this.readyState = WebSocket.CLOSED;
    this.onclose?.({} as CloseEvent);
  }

  fail(): void {
    this.onerror?.({} as Event);
  }

  open(): void {
    this.readyState = WebSocket.OPEN;
    this.onopen?.({} as Event);
  }

  receive(data: string): void {
    this.onmessage?.({ data } as MessageEvent);
  }

  send(data: string): void {
    this.sent.push(data);
  }
}

type ScheduledTask = { cancelled: boolean; delay: number; run: () => void };

describe("connectDaemon", () => {
  it("reconnects after a clean close and repeats the subscription", () => {
    const sockets: FakeSocket[] = [];
    const scheduled: ScheduledTask[] = [];
    const received: string[] = [];
    let disconnects = 0;
    const connection = connectDaemon({
      url: "ws://127.0.0.1:6768",
      onDisconnect: () => { disconnects += 1; },
      onMessage: (data) => received.push(data),
      onOpen: (opened) => { opened.send("subscribe"); },
    }, {
      createSocket: () => {
        const socket = new FakeSocket();
        sockets.push(socket);
        return socket as unknown as WebSocket;
      },
      schedule: (run, delay) => {
        const task = { cancelled: false, delay, run };
        scheduled.push(task);
        return task as unknown as ReturnType<typeof setTimeout>;
      },
      cancelScheduled: (handle) => {
        (handle as unknown as ScheduledTask).cancelled = true;
      },
    });

    sockets[0]?.open();
    sockets[0]?.receive("first");
    expect(sockets[0]?.sent).toEqual(["subscribe"]);
    expect(received).toEqual(["first"]);

    sockets[0]?.disconnect();
    expect(disconnects).toBe(1);
    expect(scheduled).toMatchObject([{ cancelled: false, delay: 0 }]);
    scheduled[0]?.run();

    expect(sockets).toHaveLength(2);
    sockets[1]?.open();
    sockets[1]?.receive("second");
    expect(sockets[1]?.sent).toEqual(["subscribe"]);
    expect(received).toEqual(["first", "second"]);

    connection.close();
    expect(sockets[1]?.readyState).toBe(WebSocket.CLOSED);
  });

  it("backs off repeated failures and caps retries for the local daemon", () => {
    const sockets: FakeSocket[] = [];
    const scheduled: ScheduledTask[] = [];
    const connection = connectDaemon({ url: "ws://127.0.0.1:6768" }, {
      createSocket: () => {
        const socket = new FakeSocket();
        sockets.push(socket);
        return socket as unknown as WebSocket;
      },
      schedule: (run, delay) => {
        const task = { cancelled: false, delay, run };
        scheduled.push(task);
        return task as unknown as ReturnType<typeof setTimeout>;
      },
      cancelScheduled: (handle) => {
        (handle as unknown as ScheduledTask).cancelled = true;
      },
    });

    for (let index = 0; index < 5; index += 1) {
      sockets[index]?.fail();
      scheduled[index]?.run();
    }

    expect(scheduled.map(({ delay }) => delay)).toEqual([0, 250, 1_000, 5_000, 5_000]);
    connection.close();
  });

  it("cancels a queued retry when its consumer closes", () => {
    const sockets: FakeSocket[] = [];
    const scheduled: ScheduledTask[] = [];
    const connection = connectDaemon({ url: "ws://127.0.0.1:6768" }, {
      createSocket: () => {
        const socket = new FakeSocket();
        sockets.push(socket);
        return socket as unknown as WebSocket;
      },
      schedule: (run, delay) => {
        const task = { cancelled: false, delay, run };
        scheduled.push(task);
        return task as unknown as ReturnType<typeof setTimeout>;
      },
      cancelScheduled: (handle) => {
        (handle as unknown as ScheduledTask).cancelled = true;
      },
    });

    sockets[0]?.disconnect();
    connection.close();
    expect(scheduled[0]?.cancelled).toBe(true);

    scheduled[0]?.run();
    expect(sockets).toHaveLength(1);
  });
});
