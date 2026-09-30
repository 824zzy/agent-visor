import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow } from "electron";
import { defaultChatVisibility } from "../../protocol/dist/index.js";
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
      pillScreen: { mode: "specific", displayId: 5, name: "DELL P3424WEB" },
      fullScreenPolicy: "onDemand",
      codexUsageGlanceEnabled: true, claudeUsageGlanceEnabled: false,
      codexHomes: [], ignoredCodexHomes: [],
      notificationSound: "Pop", hotkeyTrigger: "shift", customHotkeyCombo: null,
      sessionShortcutModifierFamily: "optionCommand", editorPreference: "auto",
      observedWindowHours: 42, launchAtLogin: false,
      chatVisibility: { ...defaultChatVisibility },
    },
    permissions: { accessibility: "needed", notifications: "not_determined" },
    agents: [
      { id: "claude", name: "Claude Code", available: true, installed: false, control: "toggle" },
      { id: "pi", name: "Pi", available: true, installed: true, control: "automatic" },
    ],
    codexHomes: [{ path: "/Users/test/.codex", status: "running" }],
    pillScreens: [
      { displayId: 1, name: "Built-in Retina Display", isBuiltIn: true, isMain: true },
      { displayId: 7, name: "XZ322QU V3", isBuiltIn: false, isMain: false },
    ],
    update: { status: "idle", currentVersion: "2.7.0" },
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
      'Chat', 'Pills', 'Notifications', 'Agents'
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

    await clickButton(window, "Chat");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Thinking, On"]'))
      && document.body.textContent.includes('MCP tools')
      && document.body.textContent.includes('Compact boundaries')`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Thinking, On"]')?.click()`);
    await waitUntil(() => actions.some((message) => message.type === "update_settings"
      && message.patch.chatVisibility?.showThinking === false));
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Thinking, Off"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Reset for Visibility defaults"]')?.click()`);
    await waitUntil(() => actions.some((message) => message.type === "update_settings"
      && message.patch.chatVisibility?.showThinking === true));

    await clickButton(window, "Pills");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Show session pills, On"]'))`);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Show session pills, On"]')?.getAttribute('aria-checked') === 'true'`),
      "enabled settings expose the correct accessibility value",
    );
    await waitFor(window, `document.body.textContent.includes('Pill screen')
      && document.body.textContent.includes('Full-screen visibility')`);
    const screenSelection = await window.webContents.executeJavaScript(`Object.fromEntries(
      [...document.querySelectorAll('[role="button"]')]
        .filter((item) => ['XZ322QU V3 (Fallback)', 'DELL P3424WEB (Unavailable)']
          .includes(item.textContent?.trim()))
        .map((item) => [item.textContent.trim(), {
          borderColor: item.style.borderColor, disabled: item.disabled,
        }])
    )`);
    assert(Boolean(screenSelection['XZ322QU V3 (Fallback)']?.borderColor)
      && screenSelection['DELL P3424WEB (Unavailable)']?.disabled === true,
    `disconnected saved screen selects the active external fallback: ${JSON.stringify(screenSelection)}`);
    await clickButton(window, "XZ322QU V3 (Fallback)");
    await waitUntil(() => actions.some((message) => message.type === "update_settings"
      && message.patch.pillScreen?.displayId === 7));
    await clickButton(window, "Always hide");
    await waitUntil(() => actions.some((message) => message.type === "update_settings"
      && message.patch.fullScreenPolicy === "alwaysHide"));
    await clickButton(window, "Notifications");
    await waitFor(window, `document.body.textContent.includes('Sound')`);
    await clickButton(window, "Agents");
    await waitFor(window, `document.body.textContent.includes('Observed session window')`);
    await waitFor(window, `document.body.textContent.includes('Codex Desktop homes')`);
    await fillInput(window, "Codex home path", "/tmp/agent-visor-copilot-fixture");
    await fillInput(window, "Codex home label", "Codex · Copilot");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Add Codex home"]').click()`);
    await waitUntil(() => actions.some((message) => message.type === "update_settings"
      && message.patch.codexHomes?.[0]?.label === "Codex · Copilot"));
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Rename Codex · Copilot"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Rename Codex · Copilot"]').click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Label for /tmp/agent-visor-copilot-fixture"]'))`);
    await fillInput(window, "Label for /tmp/agent-visor-copilot-fixture", "Work Copilot");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Save label for Codex · Copilot"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Save label for Codex · Copilot"]').click()`);
    await waitUntil(() => actions.some((message) => message.type === "update_settings"
      && message.patch.codexHomes?.[0]?.label === "Work Copilot"));
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Remove Work Copilot"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Remove Work Copilot"]').click()`);
    await waitUntil(() => actions.some((message) => message.type === "update_settings"
      && message.patch.ignoredCodexHomes?.includes("/tmp/agent-visor-copilot-fixture")));
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

    console.log("Native services accessibility PASS: Chat visibility, settings, agent connections, navigation, permissions, updates, theme, and Back.");
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

async function fillInput(window, label, value) {
  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label=' + ${JSON.stringify(JSON.stringify(label))} + ']');
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, ${JSON.stringify(value)});
    input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
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
