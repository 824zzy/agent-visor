import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow } from "electron";
import { startServer } from "../../server/dist/server.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const now = Date.parse("2026-09-09T08:00:00.000Z");
const day = 86_400_000;
const readyState = { conversation: "open", turn: "ready", route: "available" };
const makeSession = (id, section, age) => ({
  id, title: id, subtitle: section === "ready" ? "Ready to continue" : "Agent is working",
  source: "Codex", project: "agent-visor", owner: "Codex", cwd: "/fixture/freshness",
  section, updatedAt: new Date(now - age).toISOString(),
  canOpenOwner: true, canEnterChat: true,
  sessionState: section === "ready" ? readyState : {
    conversation: "open", turn: section, route: "waiting",
  },
});
const sessions = [
  makeSession("Expiring completion", "ready", 7 * day - 60_000),
  makeSession("Expired completion", "ready", 9 * day),
  makeSession("Pending approval", "needs_you", 30 * day),
  ...Array.from({ length: 30 }, (_, index) => makeSession(`Working ${index}`, "working", index * day)),
  ...Array.from({ length: 12 }, (_, index) => makeSession(`Older completion ${index}`, "ready", (15 + index) * day)),
];
const snapshot = { type: "session_snapshot", revision: 1, sessions };
const ownerActions = [];
const subscribers = new Set();
let profile;
let server;
let window;
let exitCode = 0;
app.on("window-all-closed", () => {});

void (async () => {
try {
  profile = await mkdtemp(path.join(tmpdir(), "agent-visor-freshness-"));
  app.setPath("userData", profile);
  await app.whenReady();
  server = await startServer({ port: 0, token: "session-freshness-fixture-token-000000000000000000", source: {
    current: () => structuredClone(snapshot),
    subscribe: listener => { subscribers.add(listener); return () => subscribers.delete(listener); },
    focusSession: async (sessionId) => { ownerActions.push(sessionId); },
    chatPage: async (sessionId) => ({
      type: "chat_page", sessionId, items: [], hasMoreBefore: false,
      sessionState: readyState, stateRevision: 1, pendingAction: null,
      capabilities: { canSendText: true, canSendImages: false, canCancel: false, canApprove: false, canAnswer: false },
    }),
  } });
  window = new BrowserWindow({ show: false, width: 1040, height: 760, webPreferences: {
    additionalArguments: [`--agent-visor-daemon=${server.url}`],
    contextIsolation: true, nodeIntegration: false, sandbox: true,
    preload: path.join(root, "packages/desktop/dist/preload.cjs"),
  } });
  // Control this fixture's clock only. The production minute timer still fires
  // through its normal callback, accelerated so CI need not wait a real minute.
  await window.loadURL("about:blank");
  window.webContents.debugger.attach("1.3");
  await window.webContents.debugger.sendCommand("Page.enable");
  await window.webContents.debugger.sendCommand("Page.addScriptToEvaluateOnNewDocument", { source: `
    window.fixtureNow = ${now};
    const OriginalDate = Date;
    window.Date = class extends OriginalDate {
      constructor(...args) { super(...(args.length ? args : [window.fixtureNow])); }
      static now() { return window.fixtureNow; }
    };
    const originalInterval = window.setInterval;
    window.setInterval = (callback, delay, ...args) => originalInterval(
      delay === 60000 ? () => { if (!window.pauseAgeTimer) callback(...args); } : callback,
      delay === 60000 ? 50 : delay, ...args);
  ` });
  await window.loadFile(path.join(root, "packages/app/dist/index.html"));
  await waitFor(`document.querySelector('[aria-label^="Expired completion, History,"]')`);
  assert(await evaluate(`document.getElementById('session-row-Expired%20completion').textContent.includes('Completed')`),
    "an expired completion has History accessibility and Completed row text");
  await waitFor(`document.querySelector('[aria-label^="Expiring completion, Ready to continue,"]')`);
  await evaluate(`window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))`);
  await waitUntil(() => ownerActions.length === 1);
  assert.equal(ownerActions[0], "Pending approval");

  // Read the expiring row as it moves to the bottom of the list. No
  // provider publication occurs during this test: snapshot revision stays 1.
  const anchor = await evaluate(`(() => {
    document.getElementById('session-row-Expiring%20completion').scrollIntoView({ block: 'start' });
    return {
      top: document.getElementById('session-row-Expiring%20completion').getBoundingClientRect().top,
    };
  })()`);
  await evaluate(`window.fixtureNow += 120000`);
  await waitFor(`document.querySelector('[aria-label^="Expiring completion, History,"]')`);
  const after = await evaluate(`({
    top: document.getElementById('session-row-Expiring%20completion').getBoundingClientRect().top,
    readyHeading: [...document.querySelectorAll('#sessions-canvas *')].some(e => !e.children.length && e.textContent === 'Ready to continue'),
  })`);
  assert(Math.abs(after.top - anchor.top) < 2, `expiry preserves the reading position (${anchor.top} → ${after.top})`);
  await evaluate(`window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))`);
  await waitUntil(() => ownerActions.length === 2);
  assert.equal(ownerActions[1], "Pending approval", "expiry preserves the exact keyboard action target");
  assert.equal(after.readyHeading, false, "time alone removes the empty Ready section");
  assert(await evaluate(`document.querySelector('[aria-label^="Working 29, In progress,"]') && document.querySelector('[aria-label^="Pending approval, Needs you,"]')`),
    "age does not declare working turns or pending approvals completed");

  const neighborTop = await evaluate(`document.getElementById('session-row-Expired%20completion').getBoundingClientRect().top`);
  snapshot.revision += 1;
  snapshot.sessions = snapshot.sessions.filter(({ id }) => id !== "Expiring completion");
  for (const subscriber of subscribers) subscriber(snapshot);
  await waitFor(`!document.getElementById('session-row-Expiring%20completion')`);
  const remainingTop = await evaluate(`document.getElementById('session-row-Expired%20completion').getBoundingClientRect().top`);
  assert(Math.abs(remainingTop - neighborTop) < 2, "removing the reading anchor preserves its nearest surviving neighbor");

  await setSearch("Expired completion");
  await waitFor(`document.querySelector('[aria-label="1 search results"]')`);
  assert(await evaluate(`document.querySelector('[aria-label^="Expired completion, History,"]')`),
    "search keeps the same History presentation");
  const color = await evaluate(`getComputedStyle(document.getElementById('session-row-Expired%20completion').firstElementChild.firstElementChild).backgroundColor`);
  assert(["rgb(124, 127, 147)", "rgb(147, 153, 178)"].includes(color), `History has a gray status dot (${color})`);
  await evaluate(`document.querySelector('[aria-label="Open Chat for Expired completion"]').click()`);
  await waitFor(`document.querySelector('[aria-label="Conversation status: Ready"]')`);
  await waitFor(`document.querySelector('[aria-label="Chat message"]')`);
  await setInput("Chat message", "Keep this unsent draft");
  await evaluate(`window.pauseAgeTimer = true; window.fixtureNow += ${day}; window.dispatchEvent(new Event('focus'))`);
  await waitFor(`document.getElementById('session-row-Expired%20completion').textContent.includes('10d')`);
  assert(await evaluate(`document.querySelector('[aria-label="Chat message"]').value === 'Keep this unsent draft' && document.querySelector('[aria-label="Send"]').getAttribute('aria-disabled') !== 'true'`),
    "clock/focus updates preserve an open conversation's draft and send capability");
  await evaluate(`document.querySelector('[aria-label="Back to Sessions"]').click()`);
  await waitFor(`getComputedStyle(document.querySelector('[aria-label="Search sessions"]')).visibility === 'visible'`);
  assert.equal(await evaluate(`document.querySelector('[aria-label="Search sessions"]').value`), "Expired completion");
  await evaluate(`window.fixtureNow += ${day}; document.dispatchEvent(new Event('visibilitychange'))`);
  await waitFor(`document.getElementById('session-row-Expired%20completion').textContent.includes('11d')`);
  console.log("Session freshness PASS: consistent rows/search, time-only expiry, reading position, keyboard target, wake/focus and Chat draft/capabilities.");
} catch (error) {
  console.error(error);
  exitCode = 1;
} finally {
  window?.destroy();
  await server?.close();
  if (profile) await rm(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
  app.exit(exitCode);
}
})();

async function evaluate(script) {
  try { return await window.webContents.executeJavaScript(script); }
  catch (cause) { throw new Error(`Renderer evaluation failed: ${script}`, { cause }); }
}
async function waitFor(expression) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await evaluate(`Boolean(${expression})`)) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for ${expression}`);
}
function setSearch(value) { return setInput("Search sessions", value); }
async function waitUntil(condition) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error("Timed out waiting for the exact source action");
}
function setInput(label, value) {
  return evaluate(`(() => {
    const input = document.querySelector('[aria-label=${JSON.stringify(label)}]');
    const prototype = input.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, 'value').set.call(input, ${JSON.stringify(value)});
    input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
}
