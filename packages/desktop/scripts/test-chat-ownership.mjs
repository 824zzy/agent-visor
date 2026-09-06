import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow } from "electron";
import { startServer } from "../../server/dist/server.js";

/**
 * Disposable ownership/delivery canary.
 *
 * This fixture deliberately uses an in-memory source. It does not open a
 * real Codex task, create a writer lock, or use the user's daemon. The source
 * models the provider events that the real server must expose:
 * - a read-only Chat open;
 * - a send-bound writer lease;
 * - provider request/delivery/item identity;
 * - live content while the turn is working; and
 * - release after completion or confirmed Stop.
 *
 * The writer counters below are renderer/server contract checks inside this
 * stub. They are not evidence that the real Codex route manager acquired or
 * released a native writer; the disposable native canary owns that proof.
 *
 * Run after the normal build from the desktop package:
 *   electron scripts/test-chat-ownership.mjs
 *
 * Set AGENT_VISOR_OWNERSHIP_WAIT_MS=0 for a fast local smoke check. The
 * default 30.5 second wait is intentional: it verifies that an exact native
 * identity keeps Stop alive beyond the delivery deadline.
 */

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(directory, "../../..");
const token = "chat-ownership-fixture-token-000000000000000000000";
const sessionID = "ownership-fixture";
const sessionTitle = "Ownership Fixture";
const readyState = { conversation: "open", turn: "ready", route: "available" };
const workingState = { conversation: "open", turn: "working", route: "available" };
const ownerState = {
  conversation: "open",
  turn: "ready",
  route: "unavailable",
  unavailableReason: "owner_only",
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
  models: [{
    id: "gpt-5.6-sol",
    displayName: "GPT-5.6 Sol",
    description: "Fixture model.",
    reasoningEfforts: [{ value: "high", description: "Deliberate reasoning." }],
    defaultReasoningEffort: "high",
    supportsImages: false,
    isDefault: true,
  }],
  permissionProfiles: [{
    id: ":workspace",
    displayName: "Workspace",
    description: "Fixture workspace access.",
    allowed: true,
  }],
  appliesTo: "next_turn",
  canChange: true,
};

const longHistory = createLongHistory();
let canonicalItems = [...longHistory];
let phase = "ready";
let activeDeliveryID;
let externalOwner = false;
let stopResolver;
let snapshotRevision = 1;
let stateRevision = 1;
let window;
let profileRoot;
let server;
let exitCode = 0;
const listeners = new Set();
const chatPageRequests = [];
const readChatPages = [];
const sentMessages = [];
const cancelMessages = [];
let openLeases = 0;
let writerOwner;
let writerAcquires = 0;
let writerReleases = 0;

app.on("window-all-closed", () => {});

void (async () => {
  try {
    profileRoot = await mkdtemp(path.join(tmpdir(), "agent-visor-ownership-profile-"));
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
      if (profileRoot) {
        await rm(profileRoot, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
      }
    } catch (error) {
      process.stderr.write(`Ownership fixture cleanup failed: ${error instanceof Error ? error.stack : String(error)}\n`);
      exitCode = 1;
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
    chatOpened: async (sessionId) => {
      assert.equal(sessionId, sessionID);
      // Opening Chat creates a read lease only. The fixture records no writer
      // acquisition here; a real provider route must follow the same rule.
      openLeases += 1;
      return undefined;
    },
    chatClosed: (sessionId) => {
      if (sessionId === sessionID) openLeases = Math.max(0, openLeases - 1);
    },
    chatRetry: async () => undefined,
    chatPage: async (requestedSessionID, before) => {
      assert.equal(requestedSessionID, sessionID);
      const response = page();
      chatPageRequests.push({
        before,
        phase,
        hasMoreBefore: response.hasMoreBefore,
        userIdentities: response.items
          .filter((item) => item.kind === "user")
          .map(({ id, requestId, deliveryId, providerMessageId }) => ({
            id,
            requestId,
            deliveryId,
            providerMessageId,
          })),
      });
      readChatPages.push(response);
      return response;
    },
    chatAction: async (message) => {
      assert.equal(message.sessionId, sessionID);
      if (message.type === "send_chat") return acceptSend(message);
      if (message.type === "cancel_chat") return acceptCancel(message);
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

  await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for ${sessionTitle}"]'))`);
  await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label="Open Chat for ${sessionTitle}"]')?.click()`,
  );
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Ready"]'))`);
  // The session snapshot can render Ready before the open_chat websocket
  // request reaches the server. Wait for the read lease and page response so
  // this contract check observes the completed Chat-open handshake.
  await waitUntil(
    () => openLeases === 1 && chatPageRequests.length > 0,
    "the opened Chat establishes its read lease and reads a transcript page",
  );
  assert.equal(writerAcquires, 0, "opening Chat must not acquire the Codex writer");
  assert.equal(writerOwner, undefined, "opening Chat must leave the writer unowned");
  assert.equal(openLeases, 1, "the open Chat must retain one read lease");
  assert(chatPageRequests.length > 0, "opening Chat must read a transcript page");

  await setInput(window, "draft while Codex owns the task");
  enterExternalOwner();
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Open in Codex"]'))`);
  const ownerDraft = await window.webContents.executeJavaScript(`({
    draft: document.querySelector('[aria-label="Chat message"]')?.value ?? '',
    notice: document.querySelector('[aria-label="Chat availability notice"]')?.textContent ?? '',
    sendDisabled: document.querySelector('[aria-label="Send"]')?.getAttribute('aria-disabled') === 'true',
  })`);
  assert.equal(ownerDraft.draft, "draft while Codex owns the task");
  assert(ownerDraft.notice.includes("owned by Codex"), `owner notice is clear (${JSON.stringify(ownerDraft)})`);
  assert(ownerDraft.sendDisabled, `owner-owned Chat cannot send (${JSON.stringify(ownerDraft)})`);
  releaseExternalOwner();
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Ready"]'))`);
  await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'draft while Codex owns the task'`);

  await setInput(window, "first exact identity turn");
  await click(window, '[aria-label="Send"]');
  await waitUntil(() => sentMessages.length === 1, "the first send reaches the fixture");
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: In progress"]'))`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
  assert.equal(writerAcquires, 1, "send must acquire the writer lazily");
  assert.equal(writerOwner, "agent-visor", "the writer belongs to Visor during the turn");
  await waitFor(window, `document.querySelectorAll('[id^="chat-item-"]').length > 0`);
  const firstSent = sentMessages[0];
  await waitUntil(
    () => readChatPages.some((response) => response.items.some((item) => item.id === firstSent.nativeItemId)),
    "the exact canonical user item reaches the chatPage fixture",
  );
  const firstPageIdentity = latestIdentityFor(readChatPages, firstSent.nativeItemId);
  assert.deepEqual(firstPageIdentity, {
    id: firstSent.nativeItemId,
    requestId: firstSent.requestId,
    deliveryId: firstSent.deliveryId,
    providerMessageId: firstSent.nativeItemId,
  }, "the chatPage fixture must expose the exact native user item identity");
  assert.equal(await countRowsWithID(window, firstSent.nativeItemId), 1,
    "the rendered row uses the exact native user item ID");
  assert.equal(await countRowsWithText(window, "first exact identity turn"), 1,
    "the exact canonical user row replaces the optimistic duplicate");
  assert.equal(await hasDeliveryRecovery(window), false,
    "an exact identity must settle delivery even when history is paged");

  appendLiveContent("first exact identity turn");
  // The fixture includes an assistant update after the running tool. Codex
  // groups that completed work disclosure by default, so expand it before
  // asserting that the same-turn tool result reached the renderer.
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Show 1 work item"]'))`);
  await click(window, '[aria-label="Show 1 work item"]');
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Show details for bash"]'))`);
  await click(window, '[aria-label="Show details for bash"]');
  await waitFor(window, `document.querySelector('[aria-label="Hide details for bash"]')?.getAttribute('aria-expanded') === 'true'`);
  await waitFor(window, `document.body.textContent.includes('Live tool output')`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
  completeTurn();
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Ready"]'))`);
  assert.equal(writerOwner, undefined, "completion must release Visor ownership");
  assert.equal(writerReleases, 1, "completion must release exactly one writer lease");
  assert.equal(openLeases, 1, "the Chat read lease remains open after completion");

  await setInput(window, "second exact identity turn");
  await click(window, '[aria-label="Send"]');
  await waitUntil(() => sentMessages.length === 2, "the second send reaches the fixture");
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
  assert.equal(writerOwner, "agent-visor", "the second turn owns the writer");
  const secondSent = sentMessages[1];
  await waitUntil(
    () => readChatPages.some((response) => response.items.some((item) => item.id === secondSent.nativeItemId)),
    "the second exact canonical user item reaches the chatPage fixture",
  );
  assert.deepEqual(latestIdentityFor(readChatPages, secondSent.nativeItemId), {
    id: secondSent.nativeItemId,
    requestId: secondSent.requestId,
    deliveryId: secondSent.deliveryId,
    providerMessageId: secondSent.nativeItemId,
  }, "the second chatPage row preserves native identity");
  assert.equal(await countRowsWithID(window, secondSent.nativeItemId), 1,
    "the second rendered row uses the exact native user item ID");
  assert.equal(await countRowsWithText(window, "second exact identity turn"), 1,
    "the second exact canonical row has no optimistic duplicate");

  const waitMs = Number.parseInt(process.env.AGENT_VISOR_OWNERSHIP_WAIT_MS ?? "30500", 10);
  if (Number.isFinite(waitMs) && waitMs > 0) await sleep(waitMs);
  const postDeadline = await window.webContents.executeJavaScript(`({
    stop: Boolean(document.querySelector('[aria-label="Stop agent"]')),
    recovery: Boolean(document.querySelector('[aria-label="Chat delivery recovery"]')),
    body: document.body.textContent ?? '',
  })`);
  assert(postDeadline.stop, `Stop remains available after the delivery deadline (${JSON.stringify(postDeadline)})`);
  assert(!postDeadline.recovery && !postDeadline.body.includes("Delivery uncertain"),
    `an exact active turn does not become a false delivery failure (${JSON.stringify(postDeadline)})`);

  await click(window, '[aria-label="Stop agent"]');
  await waitUntil(() => cancelMessages.length === 1, "Stop reaches the fixture");
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Canceling agent"]'))`);
  assert.equal(writerOwner, "agent-visor", "ownership remains held until Stop is confirmed");
  assert.equal(writerReleases, 1, "pending Stop must not release ownership early");
  confirmStop();
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Agent stopped"]'))`);
  assert.equal(writerOwner, undefined, "confirmed Stop must release Visor ownership");
  assert.equal(writerReleases, 2, "confirmed Stop must release the active writer lease");
  assert.equal(openLeases, 1, "the Chat read lease remains open after Stop");
  assert.equal(writerOwner === undefined, true, "Codex can resume after Visor releases the writer");

  enterExternalOwner();
  await setInput(window, "draft after returning to Codex");
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Open in Codex"]'))`);
  assert.equal(await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label="Chat message"]')?.value`,
  ), "draft after returning to Codex", "owner-busy state preserves a new draft");
  releaseExternalOwner();
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Conversation status: Ready"]'))`);
  await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'draft after returning to Codex'`);

  process.stdout.write(JSON.stringify({
    result: "PASS",
    openedReadOnly: true,
    sent: sentMessages.length,
    canceled: cancelMessages.length,
    rendererContract: {
      writerAcquires,
      writerReleases,
      openLeases,
    },
    pageReads: chatPageRequests.length,
    exactNativeRowsVerified: sentMessages.length,
  }) + "\n");
}

function acceptSend(message) {
  if (phase !== "ready" || externalOwner) return "The fixture writer is unavailable.";
  assert.equal(writerOwner, undefined, "a send must not race an existing fixture writer");
  writerOwner = "agent-visor";
  writerAcquires += 1;
  activeDeliveryID = message.deliveryId;
  const nativeItemId = `provider-${message.deliveryId}`;
  sentMessages.push({
    id: message.id,
    requestId: message.id,
    deliveryId: message.deliveryId,
    nativeItemId,
    text: message.text,
  });
  canonicalItems = [...canonicalItems, {
    id: nativeItemId,
    kind: "user",
    text: message.text,
    images: [],
    requestId: message.id,
    deliveryId: message.deliveryId,
    providerMessageId: nativeItemId,
    timestamp: new Date().toISOString(),
  }];
  phase = "working";
  stateRevision += 1;
  publishSnapshot();
  return undefined;
}

function acceptCancel(message) {
  if (phase !== "working" || writerOwner !== "agent-visor" || message.deliveryId !== activeDeliveryID) {
    return "Cancellation is unavailable for this fixture turn.";
  }
  cancelMessages.push({ id: message.id, deliveryId: message.deliveryId });
  phase = "stopping";
  stateRevision += 1;
  publishSnapshot();
  return new Promise((resolve) => { stopResolver = resolve; });
}

function confirmStop() {
  assert.equal(phase, "stopping", "the fixture can confirm only a pending Stop");
  assert.equal(writerOwner, "agent-visor");
  phase = "ready";
  writerOwner = undefined;
  writerReleases += 1;
  activeDeliveryID = undefined;
  stateRevision += 1;
  publishSnapshot();
  const resolve = stopResolver;
  stopResolver = undefined;
  resolve?.(undefined);
}

function completeTurn() {
  assert.equal(phase, "working", "the fixture can complete only a working turn");
  phase = "ready";
  writerOwner = undefined;
  writerReleases += 1;
  activeDeliveryID = undefined;
  stateRevision += 1;
  publishSnapshot();
}

function appendLiveContent(prompt) {
  canonicalItems = [...canonicalItems,
    {
      id: `tool-${prompt.replaceAll(" ", "-")}`,
      kind: "tool",
      name: "bash",
      family: "bash",
      input: { command: "printf live" },
      status: "running",
      result: "Live tool output",
      timestamp: new Date().toISOString(),
    },
    {
      id: `assistant-${prompt.replaceAll(" ", "-")}`,
      kind: "assistant",
      text: "Live assistant update",
      timestamp: new Date().toISOString(),
    },
  ];
  stateRevision += 1;
  publishSnapshot();
}

function enterExternalOwner() {
  assert.equal(writerOwner, undefined, "the fixture external owner can enter only when Visor released");
  externalOwner = true;
  phase = "owner";
  stateRevision += 1;
  publishSnapshot();
}

function releaseExternalOwner() {
  externalOwner = false;
  phase = "ready";
  stateRevision += 1;
  publishSnapshot();
}

function snapshot() {
  const state = stateForPhase();
  return {
    type: "session_snapshot",
    revision: snapshotRevision,
    sessions: [{
      id: sessionID,
      title: sessionTitle,
      subtitle: phase === "owner" ? "Owned by Codex" : phase === "working" || phase === "stopping" ? "Agent is working" : "Ready",
      source: "Codex",
      project: "agent-visor",
      owner: "Codex",
      cwd: "/fixture/ownership",
      section: phase === "working" || phase === "stopping" ? "working" : phase === "owner" ? "history" : "ready",
      attentionTier: phase === "working" || phase === "stopping" ? "working" : "history",
      updatedAt: new Date().toISOString(),
      canOpenOwner: true,
      canEnterChat: true,
      sessionState: state,
      stateRevision,
    }],
  };
}

function page() {
  const state = stateForPhase();
  const working = phase === "working" || phase === "stopping";
  const owner = phase === "owner";
  return {
    type: "chat_page",
    sessionId: sessionID,
    // The daemon returns the configured latest page only. Older items remain
    // on the provider record; this fixture proves the latest-page identity
    // contract with hasMoreBefore, while earlier-page traversal is covered by
    // the native canary and is deliberately not simulated here.
    items: canonicalItems.slice(-100),
    hasMoreBefore: true,
    nextBefore: 1,
    transcriptEvidence: {
      authoritative: true,
      complete: false,
      sourceTimestamp: canonicalItems.at(-1)?.timestamp,
    },
    capabilities: {
      canSendText: !working && !owner,
      canSendImages: false,
      canCancel: working && activeDeliveryID !== undefined,
      ...(working && activeDeliveryID ? { cancelDeliveryId: activeDeliveryID } : {}),
      canApprove: false,
      canAnswer: false,
      ...(owner ? { unavailableReason: "owner_only" } : {}),
    },
    pendingAction: null,
    metadata,
    chatSettings,
    sessionState: state,
    stateRevision,
  };
}

function stateForPhase() {
  if (phase === "owner") return ownerState;
  if (phase === "working" || phase === "stopping") return workingState;
  return readyState;
}

function publishSnapshot() {
  snapshotRevision += 1;
  for (const listener of listeners) listener(snapshot());
}

function createLongHistory() {
  const items = [];
  // Keep the initial page above the renderer's 100-item request cap. The
  // exact new user row still appears in this paged latest page so the test
  // cannot accidentally rely on a complete history baseline.
  for (let index = 0; index < 60; index += 1) {
    const timestamp = new Date(Date.UTC(2026, 8, 5, 20, index, 0)).toISOString();
    items.push({
      id: `history-user-${index}`,
      kind: "user",
      text: `Earlier prompt ${index}`,
      images: [],
      timestamp,
    });
    items.push({
      id: `history-assistant-${index}`,
      kind: "assistant",
      text: `Earlier answer ${index}`,
      timestamp,
    });
  }
  return items;
}

async function click(targetWindow, selector) {
  await targetWindow.webContents.executeJavaScript(
    `document.querySelector(${JSON.stringify(selector)})?.click()`,
  );
}

async function setInput(targetWindow, value) {
  await targetWindow.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    setter?.call(input, ${JSON.stringify(value)});
    input?.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
}

async function countRowsWithText(targetWindow, text) {
  return targetWindow.webContents.executeJavaScript(`([...document.querySelectorAll('[id^="chat-item-"]')]
    .filter((row) => row.textContent?.includes(${JSON.stringify(text)})).length)`);
}

async function countRowsWithID(targetWindow, itemID) {
  return targetWindow.webContents.executeJavaScript(
    `document.getElementById(${JSON.stringify(`chat-item-${encodeURIComponent(itemID)}`)}) ? 1 : 0`,
  );
}

function latestIdentityFor(pages, itemID) {
  for (let index = pages.length - 1; index >= 0; index -= 1) {
    const item = pages[index]?.items?.find((candidate) => candidate.id === itemID);
    if (item) {
      return {
        id: item.id,
        requestId: item.requestId,
        deliveryId: item.deliveryId,
        providerMessageId: item.providerMessageId,
      };
    }
  }
  return undefined;
}

async function hasDeliveryRecovery(targetWindow) {
  return targetWindow.webContents.executeJavaScript(
    `Boolean(document.querySelector('[aria-label="Chat delivery recovery"]'))`,
  );
}

async function waitFor(targetWindow, expression, timeoutMs = 8_000) {
  for (let elapsed = 0; elapsed < timeoutMs; elapsed += 50) {
    if (await targetWindow.webContents.executeJavaScript(`Boolean(${expression})`)) return;
    await sleep(50);
  }
  throw new Error(`Timed out waiting for ${expression}`);
}

async function waitUntil(predicate, description, timeoutMs = 8_000) {
  for (let elapsed = 0; elapsed < timeoutMs; elapsed += 50) {
    if (predicate()) return;
    await sleep(50);
  }
  throw new Error(`Timed out waiting for ${description}`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
