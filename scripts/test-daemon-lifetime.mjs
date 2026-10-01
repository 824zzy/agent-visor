import assert from "node:assert/strict";
import { fork } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const entry = fileURLToPath(new URL("../packages/server/dist/bin.js", import.meta.url));
for (const phase of ["startup", "ready"]) {
  const root = await mkdtemp(path.join(os.tmpdir(), "av-owned-daemon-"));
  const env = {
    ...process.env,
    HOME: root, CODEX_HOME: path.join(root, "codex"), CLAUDE_CONFIG_DIR: path.join(root, "claude"),
    AGENT_VISOR_DATA_DIR: path.join(root, "data"),
    AGENT_VISOR_HOOK_SOCKET: path.join(root, "hook.sock"),
    AGENT_VISOR_SETTINGS_DOMAIN: "com.agentvisor.DaemonLifetimeTests",
    AGENT_VISOR_PORT: "0", ELECTRON_RUN_AS_NODE: "1",
  };
  delete env.AGENT_VISOR_NATIVE_HELPER;
  delete env.AGENT_VISOR_TOKEN;
  const child = fork(entry, [], { env, stdio: ["ignore", "pipe", "pipe", "ipc"] });
  const exited = once(child, "exit");
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${phase}: daemon failed to exit`)), 12_000);
  });
  try {
    if (phase === "ready") {
      const [message] = await Promise.race([once(child, "message"), deadline]);
      assert.equal(message.type, "ready");
    }
    child.disconnect();
    const [code, signal] = await Promise.race([exited, deadline]);
    assert.equal(code, 0, `${phase}: clean shutdown`);
    assert.equal(signal, null);
    await assert.rejects(stat(env.AGENT_VISOR_HOOK_SOCKET), { code: "ENOENT" });
    await assert.rejects(stat(path.join(root, "data/alfred/s.sock")), { code: "ENOENT" });
    console.log(`Daemon ownership PASS: disconnect during ${phase}, exit, socket cleanup.`);
  } finally {
    clearTimeout(timer);
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
      await exited;
    }
    await rm(root, { recursive: true, force: true });
  }
}
