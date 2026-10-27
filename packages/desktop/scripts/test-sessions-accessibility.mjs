import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, ipcMain, nativeTheme } from "electron";
import { startServer } from "../../server/dist/server.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const token = "sessions-accessibility-test-token-00000000000000000000";
const now = Date.now();
const baseSessionCount = 159;
const sessions = [
  ...Array.from({ length: baseSessionCount }, (_, index) => ({
    id: `session-${index}`,
    title: `Agent session ${index}`,
    subtitle: index === 0 ? "Managed by Agent Room · Agent is working" : "Accessibility test row",
    managedBy: index === 0 ? "Agent Room" : undefined,
    source: index % 2 ? "Codex" : "Pi",
    sourceProfile: index === 0 ? "fixture-profile" : undefined,
    project: "agent-visor",
    owner: index % 2 ? "Codex" : "Ghostty",
    cwd: "/tmp/agent-visor",
    section: ["needs_you", "ready", "working", "history"][index % 4],
    presence: index === 3
      ? { state: "unknown", evidence: "unavailable", observedAt: new Date(now).toISOString() }
      : index % 4 === 3
        ? { state: "closed", evidence: "authoritative_inventory", observedAt: new Date(now).toISOString() }
        : { state: "open", evidence: index % 4 === 2 ? "runtime" : "frontend", observedAt: new Date(now).toISOString() },
    sessionState: {
      conversation: "open",
      turn: index === 3 ? "unknown" : index % 4 === 0 ? "needs_you" : index % 4 === 1 ? "ready" : "working",
      route: index % 4 === 0 || index % 4 === 1 ? "available" : "waiting",
    },
    attentionTier: index % 8 === 1 ? "acknowledged_ready" : undefined,
    updatedAt: new Date(now - index * 60_000).toISOString(),
    canOpenOwner: true,
    canEnterChat: index !== 5 && index !== 29,
  })),
  {
    id: "saved-pi-owner",
    title: "Saved Pi owner route",
    subtitle: "Transcript preview from Pi",
    source: "Pi",
    project: "agent-visor",
    owner: "Ghostty",
    cwd: "/tmp/agent-visor",
    section: "history",
    presence: { state: "unknown", evidence: "catalog", observedAt: new Date(now).toISOString() },
    sessionState: { conversation: "unknown", turn: "ready", route: "unavailable" },
    updatedAt: new Date(now - 2 * 60_000).toISOString(),
    canOpenOwner: true,
    canEnterChat: true,
    ambientEligible: false,
  },
  {
    id: "saved-pi-chat",
    title: "Saved Pi read-only Chat",
    subtitle: "Saved transcript from Pi",
    source: "Pi",
    project: "agent-visor",
    owner: "Pi",
    cwd: "/tmp/agent-visor",
    section: "history",
    presence: { state: "unknown", evidence: "catalog", observedAt: new Date(now).toISOString() },
    sessionState: { conversation: "unknown", turn: "unknown", route: "unavailable" },
    updatedAt: new Date(now - 3 * 60_000).toISOString(),
    canOpenOwner: false,
    canEnterChat: true,
    ambientEligible: false,
  },
  {
    id: "saved-pi-no-action",
    title: "Saved Pi no action",
    subtitle: "Saved transcript without a supported action",
    source: "Pi",
    project: "agent-visor",
    owner: "Pi",
    cwd: "/tmp/agent-visor",
    section: "history",
    presence: { state: "unknown", evidence: "catalog", observedAt: new Date(now).toISOString() },
    sessionState: { conversation: "unknown", turn: "unknown", route: "unavailable" },
    updatedAt: new Date(now - 4 * 60_000).toISOString(),
    canOpenOwner: false,
    canEnterChat: false,
    ambientEligible: false,
  },
  {
    id: "unavailable-retry",
    title: "Agent retryable",
    subtitle: "Detection could not be verified",
    source: "Claude Code",
    project: "agent-visor",
    owner: "Ghostty",
    cwd: "/tmp/agent-visor",
    section: "history",
    presence: { state: "unknown", evidence: "unavailable", observedAt: new Date(now).toISOString() },
    sessionState: { conversation: "unknown", turn: "ready", route: "unavailable" },
    updatedAt: new Date(now - 31 * 60_000).toISOString(),
    canOpenOwner: false,
    canEnterChat: true,
    ambientEligible: true,
  },
];

void app.whenReady()
  .then(run)
  .then(() => app.exit(0))
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });

async function run() {
  nativeTheme.themeSource = "light";
  const expectedReadyNames = Array.from({ length: baseSessionCount }, (_, index) => index)
    .filter((index) => index % 4 === 1)
    .map((index) => `Agent session ${index}`);
  let snapshot = { type: "session_snapshot", revision: 1, sessions };
  const subscribers = new Set();
  let focusActions = 0;
  let acknowledgements = 0;
  const source = {
    current: () => structuredClone(snapshot),
    subscribe: (listener) => {
      subscribers.add(listener);
      return () => subscribers.delete(listener);
    },
    focusSession: async () => {
      focusActions += 1;
      return "Exact session focus is unavailable.";
    },
    acknowledgeReady: () => { acknowledgements += 1; },
    historyPage: () => ({
      type: "session_history_page",
      sessions: [],
      total: 0,
      nextCursor: "saved-next",
    }),
    retryDetection: async (sessionId) => {
      if (sessionId !== "unavailable-retry") return "Unknown fixture session.";
      const observedAt = new Date().toISOString();
      snapshot = {
        ...snapshot,
        revision: snapshot.revision + 1,
        sessions: snapshot.sessions.map((session) => session.id === sessionId
          ? {
            ...session,
            presence: { state: "open", evidence: "frontend", observedAt },
            sessionState: { conversation: "open", turn: "ready", route: "available" },
            updatedAt: observedAt,
          }
          : session),
      };
      for (const subscriber of subscribers) subscriber(snapshot);
      return undefined;
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
  await waitFor(window, `document.querySelectorAll('[aria-label*="Open in"]').length >= ${baseSessionCount}`);
  const savedNoActionRow = await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label^="Saved Pi no action,"]')?.getAttribute('aria-label')`,
  );
  assert(savedNoActionRow !== undefined
    && !savedNoActionRow.includes("Open Chat")
    && !savedNoActionRow.includes("Open in"),
  "Saved rows without supported actions do not advertise a disabled Chat or owner route");
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Load more Saved"]'))`);
  assert(!await window.webContents.executeJavaScript(
    `Boolean(document.querySelector('[aria-label="Load more History"]'))`,
  ), "Saved pagination uses the Saved label");
  const readyGroups = await window.webContents.executeJavaScript(`(() => ({
    headings: [...document.querySelectorAll('#sessions-canvas *')]
      .filter((element) => !element.children.length && element.textContent === 'Ready').length,
    rows: [...document.querySelectorAll('[aria-label*="Open in"]')]
      .map((element) => element.getAttribute('aria-label'))
      .filter((label) => label.includes(', Ready,'))
      .map((label) => label.split(',')[0]),
  }))()`);
  assert(readyGroups.headings === 1, "Ready completions share one visible section heading");
  assert(JSON.stringify(readyGroups.rows) === JSON.stringify(
    expectedReadyNames,
  ), "the merged Ready section lists all completions by recency regardless of acknowledgment");
  const sectionHeadings = await window.webContents.executeJavaScript(`[
    ...document.querySelectorAll('#sessions-canvas *')
  ].filter((element) => !element.children.length)
    .map((element) => element.textContent)
    .filter((text) => ['Current', 'Needs you', 'In progress', 'Ready', 'Status unavailable', 'Saved'].includes(text))`);
  assert(JSON.stringify(sectionHeadings.slice(0, 6)) === JSON.stringify(
    ['Current', 'Needs you', 'In progress', 'Ready', 'Status unavailable', 'Saved'],
  ), "presence sections expose Current, Status unavailable, and Saved in order");
  const readyLabels = `[...document.querySelectorAll('[aria-label*="Open in"]')]
    .map(element => element.getAttribute('aria-label')).filter(label => label.includes(', Ready,'))`;
  snapshot = {
    ...snapshot, revision: snapshot.revision + 1,
    sessions: sessions.map(session => session.id === "session-29"
      ? { ...session, updatedAt: new Date(now).toISOString(), attentionTier: "acknowledged_ready" }
      : session),
  };
  for (const subscriber of subscribers) subscriber(snapshot);
  await waitFor(window, `${readyLabels}[0]?.startsWith('Agent session 29,')`);
  const refreshedReady = await window.webContents.executeJavaScript(`${readyLabels}.map(label => label.split(',')[0])`);
  assert(JSON.stringify(refreshedReady) === JSON.stringify(
    [`Agent session 29`, ...expectedReadyNames.filter((name) => name !== "Agent session 29")],
  ), "same-phase activity updates move a seen completion ahead of older unseen work");
  snapshot = { ...snapshot, revision: snapshot.revision + 1, sessions };
  for (const subscriber of subscribers) subscriber(snapshot);
  await waitFor(window, `${readyLabels}[0]?.startsWith('Agent session 1,')`);
  const titleBarRegion = await window.webContents.executeJavaScript(`(() => {
    const element = document.elementFromPoint(window.innerWidth / 2, 16);
    return element ? getComputedStyle(element).getPropertyValue('-webkit-app-region') : '';
  })()`);
  assert(titleBarRegion === "drag", "the empty title-bar area drags the window");

  const frames = await window.webContents.executeJavaScript(`(() => {
    const primary = [...document.querySelectorAll('[aria-label*="Open in"]')];
    const chat = [...document.querySelectorAll('[aria-label^="Open Chat for"], [aria-label^="Read chat for"]')];
    const rows = [...document.querySelectorAll('[id^="session-row-"]')].map((row) => {
      const primaryButton = row.querySelector('[aria-label*="Open in"]');
      const chatButton = row.querySelector('[aria-label^="Open Chat for"], [aria-label^="Read chat for"]');
      const moreButton = row.querySelector('[aria-label^="More actions for"]');
      const primaryRect = primaryButton?.getBoundingClientRect();
      const chatRect = chatButton?.getBoundingClientRect();
      const moreRect = moreButton?.getBoundingClientRect();
      return {
        primaryWidth: primaryRect ? Math.round(primaryRect.width) : undefined,
        chatLeft: chatRect ? Math.round(chatRect.left) : undefined,
        moreLeft: moreRect ? Math.round(moreRect.left) : undefined,
        disjoint: !chatRect || !primaryRect || primaryRect.right <= chatRect.left,
      };
    });
    return {
      primaryCount: primary.length,
      chatCount: chat.length,
      primaryWidths: rows.map(({ primaryWidth }) => primaryWidth),
      chatLefts: rows.flatMap(({ chatLeft }) => chatLeft === undefined ? [] : [chatLeft]),
      moreLefts: rows.flatMap(({ moreLeft }) => moreLeft === undefined ? [] : [moreLeft]),
      disjoint: rows.every(({ disjoint }) => disjoint),
    };
  })()`);
  assert(frames.primaryCount === baseSessionCount + 1, "all owner-routed rows expose their primary action");
  assert(frames.chatCount === baseSessionCount + 1, "all Chat-capable rows, including Chat-only Saved rows, expose a fixed Chat action");
  assert(new Set(frames.primaryWidths.filter(Boolean)).size === 1, "owner rows keep one fixed frame");
  assert(new Set(frames.chatLefts).size === 1, "Chat actions keep one aligned column");
  assert(frames.moreLefts.length === 0, "rows without secondary actions reserve an empty More slot");
  assert(frames.disjoint, "owner and Chat actions do not overlap");
  assert(await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label*="Managed by Agent Room"]'))`),
    "managed-session ownership is accessible on its row");
  const sourceActionLabel = await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label^="Agent session 0,"]')?.getAttribute('aria-label')`,
  );
  assert((sourceActionLabel ?? "").includes("Pi · fixture-profile")
    && (sourceActionLabel ?? "").includes("Open in Ghostty"),
  "search rows expose the original source profile and available owner action");
  const savedOwnerRow = await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label^="Saved Pi owner route,"]')?.getAttribute('aria-label')`,
  );
  const savedOwnerChat = await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label^="Read chat for Saved Pi owner route"]')?.getAttribute('aria-label')`,
  );
  const savedChatRow = await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label^="Saved Pi read-only Chat,"]')?.getAttribute('aria-label')`,
  );
  assert((savedOwnerRow ?? "").includes("Saved") && (savedOwnerRow ?? "").includes("Open in Ghostty"),
    "Saved catalog rows preserve an exact owner route");
  assert(savedOwnerChat?.includes("(read-only transcript") === true,
    "Saved catalog Chat remains explicitly read-only beside an exact owner route");
  const savedChatButton = await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label^="Read chat for Saved Pi read-only Chat"]')?.getAttribute('aria-label')`,
  );
  assert(savedChatButton?.includes("Read chat") === true && savedChatRow?.includes("Saved") === true,
    "ownerless Saved catalog rows expose Read chat without Retry");
  assert(!await window.webContents.executeJavaScript(
    `Boolean(document.querySelector('[aria-label^="Retry detection for Saved Pi"]'))`,
  ), "Saved catalog rows do not expose detection Retry");

  const retryRow = `[aria-label^="Agent retryable,"]`;
  const retryChat = `[aria-label^="Read chat for Agent retryable"]`;
  assert(await window.webContents.executeJavaScript(`document.querySelector(${JSON.stringify(retryRow)})?.getAttribute('aria-label')
    .includes('Retry detection')`),
  "unavailable no-route rows expose an explicit Retry detection action");
  assert(await window.webContents.executeJavaScript(
    `document.querySelector(${JSON.stringify(retryChat)})?.getAttribute('aria-label')
      .includes('(read-only transcript')`,
  ), "unavailable Chat access is clearly labelled read-only");
  await window.webContents.executeJavaScript(`window.alert = () => {};
    document.querySelector(${JSON.stringify(retryRow)})?.click()`);
  await waitFor(window, `document.querySelector(${JSON.stringify(retryRow)})?.getAttribute('aria-label').includes(', Ready,')`);
  const recoveredRetry = await window.webContents.executeJavaScript(`(() => {
    const element = document.querySelector(${JSON.stringify(retryRow)});
    return { sameRow: Boolean(document.getElementById('session-row-unavailable-retry')), label: element?.getAttribute('aria-label') };
  })()`);
  assert(recoveredRetry.sameRow && recoveredRetry.label?.includes(", Ready,"),
    "Retry detection recovers the exact unavailable session identity");
  assert(focusActions === 0 && acknowledgements === 0,
    "detection retry never focuses or acknowledges the recovered session");

  await window.webContents.executeJavaScript(`window.__focusError = null;
    window.alert = (message) => { window.__focusError = message; };
    document.querySelector('[aria-label*="Open in"]')?.click()`);
  await waitFor(window, `window.__focusError === 'Exact session focus is unavailable.'`);
  assert(ownerActions === 0, "a failed exact focus never launches the named owner app");
  await window.webContents.executeJavaScript(`window.__codexFocusError = null;
    window.alert = (message) => { window.__codexFocusError = message; };
    document.querySelector('[aria-label*="Open in Codex"]')?.click()`);
  await waitFor(window, `window.__codexFocusError === 'Exact session focus is unavailable.'`);
  assert(ownerActions === 0, "Codex focus failure keeps the exact error and never launches the owner app");
  await window.webContents.executeJavaScript(`window.__focusError = null;
    window.alert = (message) => { window.__focusError = message; };
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '1', metaKey: true, bubbles: true }))`);
  await waitFor(window, `window.__focusError === 'Exact session focus is unavailable.'`);
  assert(ownerActions === 0, "keyboard owner activation also stays exact on focus failure");

  await window.webContents.executeJavaScript(`document.querySelector('[aria-label^="Open Chat for"], [aria-label^="Read chat for"]')?.click()`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Back to Sessions"]'))`);
  await window.webContents.executeJavaScript(`window.__focusError = null;
    document.querySelector('[aria-label*="Open in Ghostty"]')?.click()`);
  await waitFor(window, `window.__focusError === 'Exact session focus is unavailable.'`);
  assert(ownerActions === 0, "the Chat owner action also stays exact on focus failure");
  await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="Search sessions"]'))`);

  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Search sessions"]');
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, 'Agent');
    input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="${sessions.length} search results"]'))`);
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
    revision: snapshot.revision + 1,
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
  await window.webContents.executeJavaScript(`document.querySelectorAll('[aria-label^="Open Chat for"], [aria-label^="Read chat for"]')[27]?.click()`);
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
    const chat = document.querySelector('[aria-label^="Open Chat for"], [aria-label^="Read chat for"]');
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
    `document.querySelector('[aria-label^="Open Chat for"], [aria-label^="Read chat for"]')?.click()`,
  );
  await waitFor(window, `Boolean(document.getElementById('chat-canvas'))`);
  const darkChatCanvas = await window.webContents.executeJavaScript(
    `getComputedStyle(document.getElementById('chat-canvas')).backgroundColor`,
  );
  assert(darkChatCanvas === darkSessionsCanvas,
    `Chat and Sessions share the dark canvas (${darkSessionsCanvas} → ${darkChatCanvas})`);

  await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Search sessions"]');
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, 'Managed by Agent Room');
    input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
  await waitFor(window, `Boolean(document.querySelector('[aria-label="1 search results"]'))`);
  assert(await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label*="Agent session updated,"][aria-label*="Managed by Agent Room"]'))`),
    "managed sessions remain searchable by their managing app");

  snapshot = {
    ...snapshot, revision: snapshot.revision + 1,
    sessions: [{
      ...sessions[0], id: "unavailable-resume", title: "Agent unavailable resume",
      source: "Claude Code", owner: "Herdr", section: "history", managedBy: undefined,
      presence: { state: "closed", evidence: "authoritative_inventory", observedAt: new Date(now).toISOString() },
      sessionState: { conversation: "archived", turn: "unknown", route: "unavailable" },
      subtitle: "Closed terminal conversation", lifecycleStatus: "closed",
      canOpenOwner: false, canEnterChat: true, canRemoveHistory: true,
      resumeState: "unavailable",
      resumeReason: "Automatic resume for Herdr isn’t supported yet. Resume this session manually in Herdr.",
    }],
  };
  for (const subscriber of subscribers) subscriber(snapshot);
  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Search sessions"]');
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, '');
    input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
  const restingResume = await window.webContents.executeJavaScript(`(() => ({
    reasonVisible: document.body.textContent.includes('Automatic resume for Herdr isn’t supported yet. Resume this session manually in Herdr.'),
    more: Boolean(document.querySelector('[aria-label="More actions for Agent unavailable resume"]')),
    rowHeight: document.querySelector('[aria-label^="Agent unavailable resume,"]')?.getBoundingClientRect().height,
  }))()`);
  assert(!restingResume.reasonVisible && restingResume.more, "known unsupported resume stays out of the resting row but advertises More");
  await window.webContents.executeJavaScript(
    `document.querySelector('[aria-label="More actions for Agent unavailable resume"]')?.click()`,
  );
  await waitFor(window, `document.body.textContent.includes('Automatic resume for Herdr isn’t supported yet. Resume this session manually in Herdr.')`);
  const resumeMenu = await window.webContents.executeJavaScript(`(() => {
    const menu = document.querySelector('[aria-label="More actions for Agent unavailable resume"] + [role="menu"]')
      || document.querySelector('[aria-label="More actions for Agent unavailable resume"]')?.parentElement.querySelector('[role="menu"]');
    const reason = [...(menu?.querySelectorAll('*') ?? [])].find(element => !element.children.length
      && element.textContent === 'Automatic resume for Herdr isn’t supported yet. Resume this session manually in Herdr.');
    const remove = menu?.querySelector('[aria-label="Remove Agent unavailable resume from Agent Visor"]');
    const textStyle = reason ? getComputedStyle(reason) : undefined;
    return {
      menu: Boolean(menu),
      reason: Boolean(reason),
      heading: menu?.textContent.includes('Automatic resume unavailable') === true,
      completeText: Boolean(reason && textStyle
        && reason.scrollHeight <= reason.clientHeight + 1
        && reason.scrollWidth <= reason.clientWidth + 1
        && textStyle.textOverflow !== 'ellipsis'
        && (!textStyle.webkitLineClamp || textStyle.webkitLineClamp === 'none')),
      removalInMenu: Boolean(remove && menu?.contains(remove)),
      horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth,
    };
  })()`);
  assert(resumeMenu.menu && resumeMenu.reason && resumeMenu.heading,
    "More exposes one neutral unsupported-resume explanation on demand");
  assert(resumeMenu.completeText && !resumeMenu.horizontalOverflow,
    "the entire resume reason remains visible without horizontal overflow");
  assert(resumeMenu.removalInMenu, "eligible removal is grouped into More without deleting source history");
  await window.webContents.executeJavaScript(`window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`);
  await waitFor(window, `!document.querySelector('[role="menu"]')`);
  await window.webContents.executeJavaScript(`(() => {
    const button = document.querySelector('[aria-label="More actions for Agent unavailable resume"]');
    button?.focus();
    button?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  })()`);
  await waitFor(window, `Boolean(document.querySelector('[role="menu"]'))`);
  const moreKeyboard = await window.webContents.executeJavaScript(`document.activeElement?.getAttribute('aria-label')`);
  assert(moreKeyboard === "More actions for Agent unavailable resume",
    "More opens from its keyboard-accessible button without moving row focus");
  await window.webContents.executeJavaScript(`window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`);
  await waitFor(window, `!document.querySelector('[role="menu"]')`);

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
