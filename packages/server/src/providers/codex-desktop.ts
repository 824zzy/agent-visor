import { realpath } from "node:fs/promises";
import path from "node:path";
import { machineWork, runProcess } from "../machine.js";
import { isCodexDesktop } from "./codex-instances.js";
import { processInstanceToken } from "./shared.js";
import type { ProcessRecord } from "./environment.js";

export type CodexDesktopIO = {
  run: typeof runProcess;
  realpath: typeof realpath;
  uid: number;
};

/** Positive live-runtime evidence only; absence never establishes closure. */
export async function readCodexDesktopRollouts(
  pid: number, home: string, processes: ProcessRecord[],
  io: CodexDesktopIO = { run: (...args) => machineWork.run(() => runProcess(...args)),
    realpath, uid: process.getuid?.() ?? -1 },
): Promise<string[]> {
  const desktop = processes.find(value => value.pid === pid && isCodexDesktop(value));
  if (!desktop?.processStartToken || io.uid < 0) return [];
  const bundle = path.dirname(path.dirname(desktop.command));
  const executables = [path.join(bundle, "Resources/codex"),
    path.join(bundle, "Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")];
  // Only a packaged backend directly owned by the bound GUI can grant Desktop
  // presence. Shells, tool children, TUI clients and shared daemons cannot.
  const backends = processes.filter(value => value.parentPID === pid && !value.tty
    && executables.includes(value.command));
  if (!backends.length || backends.length > 16) return [];
  const expected = [desktop, ...backends];
  const ids = expected.map(value => value.pid).join(",");
  const metadata = async () => {
    const result = await io.run("/bin/ps", ["-p", ids, "-o", "pid=,ppid=,uid=,tty=,lstart=,comm="],
      { deadlineMs: 1_000, maxOutputBytes: 64 * 1024, env: { ...process.env, LC_ALL: "C" } });
    if (result.status !== "success") return undefined;
    const found = new Map<number, string>();
    for (const line of result.stdout.split("\n").filter(line => line.trim())) {
      const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+\s+\d{4})\s+(.+)$/.exec(line);
      if (!match) return undefined;
      const record = expected.find(value => value.pid === Number(match[1]));
      if (!record || found.has(record.pid) || record.parentPID !== Number(match[2])
        || Number(match[3]) !== io.uid || !["?", "??", "-"].includes(match[4]!)
        || match[6] !== record.command) return undefined;
      if (record.pid === pid && processInstanceToken(pid, match[5]) !== desktop.processStartToken) return undefined;
      found.set(record.pid, line.trim());
    }
    return found.size === expected.length ? found : undefined;
  };
  try {
    const before = await metadata();
    if (!before) return [];
    const result = await io.run("/usr/sbin/lsof", ["-nP", "-a", "-p", backends.map(value => value.pid).join(","), "-F0pfatn"],
      { deadlineMs: 1_000, maxOutputBytes: 1024 * 1024 });
    if (result.status !== "success" || !result.stdout.endsWith("\0\n")) return [];
    const candidates = writableFiles(result.stdout, new Set(backends.map(value => value.pid)));
    if (!candidates) return [];
    const root = path.join(await io.realpath(home), "sessions") + path.sep;
    const files = new Set<string>();
    for (const candidate of candidates) {
      if (/[\u0000-\u001f]/.test(candidate) || !path.isAbsolute(candidate)) continue;
      if (!/^rollout-\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}\.jsonl$/i.test(path.basename(candidate))) continue;
      const canonical = await io.realpath(candidate).catch(() => undefined);
      if (canonical?.startsWith(root)) files.add(canonical);
    }
    const after = await metadata();
    if (!after || expected.some(value => before.get(value.pid) !== after.get(value.pid))) return [];
    return [...files];
  } catch {
    return [];
  }
}

function writableFiles(output: string, allowed: Set<number>): string[] | undefined {
  const files: string[] = [];
  let owned = false;
  let fd: string | undefined, access: string | undefined, type: string | undefined, name: string | undefined;
  const finish = () => {
    if (owned && /^\d+$/.test(fd ?? "") && ["u", "w"].includes(access ?? "") && type === "REG" && name) files.push(name);
    fd = access = type = name = undefined;
  };
  // NUL fields preserve boundaries even for filenames containing newlines.
  for (const raw of output.split("\0")) {
    const field = raw.replace(/^\n/, "");
    if (!field) continue;
    const value = field.slice(1);
    switch (field[0]) {
      case "p":
        finish();
        if (!/^\d+$/.test(value) || !allowed.has(Number(value))) return undefined;
        owned = true;
        break;
      case "f": finish(); fd = value; break;
      case "a": access = value; break;
      case "t": type = value; break;
      case "n": name = value; break;
      default: return undefined;
    }
  }
  finish();
  return files;
}
