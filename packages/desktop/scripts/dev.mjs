import { spawn, spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(directory, "../../..");

const helperBuild = spawnSync("./scripts/build-native-helper.sh", [], {
  cwd: root,
  encoding: "utf8",
  stdio: "inherit",
});
if (helperBuild.status !== 0) process.exit(helperBuild.status ?? 1);
const helperExecutable = path.join(
  root,
  "build/native-helper/Agent Visor Native Helper.app/Contents/MacOS/AgentVisorNativeHelper",
);

for (const workspace of ["@agent-visor/protocol", "@agent-visor/server", "@agent-visor/desktop"]) {
  const result = spawnSync("npm", ["run", "build", `--workspace=${workspace}`], {
    cwd: root,
    encoding: "utf8",
    stdio: "inherit",
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

const expo = spawn("npm", ["run", "dev", "--workspace=@agent-visor/app"], {
  cwd: root,
  env: { ...process.env, BROWSER: "none" },
  stdio: "inherit",
});

await waitFor("http://127.0.0.1:8081", 60_000);

const electron = spawn(path.join(root, "node_modules/.bin/electron"), ["packages/desktop/dist/main.js"], {
  cwd: root,
  env: {
    ...process.env,
    AGENT_VISOR_RENDERER_URL: "http://127.0.0.1:8081",
    AGENT_VISOR_NATIVE_HELPER: helperExecutable,
  },
  stdio: "inherit",
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => electron.kill(signal));
}

electron.once("exit", (code) => {
  expo.kill("SIGTERM");
  process.exitCode = code ?? 0;
});

async function waitFor(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch {
      // Expo is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  expo.kill("SIGTERM");
  throw new Error(`Expo did not start within ${timeoutMs / 1000} seconds.`);
}
