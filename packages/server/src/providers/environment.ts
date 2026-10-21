import { createReadStream } from "node:fs";
import { open, readdir, realpath, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { NativeHelperGhosttyTerminalView } from "@agent-visor/protocol";
import { machineWork, runProcess, summaryWork } from "../machine.js";
import { readCodexSettingsCatalog, type CodexSettingsCatalog } from "../codex-turn.js";
import { readCodexCliObservation, type CodexCliObservation } from "./codex-cli-observer.js";
import { CmuxClient, type CmuxSurfaceTarget } from "./cmux.js";
import { HerdrClient, type HerdrSurfaceTarget } from "./herdr.js";
import {
  ClaudeAgentInventory,
  resolveClaudeExecutable,
  type ClaudeAgentInventoryResult,
} from "./claude-agent-inventory.js";

export type ProcessRecord = {
  pid: number;
  parentPID: number;
  /** Stable helper-derived process instance token, when available. */
  processStartToken?: string;
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
  /** Bypass the short ambient process cache for an explicit focus recheck. */
  processesFresh?(): Promise<ProcessRecord[]>;
  cwd(pid: number): Promise<string | undefined>;
  processStartedAt(pid: number): Promise<Date | undefined>;
  codexDesktopCommand?(pid: number): Promise<string | undefined>;
  codexProcessHome?(pid: number): Promise<string | undefined>;
  /** Owned, bounded observer record; generic JSON is not navigation authority. */
  codexCliObservation?(pid: number, home: string): Promise<CodexCliObservation | undefined>;
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
  /** Optional provider-owned settings catalog used by interactive Codex chat. */
  codexSettingsCatalog?(cwd: string): Promise<CodexSettingsCatalog | undefined>;
  /** Optional Claude inventory seam; fixture environments leave this unset. */
  claudeAgentInventory?(): Promise<ClaudeAgentInventoryResult>;
  /** Bounded fresh inventory used only to revalidate an explicit click. */
  claudeAgentInventoryFresh?(): Promise<ClaudeAgentInventoryResult>;
  /** Resolve the trusted Claude executable used by exact background attach. */
  claudeExecutable?(): Promise<string | undefined>;
  /** Current Ghostty titles; runtime ownership alone cannot identify an attached job. */
  ghosttyTerminalViews?(conversationTitles?: readonly string[]): Promise<GhosttyTerminalView[]>;
  /** Exact local cmux surface; discovery never focuses or sends input. */
  herdrSurface?(pid: number, sessionId: string, cwd: string): Promise<HerdrSurfaceTarget | undefined>;
  /** Current Codex identity from its host, independent of the Desktop catalog source. */
  herdrCodexSurface?(pid: number, cwd: string, home: string): Promise<HerdrSurfaceTarget | undefined>;
  cmuxSurface?(pid: number, sessionId: string, cwd: string): Promise<CmuxSurfaceTarget | undefined>;
}

export type GhosttyTerminalView = NativeHelperGhosttyTerminalView;

export class LiveProviderEnvironment implements ProviderEnvironment {
  private readonly observedWindow: number | (() => number);
  private processSnapshot: Promise<ProcessRecord[]> | undefined;
  private processSnapshotExpiresAt = 0;
  private readonly cwdByPID = new Map<number, Promise<string | undefined>>();
  private readonly startedAtByPID = new Map<number, Promise<Date | undefined>>();
  private readonly claudeInventory: ClaudeAgentInventory;
  private claudeExecutablePath?: Promise<string | undefined>;
  private readonly cmux = new CmuxClient();
  private readonly herdr = new HerdrClient();
  readonly ghosttyTerminalViews?: (conversationTitles?: readonly string[]) => Promise<GhosttyTerminalView[]>;

  constructor(
    readonly home: string,
    options: {
      observedWindowMs?: number | (() => number); now?: () => Date;
      ghosttyTerminalViews?: (conversationTitles?: readonly string[]) => Promise<GhosttyTerminalView[]>;
    } = {},
  ) {
    this.observedWindow = options.observedWindowMs ?? 42 * 60 * 60 * 1_000;
    this.clock = options.now ?? (() => new Date());
    this.ghosttyTerminalViews = options.ghosttyTerminalViews;
    this.claudeInventory = new ClaudeAgentInventory({
      home,
      now: () => this.now(),
    });
  }

  private readonly clock: () => Date;

  codexCliObservation(pid: number, home: string): Promise<CodexCliObservation | undefined> {
    return readCodexCliObservation(pid, home);
  }

  herdrSurface(pid: number, sessionId: string, cwd: string): Promise<HerdrSurfaceTarget | undefined> {
    return this.herdr.resolve(pid, sessionId, cwd);
  }

  herdrCodexSurface(pid: number, cwd: string, home: string): Promise<HerdrSurfaceTarget | undefined> {
    return this.herdr.resolveCodex(pid, cwd, home);
  }

  cmuxSurface(pid: number, sessionId: string, cwd: string): Promise<CmuxSurfaceTarget | undefined> {
    return this.cmux.resolve(pid, sessionId, cwd);
  }

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
    // macOS truncates comm when it precedes another column, even with -ww.
    // Put each variable-width field last and join by PID; executable paths
    // can contain spaces and must never be reconstructed from argv text.
    this.processSnapshot ??= Promise.all([
      "pid=,ppid=,tty=,comm=", "pid=,args=",
    ].map(fields => machineWork.run(() => runProcess(
      "/bin/ps", ["-axww", "-o", fields],
      { deadlineMs: 1_000, maxOutputBytes: 4 * 1_048_576 },
    )))).then(([commands, args]) => {
      if (commands?.status !== "success" || args?.status !== "success") return [];
      const argumentsByPID = new Map(args.stdout.split("\n").flatMap(line => {
        const match = /^\s*(\d+)\s+(.*)$/.exec(line);
        return match ? [[Number(match[1]), match[2] ?? ""] as const] : [];
      }));
      return commands.stdout.split("\n").flatMap((line) => {
        const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.+)$/.exec(line);
        if (!match) return [];
        const pid = Number(match[1]);
        const args = argumentsByPID.get(pid);
        if (args === undefined) return [];
        const rawTTY = match[3];
        return [{
          pid,
          parentPID: Number(match[2]),
          tty: rawTTY && !["?", "??", "-"].includes(rawTTY) ? rawTTY : undefined,
          command: match[4] ?? "",
          arguments: args,
        }];
      });
    });
    return this.processSnapshot;
  }

  async processesFresh(): Promise<ProcessRecord[]> {
    this.processSnapshot = undefined;
    this.processSnapshotExpiresAt = 0;
    this.cwdByPID.clear();
    this.startedAtByPID.clear();
    return this.processes();
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

  async codexDesktopCommand(pid: number): Promise<string | undefined> {
    const result = await machineWork.run(() => runProcess(
      "/bin/ps", ["eww", "-p", String(pid), "-o", "command="],
      { deadlineMs: 1_000, maxOutputBytes: 64 * 1_024 },
    ));
    return result.status === "success" ? result.stdout : undefined;
  }

  async codexProcessHome(pid: number): Promise<string | undefined> {
    const command = await this.codexDesktopCommand(pid);
    if (!command) return undefined;
    const values = [...command.matchAll(/(?:^| )CODEX_HOME=(.*?)(?= [A-Za-z_][A-Za-z0-9_]*=|$)/g)];
    if (values.length > 1) return undefined;
    const value = values[0]?.[1]?.trim() ?? path.join(this.home, ".codex");
    if (!path.isAbsolute(value) || /[\u0000-\u001f]/.test(value)) return undefined;
    return realpath(value).catch(() => path.resolve(value));
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
      if (result.status !== "success") throw new Error("Provider database read failed");
      if (!result.stdout.trim()) return [];
      try {
        const value: unknown = JSON.parse(result.stdout);
        if (Array.isArray(value)) return value;
      } catch {
        throw new Error("Invalid provider database response");
      }
      throw new Error("Invalid provider database response");
    });
  }

  codexSettingsCatalog(cwd: string): Promise<CodexSettingsCatalog | undefined> {
    // CodexProvider owns the per-CWD TTL and in-flight deduplication. Keep
    // this environment seam as one uncached live read so two layers cannot
    // accidentally keep stale model/permission choices beyond that TTL.
    return readCodexSettingsCatalog(this.home, cwd).catch(() => undefined);
  }

  claudeAgentInventory(): Promise<ClaudeAgentInventoryResult> {
    if (path.resolve(this.home) !== path.resolve(os.homedir())) {
      const timestamp = this.now().valueOf();
      return Promise.resolve({
        kind: "unsupported",
        root: path.join(this.home, ".claude"),
        reason: "config_root",
        startedAt: timestamp,
        completedAt: timestamp,
      });
    }
    return this.claudeInventory.read();
  }

  claudeAgentInventoryFresh(): Promise<ClaudeAgentInventoryResult> {
    if (path.resolve(this.home) !== path.resolve(os.homedir())) {
      const timestamp = this.now().valueOf();
      return Promise.resolve({
        kind: "unsupported",
        root: path.join(this.home, ".claude"),
        reason: "config_root",
        startedAt: timestamp,
        completedAt: timestamp,
      });
    }
    return this.claudeInventory.refreshNow();
  }

  claudeExecutable(): Promise<string | undefined> {
    if (path.resolve(this.home) !== path.resolve(os.homedir())) return Promise.resolve(undefined);
    const pending = this.claudeExecutablePath ??= resolveClaudeExecutable(this.home);
    return pending.then((value) => {
      if (!value && this.claudeExecutablePath === pending) this.claudeExecutablePath = undefined;
      return value;
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
