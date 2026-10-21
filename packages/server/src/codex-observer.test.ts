import { spawn } from "node:child_process";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { readCodexCliObservation } from "./providers/codex-cli-observer.js";
import { processInstanceToken } from "./providers/shared.js";

const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });
const id = "11111111-1111-4111-8111-111111111111";

it("retains only CLI identity when an observer runs beneath a hook shell while Agent Visor is offline", async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), "av-codex-observer-"))); roots.push(root);
  const home = path.join(root, ".codex");
  const child = spawn("python3", ["-c", `
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
hook.SOCKET_PATH = sys.argv[2]
# The subprocess boundary describes the native frontend plus its hook shell.
hook.subprocess.run = lambda *args, **kwargs: subprocess.CompletedProcess(args, 0,
    stdout=f"42 7 Tue Oct 20 03:00:00 2026 ttys001 /bin/codex\\n{os.getppid()} 42 Tue Oct 20 03:00:01 2026 ?? /bin/sh\\n", stderr="")
hook.main()
`, path.resolve("../../AgentVisor/Resources/agent-visor-codex-state.py"), path.join(root, "offline.sock")],
  { env: { ...process.env, HOME: root, CODEX_HOME: home, CODEX_THREAD_ID: "" } });
  child.stdin.end(JSON.stringify({ hook_event_name: "UserPromptSubmit", thread_id: id, cwd: "/fixture/Agent Room",
    transcript_path: path.join(home, `sessions/${id}.jsonl`), prompt: "PRIVATE PROMPT MUST NOT BE SAVED" }));
  await new Promise<void>((resolve, reject) => {
    child.once("error", reject); child.once("exit", code => code === 0 ? resolve() : reject(new Error(`observer exit ${code}`)));
  });
  const raw = await readFile(path.join(home, "agent-visor/cli/42.json"), "utf8");
  expect(JSON.parse(raw)).toMatchObject({ version: 1, sessionId: id, pid: 42, tty: "ttys001", home,
    cwd: "/fixture/Agent Room", processStartToken: processInstanceToken(42, "2026-10-20T03:00:00Z"), ended: false });
  expect(raw).not.toContain("PRIVATE PROMPT");
  expect(await readCodexCliObservation(42, home)).toEqual(JSON.parse(raw));
});
