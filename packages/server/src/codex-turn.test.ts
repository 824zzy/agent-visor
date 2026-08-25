import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { codexPendingAction, codexResponseFor, sendCodexTurn } from "./codex-turn.js";

const roots: string[] = [];
const originalBinary = process.env.CODEX_BINARY;

afterEach(async () => {
  if (originalBinary === undefined) delete process.env.CODEX_BINARY;
  else process.env.CODEX_BINARY = originalBinary;
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("Codex turn delivery", () => {
  it("maps approval and question requests without guessing provider vocabulary", () => {
    expect(codexPendingAction("item/commandExecution/requestApproval", {
      itemId: "command-1", command: "npm test",
    })).toMatchObject({ type: "approval", toolUseId: "codex-command-1", toolName: "Command" });
    expect(codexResponseFor(7, "item/commandExecution/requestApproval", {}, {
      type: "respond_chat", id: "reply-1", sessionId: "thread-1",
      toolUseId: "codex-command-1", decision: "allow_always",
    })).toEqual({ id: 7, result: { decision: "acceptForSession" } });
    expect(codexResponseFor(8, "item/permissions/requestApproval", {
      permissions: { network: { enabled: true } },
    }, {
      type: "respond_chat", id: "reply-2", sessionId: "thread-1",
      toolUseId: "codex-permissions", decision: "deny",
    })).toEqual({
      id: 8,
      result: { permissions: {}, scope: "turn", strictAutoReview: false },
    });
    expect(codexPendingAction("unknown/request", {})).toBeUndefined();
  });

  it("initializes, resumes the exact thread, and starts one text and image turn", async () => {
    const parent = path.resolve("build/test-codex-turn");
    await mkdir(parent, { recursive: true });
    const root = await mkdtemp(path.join(parent, "run-"));
    roots.push(root);
    const log = path.join(root, "requests.jsonl");
    const executable = path.join(root, "codex.cjs");
    await writeFile(executable, `#!/usr/bin/env node
const fs=require('node:fs'),readline=require('node:readline');
const log=process.env.AGENT_VISOR_CODEX_TEST_LOG;
readline.createInterface({input:process.stdin}).on('line',line=>{
  fs.appendFileSync(log,line+'\\n');
  const m=JSON.parse(line);
  if(m.id) {
    process.stdout.write(JSON.stringify({id:m.id,result:{}})+'\\n');
    if(m.id===3) process.stdout.write(JSON.stringify({method:'turn/completed',params:{}})+'\\n');
  }
});
`, { mode: 0o700 });
    await chmod(executable, 0o700);
    process.env.CODEX_BINARY = executable;
    process.env.AGENT_VISOR_CODEX_TEST_LOG = log;

    await sendCodexTurn("019f3931-ec11-7f31-8400-1c8624aa9e4d", "Fix it", ["/tmp/pixel.png"]);

    const messages = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    expect(messages.map((message) => message.method)).toEqual([
      "initialize", "initialized", "thread/resume", "turn/start",
    ]);
    expect(messages[2].params.threadId).toBe("019f3931-ec11-7f31-8400-1c8624aa9e4d");
    expect(messages[3].params.input).toEqual([
      { type: "text", text: "Fix it" },
      { type: "localImage", path: "/tmp/pixel.png" },
    ]);
  });
});
