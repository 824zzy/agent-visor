import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, ipcMain, nativeTheme } from "electron";
import { RetainedHistoryStore } from "../../server/dist/retained-history.js";
import { SessionRepository } from "../../server/dist/sessions.js";
import { startServer } from "../../server/dist/server.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const token = "session-row-repository-test-token-000000000000000000";
const profileRoot = mkdtempSync(path.join(os.tmpdir(), "agent-visor-session-row-profile-"));
const fixtureRoot = mkdtempSync(path.join(os.tmpdir(), "agent-visor-session-row-data-"));
const configuredScreenshotRoot = process.env.AGENT_VISOR_SESSION_ROW_ARTIFACT_ROOT;
const screenshotRoot = configuredScreenshotRoot
  ? path.resolve(configuredScreenshotRoot)
  : mkdtempSync(path.join(os.tmpdir(), "agent-visor-session-row-artifacts-"));
const ownsScreenshotRoot = !configuredScreenshotRoot;
const observedAt = "2026-10-26T22:00:00.000Z";
const historyPath = path.join(fixtureRoot, "retained-history.json");
const herdrTranscript = path.join(fixtureRoot, "herdr.jsonl");
const ghosttyTranscript = path.join(fixtureRoot, "ghostty.jsonl");
const repairTranscript = path.join(fixtureRoot, "repair.jsonl");
let repairPickerCalls = 0;
mkdirSync(screenshotRoot, { recursive: true });
writeFileSync(herdrTranscript, "{\"kind\":\"assistant\",\"text\":\"Herdr transcript fixture\"}\n");
writeFileSync(ghosttyTranscript, "{\"kind\":\"assistant\",\"text\":\"Ghostty transcript fixture\"}\n");
writeFileSync(repairTranscript, "{\"kind\":\"assistant\",\"text\":\"Repair transcript fixture\"}\n");
app.setPath("userData", profileRoot);
ipcMain.handle("history:pick-repair-path", async (_event, kind) => {
  if (kind !== "workingDirectory") return undefined;
  repairPickerCalls += 1;
  return fixtureRoot;
});

void app.whenReady()
  .then(run)
  .then(() => app.exit(0))
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });

async function run() {
  nativeTheme.themeSource = "light";
  let server;
  let window;
  const history = new RetainedHistoryStore({ path: historyPath, now: () => new Date(observedAt) });
  history.observeMany([
    {
      id: "saved-herdr",
      provider: "codex",
      title: "Saved Herdr read-only",
      subtitle: "Closed terminal conversation",
      project: "row-ui",
      owner: "Herdr",
      host: "Herdr",
      cwd: fixtureRoot,
      transcriptPath: herdrTranscript,
      resumeUnavailableReason: "host_not_supported",
      updatedAt: observedAt,
      observedAt,
      current: false,
    },
    {
      id: "saved-ghostty",
      provider: "codex",
      title: "Saved Ghostty resume",
      subtitle: "Closed terminal conversation",
      project: "row-ui",
      owner: "Ghostty",
      host: "Ghostty",
      cwd: fixtureRoot,
      configHome: fixtureRoot,
      transcriptPath: ghosttyTranscript,
      resume: {
        version: 1,
        provider: "codex_cli",
        host: "Ghostty",
        executableRef: "/bin/sh",
        configRootRef: fixtureRoot,
        profileState: "verified_absent",
        overrideNames: [],
        provenanceObservedAt: observedAt,
      },
      updatedAt: "2026-10-26T21:59:00.000Z",
      observedAt,
      current: false,
    },
    {
      id: "saved-repair",
      provider: "codex",
      title: "Saved Locate folder",
      subtitle: "Closed terminal conversation",
      project: "row-ui",
      owner: "Ghostty",
      host: "Ghostty",
      cwd: path.join(fixtureRoot, "missing-project"),
      transcriptPath: repairTranscript,
      resumeUnavailableReason: "missing_working_directory",
      updatedAt: "2026-10-26T21:58:00.000Z",
      observedAt,
      current: false,
    },
  ]);
  history.closeMissing(new Set(), "codex");

  let currentOwnerTitle = "Current owner";
  const provider = {
    id: "codex",
    discover: async () => [
      {
        id: "current-owner",
        provider: "codex",
        title: currentOwnerTitle,
        subtitle: "Provider is ready",
        project: "row-ui",
        cwd: fixtureRoot,
        owner: "Codex",
        section: "ready",
        updatedAt: "2026-10-26T22:01:00.000Z",
        canOpenOwner: true,
        canEnterChat: true,
        presence: { state: "open", evidence: "frontend", observedAt },
        conversationState: "open",
        turnState: "ready",
        routeState: "available",
      },
      {
        id: "current-owner-only",
        provider: "codex",
        title: "Current owner only",
        subtitle: "Source route only",
        project: "row-ui",
        cwd: fixtureRoot,
        owner: "Codex",
        section: "working",
        updatedAt: "2026-10-26T22:00:30.000Z",
        canOpenOwner: true,
        canEnterChat: false,
        presence: { state: "open", evidence: "frontend", observedAt },
        conversationState: "open",
        turnState: "working",
        routeState: "available",
      },
    ],
    historyLifetime: async () => "open",
    validateWorkingDirectory: async (_record, cwd) => ({ state: "valid", cwd }),
  };
  const repository = new SessionRepository([provider], {
    retainedHistoryPath: historyPath,
    now: () => new Date(observedAt),
  });
  await repository.refresh();
  server = await startServer({ port: 0, token, source: repository });
  window = new BrowserWindow({
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
    window.show();
    window.focus();
    await waitFor(window, `Boolean(document.querySelector('[aria-label^="Current owner,"]'))`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label^="Read chat for Saved Herdr read-only"]'))`);

    const initial = await window.webContents.executeJavaScript(`(() => {
      const herdr = document.querySelector('[aria-label^="Saved Herdr read-only,"]');
      const ghostty = document.querySelector('[aria-label^="Saved Ghostty resume,"]');
      const repair = document.querySelector('[aria-label^="Saved Locate folder,"]');
      const owner = document.querySelector('[aria-label^="Current owner,"]');
      const herdrRow = herdr?.closest('[id^="session-row-"]');
      const ghosttyRow = ghostty?.closest('[id^="session-row-"]');
      const repairRow = repair?.closest('[id^="session-row-"]');
      const ownerRow = owner?.closest('[id^="session-row-"]');
      return {
        herdrPrimary: herdr?.getAttribute('aria-label'),
        herdrChat: herdrRow?.querySelector('[aria-label^="Read chat for"]')?.getAttribute('aria-label'),
        ghosttyResume: ghosttyRow?.querySelector('[aria-label^="Resume Saved Ghostty resume in Ghostty"]')?.getAttribute('aria-label'),
        ghosttyChat: ghosttyRow?.querySelector('[aria-label^="Read chat for"]')?.getAttribute('aria-label'),
        repairMore: repairRow?.querySelector('[aria-label="More actions for Saved Locate folder"]')?.getAttribute('aria-label'),
        ownerChat: ownerRow?.querySelector('[aria-label^="Open Chat for Current owner"]')?.getAttribute('aria-label'),
        ownerSource: owner?.getAttribute('aria-label'),
        moreCount: document.querySelectorAll('[aria-label^="More actions for"]').length,
      };
    })()`);
    assert(!initial.herdrPrimary?.includes("Open in") && !initial.herdrPrimary?.includes("Resume"),
      "real retained Chat-only rows leave the source slot blank");
    assert(initial.herdrChat?.includes("Read chat") && initial.herdrChat?.includes("read-only transcript"),
      "real retained closed rows expose read-only Chat without granting control");
    assert(initial.ghosttyResume && initial.ghosttyChat,
      "real retained Ghostty rows keep explicit Resume in the source slot and Read chat in Chat");
    assert(initial.repairMore && initial.ownerChat?.startsWith("Open Chat for"),
      "real repository rows reserve More only for secondary work while Current keeps Open Chat");
    assert(initial.ownerSource?.includes("Open in Codex") && initial.ownerSource?.includes(fixtureRoot)
      && initial.moreCount === 3,
      "real repository rows preserve source identity, full cwd context and More for eligible retained actions");

    await window.webContents.sendInputEvent({ type: "mouseMove", x: 2, y: 2 });
    await new Promise((resolve) => setTimeout(resolve, 50));
    const resumeBounds = await window.webContents.executeJavaScript(`(() => {
      const row = document.querySelector('[aria-label^="Saved Ghostty resume,"]')?.closest('[id^="session-row-"]');
      const resume = row?.querySelector('[aria-label^="Resume Saved Ghostty resume in Ghostty"]');
      const rect = resume?.getBoundingClientRect();
      return rect ? { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 } : undefined;
    })()`);
    const resumeBefore = await window.webContents.executeJavaScript(`(() => {
      const primary = document.querySelector('[aria-label^="Saved Ghostty resume,"]');
      return primary ? getComputedStyle(primary).backgroundColor : undefined;
    })()`);
    if (resumeBounds) {
      await window.webContents.sendInputEvent({ type: "mouseMove", x: Math.round(resumeBounds.x), y: Math.round(resumeBounds.y) });
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    const resumeAfter = await window.webContents.executeJavaScript(`(() => {
      const primary = document.querySelector('[aria-label^="Saved Ghostty resume,"]');
      return primary ? getComputedStyle(primary).backgroundColor : undefined;
    })()`);
    const resumeHover = { before: resumeBefore, after: resumeAfter };
    assert(resumeHover.before === resumeHover.after,
      `Resume hover stays source-local instead of highlighting the primary target (${JSON.stringify(resumeHover)})`);

    await window.webContents.executeJavaScript(`(() => {
      const input = document.querySelector('[aria-label="Search sessions"]');
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      setter.call(input, 'row-ui');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    })()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="5 search results"]'))`);
    await sendKeyGesture(window, "ARROWDOWN");
    const beforeMore = await browserState(window);

    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="More actions for Saved Herdr read-only"]')?.focus()`,
    );
    await sendKeyGesture(window, "ENTER");
    await waitFor(window, `Boolean(document.querySelector('[role="menu"]'))`);
    assert(await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="More actions for Saved Herdr read-only"]')?.getAttribute('aria-expanded') === 'true'`,
    ), "a real Enter keydown/keyup gesture opens More exactly once");
    await sendKeyGesture(window, "ARROWDOWN");
    const afterArrow = await browserState(window);
    assert(afterArrow.cursor === beforeMore.cursor
      && afterArrow.query === beforeMore.query
      && afterArrow.scrollTop === beforeMore.scrollTop
      && afterArrow.rowLabel === beforeMore.rowLabel,
    `More interaction keys do not move the browser state (${JSON.stringify({ beforeMore, afterArrow })})`);
    await waitFor(window, `document.body.textContent.includes('Automatic resume for Herdr isn’t supported yet. Resume this session manually in Herdr.')`);
    const herdrMenu = await window.webContents.executeJavaScript(`(() => {
      const row = document.querySelector('[aria-label^="Saved Herdr read-only,"]')?.closest('[id^="session-row-"]');
      const menu = row?.querySelector('[role="menu"]');
      return {
        reason: menu?.textContent.includes('Automatic resume for Herdr isn’t supported yet. Resume this session manually in Herdr.') === true,
        remove: Boolean(menu?.querySelector('[aria-label="Remove Saved Herdr read-only from Agent Visor"]')),
        source: row?.querySelector('[aria-label^="Open in"]') === null,
        readOnly: row?.querySelector('[aria-label^="Read chat for"]') !== null,
      };
    })()`);
    assert(herdrMenu.reason && herdrMenu.remove && herdrMenu.source && herdrMenu.readOnly,
      "real retained More keeps the complete neutral resume reason and exact eligible Remove action");
    const defaultMenuGeometry = await window.webContents.executeJavaScript(`(() => {
      const menu = document.querySelector('[aria-label="More actions for Saved Herdr read-only menu"]');
      const button = document.querySelector('[aria-label="More actions for Saved Herdr read-only"]');
      const scroller = [...document.querySelectorAll('*')].find((item) => {
        const style = getComputedStyle(item);
        return style.overflowY === 'auto' || style.overflowY === 'scroll';
      });
      const menuRect = menu?.getBoundingClientRect();
      const menuStyle = menu ? getComputedStyle(menu) : undefined;
      const buttonRect = button?.getBoundingClientRect();
      const clipRect = scroller?.getBoundingClientRect();
      return {
        menuTop: menuRect?.top,
        menuBottom: menuRect?.bottom,
        clipTop: clipRect?.top,
        clipBottom: clipRect?.bottom,
        buttonTop: buttonRect?.top,
        buttonBottom: buttonRect?.bottom,
        cssTop: menuStyle?.top,
        cssBottom: menuStyle?.bottom,
        cssPosition: menuStyle?.position,
        cssMaxHeight: menuStyle?.maxHeight,
        remove: Boolean(menu?.querySelector('[aria-label="Remove Saved Herdr read-only from Agent Visor"]')),
      };
    })()`);
    assert(defaultMenuGeometry.remove
      && defaultMenuGeometry.menuTop >= defaultMenuGeometry.clipTop - 1
      && defaultMenuGeometry.menuBottom <= defaultMenuGeometry.clipBottom + 1,
    `default More placement stays within the Sessions viewport (${JSON.stringify(defaultMenuGeometry)})`);
    currentOwnerTitle = "Current owner updated";
    await repository.refresh();
    await waitFor(window, `Boolean(document.querySelector('[aria-label^="Current owner updated,"]'))`);
    const afterBackground = await window.webContents.executeJavaScript(`(() => {
      const row = document.querySelector('[aria-label^="Saved Herdr read-only,"]')?.closest('[id^="session-row-"]');
      return {
        rowID: row?.id,
        menu: row?.querySelector('[role="menu"]')?.getAttribute('aria-label'),
      };
    })()`);
    assert(afterBackground.rowID === "session-row-saved-herdr"
      && afterBackground.menu === "More actions for Saved Herdr read-only menu"
      && repository.current().sessions.some(({ id, title }) => id === "current-owner" && title === "Current owner updated"),
    "background refresh preserves the open More identity and does not retarget its conversation");
    await sendKeyGesture(window, "ESCAPE");
    await waitFor(window, `!document.querySelector('[role="menu"]')`);
    const afterMore = await browserState(window);
    assert(afterMore.query === beforeMore.query
      && afterMore.cursor === beforeMore.cursor
      && afterMore.scrollTop === beforeMore.scrollTop
      && afterMore.rowLabel === beforeMore.rowLabel,
    `opening and dismissing More preserves query, cursor, viewport and attention identity (${JSON.stringify({ beforeMore, afterMore })})`);
    window.setSize(1_040, 760);
    await new Promise((resolve) => setTimeout(resolve, 100));

    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="More actions for Saved Locate folder"]')?.focus()`,
    );
    await sendKeyGesture(window, "ENTER");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Locate folder for Saved Locate folder"]'))`);
    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="Locate folder for Saved Locate folder"]')?.focus()`,
    );
    await sendKeyGesture(window, "ENTER");
    await waitUntil(() => repairPickerCalls >= 1);
    assert(repairPickerCalls === 1, "a real Enter keydown/keyup gesture launches Repair exactly once");
    await waitUntil(() => repository.historyPage().sessions.find(({ id }) => id === "saved-repair")?.cwd === fixtureRoot);
    assert(repository.historyPage().sessions.find(({ id }) => id === "saved-repair")?.cwd === fixtureRoot,
      "Repair applies the exact selected working directory to retained history");
    await sendKeyGesture(window, "ESCAPE");
    await waitFor(window, `!document.querySelector('[role="menu"]')`);

    await captureScreenshot("session-row-default-light.png", window);
    nativeTheme.themeSource = "dark";
    await new Promise((resolve) => setTimeout(resolve, 100));
    await captureScreenshot("session-row-default-dark.png", window);

    await window.webContents.executeJavaScript(`{
      for (let index = 0; index < 15; index += 1) {
        window.dispatchEvent(new KeyboardEvent('keydown', { key: '+', metaKey: true, bubbles: true }));
      }
    }`);
    window.setSize(960, 680);
    await new Promise((resolve) => setTimeout(resolve, 150));
    const scaled = await window.webContents.executeJavaScript(`(() => {
      const row = document.querySelector('[aria-label^="Saved Ghostty resume,"]')?.closest('[id^="session-row-"]');
      const action = row?.querySelector('[aria-label^="Resume Saved Ghostty resume in Ghostty"]');
      const chat = row?.querySelector('[aria-label^="Read chat for"]');
      return {
        horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth,
        rowHeight: row?.getBoundingClientRect().height ?? 0,
        actionHeight: action?.getBoundingClientRect().height ?? 0,
        chatHeight: chat?.getBoundingClientRect().height ?? 0,
        visibleActionText: action?.firstElementChild?.textContent,
      };
    })()`);
    assert(!scaled.horizontalOverflow && scaled.rowHeight >= 58 && scaled.actionHeight >= 32 && scaled.chatHeight >= 32,
      "real repository rows stay readable and aligned at constrained high content scale");
    assert(scaled.visibleActionText === "Resume Ghostty",
      `high-scale Resume keeps its visible destination: ${JSON.stringify(scaled)}`);
    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label^="Saved Ghostty resume,"]')?.closest('[id^="session-row-"]')?.scrollIntoView({ block: "center" })`,
    );
    await new Promise((resolve) => setTimeout(resolve, 100));
    await captureScreenshot("session-row-high-scale-dark.png", window);

    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label^="Saved Locate folder,"]')?.closest('[id^="session-row-"]')?.scrollIntoView({ block: "end" })`,
    );
    await new Promise((resolve) => setTimeout(resolve, 100));
    const beforeBottomMore = await browserState(window);
    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="More actions for Saved Locate folder"]')?.focus()`,
    );
    await sendKeyGesture(window, "ENTER");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Locate folder for Saved Locate folder"]'))`);
    const bottomMenuGeometry = await window.webContents.executeJavaScript(`(() => {
      const menu = document.querySelector('[aria-label="More actions for Saved Locate folder menu"]');
      const button = document.querySelector('[aria-label="More actions for Saved Locate folder"]');
      const row = button?.closest('[id^="session-row-"]');
      const scroller = [...document.querySelectorAll('*')].find((item) => {
        const style = getComputedStyle(item);
        return style.overflowY === 'auto' || style.overflowY === 'scroll';
      });
      const menuRect = menu?.getBoundingClientRect();
      const menuStyle = menu ? getComputedStyle(menu) : undefined;
      const repairAction = menu?.querySelector('[aria-label="Locate folder for Saved Locate folder"]');
      const repairRect = repairAction?.getBoundingClientRect();
      const buttonRect = button?.getBoundingClientRect();
      const rowRect = row?.getBoundingClientRect();
      const clipRect = scroller?.getBoundingClientRect();
      return {
        menuTop: menuRect?.top,
        menuBottom: menuRect?.bottom,
        menuHeight: menuRect?.height,
        buttonTop: buttonRect?.top,
        buttonBottom: buttonRect?.bottom,
        rowTop: rowRect?.top,
        rowBottom: rowRect?.bottom,
        clipTop: clipRect?.top,
        clipBottom: clipRect?.bottom,
        scrollHeight: menu?.scrollHeight,
        clientHeight: menu?.clientHeight,
        cssTop: menuStyle?.top,
        cssBottom: menuStyle?.bottom,
        cssPosition: menuStyle?.position,
        repairTop: repairRect?.top,
        repairBottom: repairRect?.bottom,
        reason: menu?.textContent.includes('Automatic resume') === true,
        repair: Boolean(menu?.querySelector('[aria-label="Locate folder for Saved Locate folder"]')),
      };
    })()`);
    assert(bottomMenuGeometry.reason && bottomMenuGeometry.repair
      && bottomMenuGeometry.menuTop >= bottomMenuGeometry.clipTop - 1
      && bottomMenuGeometry.menuBottom <= bottomMenuGeometry.clipBottom + 1,
    `high-scale bottom More placement stays within the Sessions viewport (${JSON.stringify(bottomMenuGeometry)})`);
    if (bottomMenuGeometry.repairBottom > bottomMenuGeometry.menuBottom + 1) {
      await window.webContents.executeJavaScript(
        `document.querySelector('[aria-label="More actions for Saved Locate folder menu"]')?.scrollTo({ top: 9999 })`,
      );
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    const visibleBottomRepair = await window.webContents.executeJavaScript(`(() => {
      const menu = document.querySelector('[aria-label="More actions for Saved Locate folder menu"]');
      const repair = menu?.querySelector('[aria-label="Locate folder for Saved Locate folder"]');
      const menuRect = menu?.getBoundingClientRect();
      const repairRect = repair?.getBoundingClientRect();
      return {
        menuTop: menuRect?.top,
        menuBottom: menuRect?.bottom,
        repairTop: repairRect?.top,
        repairBottom: repairRect?.bottom,
      };
    })()`);
    assert(visibleBottomRepair.repairTop >= visibleBottomRepair.menuTop - 1
      && visibleBottomRepair.repairBottom <= visibleBottomRepair.menuBottom + 1,
    `high-scale bottom More keeps the eligible Repair action reachable by menu scroll (${JSON.stringify(visibleBottomRepair)})`);
    const afterBottomMore = await browserState(window);
    assert(afterBottomMore.query === beforeBottomMore.query
      && afterBottomMore.cursor === beforeBottomMore.cursor
      && afterBottomMore.scrollTop === beforeBottomMore.scrollTop
      && afterBottomMore.rowLabel === beforeBottomMore.rowLabel,
    `opening bottom More preserves query, cursor, viewport and attention identity (${JSON.stringify({ beforeBottomMore, afterBottomMore })})`);
    await captureScreenshot("session-row-bottom-menu-high-scale-dark.png", window);
    await sendKeyGesture(window, "ESCAPE");
    await waitFor(window, `!document.querySelector('[aria-label="More actions for Saved Locate folder menu"]')`);

    await window.webContents.executeJavaScript(`{
      for (let index = 0; index < 15; index += 1) {
        window.dispatchEvent(new KeyboardEvent('keydown', { key: '-', metaKey: true, bubbles: true }));
      }
    }`);
    await new Promise((resolve) => setTimeout(resolve, 100));
    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="More actions for Saved Herdr read-only"]')?.focus()`,
    );
    await sendKeyGesture(window, "ENTER");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Remove Saved Herdr read-only from Agent Visor"]'))`);
    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="Remove Saved Herdr read-only from Agent Visor"]')?.focus()`,
    );
    await sendKeyGesture(window, "ENTER");
    await waitFor(window, `!document.querySelector('[aria-label^="Saved Herdr read-only,"]')`);
    assert(!repository.historyPage().sessions.some(({ id }) => id === "saved-herdr"),
      "real repository readback confirms More Remove affects only Agent Visor retained history");
    assert(repository.historyPage().sessions.some(({ id }) => id === "saved-ghostty")
      && repository.historyPage().sessions.some(({ id }) => id === "saved-repair"),
    "More Remove changes only the exact retained history row");

    console.log("Session-row repository PASS: real repository projection, fixed slots, More effects, and high-scale geometry.");
  } finally {
    nativeTheme.themeSource = "system";
    window.destroy();
    await server.close();
    rmSync(fixtureRoot, { recursive: true, force: true });
    rmSync(profileRoot, { recursive: true, force: true });
    if (ownsScreenshotRoot) rmSync(screenshotRoot, { recursive: true, force: true });
  }
}

function assert(value, message) {
  if (!value) throw new Error(`Session-row repository failed: ${message}`);
}

async function captureScreenshot(name, window) {
  const image = await window.webContents.capturePage();
  writeFileSync(path.join(screenshotRoot, name), image.toPNG());
}

async function sendKeyGesture(window, keyCode) {
  window.webContents.sendInputEvent({ type: "keyDown", keyCode });
  window.webContents.sendInputEvent({ type: "keyUp", keyCode });
  await new Promise((resolve) => setTimeout(resolve, 75));
}

async function waitUntil(predicate, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error("Timed out waiting for the fixture state.");
}

async function browserState(window) {
  return window.webContents.executeJavaScript(`(() => {
    const scroller = [...document.querySelectorAll('*')].find((item) => {
      const style = getComputedStyle(item);
      return style.overflowY === 'auto' || style.overflowY === 'scroll';
    });
    return {
      query: document.querySelector('[aria-label="Search sessions"]')?.value,
      cursor: document.querySelector('[aria-selected="true"]')?.getAttribute('aria-label'),
      scrollTop: scroller?.scrollTop ?? 0,
      rowLabel: document.querySelector('[aria-label^="Saved Herdr read-only,"]')?.getAttribute('aria-label'),
    };
  })()`);
}

async function waitFor(window, expression, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await window.webContents.executeJavaScript(expression)) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out waiting for ${expression}`);
}
