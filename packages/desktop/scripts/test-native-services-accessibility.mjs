import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow } from "electron";
import { startServer } from "../../server/dist/server.js";
import { fixtureSnapshot } from "../../server/dist/fixture.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const token = "native-services-test-token-000000000000000000000";

void app.whenReady().then(run).then(() => app.exit(0)).catch((error) => {
  console.error(error);
  app.exit(1);
});

async function run() {
  let state = {
    type: "native_services_state",
    revision: 1,
    settings: {
      appearance: "dark", contentScale: 1, pillsEnabled: true,
      codexUsageGlanceEnabled: true, claudeUsageGlanceEnabled: false,
      notificationSound: "Pop", sessionShortcutModifierFamily: "optionCommand",
      editorPreference: "auto", observedWindowHours: 42, launchAtLogin: false,
    },
    permissions: { accessibility: "needed", notifications: "not_determined" },
    update: { status: "idle", currentVersion: "2.6.2" },
  };
  const subscribers = new Set();
  const actions = [];
  const nativeServices = {
    current: () => structuredClone(state),
    subscribe: (listener) => {
      subscribers.add(listener);
      return () => subscribers.delete(listener);
    },
    action: async (message) => {
      actions.push(message);
      if (message.type === "update_settings") {
        state = {
          ...state,
          revision: state.revision + 1,
          settings: { ...state.settings, ...message.patch },
        };
        for (const subscriber of subscribers) subscriber(state);
      }
      return undefined;
    },
  };
  const server = await startServer({ port: 0, token, snapshot: fixtureSnapshot, nativeServices });
  const window = new BrowserWindow({
    show: false,
    width: 1_040,
    height: 760,
    webPreferences: {
      additionalArguments: [`--agent-visor-daemon=${server.url}`],
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.resolve(directory, "../dist/preload.cjs"),
      sandbox: true,
    },
  });

  try {
    await window.loadFile(path.resolve(directory, "../../app/dist/index.html"));
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Settings"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Settings"]').click()`);
    await waitFor(window, `document.body.textContent.includes('Launch at login')`);

    const labels = await window.webContents.executeJavaScript(`[
      'Back to Sessions', 'Launch at login, Off', 'Enable for Accessibility',
      'Enable for Notifications', 'Check now for Updates', 'Theme', 'Content size',
      'Show session pills, On', 'Show Codex usage, On', 'Session shortcuts',
      'Sound', 'Observed session window'
    ].every((label) => Boolean(document.querySelector('[aria-label="' + label + '"]'))
      || document.body.textContent.includes(label))`);
    assert(labels, "settings expose permissions, updates, appearance, pills, notifications, and agents");
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Show session pills, On"]')?.getAttribute('aria-checked') === 'true'`),
      "enabled settings expose the correct accessibility value",
    );

    await window.webContents.executeJavaScript(`[...document.querySelectorAll('[role="button"]')]
      .find((item) => item.textContent === 'light')?.click()`);
    await waitUntil(() => actions.some((message) =>
      message.type === "update_settings" && message.patch.appearance === "light"));
    await waitFor(window, `[...document.querySelectorAll('*')].some((item) =>
      getComputedStyle(item).backgroundColor === 'rgb(247, 247, 250)')`);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Enable for Accessibility"]').click()`);
    await waitUntil(() => actions.some((message) =>
      message.type === "native_service_action" && message.action === "request_accessibility"));

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]').click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Search sessions"]'))`);

    console.log("Native services accessibility PASS: settings, permissions, updates, persistence messages, theme, and Back.");
  } finally {
    window.destroy();
    await server.close();
  }
}

function assert(value, message) {
  if (!value) throw new Error(`Native services accessibility failed: ${message}`);
}

async function waitFor(window, expression) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    if (await window.webContents.executeJavaScript(`Boolean(${expression})`)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for ${expression}`);
}

async function waitUntil(condition) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error("Timed out waiting for native service action.");
}
