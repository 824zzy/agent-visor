import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, ipcMain, nativeTheme } from "electron";
import { startServer } from "../../server/dist/server.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const token = "sessions-accessibility-test-token-00000000000000000000";
const now = Date.parse("2026-08-22T10:00:00.000Z");
const sessions = Array.from({ length: 30 }, (_, index) => ({
  id: `session-${index}`,
  title: `Agent session ${index}`,
  subtitle: "Accessibility test row",
  source: index % 2 ? "Pi" : "Codex",
  project: "agent-visor",
  owner: index % 2 ? "Ghostty" : "Codex",
  cwd: "/tmp/agent-visor",
  section: ["needs_you", "ready", "working", "history"][index % 4],
  updatedAt: new Date(now - index * 60_000).toISOString(),
  canOpenOwner: true,
  canEnterChat: index !== 5 && index !== 29,
}));

void app.whenReady()
  .then(run)
  .then(() => app.exit(0))
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });

async function run() {
  nativeTheme.themeSource = "light";
  let snapshot = { type: "session_snapshot", revision: 1, sessions };
  const subscribers = new Set();
  const source = {
    current: () => structuredClone(snapshot),
    subscribe: (listener) => {
      subscribers.add(listener);
      return () => subscribers.delete(listener);
    },
  };
  const server = await startServer({ port: 0, token, source });
  let ownerActions = 0;
  ipcMain.on("session:open-owner", () => { ownerActions += 1; });

  const window = new BrowserWindow({
    show: false,
    width: 1_040,
    height: 760,
    titleBarStyle: "hiddenInset",
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
  await waitFor(window, `document.querySelectorAll('[aria-label*="Open in"]').length >= 30`);
  const titleBarRegion = await window.webContents.executeJavaScript(`(() => {
    const element = document.elementFromPoint(window.innerWidth / 2, 16);
    return element ? getComputedStyle(element).getPropertyValue('-webkit-app-region') : '';
  })()`);
  assert(titleBarRegion === "drag", "the empty title-bar area drags the window");

  const frames = await window.webContents.executeJavaScript(`(() => {
    const primary = [...document.querySelectorAll('[aria-label*="Open in"]')];
    const chat = [...document.querySelectorAll('[aria-label^="Open Chat for"]')];
    const rows = primary.map((button) => {
      const primaryRect = button.getBoundingClientRect();
      const chatButton = button.parentElement.querySelector('[aria-label^="Open Chat for"]');
      const chatRect = chatButton?.getBoundingClientRect();
      return {
        primaryWidth: Math.round(primaryRect.width),
        chatLeft: chatRect ? Math.round(chatRect.left) : undefined,
        disjoint: !chatRect || primaryRect.right <= chatRect.left,
      };
    });
    return {
      primaryCount: primary.length,
      chatCount: chat.length,
      primaryWidths: rows.map(({ primaryWidth }) => primaryWidth),
      chatLefts: rows.flatMap(({ chatLeft }) => chatLeft === undefined ? [] : [chatLeft]),
      disjoint: rows.every(({ disjoint }) => disjoint),
    };
  })()`);
  assert(frames.primaryCount === 30, "all rows expose their primary owner action");
  assert(frames.chatCount === 28, "only Chat-capable rows expose Open Chat");
  assert(new Set(frames.primaryWidths).size === 1, "owner rows keep one fixed frame");
  assert(new Set(frames.chatLefts).size === 1, "Chat actions keep one aligned column");
  assert(frames.disjoint, "owner and Chat actions do not overlap");

  await window.webContents.executeJavaScript(`document.querySelector('[aria-label*="Open in"]')?.click()`);
  await waitUntil(() => ownerActions === 1);
  await window.webContents.executeJavaScript(`window.dispatchEvent(new KeyboardEvent('keydown', { key: '1', metaKey: true, bubbles: true }))`);
  await waitUntil(() => ownerActions === 2);

  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Search sessions"]');
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, 'Agent');
    input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="30 search results"]'))`);
  await window.webContents.executeJavaScript(`window.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))`);
  await new Promise((resolve) => setTimeout(resolve, 100));
  const before = await window.webContents.executeJavaScript(`(() => {
    const scroller = [...document.querySelectorAll('*')].find((item) => {
      const style = getComputedStyle(item);
      return style.overflowY === 'auto' || style.overflowY === 'scroll';
    });
    scroller.scrollTop = scroller.scrollHeight;
    return {
      cursor: document.querySelector('[aria-selected="true"]')?.getAttribute('aria-label'),
      scrollTop: scroller.scrollTop,
    };
  })()`);
  snapshot = {
    ...snapshot,
    revision: 2,
    sessions: snapshot.sessions.map((session, index) => index ? session : { ...session, title: "Agent session updated" }),
  };
  for (const subscriber of subscribers) subscriber(snapshot);
  await waitFor(window, `document.body.textContent.includes('Agent session updated')`);
  const afterBackground = await browserState(window);
  assert(afterBackground.cursor === before.cursor, "background updates preserve the keyboard cursor");
  assert(afterBackground.scrollTop === before.scrollTop, "background updates preserve the Sessions viewport");

  const afterHover = await window.webContents.executeJavaScript(`(async () => {
    document.querySelector('[aria-label*="Open in"]')?.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 50));
    const scroller = [...document.querySelectorAll('*')].find((item) => {
      const style = getComputedStyle(item);
      return style.overflowY === 'auto' || style.overflowY === 'scroll';
    });
    return {
      cursor: document.querySelector('[aria-selected="true"]')?.getAttribute('aria-label'),
      scrollTop: scroller.scrollTop,
    };
  })()`);
  assert(afterHover.cursor === before.cursor, "hover preserves the keyboard cursor");
  assert(afterHover.scrollTop === before.scrollTop, "hover preserves the Sessions viewport");

  const lightSessionsCanvas = await window.webContents.executeJavaScript(
    `getComputedStyle(document.getElementById('sessions-canvas')).backgroundColor`,
  );
  await window.webContents.executeJavaScript(`document.querySelectorAll('[aria-label^="Open Chat for"]')[27]?.click()`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Back to Sessions"]'))`);
  const lightChatCanvas = await window.webContents.executeJavaScript(
    `getComputedStyle(document.getElementById('chat-canvas')).backgroundColor`,
  );
  assert(lightChatCanvas === lightSessionsCanvas,
    `Chat and Sessions share the light canvas (${lightSessionsCanvas} → ${lightChatCanvas})`);
  assert(
    await window.webContents.executeJavaScript(`getComputedStyle(document.querySelector('[aria-label="Search sessions"]')).visibility === 'hidden'`),
    "Chat hides the retained Sessions browser from accessibility",
  );
  await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Search sessions"]'))`);

  const restored = await window.webContents.executeJavaScript(`(() => {
    const scroller = [...document.querySelectorAll('*')].find((item) => {
      const style = getComputedStyle(item);
      return style.overflowY === 'auto' || style.overflowY === 'scroll';
    });
    return {
      cursor: document.querySelector('[aria-selected="true"]')?.getAttribute('aria-label'),
      query: document.querySelector('[aria-label="Search sessions"]')?.value,
      scrollTop: scroller.scrollTop,
    };
  })()`);
  assert(restored.query === "Agent", "Back preserves the Sessions query");
  assert(restored.cursor === before.cursor, "Back preserves the Sessions keyboard cursor");
  assert(
    Math.abs(restored.scrollTop - before.scrollTop) < 2,
    `Back preserves the Sessions viewport (${before.scrollTop} → ${restored.scrollTop})`,
  );

  await window.webContents.executeJavaScript(`window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true, bubbles: true }))`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Back to Sessions"]'))`);
  await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
  await waitFor(window, `getComputedStyle(document.querySelector('[aria-label="Search sessions"]')).visibility === 'visible'`);

  const beforeScale = await browserState(window);
  await window.webContents.executeJavaScript(`{
    for (let index = 0; index < 15; index += 1) {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: '+', metaKey: true, bubbles: true }));
    }
  }`);
  window.setSize(960, 680);
  await new Promise((resolve) => setTimeout(resolve, 150));
  const scaled = await window.webContents.executeJavaScript(`(() => {
    const search = document.querySelector('[aria-label="Search sessions"]');
    const row = document.querySelector('[aria-label*="Open in"]');
    const chat = document.querySelector('[aria-label^="Open Chat for"]');
    return {
      cursor: document.querySelector('[aria-selected="true"]')?.getAttribute('aria-label'),
      horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth,
      query: search?.value,
      searchHeight: search?.getBoundingClientRect().height,
      rowHeight: row?.getBoundingClientRect().height,
      chatHeight: chat?.getBoundingClientRect().height,
    };
  })()`);
  assert(scaled.cursor === beforeScale.cursor, "content scaling preserves the keyboard cursor");
  assert(scaled.query === "Agent", "content scaling preserves the query");
  assert(!scaled.horizontalOverflow, "250% content scaling does not add horizontal scrolling");
  assert(scaled.searchHeight >= 40, "scaled search text is not clipped");
  assert(scaled.rowHeight >= 58, "scaled row text is not clipped");
  assert(scaled.chatHeight >= 32, "scaled Chat action text is not clipped");

  assert(
    await window.webContents.executeJavaScript(`[...document.querySelectorAll('*')].some((item) => getComputedStyle(item).backgroundColor === 'rgb(239, 241, 245)')`),
    "light appearance uses the semantic light canvas",
  );
  nativeTheme.themeSource = "dark";
  await waitFor(window, `[...document.querySelectorAll('*')].some((item) => getComputedStyle(item).backgroundColor === 'rgb(30, 30, 46)')`);
  const darkSessionsCanvas = await window.webContents.executeJavaScript(
    `getComputedStyle(document.getElementById('sessions-canvas')).backgroundColor`,
  );
  await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label^="Open Chat for"]')?.click()`,
  );
  await waitFor(window, `Boolean(document.getElementById('chat-canvas'))`);
  const darkChatCanvas = await window.webContents.executeJavaScript(
    `getComputedStyle(document.getElementById('chat-canvas')).backgroundColor`,
  );
  assert(darkChatCanvas === darkSessionsCanvas,
    `Chat and Sessions share the dark canvas (${darkSessionsCanvas} → ${darkChatCanvas})`);

  console.log("Sessions accessibility PASS: action labels, disjoint frames, aligned columns, shared canvas, and retained browser state.");
  } finally {
    nativeTheme.themeSource = "system";
    window.destroy();
    await server.close();
  }
}

function assert(value, message) {
  if (!value) throw new Error(`Sessions accessibility failed: ${message}`);
}

async function browserState(window) {
  return await window.webContents.executeJavaScript(`(() => {
    const scroller = [...document.querySelectorAll('*')].find((item) => {
      const style = getComputedStyle(item);
      return style.overflowY === 'auto' || style.overflowY === 'scroll';
    });
    return {
      cursor: document.querySelector('[aria-selected="true"]')?.getAttribute('aria-label'),
      scrollTop: scroller.scrollTop,
    };
  })()`);
}

async function waitFor(window, expression) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
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
  throw new Error("Timed out waiting for Electron IPC action.");
}
