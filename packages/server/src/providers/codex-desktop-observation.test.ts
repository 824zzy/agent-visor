import { describe, expect, it } from "vitest";
import { readCodexDesktopRollouts, type CodexDesktopIO } from "./codex-desktop.js";
import type { ProcessRecord } from "./environment.js";
import { processInstanceToken } from "./shared.js";

const desktop = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT";
const backend = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex";
const home = "/fixture/.codex";
const rollout = `${home}/sessions/2026/10/27/rollout-2026-10-27T18-18-19-01a18016-2d8e-7040-8f7d-7b2439671b7c.jsonl`;
const processes: ProcessRecord[] = [
  { pid: 100, parentPID: 1, command: desktop, arguments: desktop,
    processStartToken: processInstanceToken(100, "Tue Oct 27 18:10:48 2026") },
  { pid: 101, parentPID: 100, command: backend, arguments: `${backend} -c redacted app-server` },
];
const metadata = (pid: number, parent: number, command: string, start = "Tue Oct 27 18:10:48 2026") =>
  `${pid} ${parent} 501 ?? ${start} ${command}\n`;
const processTable = metadata(100, 1, desktop) + metadata(101, 100, backend);
const files = (access = "u", file = rollout) => `p101\0\nf89\0a${access}\0tREG\0n${file}\0\n`;

function fixture() {
  const calls: string[] = [];
  const io: CodexDesktopIO = {
    uid: 501,
    realpath: async value => String(value),
    run: async executable => {
      calls.push(executable);
      return { status: "success", exitCode: 0, stderr: "",
        stdout: executable === "/bin/ps" ? processTable : files() };
    },
  };
  return { io, calls };
}

describe("Codex Desktop runtime observation", () => {
  it("observes the exact writable transcript of the bound Desktop backend without navigation", async () => {
    const { io, calls } = fixture();
    expect(await readCodexDesktopRollouts(100, home, processes, io)).toEqual([rollout]);
    expect(calls).toEqual(["/bin/ps", "/usr/sbin/lsof", "/bin/ps"]);
  });

  it.each(["read-only", "foreign-home", "foreign-writer", "deleted", "malformed", "failed", "symlink", "pid-reused", "wrong-uid", "tty"])(
    "does not grant Desktop presence from %s evidence", async change => {
      const { io } = fixture();
      let reads = 0;
      const run = io.run;
      io.run = async (...args) => {
        const result = await run(...args);
        if (args[0] === "/bin/ps") {
          reads++;
          if (change === "pid-reused" && reads === 2) result.stdout = processTable.replace("18:10:48", "18:20:48");
          if (change === "wrong-uid") result.stdout = processTable.replaceAll("501", "502");
          if (change === "tty") result.stdout = processTable.replaceAll("??", "ttys001");
        } else {
          if (change === "read-only") result.stdout = files("r");
          if (change === "foreign-home") result.stdout = files("u", rollout.replace("/fixture", "/other"));
          if (change === "foreign-writer") result.stdout = files().replace("p101", "p102");
          if (change === "deleted") result.stdout = files("u", rollout + " (deleted)");
          if (change === "malformed") result.stdout = files().slice(0, -2);
          if (change === "failed") return { status: "timed_out", stdout: files(), stderr: "" };
        }
        return result;
      };
      if (change === "symlink") io.realpath = async value => String(value) === rollout ? rollout.replace("/fixture", "/other") : String(value);
      expect(await readCodexDesktopRollouts(100, home, processes, io)).toEqual([]);
    },
  );

  it("does not inspect terminal clients, shared servers or unrelated children as Desktop backends", async () => {
    const { io, calls } = fixture();
    expect(await readCodexDesktopRollouts(100, home, [processes[0]!,
      { ...processes[1]!, parentPID: 1 },
      { ...processes[1]!, pid: 102, tty: "ttys001" },
      { ...processes[1]!, pid: 103, command: "/bin/zsh" }], io)).toEqual([]);
    expect(calls).toEqual([]);
  });
});
