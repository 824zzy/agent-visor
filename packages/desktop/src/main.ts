import { spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow } from "electron";
import { daemonUrlFromReadyMessage, rendererLocation } from "./desktop-contract.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
let daemon: ChildProcess | undefined;
let mainWindow: BrowserWindow | undefined;

app.setName("Agent Visor Next");

app.on("before-quit", () => daemon?.kill("SIGTERM"));
app.on("window-all-closed", () => app.quit());

void app.whenReady()
  .then(async () => {
    const daemonResult = await startDaemon();
    daemon = daemonResult.process;
    mainWindow = await createMainWindow(daemonResult.url);
  })
  .catch((error: unknown) => {
    console.error(error);
    app.quit();
  });

async function createMainWindow(daemonUrl: string): Promise<BrowserWindow> {
  const window = new BrowserWindow({
    width: 1040,
    height: 760,
    minWidth: 760,
    minHeight: 520,
    backgroundColor: "#f1f2f7",
    title: "Agent Visor Next",
    titleBarStyle: "hiddenInset",
    webPreferences: {
      additionalArguments: [`--agent-visor-daemon=${daemonUrl}`],
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.resolve(directory, "preload.cjs"),
      sandbox: true,
    },
  });

  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  const rendererBase = process.env.AGENT_VISOR_RENDERER_URL
    ?? path.resolve(directory, "../../app/dist/index.html");
  const location = rendererLocation(rendererBase);
  if (location.kind === "url") {
    await window.loadURL(location.value);
  } else {
    await window.loadFile(location.path);
  }
  return window;
}

async function startDaemon(): Promise<{ process: ChildProcess; url: string }> {
  const entry = path.resolve(directory, "../../server/dist/bin.js");
  const child = spawn(process.execPath, [entry], {
    env: {
      ...process.env,
      AGENT_VISOR_PORT: "0",
      AGENT_VISOR_TOKEN: randomBytes(32).toString("base64url"),
      ELECTRON_RUN_AS_NODE: "1",
    },
    stdio: ["ignore", "pipe", "pipe", "ipc"],
  });
  child.stdout?.on("data", (data) => process.stdout.write(data));
  child.stderr?.on("data", (data) => process.stderr.write(data));

  return await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error("The Agent Visor daemon did not start within 10 seconds."));
    }, 10_000);

    child.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.once("exit", (code) => {
      clearTimeout(timeout);
      reject(new Error(`The Agent Visor daemon exited before startup (${code ?? "signal"}).`));
    });
    child.on("message", (message) => {
      const url = daemonUrlFromReadyMessage(message);
      if (!url) return;
      clearTimeout(timeout);
      resolve({ process: child, url });
    });
  });
}
