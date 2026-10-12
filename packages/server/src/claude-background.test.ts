import { execFile } from "node:child_process";
import { mkdtemp, mkdir, realpath, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { expect, it } from "vitest";
import { claudeAttachCommand } from "./claude-background.js";

it("opens an exact job with client titles enabled while preserving quoted paths and other launch settings", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-attach-test-"));
  const cwd = path.join(root, 'it\'s "here"');
  const executable = path.join(root, "claude 'test'");
  try {
    await mkdir(cwd);
    // A harmless executable at the OS boundary; never invokes Claude or a real terminal.
    await writeFile(executable, [
      "#!/bin/sh",
      'printf "%s\\n" "${CLAUDE_CODE_DISABLE_TERMINAL_TITLE-unset}" "$AV_ATTACH_TEST_MARKER" "$1" "$2" "$PWD"',
    ].join("\n"), { mode: 0o700 });
    const { stdout } = await promisify(execFile)("/bin/zsh", ["-c", claudeAttachCommand({
      cwd, executable, jobId: "8e45ed2c", application: "Terminal",
    })], {
      cwd, timeout: 5_000,
      env: { ...process.env, CLAUDE_CODE_DISABLE_TERMINAL_TITLE: "true", AV_ATTACH_TEST_MARKER: "preserved" },
    });
    expect(stdout.trim().split("\n")).toEqual(["unset", "preserved", "attach", "8e45ed2c", await realpath(cwd)]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
