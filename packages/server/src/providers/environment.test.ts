import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { LiveProviderEnvironment } from "./environment.js";
import { processInstanceToken } from "./shared.js";

describe("macOS process discovery", () => {
  it.skipIf(process.platform !== "darwin")("discovers process identities under a non-English inherited locale", async () => {
    const previous = process.env.LC_ALL;
    process.env.LC_ALL = "de_DE.UTF-8";
    try {
      const environment = new LiveProviderEnvironment("/fixture");
      const record = (await environment.processesFresh()).find(value => value.pid === process.pid);
      expect(record?.processStartToken).toBeTypeOf("string");
      expect(process.env.LC_ALL).toBe("de_DE.UTF-8");
    } finally {
      if (previous === undefined) delete process.env.LC_ALL;
      else process.env.LC_ALL = previous;
    }
  });

  it.skipIf(process.platform !== "darwin")("preserves long executable paths with spaces and their arguments", async () => {
    const directory = mkdtempSync(path.join(tmpdir(), "agent-visor-process-"));
    try {
      const executable = path.join(directory, "Application Support", "Agent Visor Process Fixture", "long executable path", "worker");
      mkdirSync(path.dirname(executable), { recursive: true });
      // Copying Apple's /bin/sleep violates its macOS launch constraints. Build
      // a test-owned worker and require proof it actually started before ps.
      execFileSync("/usr/bin/cc", ["-x", "c", "-o", executable, "-"], {
        input: '#include <unistd.h>\nint main(void) { char c; if (write(1, "ready\\n", 6) != 6) return 1; return read(0, &c, 1) < 0; }\n',
        timeout: 10_000,
        stdio: ["pipe", "ignore", "pipe"],
      });
      const child = spawn(executable, ["fixture-argument"], { stdio: ["pipe", "pipe", "ignore"] });
      const exited = once(child, "exit");
      try {
        const [ready] = await Promise.race([
          once(child.stdout, "data"),
          exited.then(() => { throw new Error("The process fixture exited before readiness."); }),
        ]);
        expect(String(ready)).toBe("ready\n");
        const environment = new LiveProviderEnvironment(directory);
        const record = (await environment.processes()).find(p => p.pid === child.pid);
        expect(record).toMatchObject({ command: executable, parentPID: process.pid });
        expect(record?.arguments).toBe(`${executable} fixture-argument`);
        const startedAt = await environment.processStartedAt(child.pid!);
        expect(record?.processStartToken).toBeTypeOf("string");
        expect(record?.processStartToken).toBe(processInstanceToken(child.pid!, startedAt));
        const fresh = (await environment.processesFresh()).find(value => value.pid === child.pid);
        expect(fresh?.processStartToken).toBe(record?.processStartToken);
        expect(await environment.processes()).toContainEqual(record);
      } finally {
        child.stdin.end();
        const timeout = setTimeout(() => child.kill("SIGKILL"), 2_000);
        try { expect(await exited).toEqual([0, null]); } finally { clearTimeout(timeout); }
      }
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it.skipIf(process.platform !== "darwin")("clears cached cwd facts at the explicit fresh inventory boundary", async () => {
    const directory = mkdtempSync(path.join(tmpdir(), "agent-visor-process-fresh-"));
    const firstPath = path.join(directory, "first");
    const secondPath = path.join(directory, "second");
    mkdirSync(firstPath, { recursive: true });
    mkdirSync(secondPath, { recursive: true });
    const firstCWD = realpathSync(firstPath);
    const secondCWD = realpathSync(secondPath);
    const child = spawn("/usr/bin/python3", ["-c", [
      "import os, sys",
      "sys.stdout.write('ready\\n'); sys.stdout.flush()",
      "os.read(0, 1)",
      "os.chdir(sys.argv[2])",
      "sys.stdout.write('changed\\n'); sys.stdout.flush()",
      "os.read(0, 1)",
    ].join(";"), firstCWD, secondCWD], {
      cwd: firstCWD,
      stdio: ["pipe", "pipe", "ignore"],
    });
    const exited = once(child, "exit");
    try {
      const [ready] = await Promise.race([
        once(child.stdout, "data"),
        exited.then(() => { throw new Error("The cwd fixture exited before readiness."); }),
      ]);
      expect(String(ready)).toBe("ready\n");
      const environment = new LiveProviderEnvironment(directory);
      expect(await environment.cwd(child.pid!)).toBe(firstCWD);

      child.stdin.write("2");
      const [changed] = await once(child.stdout, "data");
      expect(String(changed)).toBe("changed\n");
      await environment.processesFreshInventory();

      expect(await environment.cwd(child.pid!)).toBe(secondCWD);
    } finally {
      child.stdin.end();
      const timeout = setTimeout(() => child.kill("SIGKILL"), 2_000);
      try { expect(await exited).toEqual([0, null]); } finally { clearTimeout(timeout); }
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
