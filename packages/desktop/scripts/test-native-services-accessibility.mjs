import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow } from "electron";
import { startServer } from "../../server/dist/server.js";
import { fixtureSnapshot } from "../../server/dist/fixture.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const token = "native-services-test-token-000000000000000000000";
const profileRoot = mkdtempSync(path.join(os.tmpdir(), "agent-visor-clean-profile-"));
app.setPath("userData", profileRoot);

void app.whenReady().then(run).then(() => {
  rmSync(profileRoot, { recursive: true, force: true });
  app.exit(0);
}).catch((error) => {
  console.error(error);
  rmSync(profileRoot, { recursive: true, force: true });
  app.exit(1);
});

async function run() {
  let state = {
    type: "native_services_state",
    revision: 1,
    settings: {
      appearance: "dark", contentScale: 1, pillsEnabled: true,
      pillScreen: { mode: "automatic" }, fullScreenPolicy: "onDemand",
      codexUsageGlanceEnabled: true, claudeUsageGlanceEnabled: false,
      notificationSound: "Pop", hotkeyTrigger: "shift", customHotkeyCombo: null,
      sessionShortcutModifierFamily: "optionCommand", editorPreference: "auto",
      observedWindowHours: 42, launchAtLogin: false,
    },
    permissions: { accessibility: "needed", notifications: "not_determined" },
    agents: [
      { id: "claude", name: "Claude Code", available: true, installed: false, control: "toggle" },
      { id: "pi", name: "Pi", available: true, installed: true, control: "automatic" },
    ],
    pillScreens: [
      { displayId: 1, name: "Built-in Retina Display", isBuiltIn: true, isMain: true },
      { displayId: 5, name: "XZ322QU V3", isBuiltIn: false, isMain: false },
    ],
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
      } else if (message.type === "set_agent_connection") {
        state = {
          ...state,
          revision: state.revision + 1,
          agents: state.agents.map((agent) => agent.id === message.agent
            ? { ...agent, installed: message.enabled } : agent),
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
      'Enable for Notifications', 'Check now for Updates', 'General', 'Appearance',
      'Pills', 'Notifications', 'Agents'
    ].every((label) => Boolean(document.querySelector('[aria-label="' + label + '"]'))
      || document.body.textContent.includes(label))`);
    assert(labels, "settings expose native categories, permissions, and updates");

    await clickButton(window, "Appearance");
    await waitFor(window, `document.body.textContent.includes('Content size')`);
    await clickButton(window, "Light");
    await waitUntil(() => actions.some((message) =>
      message.type === "update_settings" && message.patch.appearance === "light"));
    await waitFor(window, `[...document.querySelectorAll('*')].some((item) =>
      getComputedStyle(item).backgroundColor === 'rgb(239, 241, 245)')`);

    await clickButton(window, "Pills");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Show session pills, On"]'))`);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Show session pills, On"]')?.getAttribute('aria-checked') === 'true'`),
      "enabled settings expose the correct accessibility value",
    );
    await waitFor(window, `document.body.textContent.includes('Pill screen')
      && document.body.textContent.includes('Full-screen visibility')`);
    await clickButton(window, "XZ322QU V3");
    await waitUntil(() => actions.some((message) => message.type === "update_settings"
      && message.patch.pillScreen?.displayId === 5));
    await clickButton(window, "Always hide");
    await waitUntil(() => actions.some((message) => message.type === "update_settings"
      && message.patch.fullScreenPolicy === "alwaysHide"));
    await clickButton(window, "Notifications");
    await waitFor(window, `document.body.textContent.includes('Sound')`);
    await clickButton(window, "Agents");
    await waitFor(window, `document.body.textContent.includes('Observed session window')`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Connect for Claude Code"]').click()`);
    await waitUntil(() => actions.some((message) => message.type === "set_agent_connection"
      && message.agent === "claude" && message.enabled));
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Disconnect for Claude Code"]'))`);
    await clickButton(window, "General");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Enable for Accessibility"]').click()`);
    await waitUntil(() => actions.some((message) =>
      message.type === "native_service_action" && message.action === "request_accessibility"));

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]').click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Search sessions"]'))`);

    const chatSession = fixtureSnapshot.sessions.find((session) => session.canEnterChat);
    assert(chatSession, "fixture provides a Chat session");
    window.webContents.send("app:navigate", { page: "chat", sessionId: chatSession.id });
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Back to Sessions"]'))`);
    window.webContents.send("app:navigate", { page: "sessions" });
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Search sessions"]'))`);
    window.webContents.send("app:navigate", { page: "settings" });
    await waitFor(window, `document.body.textContent.includes('Launch at login')`);

    console.log("Native services accessibility PASS: settings, agent connections, navigation, permissions, updates, theme, and Back.");
  } finally {
    window.destroy();
    await server.close();
  }
}

function assert(value, message) {
  if (!value) throw new Error(`Native services accessibility failed: ${message}`);
}

async function clickButton(window, label) {
  await window.webContents.executeJavaScript(`[...document.querySelectorAll('[role="button"]')]
    .find((item) => item.textContent?.trim() === ${JSON.stringify(label)})?.click()`);
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
