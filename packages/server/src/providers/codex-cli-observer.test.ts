import { chmod, mkdtemp, mkdir, open, readFile, rm, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { readCodexCliObservation } from "./codex-cli-observer.js";
import { processInstanceToken } from "./shared.js";

const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });

it.each(["writable", "symlink", "oversized", "wrong-owner"])("rejects an unsafe observer file (%s)", async change => {
  const home = await mkdtemp(path.join(os.tmpdir(), "av-observer-file-")); roots.push(home);
  const directory = path.join(home, "agent-visor/cli"); await mkdir(directory, { recursive: true });
  const file = path.join(directory, "42.json");
  await writeFile(file, JSON.stringify({ version: 1, sessionId: "11111111-1111-4111-8111-111111111111",
    pid: 42, tty: "ttys001", cwd: "/fixture", home, observedAt: "2026-10-20T03:00:01Z",
    processStartToken: processInstanceToken(42, "2026-10-20T03:00:00Z"), ended: false }), { mode: 0o600 });
  if (change === "writable") await chmod(file, 0o666);
  if (change === "oversized") await writeFile(file, " ".repeat(16 * 1024 + 1));
  if (change === "symlink") {
    const destination = path.join(home, "record.json"); await writeFile(destination, await readFile(file));
    await rm(file); await symlink(destination, file);
  }
  const files = { open: async (...args: Parameters<typeof open>) => {
    const handle = await open(...args);
    if (change === "wrong-owner") {
      const stat = handle.stat.bind(handle);
      handle.stat = (async () => Object.assign(await stat(), { uid: (process.getuid?.() ?? 0) + 1 })) as typeof handle.stat;
    }
    return handle;
  } };
  expect(await readCodexCliObservation(42, home, files)).toBeUndefined();
});
