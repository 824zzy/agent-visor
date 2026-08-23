import { spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  app,
  BrowserWindow,
  ipcMain,
  Menu,
  Notification,
  shell,
  type MenuItemConstructorOptions,
} from "electron";
import {
  daemonUrlFromReadyMessage,
  electronDataName,
  nativeActionFromDaemonMessage,
  nativeEffectFromDaemonMessage,
  ownerApplication,
  productName,
  rendererLocation,
} from "./desktop-contract.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
let daemon: ChildProcess | undefined;
let mainWindow: BrowserWindow | undefined;
let nativeActionQueue = Promise.resolve();

// Keep Electron data separate from the Swift rollback application.
app.setName(electronDataName);

app.on("before-quit", () => daemon?.kill("SIGTERM"));
app.on("window-all-closed", () => app.quit());
ipcMain.on("session:open-owner", (event, owner: unknown) => {
  if (event.sender !== mainWindow?.webContents || typeof owner !== "string") return;
  const application = ownerApplication(owner);
  if (!application) return;
  void openApplication(application);
});

void app.whenReady()
  .then(async () => {
    const daemonResult = await startDaemon();
    daemon = daemonResult.process;
    mainWindow = await createMainWindow(daemonResult.url);
    configureApplicationMenu();
  })
  .catch((error: unknown) => {
    console.error(error);
    app.quit();
  });

async function createMainWindow(daemonUrl: string): Promise<BrowserWindow> {
  const window = new BrowserWindow({
    width: 1040,
    height: 760,
    minWidth: 960,
    minHeight: 680,
    backgroundColor: "#eff1f5",
    title: productName,
    titleBarStyle: "hiddenInset",
    webPreferences: {
      additionalArguments: [`--agent-visor-daemon=${daemonUrl}`],
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.resolve(directory, "preload.cjs"),
      sandbox: true,
    },
  });

  window.once("closed", () => {
    daemon?.kill("SIGTERM");
    app.exit(0);
  });
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  const rendererBase = process.env.AGENT_VISOR_RENDERER_URL
    ?? path.resolve(directory, "../../app/dist/index.html");
  const location = rendererLocation(rendererBase);
  if (location.kind === "url") {
    await window.webContents.session.clearCache();
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
      AGENT_VISOR_NATIVE_HELPER: process.env.AGENT_VISOR_NATIVE_HELPER
        ?? path.join(process.resourcesPath, "AgentVisorNativeHelper"),
      AGENT_VISOR_DATA_DIR: app.getPath("userData"),
      AGENT_VISOR_SETTINGS_DOMAIN: app.isPackaged
        ? "com.824zzy.AgentVisor"
        : "com.824zzy.AgentVisor.Dev",
      AGENT_VISOR_VERSION: productVersion(),
      ...(app.isPackaged
        ? { AGENT_VISOR_LAUNCH_AT_LOGIN: String(app.getLoginItemSettings().openAtLogin) }
        : {}),
    },
    stdio: ["ignore", "pipe", "pipe", "ipc"],
  });
  child.stdout?.on("data", (data) => process.stdout.write(data));
  child.stderr?.on("data", (data) => process.stderr.write(data));
  child.on("message", (message) => {
    const effect = nativeEffectFromDaemonMessage(message);
    if (effect) {
      if (effect.action === "set_login_item") {
        if (app.isPackaged) app.setLoginItemSettings({ openAtLogin: effect.enabled });
      } else if (effect.action === "open_update") {
        void shell.openExternal(effect.url);
      } else if (effect.action === "request_notifications") {
        if (Notification.isSupported()) {
          new Notification({ title: productName, body: "Notifications are ready." }).show();
        }
        void shell.openExternal(
          "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        );
      } else if (Notification.isSupported()) {
        const notification = new Notification({
          title: effect.notification.title,
          body: effect.notification.body,
          silent: effect.notification.sound === "None",
          ...(effect.notification.sound === "None" ? {} : { sound: effect.notification.sound }),
        });
        notification.once("click", () => queueOwnerActivation(effect.notification.owner));
        notification.show();
      }
      return;
    }
    const action = nativeActionFromDaemonMessage(message);
    if (!action) return;
    nativeActionQueue = nativeActionQueue
      .then(async () => {
        if (action.action === "open_sessions") {
          navigateRenderer({ page: "sessions" });
          return;
        }
        if (action.action === "open_chat") {
          navigateRenderer({ page: "chat", sessionId: action.sessionId });
          return;
        }
        if (action.action === "open_session_url") {
          await shell.openExternal(action.url);
          return;
        }
        const application = ownerApplication(action.owner);
        if (application) await openApplication(application);
      })
      .catch((error: unknown) => console.error(error));
  });

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

type RendererNavigation =
  | { page: "sessions" }
  | { page: "settings"; checkUpdates?: boolean }
  | { page: "chat"; sessionId: string }
  | { page: "scale"; delta: -0.1 | 0 | 0.1 };

function navigateRenderer(action: RendererNavigation): void {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.show();
  mainWindow.focus();
  mainWindow.webContents.send("app:navigate", action);
}

function configureApplicationMenu(): void {
  const template: MenuItemConstructorOptions[] = [
    {
      label: productName,
      submenu: [
        { role: "about" },
        { label: "Check for Updates…", click: () => navigateRenderer({ page: "settings", checkUpdates: true }) },
        { type: "separator" },
        { label: "Settings…", accelerator: "CommandOrControl+,", click: () => navigateRenderer({ page: "settings" }) },
        { type: "separator" },
        { role: "services" },
        { type: "separator" },
        { role: "hide" },
        { role: "hideOthers" },
        { role: "unhide" },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    { role: "editMenu" },
    {
      label: "View",
      submenu: [
        { label: "Zoom In", accelerator: "CommandOrControl+Plus", click: () => navigateRenderer({ page: "scale", delta: 0.1 }) },
        { label: "Zoom Out", accelerator: "CommandOrControl+-", click: () => navigateRenderer({ page: "scale", delta: -0.1 }) },
        { label: "Actual Size", accelerator: "CommandOrControl+0", click: () => navigateRenderer({ page: "scale", delta: 0 }) },
        { type: "separator" },
        { role: "togglefullscreen" },
      ],
    },
    { role: "windowMenu" },
    {
      role: "help",
      submenu: [{
        label: "Agent Visor Help",
        click: () => void shell.openExternal("https://github.com/824zzy/agent-visor"),
      }],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function queueOwnerActivation(owner: string): void {
  const application = ownerApplication(owner);
  if (!application) return;
  nativeActionQueue = nativeActionQueue
    .then(() => openApplication(application))
    .catch((error: unknown) => console.error(error));
}

function productVersion(): string {
  if (app.isPackaged) return app.getVersion();
  try {
    const value = JSON.parse(readFileSync(path.resolve(directory, "../../../package.json"), "utf8"));
    return typeof value.version === "string" ? value.version : "0.0.0";
  } catch {
    return "0.0.0";
  }
}

async function openApplication(application: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn("/usr/bin/open", ["-a", application], { stdio: "ignore" });
    const deadline = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`Opening ${application} timed out.`));
    }, 5_000);
    child.once("error", (error) => {
      clearTimeout(deadline);
      reject(error);
    });
    child.once("close", (code) => {
      clearTimeout(deadline);
      code === 0 ? resolve() : reject(new Error(`Opening ${application} failed.`));
    });
  });
}
