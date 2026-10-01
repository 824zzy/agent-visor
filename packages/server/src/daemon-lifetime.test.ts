import { fork, spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

const roots: string[] = [];
const children: ChildProcess[] = [];
afterEach(async () => {
  for (const child of children.splice(0)) {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.kill("SIGKILL");
      await exited;
    }
  }
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function launch(mode: string, ipc = true) {
  const root = await mkdtemp(path.join(os.tmpdir(), "av-lifetime-"));
  roots.push(root);
  const receipt = path.join(root, "cleanup");
  const entry = path.join(root, "fixture.mjs");
  const source = fileURLToPath(new URL("./daemon-lifetime.ts", import.meta.url));
  await writeFile(entry, `
    import { appendFile } from 'node:fs/promises';
    const delay = ms => new Promise(r => setTimeout(r, ms));
    const announce = () => process.connected ? process.send('stage') : console.log('stage');
    if (${JSON.stringify(mode)} === 'before-import') { announce(); await delay(200); }
    const { runDaemon } = await import(${JSON.stringify(source)});
    await runDaemon(async lifetime => {
      lifetime.onStop(async () => {
        await appendFile(${JSON.stringify(receipt)}, 'cleanup\\n');
        if (${JSON.stringify(mode)} === 'cleanup-hang') await new Promise(() => {});
        if (${JSON.stringify(mode)} === 'cleanup-error') throw new Error('fixture cleanup');
      });
      announce();
      if (${JSON.stringify(mode)} === 'startup-hang') await new Promise(() => {});
      if (${JSON.stringify(mode)} === 'startup') await delay(200);
      if (lifetime.stopping) return;
      if (${JSON.stringify(mode)} === 'startup-error') throw new Error('fixture startup');
      setInterval(() => {}, 1000);
    }, 700);
  `);
  const child = ipc
    ? fork(entry, [], { execArgv: ["--experimental-strip-types"], stdio: ["ignore", "pipe", "pipe", "ipc"] })
    : spawn(process.execPath, ["--experimental-strip-types", entry], { stdio: ["ignore", "pipe", "pipe"] });
  children.push(child);
  const exited = once(child, "exit");
  await (ipc ? once(child, "message") : once(child.stdout!, "data"));
  return { child, exited, receipt };
}

describe("desktop-owned daemon lifetime (real child processes)", () => {
  it.each(["running", "startup"])("closes once after disconnect during %s", async (mode) => {
    const { child, exited, receipt } = await launch(mode);
    child.disconnect();
    expect((await exited)[0]).toBe(0);
    expect(await readFile(receipt, "utf8")).toBe("cleanup\n");
  });
  it("does not start after the parent disconnected during module loading", async () => {
    const { child, exited, receipt } = await launch("before-import");
    child.disconnect();
    expect((await exited)[0]).toBe(0);
    await expect(readFile(receipt)).rejects.toMatchObject({ code: "ENOENT" });
  });
  it.each(["startup-hang", "cleanup-hang", "cleanup-error"])("bounds %s after disconnect", async (mode) => {
    const { child, exited } = await launch(mode);
    child.disconnect();
    expect((await exited)[0]).toBe(1);
  });
  it("cleans partially acquired resources after a startup failure", async () => {
    const { exited, receipt } = await launch("startup-error");
    expect((await exited)[0]).toBe(1);
    expect(await readFile(receipt, "utf8")).toBe("cleanup\n");
  });
  it("keeps standalone mode alive and cleans up once on repeated signals", async () => {
    const { child, exited, receipt } = await launch("startup", false);
    expect(child.exitCode).toBeNull();
    child.kill("SIGTERM");
    child.kill("SIGINT");
    expect((await exited)[0]).toBe(0);
    expect(await readFile(receipt, "utf8")).toBe("cleanup\n");
  });
});
