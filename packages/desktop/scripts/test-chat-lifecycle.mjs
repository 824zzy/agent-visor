import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow } from "electron";
import { startServer } from "../../server/dist/server.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(directory, "../../..");
const token = "chat-lifecycle-fixture-token-000000000000000000000";
const readyState = { conversation: "open", turn: "ready", route: "available" };
const busyState = {
  conversation: "open",
  turn: "working",
  route: "waiting",
  unavailableReason: "turn_in_progress",
};
const outageState = {
  conversation: "open",
  turn: "ready",
  route: "unavailable",
  unavailableReason: "provider_unavailable",
};
const ownerOnlyState = {
  conversation: "open",
  turn: "ready",
  route: "unavailable",
  unavailableReason: "owner_only",
};
const archivedState = {
  conversation: "archived",
  turn: "unknown",
  route: "unavailable",
  unavailableReason: "archived",
};
const externalDeliveryId = "external-turn-42";
const lifecycleSession = {
  id: "lifecycle-fixture",
  title: "Lifecycle Fixture",
  subtitle: "Ready to continue",
  source: "Codex",
  project: "agent-visor",
  owner: "Codex",
  cwd: "/fixture/lifecycle",
  // Deliberately old in the list. The opened conversation remains ready.
  section: "history",
  attentionTier: "history",
  updatedAt: "2026-09-05T00:00:00.000Z",
  canOpenOwner: true,
  canEnterChat: true,
};
const metadata = {
  model: "GPT-5.6 Sol",
  modelId: "gpt-5.6-sol",
  modelProvider: "openai-codex",
  reasoningEffort: "high",
  sandbox: "workspace-write",
  approvalPolicy: "on-request",
};
const chatSettings = {
  provider: "codex",
  current: {
    modelId: "gpt-5.6-sol",
    reasoningEffort: "high",
    permissionProfile: ":workspace",
  },
  models: [
    {
      id: "gpt-5.6-sol",
      displayName: "GPT-5.6 Sol",
      description: "Reliable agentic workhorse.",
      reasoningEfforts: [{ value: "high", description: "Deliberate reasoning." }],
      defaultReasoningEffort: "high",
      supportsImages: true,
      isDefault: true,
    },
    {
      id: "gpt-6-astra",
      displayName: "GPT-6 Astra",
      description: "Most capable model.",
      reasoningEfforts: [{ value: "max", description: "Maximum reasoning." }],
      defaultReasoningEffort: "max",
      supportsImages: true,
      isDefault: false,
    },
  ],
  permissionProfiles: [
    { id: ":workspace", displayName: "Workspace", description: "Workspace access.", allowed: true },
    { id: ":danger-full-access", displayName: "Full access", description: "Unrestricted access.", allowed: true },
  ],
  appliesTo: "next_turn",
  canChange: true,
};

let profileRoot;
let server;
let window;
let exitCode = 0;
let state = readyState;
let stateRevision = 1;
let snapshotRevision = 1;
let outageRefreshes = 0;
const listeners = new Set();

app.on("window-all-closed", () => {});

void (async () => {
  try {
    profileRoot = await mkdtemp(path.join(tmpdir(), "agent-visor-lifecycle-profile-"));
    app.setPath("userData", profileRoot);
    await app.whenReady();
    await run();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
    exitCode = 1;
  } finally {
    try {
      if (window && !window.isDestroyed()) window.destroy();
      await server?.close();
      if (profileRoot) await rm(profileRoot, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
    } finally {
      if (app.isReady()) app.exit(exitCode);
    }
  }
})();

async function run() {
  const source = {
    current: () => snapshot(),
    subscribe: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    chatPage: async (sessionId) => {
      assert.equal(sessionId, lifecycleSession.id);
      // The first refresh after the outage transition confirms the outage;
      // the explicit Retry action gets the next refresh and restores the
      // route. This makes the fixture exercise the real retry seam.
      if (state === outageState) {
        outageRefreshes += 1;
        if (outageRefreshes > 1) transition(readyState);
      }
      return page(sessionId);
    },
    chatAction: async (message) => {
      if (message.type === "cancel_chat" && state === busyState) {
        transition(readyState);
      }
      return undefined;
    },
  };
  server = await startServer({ port: 0, token, source });
  window = new BrowserWindow({
    show: false,
    width: 1_100,
    height: 760,
    webPreferences: {
      additionalArguments: [`--agent-visor-daemon=${server.url}`],
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(root, "packages/desktop/dist/preload.cjs"),
      sandbox: true,
    },
  });
  await window.loadFile(path.resolve(directory, "../../app/dist/index.html"));
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Lifecycle Fixture"]'))`);
  await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Lifecycle Fixture"]')?.click()`);
  await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === ''`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Ready"]'))`);
  await setInput(window, "ready send probe");
  await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'ready send probe'`);
  const readyProbe = await window.webContents.executeJavaScript(`(() => {
    const canvas = document.getElementById('chat-canvas');
    const text = canvas?.textContent ?? '';
    const send = canvas?.querySelector('[aria-label="Send"]');
    return {
      ready: Boolean(canvas?.querySelector('[aria-label="Conversation status: Ready"]')),
      composer: Boolean(canvas?.querySelector('[aria-label="Chat message"]')),
      sendDisabled: send?.getAttribute('aria-disabled') === 'true',
      hasLegacyEndedCopy: text.includes('session has ended')
        || text.includes('Chat history is read only.'),
      hasHistoryGroupCopy: text.includes('History'),
    };
  })()`);
  assert(
    readyProbe.ready && readyProbe.composer && !readyProbe.sendDisabled
      && !readyProbe.hasLegacyEndedCopy && !readyProbe.hasHistoryGroupCopy,
    `an old list section does not turn an open conversation into ended history (${JSON.stringify(readyProbe)})`,
  );

  await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Composer model and effort"]')?.click()`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Model: GPT-6 Astra"]'))`);
  await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Model: GPT-6 Astra"]')?.click()`);
  await setInput(window, "lifecycle draft");
  await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'lifecycle draft'`);

  transition(busyState);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: In progress"]'))`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
  const busyProbe = await window.webContents.executeJavaScript(`(() => ({
    draft: document.querySelector('[aria-label="Chat message"]')?.value ?? '',
    model: document.querySelector('[aria-label="Composer model and effort"]')?.textContent ?? '',
    sendDisabled: document.querySelector('[aria-label="Send"]')?.getAttribute('aria-disabled') === 'true',
    stop: Boolean(document.querySelector('[aria-label="Stop agent"]')),
  }))()`);
  assert.equal(busyProbe.draft, "lifecycle draft", "a running turn keeps the unsent draft");
  assert(busyProbe.model.includes("GPT-6 Astra"), "a running turn keeps the staged model");
  assert(busyProbe.sendDisabled && busyProbe.stop, `busy Chat exposes wait + exact Stop (${JSON.stringify(busyProbe)})`);

  // Repeat the same provider state without changing its state revision. The
  // exact cancel identity must survive a capability-only snapshot refresh.
  publishSnapshot();
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
  assert(
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === 'lifecycle draft'`),
    "a repeated busy snapshot preserves the draft",
  );

  transition(ownerOnlyState);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Open in Codex"]'))`);
  const ownerProbe = await window.webContents.executeJavaScript(`({
    draft: document.querySelector('[aria-label="Chat message"]')?.value ?? '',
    model: document.querySelector('[aria-label="Composer model and effort"]')?.textContent ?? '',
    retry: Boolean(document.querySelector('[aria-label="Retry availability"]')),
    notice: document.querySelector('[aria-label="Chat availability notice"]')?.textContent ?? '',
  })`);
  assert(ownerProbe.draft === "lifecycle draft"
    && ownerProbe.model.includes("GPT-6 Astra")
    && !ownerProbe.retry
    && ownerProbe.notice.includes("owned by Codex"),
  `owner-held idle Chat preserves the staged draft and points to Codex (${JSON.stringify(ownerProbe)})`);
  transition(readyState);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Ready"]'))`);

  transition(outageState);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Unavailable"]'))`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Retry availability"]'))`);
  const outageProbe = await window.webContents.executeJavaScript(`({
    draft: document.querySelector('[aria-label="Chat message"]')?.value ?? '',
    retry: Boolean(document.querySelector('[aria-label="Retry availability"]')),
    sendDisabled: document.querySelector('[aria-label="Send"]')?.getAttribute('aria-disabled') === 'true',
    notice: document.querySelector('[aria-label="Chat availability notice"]')?.textContent ?? '',
  })`);
  assert.equal(outageProbe.draft, "lifecycle draft", "temporary route loss preserves the draft");
  assert(outageProbe.retry && outageProbe.sendDisabled
    && outageProbe.notice.includes("temporarily unavailable"),
  `temporary route loss is retryable and clear (${JSON.stringify(outageProbe)})`);

  await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Retry availability"]')?.click()`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Ready"]'))`);
  await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'lifecycle draft'`);
  const recoveredProbe = await window.webContents.executeJavaScript(`({
    draft: document.querySelector('[aria-label="Chat message"]')?.value ?? '',
    model: document.querySelector('[aria-label="Composer model and effort"]')?.textContent ?? '',
    sendDisabled: document.querySelector('[aria-label="Send"]')?.getAttribute('aria-disabled') === 'true',
  })`);
  assert.equal(recoveredProbe.draft, "lifecycle draft", "retry keeps the draft");
  assert(recoveredProbe.model.includes("GPT-6 Astra") && !recoveredProbe.sendDisabled,
    `recovery restores send while retaining staged settings (${JSON.stringify(recoveredProbe)})`);

  transition(archivedState);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Archived"]'))`);
  const archivedProbe = await window.webContents.executeJavaScript(`({
    notice: document.querySelector('[aria-label="Chat availability notice"]')?.textContent ?? '',
    inputDisabled: (() => {
      const input = document.querySelector('[aria-label="Chat message"]');
      return Boolean(input?.disabled || input?.readOnly || input?.getAttribute('aria-disabled') === 'true');
    })(),
    sendDisabled: document.querySelector('[aria-label="Send"]')?.getAttribute('aria-disabled') === 'true',
    owner: Boolean(document.querySelector('[aria-label="Open in Codex"]')),
  })`);
  assert(archivedProbe.notice.includes("archived") && archivedProbe.inputDisabled
    && archivedProbe.sendDisabled && archivedProbe.owner,
    `archived Chat gives an explicit owner path (${JSON.stringify(archivedProbe)})`);
}

function snapshot() {
  return {
    type: "session_snapshot",
    revision: snapshotRevision,
    sessions: [{
      ...lifecycleSession,
      subtitle: state === busyState
        ? "Agent is working"
        : state === outageState
          ? "Provider unavailable"
          : state === ownerOnlyState
            ? "Owned by Codex"
            : "Ready to continue",
      section: state === busyState ? "working" : state === archivedState ? "history" : "history",
      attentionTier: state === busyState ? "working" : state === archivedState ? "history" : "history",
      sessionState: state,
      stateRevision,
    }],
  };
}

function page(sessionId) {
  const canSend = state === readyState;
  const canCancel = state === busyState;
  return {
    type: "chat_page",
    sessionId,
    items: [{ id: "lifecycle-answer", kind: "assistant", text: "Lifecycle fixture." }],
    hasMoreBefore: false,
    capabilities: {
      canSendText: canSend,
      canSendImages: canSend,
      canCancel,
      ...(canCancel ? { cancelDeliveryId: externalDeliveryId } : {}),
      canApprove: false,
      canAnswer: false,
      ...(state === outageState ? { unavailableReason: "provider_unavailable" } : {}),
      ...(state === ownerOnlyState ? { unavailableReason: "owner_only" } : {}),
      ...(state === archivedState ? { unavailableReason: "archived" } : {}),
    },
    pendingAction: null,
    metadata,
    chatSettings,
    sessionState: state,
    stateRevision,
  };
}

function transition(next) {
  state = next;
  stateRevision += 1;
  if (next === outageState) outageRefreshes = 0;
  publishSnapshot();
}

function publishSnapshot() {
  snapshotRevision += 1;
  for (const listener of listeners) listener(snapshot());
}

async function setInput(targetWindow, value) {
  await targetWindow.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    setter?.call(input, ${JSON.stringify(value)});
    input?.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
}

async function waitFor(targetWindow, expression, timeoutMs = 6_000) {
  for (let elapsed = 0; elapsed < timeoutMs; elapsed += 50) {
    if (await targetWindow.webContents.executeJavaScript(`Boolean(${expression})`)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for ${expression}`);
}
