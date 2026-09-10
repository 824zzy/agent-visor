import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { LiveProviderEnvironment } from "./environment.js";

describe("macOS process discovery", () => {
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
        expect(await environment.processes()).toContain(record);
      } finally {
        child.stdin.end();
        const timeout = setTimeout(() => child.kill("SIGKILL"), 2_000);
        try { expect(await exited).toEqual([0, null]); } finally { clearTimeout(timeout); }
      }
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
