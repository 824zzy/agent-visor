import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, ipcMain } from "electron";
import { startServer } from "../../server/dist/server.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const token = "chat-accessibility-test-token-000000000000000000000";
let mode = "history";
const session = {
  id: "pi-chat",
  title: "Migration Chat",
  subtitle: "Ready",
  source: "Pi",
  project: "agent-visor",
  owner: "Ghostty",
  cwd: "/tmp/agent-visor",
  section: "ready",
  updatedAt: "2026-08-22T10:00:00.000Z",
  canOpenOwner: true,
  canEnterChat: true,
};

void app.whenReady()
  .then(run)
  .then(() => app.exit(0))
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });

async function run() {
  const actions = [];
  const listeners = new Set();
  let revision = 1;
  let updatedAt = session.updatedAt;
  const publish = () => {
    revision += 1;
    updatedAt = new Date(Date.parse(updatedAt) + 1_000).toISOString();
    for (const listener of listeners) listener({
      type: "session_snapshot", revision, sessions: [{ ...session, updatedAt }],
    });
  };
  let ownerActions = 0;
  ipcMain.on("session:open-owner", () => { ownerActions += 1; });
  const source = {
    current: () => ({ type: "session_snapshot", revision, sessions: [{ ...session, updatedAt }] }),
    subscribe: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    chatPage: async (_sessionId, before) => {
      if (before !== undefined) {
        return {
          type: "chat_page",
          sessionId: session.id,
          items: [
            { id: "older-user", kind: "user", text: "Earlier prompt", images: [] },
            { id: "older-answer", kind: "assistant", text: "Earlier answer" },
          ],
          hasMoreBefore: false,
          capabilities: capabilities(),
          pendingAction: null,
        };
      }
      return {
        type: "chat_page",
        sessionId: session.id,
        items: [
          { id: "user-1", kind: "user", text: "Fix it", images: [{ name: "diagram.png", mimeType: "image/png", data: "iVBORw0KGgo=" }] },
          { id: "thinking-1", kind: "thinking", text: "Inspecting files" },
          { id: "tool-1", kind: "tool", name: "Bash", input: { command: "npm test" }, status: "success", result: "45 passed" },
          { id: "answer-1", kind: "assistant", text: "**Done**\n```text\nAll checks passed\n```" },
        ],
        hasMoreBefore: true,
        nextBefore: 100,
        capabilities: capabilities(),
        pendingAction: mode === "approval" ? {
          type: "approval",
          toolUseId: "approval-1",
          toolName: "Bash",
          input: { command: "npm publish" },
          canPersist: true,
        } : mode === "question" ? {
          type: "question",
          toolUseId: "question-1",
          questions: [{
            id: "Strategy",
            question: "Which strategy?",
            choices: ["Minimal", "Complete"],
            multiple: false,
          }],
        } : null,
      };
    },
    chatAction: async (message) => {
      actions.push(message);
      if (message.type === "respond_chat") mode = "history";
      return undefined;
    },
  };
  const server = await startServer({ port: 0, token, source });
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
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Migration Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Done')`);
    assert(
      await window.webContents.executeJavaScript(`!document.body.textContent.includes('**Done**')`),
      "basic Markdown emphasis renders without raw markers",
    );

    const actionsAreIndependent = await window.webContents.executeJavaScript(`(() => {
      const back = document.querySelector('[aria-label="Back to Sessions"]').getBoundingClientRect();
      const owner = document.querySelector('[aria-label="Open in Ghostty"]').getBoundingClientRect();
      const details = document.querySelector('[aria-label="Chat Details"]').getBoundingClientRect();
      return back.right <= owner.left && owner.right <= details.left;
    })()`);
    assert(actionsAreIndependent, "Back, owner, and Details actions have independent frames");

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open in Ghostty"]')?.click()`);
    await waitUntil(() => ownerActions === 1);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat Details"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Path: /tmp/agent-visor')`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat Details"]')?.click()`);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Show 2 work items"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Show details for Bash"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Show details for Bash"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('45 passed')`);
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="diagram.png"]'))`),
      "image messages expose their names",
    );

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Load earlier messages"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Earlier answer')`);

    await setInput(window, "Chat message", "Continue");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat"));

    mode = "approval";
    publish();
    await waitFor(window, `document.body.textContent.includes('Approve Bash?')`, 6_000);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Allow"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "respond_chat" && action.decision === "allow"));

    mode = "question";
    publish();
    await waitFor(window, `document.body.textContent.includes('Which strategy?')`, 6_000);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Select Minimal"]')?.click()`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Submit answers"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "respond_chat" && action.decision === "answer"));

    await window.webContents.executeJavaScript(`window.dispatchEvent(new KeyboardEvent('keydown', { key: '+', metaKey: true, bubbles: true }))`);
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert(
      await window.webContents.executeJavaScript(`document.documentElement.scrollWidth <= window.innerWidth`),
      "Chat scaling does not add horizontal scrolling",
    );

    console.log("Chat accessibility PASS: grouped turns, tools, pagination, images, actions, approvals, questions, and scaling.");
  } finally {
    window.destroy();
    await server.close();
  }
}

function capabilities() {
  return {
    canSendText: true,
    canSendImages: true,
    canApprove: mode === "approval",
    canAnswer: mode === "question",
  };
}

function assert(value, message) {
  if (!value) throw new Error(`Chat accessibility failed: ${message}`);
}

async function setInput(window, label, value) {
  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="${label}"]');
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set
      ?? Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, ${JSON.stringify(value)});
    input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
}

async function waitFor(window, expression, timeoutMs = 5_000) {
  for (let elapsed = 0; elapsed < timeoutMs; elapsed += 50) {
    if (await window.webContents.executeJavaScript(`Boolean(${expression})`)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for ${expression}`);
}

async function waitUntil(condition) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error("Timed out waiting for an Electron action.");
}
