import { createReadStream } from "node:fs";
import { open, readdir, stat } from "node:fs/promises";
import { machineWork, runProcess, summaryWork } from "../machine.js";

export type ProcessRecord = {
  pid: number;
  parentPID: number;
  tty?: string;
  command: string;
  arguments: string;
};

export type FileStamp = {
  modifiedAt: Date;
  size: number;
};

export interface ProviderEnvironment {
  readonly home: string;
  readonly observedWindowMs: number;
  now(): Date;
  processes(): Promise<ProcessRecord[]>;
  cwd(pid: number): Promise<string | undefined>;
  processStartedAt(pid: number): Promise<Date | undefined>;
  directory(path: string): Promise<string[]>;
  isDirectory(path: string): Promise<boolean>;
  stamp(path: string): Promise<FileStamp | undefined>;
  read(path: string, maxBytes?: number): Promise<string | undefined>;
  readHeadTail(path: string, bytes?: number): Promise<{ head: string; tail: string } | undefined>;
  scanLinePrefixes(
    path: string,
    prefixBytes: number,
    visit: (line: string) => void,
    startAt?: number,
  ): Promise<number>;
  sqlite(database: string, sql: string): Promise<unknown[]>;
}

export class LiveProviderEnvironment implements ProviderEnvironment {
  private readonly observedWindow: number | (() => number);
  private processSnapshot: Promise<ProcessRecord[]> | undefined;
  private processSnapshotExpiresAt = 0;
  private readonly cwdByPID = new Map<number, Promise<string | undefined>>();
  private readonly startedAtByPID = new Map<number, Promise<Date | undefined>>();

  constructor(
    readonly home: string,
    options: { observedWindowMs?: number | (() => number); now?: () => Date } = {},
  ) {
    this.observedWindow = options.observedWindowMs ?? 42 * 60 * 60 * 1_000;
    this.clock = options.now ?? (() => new Date());
  }

  private readonly clock: () => Date;

  get observedWindowMs(): number {
    return typeof this.observedWindow === "function"
      ? this.observedWindow() : this.observedWindow;
  }

  now(): Date {
    return this.clock();
  }

  async processes(): Promise<ProcessRecord[]> {
    if (Date.now() >= this.processSnapshotExpiresAt) {
      this.processSnapshot = undefined;
      this.cwdByPID.clear();
      this.startedAtByPID.clear();
      this.processSnapshotExpiresAt = Date.now() + 1_000;
    }
    this.processSnapshot ??= machineWork.run(async () => {
      const result = await runProcess(
        "/bin/ps",
        ["-axo", "pid=,ppid=,tty=,comm=,args="],
        { deadlineMs: 1_000, maxOutputBytes: 4 * 1_048_576 },
      );
      if (result.status !== "success") return [];
      return result.stdout.split("\n").flatMap((line) => {
        const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s*(.*)$/.exec(line);
        if (!match) return [];
        const rawTTY = match[3];
        return [{
          pid: Number(match[1]),
          parentPID: Number(match[2]),
          tty: rawTTY && !["?", "??", "-"].includes(rawTTY) ? rawTTY : undefined,
          command: match[4] ?? "",
          arguments: match[5] ?? "",
        }];
      });
    });
    return this.processSnapshot;
  }

  async cwd(pid: number): Promise<string | undefined> {
    let pending = this.cwdByPID.get(pid);
    if (!pending) {
      pending = machineWork.run(async () => {
        const result = await runProcess(
          "/usr/sbin/lsof",
          ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
          { deadlineMs: 1_000 },
        );
        if (result.status !== "success") return undefined;
        const line = result.stdout.split("\n").find((value) => value.startsWith("n"));
        return line?.slice(1) || undefined;
      });
      this.cwdByPID.set(pid, pending);
    }
    return pending;
  }

  async processStartedAt(pid: number): Promise<Date | undefined> {
    let pending = this.startedAtByPID.get(pid);
    if (!pending) {
      pending = machineWork.run(async () => {
        const result = await runProcess(
          "/bin/ps",
          ["-p", String(pid), "-o", "lstart="],
          { deadlineMs: 1_000 },
        );
        if (result.status !== "success") return undefined;
        const value = new Date(result.stdout.trim());
        return Number.isNaN(value.valueOf()) ? undefined : value;
      });
      this.startedAtByPID.set(pid, pending);
    }
    return pending;
  }

  async directory(path: string): Promise<string[]> {
    return machineWork.run(async () => {
      try { return await readdir(path); } catch { return []; }
    });
  }

  async isDirectory(path: string): Promise<boolean> {
    return machineWork.run(async () => {
      try { return (await stat(path)).isDirectory(); } catch { return false; }
    });
  }

  async stamp(path: string): Promise<FileStamp | undefined> {
    return machineWork.run(async () => {
      try {
        const value = await stat(path);
        return value.isFile() ? { modifiedAt: value.mtime, size: value.size } : undefined;
      } catch {
        return undefined;
      }
    });
  }

  async read(path: string, maxBytes = 1_048_576): Promise<string | undefined> {
    return machineWork.run(() => readSlice(path, maxBytes));
  }

  async readHeadTail(
    path: string,
    bytes = 64 * 1_024,
  ): Promise<{ head: string; tail: string } | undefined> {
    return summaryWork.run(async () => {
      let handle;
      try {
        handle = await open(path, "r");
        const metadata = await handle.stat();
        const headLength = Math.min(bytes, metadata.size);
        const tailStart = Math.max(0, metadata.size - bytes);
        const head = Buffer.alloc(headLength);
        const tail = Buffer.alloc(metadata.size - tailStart);
        await handle.read(head, 0, head.length, 0);
        await handle.read(tail, 0, tail.length, tailStart);
        return { head: head.toString("utf8"), tail: tail.toString("utf8") };
      } catch {
        return undefined;
      } finally {
        await handle?.close();
      }
    });
  }

  async scanLinePrefixes(
    path: string,
    prefixBytes: number,
    visit: (line: string) => void,
    startAt = 0,
  ): Promise<number> {
    return summaryWork.run(async () => {
      const stream = createReadStream(path, { highWaterMark: 256 * 1_024, start: startAt });
      let prefix = Buffer.alloc(0);
      let position = startAt;
      let completeThrough = startAt;
      try {
        for await (const value of stream) {
          let chunk = value as Buffer;
          while (chunk.length > 0) {
            const newline = chunk.indexOf(0x0a);
            const part = newline >= 0 ? chunk.subarray(0, newline) : chunk;
            if (prefix.length < prefixBytes) {
              prefix = Buffer.concat([prefix, part.subarray(0, prefixBytes - prefix.length)]);
            }
            position += part.length;
            if (newline < 0) break;
            position += 1;
            completeThrough = position;
            visit(prefix.toString("utf8"));
            prefix = Buffer.alloc(0);
            chunk = chunk.subarray(newline + 1);
          }
        }
      } catch {
        stream.destroy();
      }
      return completeThrough;
    });
  }

  async sqlite(database: string, sql: string): Promise<unknown[]> {
    return machineWork.run(async () => {
      const result = await runProcess(
        "/usr/bin/sqlite3",
        ["-readonly", "-cmd", ".timeout 500", "-json", database, sql],
        { deadlineMs: 1_500, maxOutputBytes: 5 * 1_048_576 },
      );
      if (result.status !== "success" || !result.stdout.trim()) return [];
      try {
        const value: unknown = JSON.parse(result.stdout);
        return Array.isArray(value) ? value : [];
      } catch {
        return [];
      }
    });
  }
}

async function readSlice(path: string, maxBytes: number): Promise<string | undefined> {
  let handle;
  try {
    handle = await open(path, "r");
    const metadata = await handle.stat();
    const length = Math.min(maxBytes, metadata.size);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, 0);
    return buffer.toString("utf8");
  } catch {
    return undefined;
  } finally {
    await handle?.close();
  }
}
