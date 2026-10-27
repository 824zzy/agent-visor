import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, nativeTheme } from "electron";
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
mkdirSync(screenshotRoot, { recursive: true });
writeFileSync(herdrTranscript, "{\"kind\":\"assistant\",\"text\":\"Herdr transcript fixture\"}\n");
writeFileSync(ghosttyTranscript, "{\"kind\":\"assistant\",\"text\":\"Ghostty transcript fixture\"}\n");
writeFileSync(repairTranscript, "{\"kind\":\"assistant\",\"text\":\"Repair transcript fixture\"}\n");
app.setPath("userData", profileRoot);

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

  const provider = {
    id: "codex",
    discover: async () => [
      {
        id: "current-owner",
        provider: "codex",
        title: "Current owner",
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
    assert(initial.ownerSource?.includes("Open in Codex") && initial.moreCount === 3,
      "real repository rows preserve source identity and expose More for eligible retained actions");

    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="More actions for Saved Herdr read-only"]')?.click()`,
    );
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
    await window.webContents.executeJavaScript(`window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`);
    await waitFor(window, `!document.querySelector('[role="menu"]')`);

    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="More actions for Saved Locate folder"]')?.click()`,
    );
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Locate folder for Saved Locate folder"]'))`);
    assert(await window.webContents.executeJavaScript(
      `Boolean(document.querySelector('[aria-label="Locate folder for Saved Locate folder"]'))`,
    ), "real repairable retained rows keep their existing Locate folder action in More");
    await window.webContents.executeJavaScript(`window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`);
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

    await window.webContents.executeJavaScript(`{
      for (let index = 0; index < 15; index += 1) {
        window.dispatchEvent(new KeyboardEvent('keydown', { key: '-', metaKey: true, bubbles: true }));
      }
    }`);
    await new Promise((resolve) => setTimeout(resolve, 100));
    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="More actions for Saved Herdr read-only"]')?.click()`,
    );
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Remove Saved Herdr read-only from Agent Visor"]'))`);
    await window.webContents.executeJavaScript(
      `document.querySelector('[aria-label="Remove Saved Herdr read-only from Agent Visor"]')?.click()`,
    );
    await waitFor(window, `!document.querySelector('[aria-label^="Saved Herdr read-only,"]')`);
    assert(!repository.historyPage().sessions.some(({ id }) => id === "saved-herdr"),
      "real repository readback confirms More Remove affects only Agent Visor retained history");

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

async function waitFor(window, expression, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await window.webContents.executeJavaScript(expression)) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out waiting for ${expression}`);
}
