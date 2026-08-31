import { mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { app, BrowserWindow, ipcMain } from "electron";
import { startServer } from "../../server/dist/server.js";
import { rendererLocation, rendererURLAllowed, safeExternalURL } from "../dist/desktop-contract.js";
import { readImageFileURL } from "../dist/image-file-reader.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const rendererTrust = rendererLocation(path.resolve(directory, "../../app/dist/index.html"));
const token = "chat-accessibility-test-token-000000000000000000000";
const validImageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
const validImageDataURI = `data:image/png;base64,${validImageBase64}`;
const externalURLs = [];
const expectedFixtureContent = {
  "chat-item-user-1": ["Fix it"],
  "chat-item-thinking-1": ["Inspecting", "files"],
  "chat-item-tool-1": ["Bash", "45 passed"],
  "chat-item-answer-1": ["Done", "All checks passed"],
};
let mode = "history";
let activeServer;
let activeWindow;
let exitCode = 0;
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
const codexUsageSession = {
  ...session,
  id: "codex-chat-usage",
  title: "Codex Usage Chat",
  source: "Codex",
  owner: "Codex",
  subtitle: "Ready",
  updatedAt: "2026-08-22T09:30:00.000Z",
};
const claudeModeSession = {
  ...session,
  id: "claude-chat-mode",
  title: "Claude Permission Chat",
  source: "Claude Code",
  owner: "Ghostty",
  subtitle: "Agent is working",
  section: "working",
  updatedAt: "2026-08-22T09:15:00.000Z",
};
const workingSession = {
  ...session,
  id: "pi-chat-working",
  title: "Working Migration Chat",
  subtitle: "Agent is working",
  section: "working",
  updatedAt: "2026-08-22T11:00:00.000Z",
};
const secondSession = {
  ...session,
  id: "pi-chat-second",
  title: "Second Migration Chat",
  subtitle: "Independent draft",
  updatedAt: "2026-08-22T09:00:00.000Z",
};
const deliverySession = {
  ...session,
  id: "pi-chat-delivery",
  title: "Delivery Parity Chat",
  subtitle: "Delivery identity fixture",
  updatedAt: "2026-08-22T08:00:00.000Z",
};
const startupRaceSession = {
  ...session,
  id: "pi-chat-startup-race",
  title: "Startup Race Chat",
  subtitle: "Agent is working",
  section: "working",
  updatedAt: "2026-08-22T07:30:00.000Z",
};
const terminalEvidenceSession = {
  ...workingSession,
  id: "pi-chat-terminal-evidence",
  title: "Terminal Evidence Chat",
  subtitle: "Waiting for canonical turn evidence",
  updatedAt: "2026-08-22T07:15:00.000Z",
};
const scopedExpirySession = {
  ...workingSession,
  id: "pi-chat-scoped-expiry",
  title: "Scoped Expiry Chat",
  subtitle: "Pending delivery scope fixture",
  updatedAt: "2026-08-22T07:05:00.000Z",
};
const tailSession = {
  ...session,
  id: "pi-chat-tail",
  title: "Tail Policy Chat",
  subtitle: "Streaming tail fixture",
  updatedAt: "2026-08-22T06:00:00.000Z",
};
const recoveryWorkingSession = {
  ...session,
  id: "pi-chat-recovery-working",
  title: "Recovery Working Chat",
  subtitle: "Agent is working",
  section: "working",
  updatedAt: "2026-08-22T07:00:00.000Z",
};
const endedSession = {
  ...session,
  id: "pi-chat-ended",
  title: "Ended Migration Chat",
  subtitle: "Session ended",
  section: "history",
  updatedAt: "2026-08-21T09:00:00.000Z",
};
const invalidPageSession = {
  ...session,
  id: "pi-chat-invalid-page",
  title: "Invalid Chat Response",
  subtitle: "Protocol error",
  updatedAt: "2026-08-20T09:00:00.000Z",
};
const invalidSlashSession = {
  ...session,
  id: "pi-chat-invalid-slash",
  title: "Invalid Slash Response",
  subtitle: "Protocol error",
  updatedAt: "2026-08-19T09:00:00.000Z",
};
const fixtureSessions = [session, codexUsageSession, claudeModeSession, workingSession, deliverySession, startupRaceSession, terminalEvidenceSession, scopedExpirySession, recoveryWorkingSession, tailSession, secondSession, endedSession, invalidPageSession, invalidSlashSession];
const tailFixture = {
  // ponytail: keep this fixture larger than the initial renderer window so the
  // E2E check proves bounded DOM history rather than a short-list accident.
  items: Array.from({ length: 400 }, (_, index) => ({
    id: `tail-row-${index + 1}`,
    kind: "assistant",
    text: `Tail row ${index + 1}`,
  })),
  streamRevision: 0,
  publish: undefined,
  bumpStream() {
    this.streamRevision += 1;
    const last = this.items.at(-1);
    if (last) last.text = `Tail row ${this.items.length} stream tick ${this.streamRevision}`;
    this.publish?.();
  },
  appendTail() {
    const next = this.items.length + 1;
    this.items.push({ id: `tail-row-${next}`, kind: "assistant", text: `Tail row ${next}` });
    this.publish?.();
  },
};

void (async () => {
  try {
    await app.whenReady();
    await run();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
    exitCode = 1;
  } finally {
    if (activeWindow && !activeWindow.isDestroyed()) activeWindow.destroy();
    activeWindow = undefined;
    if (activeServer) {
      const server = activeServer;
      activeServer = undefined;
      await server.close().catch(() => undefined);
    }
    if (app.isReady()) app.exit(exitCode);
  }
})();

async function run() {
  const actions = [];
  const listeners = new Set();
  let revision = 1;
  const updatedAtBySession = new Map(fixtureSessions.map((entry) => [entry.id, entry.updatedAt]));
  const snapshotSessions = () => fixtureSessions.map((entry) => ({
    ...entry,
    updatedAt: updatedAtBySession.get(entry.id) ?? entry.updatedAt,
  }));
  const publish = (sessionId = session.id) => {
    revision += 1;
    const current = updatedAtBySession.get(sessionId) ?? session.updatedAt;
    updatedAtBySession.set(sessionId, new Date(Date.parse(current) + 1_000).toISOString());
    for (const listener of listeners) listener({
      type: "session_snapshot",
      revision,
      sessions: snapshotSessions(),
    });
  };
  tailFixture.publish = () => publish(tailSession.id);
  let ownerActions = 0;
  let cancelAttempts = 0;
  let claudePermissionMode = "default";
  let releaseFirstCancel;
  const deliveryFixture = {
    canonical: [],
    pendingCanonical: [],
    ackBeforePageConsumed: false,
    revealPendingCanonical: false,
    repeatAckReleases: [],
    releasePageBeforeAck: undefined,
    releaseTimeout: undefined,
    releaseStale: undefined,
    releaseConflict: undefined,
    releaseCancelSend: undefined,
    releaseCancelFailureSend: undefined,
    recoveryCancelDeliveryId: undefined,
    releaseCancelSafe: undefined,
    cancelFailureDeliveryId: undefined,
    cancelFailureRequest: undefined,
    releaseCancelFailureAction: undefined,
    cancelSafeDeliveryId: undefined,
    releaseRetryCancel: undefined,
    startupRaceDeliveryId: undefined,
    startupRaceConfirmed: false,
    startupRacePageMode: "old",
    publishStartupRacePage: undefined,
    confirmStartupRace: undefined,
    releaseStartupRaceCancel: undefined,
    terminalEvidenceDeliveryId: undefined,
    terminalEvidenceRequestId: undefined,
    terminalEvidenceMode: "baseline",
    publishTerminalEvidencePage: undefined,
    releaseScopedExpiry: undefined,
    scopedExpiryDeliveryId: undefined,
    retrySuccessAttempts: 0,
    retryFailureAttempts: 0,
    recoveryCanonical: [],
    sequence: 0,
  };
  deliveryFixture.publishStartupRacePage = (pageMode) => {
    deliveryFixture.startupRacePageMode = pageMode;
    publish(startupRaceSession.id);
  };
  deliveryFixture.confirmStartupRace = () => {
    deliveryFixture.startupRaceConfirmed = true;
    deliveryFixture.startupRacePageMode = "matching";
    publish(startupRaceSession.id);
  };
  deliveryFixture.publishTerminalEvidencePage = (mode) => {
    deliveryFixture.terminalEvidenceMode = mode;
    publish(terminalEvidenceSession.id);
  };
  ipcMain.on("session:open-owner", () => { ownerActions += 1; });
  const source = {
    current: () => ({
      type: "session_snapshot",
      revision,
      sessions: snapshotSessions(),
    }),
    subscribe: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    chatPage: async (sessionId, before) => {
      const requested = fixtureSessions.find((entry) => entry.id === sessionId) ?? session;
      if (requested.id === endedSession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "ended-answer", kind: "assistant", text: "This session is complete." }],
          hasMoreBefore: false,
          capabilities: capabilities(requested),
          pendingAction: null,
        };
      }
      if (requested.id === claudeModeSession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "claude-mode-answer", kind: "assistant", text: "Claude mode fixture." }],
          hasMoreBefore: false,
          metadata: {
            model: "Claude Sonnet",
            permissionMode: claudePermissionMode,
          },
          capabilities: {
            canSendText: true,
            canSendImages: true,
            canCancel: true,
            cancelDeliveryId: "claude-mode-delivery",
            canApprove: false,
            canAnswer: false,
            canCyclePermissionMode: true,
          },
          pendingAction: null,
        };
      }
      if (requested.id === deliverySession.id) {
        if (deliveryFixture.pendingCanonical.length
          && (deliveryFixture.ackBeforePageConsumed || deliveryFixture.revealPendingCanonical)) {
          deliveryFixture.canonical.push(...deliveryFixture.pendingCanonical);
          deliveryFixture.pendingCanonical = [];
          deliveryFixture.revealPendingCanonical = false;
        } else if (deliveryFixture.pendingCanonical.length && !deliveryFixture.ackBeforePageConsumed) {
          deliveryFixture.ackBeforePageConsumed = true;
        }
        return {
          type: "chat_page",
          sessionId,
          items: deliveryFixture.canonical,
          hasMoreBefore: false,
          capabilities: capabilities(requested),
          pendingAction: null,
        };
      }
      if (requested.id === startupRaceSession.id) {
        const startupRaceCancelDeliveryId = deliveryFixture.startupRaceConfirmed
          ? deliveryFixture.startupRaceDeliveryId
          : deliveryFixture.startupRacePageMode === "wrong"
            ? "startup-race-wrong-delivery"
            : deliveryFixture.startupRacePageMode === "missing"
              ? null
              : undefined;
        return {
          type: "chat_page",
          sessionId,
          items: [
            { id: "startup-race-answer", kind: "assistant", text: "Startup race fixture." },
          ],
          hasMoreBefore: false,
          capabilities: capabilities(
            requested,
            startupRaceCancelDeliveryId,
          ),
          pendingAction: null,
        };
      }
      if (requested.id === terminalEvidenceSession.id) {
        const terminalEvidenceCancelDeliveryId = deliveryFixture.terminalEvidenceMode === "matching"
          ? deliveryFixture.terminalEvidenceDeliveryId
          : null;
        const canonical = [
          { id: "terminal-evidence-baseline", kind: "user", text: "Prior prompt", images: [] },
        ];
        if (deliveryFixture.terminalEvidenceMode === "matching"
          || deliveryFixture.terminalEvidenceMode === "external") {
          canonical.push({
            id: "terminal-evidence-matching",
            kind: "user",
            text: "terminal-delayed-echo",
            images: [],
            requestId: deliveryFixture.terminalEvidenceRequestId,
            deliveryId: deliveryFixture.terminalEvidenceDeliveryId,
          });
        }
        if (deliveryFixture.terminalEvidenceMode === "external") {
          canonical.push({
            id: "terminal-evidence-external",
            kind: "user",
            text: "external same-target turn",
            images: [],
          });
        }
        return {
          type: "chat_page",
          sessionId,
          items: canonical,
          hasMoreBefore: false,
          capabilities: capabilities(requested, terminalEvidenceCancelDeliveryId),
          pendingAction: null,
        };
      }
      if (requested.id === scopedExpirySession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [],
          hasMoreBefore: false,
          capabilities: capabilities(requested),
          pendingAction: null,
        };
      }
      if (requested.id === tailSession.id) {
        if (before !== undefined) {
          return {
            type: "chat_page",
            sessionId,
            items: Array.from({ length: 20 }, (_, index) => ({
              id: `tail-earlier-${index + 1}`,
              kind: "assistant",
              text: `Earlier tail row ${index + 1}`,
            })),
            hasMoreBefore: false,
            capabilities: capabilities(requested),
            pendingAction: null,
          };
        }
        return {
          type: "chat_page",
          sessionId,
          items: tailFixture.items,
          hasMoreBefore: true,
          nextBefore: 1,
          capabilities: capabilities(requested),
          pendingAction: null,
        };
      }
      if (requested.id === recoveryWorkingSession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: deliveryFixture.recoveryCanonical,
          hasMoreBefore: false,
          capabilities: capabilities(requested, deliveryFixture.recoveryCancelDeliveryId),
          pendingAction: null,
        };
      }
      if (requested.id === secondSession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "second-answer", kind: "assistant", text: "Second session content." }],
          hasMoreBefore: false,
          capabilities: capabilities(requested),
          pendingAction: null,
        };
      }
      if (requested.id === invalidPageSession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [],
          hasMoreBefore: false,
          capabilities: capabilities(requested),
          pendingAction: null,
          unexpected: true,
        };
      }
      if (requested.id === invalidSlashSession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "invalid-slash-answer", kind: "assistant", text: "Slash test session." }],
          hasMoreBefore: false,
          capabilities: capabilities(requested),
          pendingAction: null,
        };
      }
      if (before !== undefined) {
        return {
          type: "chat_page",
          sessionId,
          items: [
            { id: "older-user", kind: "user", text: "Earlier prompt", images: [] },
            { id: "older-answer", kind: "assistant", text: "Earlier answer" },
          ],
          hasMoreBefore: false,
          capabilities: capabilities(requested),
          pendingAction: null,
        };
      }
      return {
        type: "chat_page",
        sessionId,
        items: [
          { id: "user-1", kind: "user", text: "Fix it", images: [
            { name: "diagram.png", mimeType: "image/png", data: validImageBase64 },
            { name: "remote.png", mimeType: "image/png", data: "https://history-image.invalid/remote.png" },
            { name: "local.png", mimeType: "image/png", data: "/tmp/local.png" },
          ] },
          { id: "thinking-1", kind: "thinking", text: "Inspecting ```text\nfiles\n```" },
          { id: "tool-1", kind: "tool", name: "Bash", input: { command: "npm test" }, status: "success", result: "45 passed" },
          { id: "answer-1", kind: "assistant", text: "**Done**\n\n[Open the docs](https://example.com/docs)\n\n1. **Your request reached an old API pod** (`8821978`) because [Request evidence](/Users/zhengyuanz/Codes/.scratch/service-investigation-20260830/investigation.md:27)\n2. **The replacement API pod** loaded the corrected configuration.\n\n~~old~~ *new* and $x^2$\n\n| Check | Result |\n| --- | --- |\n| Tests | **all 45 tests passed** (`packages/server`) |\n\n```text\nAll checks passed\n```" },
        ],
        hasMoreBefore: true,
        nextBefore: 100,
        metadata: {
          model: "GPT-5.6 Sol",
          modelId: "gpt-5.6-sol",
          modelProvider: "openai-codex",
          reasoningEffort: "high",
          sandbox: "workspace-write",
          approvalPolicy: "on-request",
          contextTokens: 12_000,
          contextWindow: 114_688,
          usageGlance: {
            provider: "codex",
            percentUsed: 42,
            label: "5h 42%",
            detail: "Codex usage, 5 hour 42 percent used",
            observedAt: "2026-08-22T10:00:00.000Z",
          },
        },
        capabilities: capabilities(requested),
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
    chatCommands: async (sessionId) => ({
      ...(sessionId === invalidSlashSession.id
        ? { type: "chat_commands", sessionId, truncated: false, commands: "invalid" }
        : {
          type: "chat_commands",
          sessionId,
          truncated: true,
          commands: [
            {
              name: "compact",
              aliases: [],
              description: "Summarize the conversation so far",
              argNames: [],
              source: "builtin",
              isHidden: false,
              opensInTerminalDialog: false,
            },
            {
              name: "review",
              aliases: ["inspect"],
              description: "Review the current branch",
              argNames: [],
              source: "builtin",
              isHidden: false,
              opensInTerminalDialog: false,
            },
            {
              name: "config",
              aliases: [],
              description: "Open config panel",
              argNames: [],
              source: "builtin",
              isHidden: false,
              opensInTerminalDialog: true,
            },
          ],
        }),
    }),
    chatAction: async (message) => {
      actions.push(message);
      if (message.type === "cycle_permission_mode") {
        assert(message.sessionId === claudeModeSession.id
          && message.generation > 0
          && message.expectedMode === claudePermissionMode,
        "permission mode cycle carries the exact session, generation, and expected mode");
        claudePermissionMode = message.expectedMode === "default"
          ? "acceptEdits"
          : message.expectedMode === "acceptEdits"
            ? "plan"
            : "default";
        publish(claudeModeSession.id);
        return undefined;
      }
      if (message.type === "send_chat") {
        assert(message.generation > 0 && message.deliveryId,
          "delivery fixture receives request-scoped generation and delivery identity");
        const canonicalTurn = (suffix) => ({
          id: `delivery-canonical-${++deliveryFixture.sequence}-${suffix}`,
          kind: "user",
          text: message.text,
          images: message.images,
          requestId: message.id,
          deliveryId: message.deliveryId,
        });
        if (message.text === "ack-before-canonical") {
          deliveryFixture.pendingCanonical = [canonicalTurn("ack-before-page")];
          deliveryFixture.ackBeforePageConsumed = false;
          return undefined;
        }
        if (message.text === "page-before-ack") {
          deliveryFixture.canonical.push(canonicalTurn("page-before-ack"));
          return new Promise((resolve) => { deliveryFixture.releasePageBeforeAck = resolve; });
        }
        if (message.text === "repeat") {
          deliveryFixture.pendingCanonical.push(canonicalTurn("repeat"));
          deliveryFixture.revealPendingCanonical = true;
          return new Promise((resolve) => { deliveryFixture.repeatAckReleases.push(resolve); });
        }
        if (message.text === "failed-send") return "Provider rejected this message.";
        if (message.text === "retry-success") {
          deliveryFixture.retrySuccessAttempts += 1;
          if (deliveryFixture.retrySuccessAttempts === 2) {
            // The ACK is not transcript proof by itself.  Make the fixture
            // publish the exact replacement identity on the subsequent page
            // so the recovery card is consumed by canonical evidence rather
            // than by the action result alone.
            deliveryFixture.pendingCanonical = [canonicalTurn("retry-success")];
            deliveryFixture.ackBeforePageConsumed = true;
          }
          return deliveryFixture.retrySuccessAttempts === 1
            ? "Initial delivery failed; retry is available."
            : undefined;
        }
        if (message.text === "retry-failure") {
          deliveryFixture.retryFailureAttempts += 1;
          return deliveryFixture.retryFailureAttempts === 1
            ? "Initial delivery failed; retry is available."
            : "Retry failed again.";
        }
        if (message.text === "conflict-send") {
          return new Promise((resolve) => { deliveryFixture.releaseConflict = resolve; });
        }
        if (message.text === "timeout-send") {
          return new Promise((resolve) => { deliveryFixture.releaseTimeout = resolve; });
        }
        if (message.text === "cancel-safe") {
          deliveryFixture.cancelSafeDeliveryId = message.deliveryId;
          deliveryFixture.recoveryCancelDeliveryId = message.deliveryId;
          publish(recoveryWorkingSession.id);
          return new Promise((resolve) => { deliveryFixture.releaseCancelSend = resolve; });
        }
        if (message.text === "cancel-fail") {
          deliveryFixture.cancelFailureDeliveryId = message.deliveryId;
          deliveryFixture.recoveryCancelDeliveryId = message.deliveryId;
          publish(recoveryWorkingSession.id);
          return new Promise((resolve) => { deliveryFixture.releaseCancelFailureSend = resolve; });
        }
        if (message.text === "startup-race-b") {
          deliveryFixture.startupRaceDeliveryId = message.deliveryId;
          return undefined;
        }
        if (message.text === "terminal-delayed-echo") {
          deliveryFixture.terminalEvidenceDeliveryId = message.deliveryId;
          deliveryFixture.terminalEvidenceRequestId = message.id;
          deliveryFixture.terminalEvidenceMode = "baseline";
          return undefined;
        }
        if (message.text === "scoped-expiry") {
          deliveryFixture.scopedExpiryDeliveryId = message.deliveryId;
          return new Promise((resolve) => { deliveryFixture.releaseScopedExpiry = resolve; });
        }
        if (message.text === "stale-send") {
          return new Promise((resolve) => { deliveryFixture.releaseStale = resolve; });
        }
      }
      if (message.type === "respond_chat") mode = "history";
      if (message.type === "cancel_chat") {
        if (message.sessionId === startupRaceSession.id) {
          return new Promise((resolve) => { deliveryFixture.releaseStartupRaceCancel = resolve; });
        }
        if (message.sessionId === recoveryWorkingSession.id) {
          if (message.deliveryId === deliveryFixture.cancelFailureDeliveryId) {
            deliveryFixture.cancelFailureRequest = {
              id: message.id,
              sessionId: message.sessionId,
              generation: message.generation,
              deliveryId: message.deliveryId,
            };
            return new Promise((resolve) => { deliveryFixture.releaseCancelFailureAction = resolve; });
          }
          if (message.deliveryId === deliveryFixture.cancelSafeDeliveryId) {
            return new Promise((resolve) => { deliveryFixture.releaseCancelSafe = resolve; });
          }
          return message.deliveryId === undefined
            ? "The fixture requires a delivery identity."
            : undefined;
        }
        cancelAttempts += 1;
        if (cancelAttempts === 1) {
          return new Promise((resolve) => { releaseFirstCancel = resolve; });
        }
        if (cancelAttempts === 2) return "The fixture could not stop this turn.";
        if (cancelAttempts === 3) {
          return new Promise((resolve) => { deliveryFixture.releaseRetryCancel = resolve; });
        }
      }
      return undefined;
    },
  };
  const server = await startServer({ port: 0, token, source });
  activeServer = server;
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
  activeWindow = window;
  const remoteImageRequests = [];
  window.webContents.session.webRequest.onBeforeRequest(
    { urls: ["https://history-image.invalid/*"] },
    (details, callback) => {
      remoteImageRequests.push(details.url);
      callback({});
    },
  );
  assert(rendererTrust, "the focused harness uses the production renderer trust location");
  assert(
    rendererURLAllowed(rendererTrust, pathToFileURL(path.resolve(directory, "../../app/dist/index.html")).href),
    "the packaged renderer entry is allowed by the production trust contract",
  );
  assert(
    !rendererURLAllowed(rendererTrust, "http://127.0.0.1:8081/chat"),
    "an unexpected dev origin is rejected by the production trust contract",
  );
  assert(
    !rendererURLAllowed(rendererTrust, pathToFileURL(path.resolve(directory, "../../app/dist/other.html")).href),
    "an unexpected packaged navigation is rejected by the production trust contract",
  );
  ipcMain.handle("chat:read-image-file", (event, value) => (
    event.sender === window.webContents
      && event.senderFrame
      && rendererURLAllowed(rendererTrust, event.senderFrame.url)
      ? readImageFileURL(value)
      : undefined
  ));
  ipcMain.handle("chat:open-external", async (event, value) => {
    const url = safeExternalURL(value);
    if (event.sender !== window.webContents
      || !event.senderFrame
      || !rendererTrust
      || !rendererURLAllowed(rendererTrust, event.senderFrame.url)
      || !url) return false;
    externalURLs.push(url);
    return true;
  });
  const fixtureDirectory = await mkdtemp(path.join("/tmp", "agent-visor-paste-"));
  const fixturePath = path.join(fixtureDirectory, "finder-copy.png");
  await writeFile(fixturePath, Buffer.from(
    validImageDataURI.slice(validImageDataURI.indexOf(",") + 1),
    "base64",
  ));

  try {
    await window.loadFile(path.resolve(directory, "../../app/dist/index.html"));
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Migration Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Done')`);
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label*="used"]')`),
      "a non-Codex session does not display a Codex-only usage glance",
    );
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label="Stop agent"]')`),
      "ready Chat does not advertise a Stop control",
    );

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Codex Usage Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Codex Usage Chat"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label*="42% used"]'))`);
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Codex usage, 5 hour 42 percent used; 42% used"]'))`),
      "Codex Chat shows the authoritative usage glance with its provider detail",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Claude Permission Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Claude Permission Chat"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Permission mode: Default"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Permission mode: Default"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "cycle_permission_mode"
      && action.sessionId === claudeModeSession.id
      && action.expectedMode === "default"));
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Permission mode: Accept Edits"]'))`);
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Permission mode: Accept Edits"]'))`),
      "Claude Chat cycles permission mode through the exact action seam",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Tail Policy Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Tail Policy Chat"]')?.click()`);
    await waitFor(window, `document.querySelector('[aria-label="Chat timeline update"]')?.textContent.includes('Tail row 400')`);
    const boundedInitialTail = await window.webContents.executeJavaScript(`(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      return {
        rows: document.querySelectorAll('[id^="chat-item-tail-row-"]').length,
        overflow: timeline ? timeline.scrollHeight > timeline.clientHeight : false,
      };
    })()`);
    assert(boundedInitialTail.rows > 0 && boundedInitialTail.rows < 400 && boundedInitialTail.overflow,
      `initial grouped Chat history uses a bounded rendered window (${JSON.stringify(boundedInitialTail)})`);
    await waitFor(window, `(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      return Boolean(timeline && timeline.scrollHeight > timeline.clientHeight
        && timeline.scrollHeight - (timeline.scrollTop + timeline.clientHeight) <= 2);
    })()`);

    await window.webContents.executeJavaScript(`(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      if (!timeline) return;
      timeline.dispatchEvent(new Event('touchstart', { bubbles: true }));
      timeline.scrollTop = 0;
      timeline.dispatchEvent(new Event('scroll', { bubbles: true }));
    })()`);
    const farBeforeStream = await measureTimeline(window);
    tailFixture.bumpStream();
    await waitFor(window, `document.querySelector('[aria-label="Chat timeline update"]')?.textContent.includes('stream tick 1')`);
    const farAfterStream = await measureTimeline(window);
    assert(farAfterStream.scrollTop <= farBeforeStream.scrollTop + 2,
      `stream growth preserves a reader parked away from the tail (${farBeforeStream.scrollTop} → ${farAfterStream.scrollTop})`);

    await window.webContents.executeJavaScript(`(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      if (!timeline) return;
      timeline.dispatchEvent(new Event('touchstart', { bubbles: true }));
      timeline.scrollTop = timeline.scrollHeight;
      timeline.dispatchEvent(new Event('scroll', { bubbles: true }));
    })()`);
    tailFixture.bumpStream();
    await waitFor(window, `document.querySelector('[aria-label="Chat timeline update"]')?.textContent.includes('stream tick 2')`);
    const nearAfterStream = await measureTimeline(window);
    assert(nearAfterStream.distanceFromBottom <= 2,
      `stream growth keeps a near-tail reader pinned (${JSON.stringify(nearAfterStream)})`);

    await window.webContents.executeJavaScript(`(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      if (!timeline) return;
      timeline.dispatchEvent(new Event('touchstart', { bubbles: true }));
      timeline.scrollTop = Math.min(180, Math.max(0, timeline.scrollHeight - timeline.clientHeight));
      timeline.dispatchEvent(new Event('scroll', { bubbles: true }));
    })()`);
    // FlatList recycles cells asynchronously after a programmatic scroll;
    // wait for a mounted row in the reader viewport before measuring the
    // prepend anchor instead of sampling the old render window.
    await waitFor(window, `(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      const viewport = timeline?.getBoundingClientRect();
      return Boolean(timeline && viewport && [...timeline.querySelectorAll('[id^="chat-item-tail-row-"]')]
        .some((candidate) => {
          const rect = candidate.getBoundingClientRect();
          return rect.bottom > viewport.top && rect.top < viewport.bottom;
        }));
    })()`);
    const anchorBefore = await window.webContents.executeJavaScript(`(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      const viewport = timeline?.getBoundingClientRect();
      const rows = [...(timeline?.querySelectorAll('[id^="chat-item-tail-row-"]') ?? [])];
      const row = rows
        .find((candidate) => {
          const rect = candidate.getBoundingClientRect();
          return viewport && rect.bottom > viewport.top && rect.top < viewport.bottom;
        });
      return row ? {
        id: row.id,
        top: row.getBoundingClientRect().top,
        nativeID: timeline?.id ?? "",
        scrollTop: timeline?.scrollTop ?? -1,
      } : {
        rows: rows.length,
        timeline: timeline ? {
          scrollTop: timeline.scrollTop,
          scrollHeight: timeline.scrollHeight,
          clientHeight: timeline.clientHeight,
          top: viewport?.top,
          bottom: viewport?.bottom,
        } : undefined,
        rowRects: rows.slice(0, 3).map((candidate) => {
          const rect = candidate.getBoundingClientRect();
          return { id: candidate.id, top: rect.top, bottom: rect.bottom, height: rect.height };
        }),
      };
    })()`);
    if (!anchorBefore?.id) throw new Error(`Unable to capture prepend anchor: ${JSON.stringify(anchorBefore)}`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Load earlier messages"]')?.click()`);
    // Earlier rows are intentionally outside the mounted window after the
    // prepend; the retained-count status is the authoritative data signal.
    await waitFor(window, `document.body.textContent.includes('Showing 420 retained messages')`);
    const expandedTail = await window.webContents.executeJavaScript(`(() => ({
      retained: document.body.textContent.includes('Showing 420 retained messages') ? 420 : 0,
      mounted: document.querySelectorAll('[id^="chat-item-tail-row-"], [id^="chat-item-tail-earlier-"]').length,
    }))()`);
    assert(expandedTail.retained > 0 && expandedTail.mounted < expandedTail.retained,
      `expanded grouped Chat history stays virtualized (${JSON.stringify(expandedTail)})`);
    await waitFor(window, `Boolean(document.getElementById(${JSON.stringify(anchorBefore?.id ?? "")})?.getClientRects().length)`);
    const anchorAfter = await window.webContents.executeJavaScript(`(() => {
      const row = document.getElementById(${JSON.stringify(anchorBefore?.id ?? "")});
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      return row ? {
        top: row.getBoundingClientRect().top,
        scrollTop: timeline?.scrollTop ?? -1,
        scrollHeight: timeline?.scrollHeight ?? -1,
      } : undefined;
    })()`);
    assert(anchorBefore?.top !== undefined && anchorAfter !== undefined
      && Math.abs(anchorAfter.top - anchorBefore.top) <= 2,
      `earlier-page prepend preserves the reader viewport (${JSON.stringify(anchorBefore)} → ${JSON.stringify(anchorAfter)})`);

    await window.webContents.executeJavaScript(`(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      if (!timeline) return;
      timeline.dispatchEvent(new Event('touchstart', { bubbles: true }));
      timeline.scrollTop = 0;
      timeline.dispatchEvent(new Event('scroll', { bubbles: true }));
    })()`);
    const farBeforeInsert = await measureTimeline(window);
    tailFixture.appendTail();
    // The appended row may be outside the virtualized DOM window while the
    // reader is far from the tail. The retained-count status is the
    // renderer-independent proof that the transcript grew.
    await waitFor(window, `document.body.textContent.includes('Showing 421 retained messages')`);
    const farAfterInsert = await measureTimeline(window);
    assert(farAfterInsert.scrollTop <= farBeforeInsert.scrollTop + 2,
      `tail insert does not steal a reader away from older context (${farBeforeInsert.scrollTop} → ${farAfterInsert.scrollTop})`);

    await window.webContents.executeJavaScript(`(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      if (!timeline) return;
      timeline.dispatchEvent(new Event('touchstart', { bubbles: true }));
      timeline.scrollTop = timeline.scrollHeight;
      timeline.dispatchEvent(new Event('scroll', { bubbles: true }));
    })()`);
    const nearBeforeInsert = await measureTimeline(window);
    tailFixture.appendTail();
    await waitFor(window, `document.body.textContent.includes('Showing 422 retained messages')`);
    const nearAfterInsert = await measureTimeline(window);
    assert(nearAfterInsert.distanceFromBottom <= 2,
      `tail insert keeps a near-tail reader pinned (${JSON.stringify(nearAfterInsert)})`);

    await window.webContents.executeJavaScript(`(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      if (!timeline) return;
      timeline.dispatchEvent(new Event('touchstart', { bubbles: true }));
      timeline.scrollTop = 0;
      timeline.dispatchEvent(new Event('scroll', { bubbles: true }));
    })()`);
    await setInput(window, "Chat message", "Local tail send");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    // The composer already contains this text before submit; wait for the
    // optimistic delivery row and draft clear so the pin assertion samples
    // the post-send layout rather than the pre-submit viewport.
    await waitFor(window, `(() => {
      const row = [...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .find((candidate) => candidate.textContent?.includes('Local tail send'));
      const input = document.querySelector('[aria-label="Chat message"]');
      return Boolean(row && input && input.value === '');
    })()`);
    const afterLocalSend = await measureTimeline(window);
    assert(afterLocalSend.distanceFromBottom <= 2,
      `an explicit local send pins the conversation even from an older scroll position (${JSON.stringify(afterLocalSend)})`);

    const nearBeforeComposerResize = await measureTimeline(window);
    await setInput(window, "Chat message", "near line 1\nnear line 2\nnear line 3\nnear line 4\nnear line 5\nnear line 6");
    await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value.includes('near line 6')`);
    await new Promise((resolve) => setTimeout(resolve, 100));
    const nearAfterComposerResize = await measureTimeline(window);
    assert(nearAfterComposerResize.distanceFromBottom <= 2,
      `composer resize keeps a near-tail reader pinned (${JSON.stringify({ before: nearBeforeComposerResize, after: nearAfterComposerResize })})`);
    await clearComposer(window);

    await window.webContents.executeJavaScript(`(() => {
      const timeline = document.querySelector('[aria-label="Chat timeline"]');
      if (!timeline) return;
      timeline.dispatchEvent(new Event('touchstart', { bubbles: true }));
      timeline.scrollTop = 0;
      timeline.dispatchEvent(new Event('scroll', { bubbles: true }));
    })()`);
    const farBeforeComposerResize = await measureTimeline(window);
    await setInput(window, "Chat message", "far line 1\nfar line 2\nfar line 3\nfar line 4\nfar line 5\nfar line 6");
    await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value.includes('far line 6')`);
    await new Promise((resolve) => setTimeout(resolve, 100));
    const farAfterComposerResize = await measureTimeline(window);
    assert(farAfterComposerResize.scrollTop <= farBeforeComposerResize.scrollTop + 2,
      `composer resize preserves a reader parked away from the tail (${JSON.stringify({ before: farBeforeComposerResize, after: farAfterComposerResize })})`);
    await clearComposer(window);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Startup Race Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Startup Race Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Startup race fixture.')`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
    await setInput(window, "Chat message", "startup-race-b");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "startup-race-b"));
    await waitFor(window, `!document.querySelector('[aria-label="Stop agent"]')`);
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label="Stop agent"]')`),
      "a new delivery stays non-cancellable until the daemon confirms its exact active identity",
    );
    deliveryFixture.publishStartupRacePage?.("wrong");
    await waitFor(window, `!document.querySelector('[aria-label="Stop agent"]')`);
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label="Stop agent"]')`),
      "a page with a wrong delivery identity cannot expose Stop for the new delivery",
    );
    deliveryFixture.publishStartupRacePage?.("missing");
    await waitFor(window, `!document.querySelector('[aria-label="Stop agent"]')`);
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label="Stop agent"]')`),
      "a page without a delivery identity cannot expose Stop during the startup gap",
    );
    deliveryFixture.confirmStartupRace?.();
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Stop agent"]'))`),
      "Stop appears after a page confirms the new delivery identity",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Stop agent"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Canceling agent"]'))`);
    await waitUntil(() => actions.some((action) => action.type === "cancel_chat"
      && action.sessionId === startupRaceSession.id
      && action.deliveryId === deliveryFixture.startupRaceDeliveryId));
    deliveryFixture.releaseStartupRaceCancel?.();
    deliveryFixture.releaseStartupRaceCancel = undefined;
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Agent stopped"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Terminal Evidence Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Terminal Evidence Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Prior prompt')`);
    await setInput(window, "Chat message", "terminal-delayed-echo");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "terminal-delayed-echo"));
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-pending-"]')]
      .some((row) => row.textContent?.trim() === 'terminal-delayed-echo'))`);
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label="Stop agent"]')`),
      "a terminal send keeps Stop hidden while its provider echo is delayed",
    );
    deliveryFixture.publishTerminalEvidencePage?.("baseline");
    await waitFor(window, `!document.querySelector('[aria-label="Stop agent"]')`);
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label="Stop agent"]')`),
      "a baseline-only canonical page cannot authorize the pending terminal delivery",
    );
    deliveryFixture.publishTerminalEvidencePage?.("matching");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Stop agent"]'))`),
      "Stop appears only after the canonical page confirms the exact new delivery identity",
    );
    deliveryFixture.publishTerminalEvidencePage?.("external");
    await waitFor(window, `!document.querySelector('[aria-label="Stop agent"]')`);
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label="Stop agent"]')`),
      "a later external same-target user turn removes Stop for the prior delivery",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Scoped Expiry Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Scoped Expiry Chat"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Chat message"]'))`);
    await setInput(window, "Chat message", "scoped-expiry");
    await addPickerImage(window, "scoped-expiry.png");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image scoped-expiry.png"]'))`);
    await window.webContents.executeJavaScript(`(() => {
      const originalNow = Date.now;
      const originalSetTimeout = globalThis.setTimeout;
      globalThis.__agentVisorOriginalDateNow = originalNow;
      globalThis.__agentVisorOriginalSetTimeout = originalSetTimeout;
      globalThis.__agentVisorDeliveryNow = originalNow();
      globalThis.__agentVisorExpiryRun = undefined;
      globalThis.__agentVisorStaleExpiryRun = undefined;
      Date.now = () => globalThis.__agentVisorDeliveryNow;
      globalThis.setTimeout = (run, delay, ...args) => {
        if (delay >= 29_000) {
          globalThis.__agentVisorExpiryRun = run;
          return 0;
        }
        return originalSetTimeout(run, delay, ...args);
      };
    })()`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "scoped-expiry"));
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-pending-"]')]
      .some((row) => row.textContent?.trim() === 'scoped-expiry'))`);
    await window.webContents.executeJavaScript(`(() => {
      if (typeof globalThis.__agentVisorExpiryRun !== 'function') {
        throw new Error('Chat accessibility failed: scoped-expiry timer was not captured');
      }
      globalThis.__agentVisorStaleExpiryRun = globalThis.__agentVisorExpiryRun;
      globalThis.__agentVisorExpiryRun = undefined;
    })()`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Second Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Second Migration Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Second session content.')`);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === ''
        && !document.querySelector('[aria-label="Attached image scoped-expiry.png"]')
        && !document.querySelector('[aria-label="Chat delivery recovery"]')
        && !document.body.textContent.includes('The provider did not confirm this message before the delivery window expired.')`),
      "switching from a pending A delivery to B does not leak A failure, draft, or attachment state",
    );
    await window.webContents.executeJavaScript(`(() => {
      globalThis.__agentVisorDeliveryNow += 31_000;
      const release = globalThis.__agentVisorStaleExpiryRun;
      globalThis.__agentVisorStaleExpiryRun = undefined;
      release?.();
    })()`);
    await waitFor(window, `document.body.textContent.includes('Second session content.')`);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === ''
        && !document.querySelector('[aria-label="Attached image scoped-expiry.png"]')
        && !document.querySelector('[aria-label="Chat delivery recovery"]')`),
      "releasing A's stale expiry timer after navigation is harmless in B",
    );
    await window.webContents.executeJavaScript(`(() => {
      if (globalThis.__agentVisorOriginalDateNow) Date.now = globalThis.__agentVisorOriginalDateNow;
      if (globalThis.__agentVisorOriginalSetTimeout) globalThis.setTimeout = globalThis.__agentVisorOriginalSetTimeout;
      delete globalThis.__agentVisorOriginalDateNow;
      delete globalThis.__agentVisorOriginalSetTimeout;
      delete globalThis.__agentVisorDeliveryNow;
      delete globalThis.__agentVisorStaleExpiryRun;
    })()`);
    deliveryFixture.releaseScopedExpiry?.();
    deliveryFixture.releaseScopedExpiry = undefined;
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Delivery Parity Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Delivery Parity Chat"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Chat message"]'))`);

    await setInput(window, "Chat message", "ack-before-canonical");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "ack-before-canonical"));
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-pending-"]')]
      .filter((row) => row.textContent?.includes('ack-before-canonical')).length === 1)`);
    assert(
      await window.webContents.executeJavaScript(`([...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .filter((row) => row.textContent?.includes('ack-before-canonical')).length === 1)`),
      "an optimistic user row appears immediately for a submitted message",
    );
    await waitFor(window, `document.body.textContent.includes('ack-before-canonical')`);
    assert(
      await window.webContents.executeJavaScript(`([...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .filter((row) => row.textContent?.includes('ack-before-canonical')).length === 1)`),
      "an acknowledgement before the canonical page does not lose the optimistic row",
    );

    publish(deliverySession.id);
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-"]')]
      .filter((row) => row.textContent?.trim() === 'ack-before-canonical').length === 1
      && ![...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .some((row) => row.textContent?.includes('ack-before-canonical')))`);
    assert(
      await window.webContents.executeJavaScript(`![...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .some((row) => row.textContent?.includes('ack-before-canonical'))`),
      "the canonical page consumes the retained optimistic row",
    );
    publish(deliverySession.id);
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-"]')]
      .filter((row) => row.textContent?.trim() === 'ack-before-canonical').length === 1)`);
    assert(
      await window.webContents.executeJavaScript(`([...document.querySelectorAll('[id^="chat-item-"]')]
        .filter((row) => row.textContent?.trim() === 'ack-before-canonical').length === 1)`),
      "replaying a canonical page does not duplicate the user row",
    );

    await setInput(window, "Chat message", "page-before-ack");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "page-before-ack"));
    publish(deliverySession.id);
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-"]')]
      .filter((row) => row.textContent?.trim() === 'page-before-ack').length === 1
      && ![...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .some((row) => row.textContent?.includes('page-before-ack')))`);
    assert(
      await window.webContents.executeJavaScript(`![...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .some((row) => row.textContent?.includes('page-before-ack'))`),
      "a canonical page before the action acknowledgement reconciles immediately",
    );
    deliveryFixture.releasePageBeforeAck?.();
    deliveryFixture.releasePageBeforeAck = undefined;
    await new Promise((resolve) => setTimeout(resolve, 50));

    await setInput(window, "Chat message", "repeat");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await setInput(window, "Chat message", "repeat");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.filter((action) => action.type === "send_chat" && action.text === "repeat").length === 2);
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-pending-"]')]
      .filter((row) => row.textContent?.trim() === 'repeat').length === 2)`);
    publish(deliverySession.id);
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-"]')]
      .filter((row) => row.textContent?.trim() === 'repeat').length === 2
      && ![...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .some((row) => row.textContent?.trim() === 'repeat'))`);
    assert(
      await window.webContents.executeJavaScript(`![...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .some((row) => row.textContent?.trim() === 'repeat')`),
      "two identical submissions reconcile as two distinct canonical rows",
    );
    publish(deliverySession.id);
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-"]')]
      .filter((row) => row.textContent?.trim() === 'repeat').length === 2)`);
    for (const release of deliveryFixture.repeatAckReleases.splice(0)) release();
    await new Promise((resolve) => setTimeout(resolve, 50));

    await clearComposer(window);
    await setInput(window, "Chat message", "failed-send");
    await addPickerImage(window, "failed-attachment.png");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image failed-attachment.png"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "failed-send"));
    await waitFor(window, `document.body.textContent.includes('Provider rejected this message.')`);
    assert(
      await window.webContents.executeJavaScript(`([...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .filter((row) => row.textContent?.trim() === 'failed-send').length === 1)`),
      "a failed send keeps the submitted text visible as a failed optimistic row",
    );
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === 'failed-send'
        && Boolean(document.querySelector('[aria-label="Attached image failed-attachment.png"]'))
        && Boolean(document.querySelector('[aria-label="Retry failed message"]'))
        && Boolean(document.querySelector('[aria-label="Dismiss failed message"]'))`),
      "a failed send restores the exact text and attachment snapshot with accessible recovery actions",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Dismiss failed message"]')?.click()`);
    await waitFor(window, `!document.querySelector('[aria-label="Dismiss failed message"]')`);
    assert(
      await window.webContents.executeJavaScript(`![...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .some((row) => row.textContent?.trim() === 'failed-send')`),
      "dismissing a failed recovery removes only its synthetic row",
    );

    await clearComposer(window);
    await setInput(window, "Chat message", "timeout-send");
    await addPickerImage(window, "timeout-attachment.png");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image timeout-attachment.png"]'))`);
    await window.webContents.executeJavaScript(`(() => {
      const originalNow = Date.now;
      const originalSetTimeout = globalThis.setTimeout;
      globalThis.__agentVisorOriginalDateNow = originalNow;
      globalThis.__agentVisorOriginalSetTimeout = originalSetTimeout;
      globalThis.__agentVisorDeliveryNow = originalNow();
      globalThis.__agentVisorExpiryRun = undefined;
      Date.now = () => globalThis.__agentVisorDeliveryNow;
      globalThis.setTimeout = (run, delay, ...args) => {
        if (delay >= 29_000) {
          globalThis.__agentVisorExpiryRun = run;
          return 0;
        }
        return originalSetTimeout(run, delay, ...args);
      };
    })()`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "timeout-send"));
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-pending-"]')]
      .filter((row) => row.textContent?.trim() === 'timeout-send').length === 1)`);
    await window.webContents.executeJavaScript(`(() => {
      if (typeof globalThis.__agentVisorExpiryRun !== 'function') {
        throw new Error('Chat accessibility failed: expiry scheduler did not expose its bounded timer');
      }
      globalThis.__agentVisorDeliveryNow += 31_000;
      const release = globalThis.__agentVisorExpiryRun;
      globalThis.__agentVisorExpiryRun = undefined;
      release();
    })()`);
    await waitFor(window, `document.body.textContent.includes('The provider did not confirm this message before the delivery window expired.')`);
    assert(
      await window.webContents.executeJavaScript(`([...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .filter((row) => row.textContent?.trim() === 'timeout-send').length === 1)`),
      "the fake-clock expiry path keeps an unconfirmed submission visible as failed",
    );
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === 'timeout-send'
        && Boolean(document.querySelector('[aria-label="Attached image timeout-attachment.png"]'))
        && Boolean(document.querySelector('[aria-label="Retry failed message"]'))`),
      "the fake-clock expiry path restores the exact text and attachment snapshot",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Dismiss failed message"]')?.click()`);
    await waitFor(window, `!document.querySelector('[aria-label="Dismiss failed message"]')`);
    await window.webContents.executeJavaScript(`(() => {
      if (globalThis.__agentVisorOriginalDateNow) Date.now = globalThis.__agentVisorOriginalDateNow;
      if (globalThis.__agentVisorOriginalSetTimeout) globalThis.setTimeout = globalThis.__agentVisorOriginalSetTimeout;
      delete globalThis.__agentVisorOriginalDateNow;
      delete globalThis.__agentVisorOriginalSetTimeout;
    })()`);
    deliveryFixture.releaseTimeout?.();
    deliveryFixture.releaseTimeout = undefined;
    await new Promise((resolve) => setTimeout(resolve, 50));

    await clearComposer(window);
    await setInput(window, "Chat message", "conflict-send");
    await addPickerImage(window, "conflict-original.png");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image conflict-original.png"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "conflict-send"));
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-pending-"]')]
      .some((row) => row.textContent?.trim() === 'conflict-send'))`);
    await clearComposer(window);
    await setInput(window, "Chat message", "newer draft wins");
    await addPickerImage(window, "conflict-newer.png");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image conflict-newer.png"]'))`);
    deliveryFixture.releaseConflict?.("Provider rejected after a newer edit.");
    deliveryFixture.releaseConflict = undefined;
    await waitFor(window, `document.body.textContent.includes('Provider rejected after a newer edit.')`);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === 'newer draft wins'
        && Boolean(document.querySelector('[aria-label="Attached image conflict-newer.png"]'))
        && !Boolean(document.querySelector('[aria-label="Attached image conflict-original.png"]'))
        && Boolean(document.querySelector('[aria-label="Retry failed message"]'))`),
      "a newer text and attachment draft is preserved while retry remains available",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Dismiss failed message"]')?.click()`);
    await waitFor(window, `!document.querySelector('[aria-label="Dismiss failed message"]')`);

    await clearComposer(window);
    await setInput(window, "Chat message", "retry-success");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.filter((action) => action.type === "send_chat" && action.text === "retry-success").length === 1);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Retry failed message"]'))`);
    await window.webContents.executeJavaScript(`(() => {
      const button = document.querySelector('[aria-label="Retry failed message"]');
      button?.click();
      button?.click();
    })()`);
    await waitUntil(() => actions.filter((action) => action.type === "send_chat" && action.text === "retry-success").length === 2);
    const retrySuccessIdentities = actions
      .filter((action) => action.type === "send_chat" && action.text === "retry-success")
      .map((action) => ({ requestId: action.id, deliveryId: action.deliveryId }));
    assert(retrySuccessIdentities.length === 2
      && retrySuccessIdentities[0].requestId !== retrySuccessIdentities[1].requestId
      && retrySuccessIdentities[0].deliveryId !== retrySuccessIdentities[1].deliveryId,
    "retry uses one new request/delivery identity even when clicked twice");
    await waitFor(window, `!document.querySelector('[aria-label="Chat delivery recovery"]')`);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === ''`),
      "a successful retry consumes the recovery and clears only its restored draft",
    );

    await clearComposer(window);
    await setInput(window, "Chat message", "retry-failure");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.filter((action) => action.type === "send_chat" && action.text === "retry-failure").length === 1);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Retry failed message"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Retry failed message"]')?.click()`);
    await waitUntil(() => actions.filter((action) => action.type === "send_chat" && action.text === "retry-failure").length === 2);
    await waitFor(window, `document.body.textContent.includes('Retry failed again.')`);
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Retry failed message"]'))
        && document.querySelector('[aria-label="Chat message"]')?.value === 'retry-failure'`),
      "a failed retry remains actionable and restores its immutable snapshot",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Dismiss failed message"]')?.click()`);
    await waitFor(window, `!document.querySelector('[aria-label="Dismiss failed message"]')`);

    await clearComposer(window);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Recovery Working Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Recovery Working Chat"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Chat message"]'))`);

    await setInput(window, "Chat message", "cancel-safe");
    await addPickerImage(window, "cancel-safe-attachment.png");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image cancel-safe-attachment.png"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "cancel-safe"));
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-pending-"]')]
      .some((row) => row.textContent?.trim() === 'cancel-safe'))`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Stop agent"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Canceling agent"]'))`);
    await waitUntil(() => actions.some((action) => action.type === "cancel_chat"
      && action.sessionId === recoveryWorkingSession.id
      && action.deliveryId === deliveryFixture.cancelSafeDeliveryId));
    deliveryFixture.releaseCancelSafe?.();
    deliveryFixture.releaseCancelSafe = undefined;
    await waitFor(window, `Boolean(document.querySelector('[aria-label^="Message canceled:"]'))`);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === 'cancel-safe'
        && Boolean(document.querySelector('[aria-label="Attached image cancel-safe-attachment.png"]'))
        && ![...document.querySelectorAll('[id^="chat-item-pending-"]')]
          .some((row) => row.textContent?.trim() === 'cancel-safe')`),
      "confirmed cancellation restores the exact draft and hides the canceled synthetic row",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Dismiss canceled message"]')?.click()`);
    await waitFor(window, `!document.querySelector('[aria-label^="Message canceled:"]')`);
    deliveryFixture.releaseCancelSend?.();
    deliveryFixture.releaseCancelSend = undefined;
    await new Promise((resolve) => setTimeout(resolve, 50));

    await clearComposer(window);
    await setInput(window, "Chat message", "cancel-fail");
    await addPickerImage(window, "cancel-fail-attachment.png");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image cancel-fail-attachment.png"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "cancel-fail"));
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-pending-"]')]
      .some((row) => row.textContent?.trim() === 'cancel-fail'))`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Stop agent"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Canceling agent"]'))`);
    await waitUntil(() => actions.some((action) => action.type === "cancel_chat"
      && action.id === deliveryFixture.cancelFailureRequest?.id
      && action.sessionId === recoveryWorkingSession.id
      && action.generation > 0
      && action.deliveryId === deliveryFixture.cancelFailureDeliveryId));
    assert(
      deliveryFixture.cancelFailureRequest?.sessionId === recoveryWorkingSession.id
        && deliveryFixture.cancelFailureRequest?.generation > 0
        && deliveryFixture.cancelFailureRequest?.deliveryId === deliveryFixture.cancelFailureDeliveryId,
      "cancel failure fixture retains the exact request/session/generation/delivery identity",
    );
    deliveryFixture.releaseCancelFailureAction?.("The turn could not be cancelled.");
    deliveryFixture.releaseCancelFailureAction = undefined;
    await waitFor(window, `document.body.textContent.includes('The turn could not be cancelled.')`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Retry stopping agent"]'))`);
    const cancelFailureState = await window.webContents.executeJavaScript(`({
      input: document.querySelector('[aria-label="Chat message"]')?.value,
      canceled: Boolean(document.querySelector('[aria-label^="Message canceled:"]')),
      pending: [...document.querySelectorAll('[id^="chat-item-pending-"]')]
        .map((row) => row.textContent?.trim()),
    })`);
    assert(
      cancelFailureState.input === ''
        && !cancelFailureState.canceled
        && cancelFailureState.pending.includes('cancel-fail'),
      "cancel failure leaves the working draft empty and the pending delivery visible without recovery",
    );
    deliveryFixture.releaseCancelFailureSend?.();
    deliveryFixture.releaseCancelFailureSend = undefined;
    await new Promise((resolve) => setTimeout(resolve, 50));

    await setInput(window, "Chat message", "stale-send");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "stale-send"));
    await waitFor(window, `([...document.querySelectorAll('[id^="chat-item-pending-"]')]
      .filter((row) => row.textContent?.trim() === 'stale-send').length === 1)`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Second Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Second Migration Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Second session content.')`);
    deliveryFixture.releaseStale?.();
    deliveryFixture.releaseStale = undefined;
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert(
      await window.webContents.executeJavaScript(`!document.body.textContent.includes('stale-send')`),
      "a stale send acknowledgement does not leak into a different Chat session",
    );

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Migration Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Done')`);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Working Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Working Migration Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Done')`);
    const cancellationsBeforeWorking = actions.filter((action) => action.type === "cancel_chat").length;
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Stop agent"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Canceling agent"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Canceling agent"]')?.click()`);
    await waitUntil(() => actions.filter((action) => action.type === "cancel_chat").length === cancellationsBeforeWorking + 1);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Canceling agent"]')?.getAttribute('aria-disabled') === 'true'`),
      "Canceling disables repeated Stop clicks",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Migration Chat"]'))`);
    releaseFirstCancel?.("The stale cancellation result was ignored.");
    releaseFirstCancel = undefined;
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert(
      await window.webContents.executeJavaScript(`!document.body.textContent.includes('The stale cancellation result was ignored.')`),
      "a cancellation result from a closed Chat generation does not leak into the next session",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Working Migration Chat"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Stop agent"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Stop agent"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('The fixture could not stop this turn.')`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Retry stopping agent"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Retry stopping agent"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Canceling agent"]'))`);
    await waitUntil(() => actions.filter((action) => action.type === "cancel_chat").length === cancellationsBeforeWorking + 3);
    deliveryFixture.releaseRetryCancel?.();
    deliveryFixture.releaseRetryCancel = undefined;
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Agent stopped"]'))`);
    await waitUntil(() => actions.filter((action) => action.type === "cancel_chat").length === cancellationsBeforeWorking + 3);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Migration Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Done')`);
    assert(
      await window.webContents.executeJavaScript(`!document.body.textContent.includes('**Done**')`),
      "basic Markdown emphasis renders without raw markers",
    );
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Link: Open the docs"]'))
        && Boolean(document.querySelector('[aria-label="Markdown table"]'))
        && Boolean(document.querySelector('[aria-label="Code block (text)"]'))
        && Boolean(document.querySelector('[aria-label="Formula: x^2"]'))
        && document.body.textContent.includes('old')
        && document.body.textContent.includes('new')`),
      "rich Chat content preserves code language, links, tables, formulas, and emphasis",
    );
    await waitForMixedFlowLayout(window);
    const mixedFlowProbe = await measureMixedFlow(window);
    assert(
      mixedFlowIsContinuous(mixedFlowProbe)
        && mixedFlowProbe.tableCellHeight < 70,
      "mixed Markdown fragments flow as readable list/table text (" + JSON.stringify(mixedFlowProbe) + ")",
    );
    assert(
      Math.abs(mixedFlowProbe.markerLineHeight - mixedFlowProbe.phraseLineHeight) <= 0.5
        && Math.abs(mixedFlowProbe.phraseFontSize - 14) <= 0.5,
      "mixed list fragments inherit the body type scale and line height (" + JSON.stringify(mixedFlowProbe) + ")",
    );
    await window.setSize(1_440, 760);
    await waitFor(window, `window.innerWidth >= 1_300`);
    await waitForMixedFlowLayout(window);
    const wideMixedFlow = await measureMixedFlow(window);
    assert(
      mixedFlowIsContinuous(wideMixedFlow)
        && wideMixedFlow.tableCellHeight < 70,
      "wide Chat keeps mixed list/table content in one readable flow (" + JSON.stringify(wideMixedFlow) + ")",
    );
    await window.setSize(960, 760);
    await waitFor(window, `window.innerWidth <= 1_000`);
    await waitForMixedFlowLayout(window);
    const narrowMixedFlow = await measureMixedFlow(window);
    assert(
      mixedFlowIsContinuous(narrowMixedFlow)
        && narrowMixedFlow.tableCellHeight < 90,
      "narrow Chat keeps mixed list/table content within the rail (" + JSON.stringify(narrowMixedFlow) + ")",
    );
    await window.setSize(1_040, 760);
    await waitFor(window, `window.innerWidth >= 1_000 && window.innerWidth <= 1_100`);
    await waitForMixedFlowLayout(window);
    const localReferencePath = "/Users/zhengyuanz/Codes/.scratch/service-investigation-20260830/investigation.md:27";
    const localReferenceSelector = "[aria-label=\"Local file reference: " + localReferencePath + "\"]";
    const localReferenceProbe = await window.webContents.executeJavaScript([
      "(() => {",
      "  const element = document.querySelector(" + JSON.stringify(localReferenceSelector) + ");",
      "  return {",
      "    label: element?.getAttribute('aria-label') ?? '',",
      "    role: element?.getAttribute('role') ?? '',",
      "    tabIndex: element?.getAttribute('tabindex') ?? '',",
      "    expanded: element?.getAttribute('aria-expanded') ?? '',",
      "    userSelect: element ? getComputedStyle(element).userSelect : '',",
      "    text: element?.textContent ?? '',",
      "  };",
      "})()",
    ].join("\n"));
    assert(
      localReferenceProbe.label === "Local file reference: " + localReferencePath
        && localReferenceProbe.role === "button"
        && localReferenceProbe.tabIndex === "0"
        && localReferenceProbe.expanded === "false"
        && localReferenceProbe.userSelect !== "none"
        && localReferenceProbe.text === "Request evidence",
      "local evidence uses a compact, keyboard-operable label with full-path identity (" + JSON.stringify(localReferenceProbe) + ")",
    );
    const localReferenceEnter = await window.webContents.executeJavaScript([
      "(() => {",
      "  const element = document.querySelector(" + JSON.stringify(localReferenceSelector) + ");",
      "  if (!element) return { defaultPrevented: false };",
      "  element.focus();",
      "  const down = new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true });",
      "  const up = new KeyboardEvent('keyup', { key: 'Enter', bubbles: true, cancelable: true });",
      "  element.dispatchEvent(down);",
      "  element.dispatchEvent(up);",
      "  return { defaultPrevented: down.defaultPrevented, focused: document.activeElement === element };",
      "})()",
    ].join("\n"));
    await waitFor(window,
      "document.querySelector(" + JSON.stringify(localReferenceSelector) + ")?.textContent === " + JSON.stringify(localReferencePath),
    );
    assert(localReferenceEnter.defaultPrevented && localReferenceEnter.focused,
      "Enter reveals the selectable full local evidence path");
    const localReferenceSpace = await window.webContents.executeJavaScript([
      "(() => {",
      "  const element = document.querySelector(" + JSON.stringify(localReferenceSelector) + ");",
      "  if (!element) return { defaultPrevented: false };",
      "  const down = new KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true });",
      "  const up = new KeyboardEvent('keyup', { key: ' ', bubbles: true, cancelable: true });",
      "  element.dispatchEvent(down);",
      "  element.dispatchEvent(up);",
      "  return { defaultPrevented: down.defaultPrevented };",
      "})()",
    ].join("\n"));
    await waitFor(window,
      "document.querySelector(" + JSON.stringify(localReferenceSelector) + ")?.textContent === " + JSON.stringify("Request evidence"),
    );
    assert(localReferenceSpace.defaultPrevented,
      "Space hides the full local evidence path without opening a file URL");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Link: Open the docs"]')?.click()`);
    await waitUntil(() => externalURLs.includes("https://example.com/docs"));
    assert(await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Back to Sessions"]'))
      && document.body.textContent.includes('Done')`),
      "safe Chat links stay in the external-link IPC path instead of navigating the renderer");

    assert(
      await window.webContents.executeJavaScript(`document.activeElement?.getAttribute('aria-label') === 'Chat message'`),
      "writable Chat focuses its composer when it opens",
    );
    await setInput(window, "Chat message", "/");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Slash command suggestions"]'))`);
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Slash command /compact"]'))`),
      "Chat requests and displays the daemon slash-command catalog",
    );
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Slash command discovery limit reached"]'))`),
      "Chat surfaces the slash discovery limit without claiming a known command exists",
    );
    const slashEscape = await dispatchComposerKey(window, { key: "Escape" });
    assert(slashEscape.defaultPrevented && slashEscape.value === "/",
      "Escape closes slash suggestions without leaving Chat");
    await waitFor(window, `!document.querySelector('[aria-label="Slash command suggestions"]')`);
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Chat message"]'))`),
      "closing slash suggestions keeps the composer focused in Chat",
    );
    await setInput(window, "Chat message", "/comp");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Slash command /compact"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Slash command /compact"]')?.click()`);
    await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === '/compact '`);

    const composingEnter = await dispatchComposerKey(window, { key: "Enter", isComposing: true });
    assert(!composingEnter.defaultPrevented && composingEnter.value === "/compact ",
      "IME Enter does not submit or clear the composer");
    const shiftEnter = await dispatchComposerKey(window, { key: "Enter", shiftKey: true });
    assert(!shiftEnter.defaultPrevented, "Shift+Enter remains available for a newline");

    await setInput(window, "Chat message", "Draft survives");
    await addPickerImage(window, "picker.png");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image picker.png"]'))`);
    await pasteImage(window, "invalid.bmp", "image/bmp", [1, 2, 3]);
    await waitFor(window, `document.body.textContent.includes('choose a PNG, JPEG, GIF, WebP, TIFF, or HEIC image')`);
    await pasteImage(window, "invalid-content.png", "image/png", [255, 216, 255]);
    await waitFor(window, `document.body.textContent.includes('not a valid png image')`);
    await pasteMixedImageItem(window, "mixed-item.png", "image/png", [137, 80, 78, 71, 13, 10, 26, 10]);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image mixed-item.png"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Remove image mixed-item.png"]')?.click()`);
    await waitFor(window, `!document.querySelector('[aria-label="Attached image mixed-item.png"]')`);
    await pasteImageItem(window, "pasted-item.tiff", "image/tiff", [73, 73, 42, 0]);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image pasted-item.tiff"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Remove image pasted-item.tiff"]')?.click()`);
    await waitFor(window, `!document.querySelector('[aria-label="Attached image pasted-item.tiff"]')`);
    await pasteImage(window, "pasted.png", "image/png", [137, 80, 78, 71, 13, 10, 26, 10]);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image pasted.png"]'))`);
    await pasteImageURL(window, pathToFileURL(fixturePath).href);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image finder-copy.png"]'))`);
    await setInput(window, "Chat message", "Keep multi-URL text");
    await setInputSelection(window, "Chat message", 5, 5);
    const multiURLPaste = await pasteText(window, "file:///tmp/one.png\nfile:///tmp/two.png");
    await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'Keep file:///tmp/one.png\\nfile:///tmp/two.pngmulti-URL text'`);
    const multiURLValue = await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value`);
    assert(multiURLPaste.defaultPrevented && multiURLValue === "Keep file:///tmp/one.png\nfile:///tmp/two.pngmulti-URL text",
      "multi-URL clipboard text is preserved at the current composer selection");
    await setInput(window, "Chat message", "Keep newer edits");
    await startDeferredTextPaste(window);
    await waitFor(window, `typeof globalThis.__agentVisorReleasePaste === 'function'`);
    await setInput(window, "Chat message", "Newer user text");
    await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'Newer user text'`);
    await releaseDeferredTextPaste(window, "late clipboard text");
    await waitFor(window, `document.body.textContent.includes('Paste canceled because the composer changed.')`);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === 'Newer user text'`),
      "a late async paste does not overwrite newer user edits",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Remove image picker.png"]')?.click()`);
    await waitFor(window, `!document.querySelector('[aria-label="Attached image picker.png"]')`);
    const clearEscape = await dispatchComposerKey(window, { key: "Escape" });
    assert(clearEscape.defaultPrevented,
      "Escape without suggestions is consumed by the composer");
    await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === ''`);
    await waitFor(window, `!document.querySelector('[aria-label="Attached image pasted.png"]')`);
    assert(
      await window.webContents.executeJavaScript(`Boolean(document.querySelector('[aria-label="Chat message"]'))`),
      "clearing the composer draft does not bubble Escape to Chat navigation",
    );
    await setInput(window, "Chat message", "Draft survives");
    await pasteImage(window, "pasted.png", "image/png", [137, 80, 78, 71, 13, 10, 26, 10]);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image pasted.png"]'))`);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Invalid Slash Response"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Invalid Slash Response"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Slash test session.')`);
    await setInput(window, "Chat message", "/");
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Slash command suggestions"]'))`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Slash command error"]'))`);
    assert(
      await window.webContents.executeJavaScript(`document.body.textContent.includes('Unable to load slash commands: Daemon produced an invalid protocol response.')`),
      "invalid slash responses stop command loading and surface a visible error",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Invalid Chat Response"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Invalid Chat Response"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Daemon produced an invalid protocol response.')`);
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label="Chat message"]')`),
      "invalid Chat page responses fail the active session and disable the composer",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Second Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Second Migration Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Second session content.')`);
    assert(
      await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === ''`),
      "a second Chat session starts with an independent draft",
    );
    await setInput(window, "Chat message", "Second draft");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Migration Chat"]')?.click()`);
    await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'Draft survives'`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Attached image pasted.png"]'))`);
    assert(
      await window.webContents.executeJavaScript(`document.activeElement?.getAttribute('aria-label') === 'Chat message'`),
      "restored writable Chat returns focus to its composer",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Remove image pasted.png"]')?.click()`);
    await waitFor(window, `!document.querySelector('[aria-label="Attached image pasted.png"]')`);
    await setInput(window, "Chat message", "Enter submission");
    await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'Enter submission'`);
    const plainEnter = await dispatchComposerKey(window, { key: "Enter" });
    assert(plainEnter.defaultPrevented, "plain Enter is consumed by the submit action");
    await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "Enter submission"));

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Second Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Second Migration Chat"]')?.click()`);
    await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === 'Second draft'`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Ended Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Ended Migration Chat"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('This session has ended. Chat history is read only.')`);
    assert(
      await window.webContents.executeJavaScript(`!document.querySelector('[aria-label="Chat message"]')
        && !document.querySelector('[aria-label="Send"]')
        && !document.querySelector('[aria-label="Add image"]')`),
      "ended Chat disables text, image, and submit controls",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Migration Chat"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Chat message"]'))`);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Show 2 work items"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Show details for Bash"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Show details for Bash"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('45 passed')`);
    const actionsAreIndependent = await window.webContents.executeJavaScript(`(() => {
      const back = document.querySelector('[aria-label="Back to Sessions"]').getBoundingClientRect();
      const owner = document.querySelector('[aria-label="Open in Ghostty"]').getBoundingClientRect();
      const details = document.querySelector('[aria-label="Chat Details"]').getBoundingClientRect();
      return back.right <= owner.left && owner.right <= details.left;
    })()`);
    assert(actionsAreIndependent, "Back, owner, and Details actions have independent frames");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat Details"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Chat technical details"]'))`);
    await window.setSize(1_440, 760);
    await waitFor(window, `window.innerWidth >= 1_300`);
    const wideChat = await measureRails(window);
    assertRailGeometry(wideChat, "wide Chat");
    assertDetailsGeometry(await measureDetails(window), "wide Chat");
    await window.setSize(960, 760);
    await waitFor(window, `window.innerWidth <= 1_000`);
    const narrowChat = await measureRails(window);
    assertRailGeometry(narrowChat, "narrow Chat");
    assertDetailsGeometry(await measureDetails(window), "narrow Chat");

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open in Ghostty"]')?.click()`);
    await waitUntil(() => ownerActions === 1);
    await waitFor(window, `document.body.textContent.includes('Path: /tmp/agent-visor')`);
    assert(
      await window.webContents.executeJavaScript(`document.body.textContent.includes('Model: GPT-5.6 Sol')
        && document.body.textContent.includes('Model provider: OpenAI Codex')
        && document.body.textContent.includes('Sandbox: Workspace Write')
        && document.body.textContent.includes('Approval: On Request')
        && document.body.textContent.includes('Context: 12,000 / 114,688 tokens (10%)')`),
      "Chat Details shows authoritative model and context metadata",
    );
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat Details"]')?.click()`);

    const thinkingProbe = await window.webContents.executeJavaScript(`(() => {
      const thinking = document.querySelector('[aria-label="Thinking: Inspecting files"]');
      if (!thinking) return { found: false };
      const hasItalicText = [...thinking.querySelectorAll('*')]
        .some((element) => getComputedStyle(element).fontStyle === 'italic');
      return {
        found: true,
        text: thinking.textContent,
        label: thinking.getAttribute('aria-label'),
        hasItalicText,
        generic: Boolean(document.querySelector('[aria-label="Thinking message"]')),
      };
    })()`);
    assert(
      thinkingProbe.found
        && thinkingProbe.label === 'Thinking: Inspecting files'
        && thinkingProbe.text?.includes('Inspecting')
        && thinkingProbe.text?.includes('files')
        && !thinkingProbe.generic
        && thinkingProbe.hasItalicText
        && !thinkingProbe.text.includes('**')
        && !thinkingProbe.text.includes('```'),
      "fenced-code thinking row has a dynamic accessible name and rendered content",
    );
    await waitFor(window, `document.body.textContent.includes('45 passed')`);
    await waitFor(window, `(() => {
      const container = document.querySelector('[aria-label="diagram.png"]');
      const visual = container?.firstElementChild;
      const hiddenImage = container?.querySelector('img');
      const uri = ${JSON.stringify(validImageDataURI)};
      const rect = container?.getBoundingClientRect();
      const background = visual ? getComputedStyle(visual).backgroundImage : '';
      return Boolean(container
        && container.getAttribute('role') === 'img'
        && rect && rect.width > 0 && rect.height > 0
        && (hiddenImage?.getAttribute('src') === uri || background.includes(uri)));
    })()`);
    const historyImageProbe = await window.webContents.executeJavaScript(`(() => ({
      valid: (() => {
        const container = document.querySelector('[aria-label="diagram.png"]');
        const visual = container?.firstElementChild;
        const hiddenImage = container?.querySelector('img');
        const rect = container?.getBoundingClientRect();
        const uri = ${JSON.stringify(validImageDataURI)};
        return Boolean(container
          && container.getAttribute('role') === 'img'
          && rect && rect.width > 0 && rect.height > 0
          && (hiddenImage?.getAttribute('src') === uri
            || (visual && getComputedStyle(visual).backgroundImage.includes(uri))));
      })(),
      remotePlaceholder: Boolean(document.querySelector('[aria-label="Image unavailable: remote.png"]')),
      localPlaceholder: Boolean(document.querySelector('[aria-label="Image unavailable: local.png"]')),
      remoteImage: Boolean(document.querySelector('img[src^="https://history-image.invalid/"]')),
      remoteRequests: ${JSON.stringify(remoteImageRequests)},
    }))()`);
    assert(historyImageProbe.valid,
      `validated data image messages render as images (${JSON.stringify(historyImageProbe)})`);
    assert(historyImageProbe.remotePlaceholder && historyImageProbe.localPlaceholder,
      "remote URLs and raw local paths render accessible non-fetching placeholders");
    assert(!historyImageProbe.remoteImage,
      "remote history image URLs never become image sources");
    assert(historyImageProbe.remoteRequests.length === 0,
      `remote history image URLs never trigger requests (${JSON.stringify(historyImageProbe.remoteRequests)})`);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Load earlier messages"]')?.click()`);
    await waitFor(window, `document.body.textContent.includes('Earlier answer')`);

    await setInput(window, "Chat message", "Continue");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Send"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "send_chat"));

    mode = "approval";
    publish();
    await waitFor(window, `document.body.textContent.includes('Approve Bash?')`, 6_000);
    await window.setSize(1_440, 760);
    await waitFor(window, `window.innerWidth >= 1_300`);
    assertRailGeometry(await measureRails(window, true), "wide approval Chat");
    await window.setSize(960, 760);
    await waitFor(window, `window.innerWidth <= 1_000`);
    assertRailGeometry(await measureRails(window, true), "narrow approval Chat");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Allow"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "respond_chat" && action.decision === "allow"));

    mode = "question";
    publish();
    await waitFor(window, `document.body.textContent.includes('Which strategy?')`, 6_000);
    await window.setSize(1_440, 760);
    await waitFor(window, `window.innerWidth >= 1_300`);
    assertRailGeometry(await measureRails(window, true), "wide question Chat");
    await window.setSize(960, 760);
    await waitFor(window, `window.innerWidth <= 1_000`);
    assertRailGeometry(await measureRails(window, true), "narrow question Chat");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Select Minimal"]')?.click()`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Submit answers"]')?.click()`);
    await waitUntil(() => actions.some((action) => action.type === "respond_chat" && action.decision === "answer"));

    mode = "question";
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Back to Sessions"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Open Chat for Migration Chat"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for Migration Chat"]')?.click()`);
    await waitFor(window, `Boolean(document.querySelector('[aria-label="Question question-1"]'))`);
    const questionEscape = await window.webContents.executeJavaScript(`(() => {
      const question = document.querySelector('[aria-label="Question question-1"]');
      if (!question) return { defaultPrevented: false, back: false };
      const event = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true });
      question.dispatchEvent(event);
      return {
        defaultPrevented: event.defaultPrevented,
        back: Boolean(document.querySelector('[aria-label="Back to Sessions"]')),
      };
    })()`);
    await waitUntil(() => actions.some((action) => action.type === "respond_chat" && action.decision === "deny" && action.approvalId === "question-1"));
    assert(questionEscape.defaultPrevented && questionEscape.back,
      "question Escape denies the exact pending action without navigating back");

    await window.setSize(960, 760);
    await waitFor(window, `window.innerWidth <= 1_000`);
    const unscaledChat = await measureRails(window);
    assert(unscaledChat.scaleProbeFontSize > 0,
      "Chat exposes a computed font-size probe before scaling");
    await window.webContents.executeJavaScript(`{
      for (let index = 0; index < 15; index += 1) {
        window.dispatchEvent(new KeyboardEvent('keydown', { key: '+', metaKey: true, bubbles: true }));
      }
    }`);
    await new Promise((resolve) => setTimeout(resolve, 100));
    const scaledChat = await measureRails(window);
    assertRailGeometry(scaledChat, "250% Chat", { checkFixtures: false });
    const scaleRatio = scaledChat.scaleProbeFontSize / unscaledChat.scaleProbeFontSize;
    assert(scaleRatio >= 2.45 && scaleRatio <= 2.55,
      `keyboard scaling applies a 250% computed text size (observed ${scaleRatio.toFixed(2)}x)`);
    assert(
      scaledChat.timelineScrollWidth <= scaledChat.timelineClientWidth,
      "Chat scaling does not add horizontal scrolling to the Chat timeline",
    );

    console.log("Focused Electron Chat surface accessibility check PASS: metadata, grouped turns, tools, pagination, images, actions, approvals, questions, rail geometry, and scaling.");
  } finally {
    ipcMain.removeHandler("chat:read-image-file");
    ipcMain.removeHandler("chat:open-external");
    await rm(fixtureDirectory, { recursive: true, force: true });
  }
}

function capabilities(target = session, activeDeliveryId) {
  if (target.section === "history") {
    return {
      canSendText: false,
      canSendImages: false,
      canCancel: false,
      canApprove: false,
      canAnswer: false,
      readOnlyReason: "This session has ended. Chat history is read only.",
    };
  }
  return {
    canSendText: true,
    canSendImages: true,
    canCancel: target.section === "working",
    ...(target.section === "working" && activeDeliveryId !== null
      ? { cancelDeliveryId: activeDeliveryId ?? `existing-${target.id}` }
      : {}),
    canApprove: mode === "approval",
    canAnswer: mode === "question",
  };
}

function assert(value, message) {
  if (!value) throw new Error(`Chat accessibility failed: ${message}`);
}

async function measureRails(window, includeAction = false) {
  return window.webContents.executeJavaScript(`(() => {
    const timeline = document.querySelector('[aria-label="Chat timeline"]');
    const labels = ['Chat header rail', 'Chat timeline rail', ${includeAction ? '' : '"Chat composer rail",'} 'Chat status rail']
      .concat(${includeAction ? '["Chat action rail"]' : '[]'});
      return {
        viewportWidth: window.innerWidth,
        timelineLeft: timeline?.getBoundingClientRect().left ?? -1,
        timelineOverflowY: timeline ? getComputedStyle(timeline).overflowY : "",
        timelineScrollbarWidth: timeline ? getComputedStyle(timeline).scrollbarWidth : "",
        timelineWebkitScrollbarDisplay: timeline ? inspectScrollbarPseudo(timeline, "display") : null,
        timelineWebkitScrollbarWidth: timeline ? inspectScrollbarPseudo(timeline, "width") : null,
        timelineScrollWidth: timeline?.scrollWidth ?? -1,
        timelineClientWidth: timeline?.clientWidth ?? -1,
        scaleProbeFontSize: (() => {
          const status = document.querySelector('[aria-label="Chat status rail"]');
          const probe = status?.firstElementChild;
          return probe ? Number.parseFloat(getComputedStyle(probe).fontSize) : -1;
        })(),
        rails: labels.map((label) => {
          const element = document.querySelector('[aria-label="' + label + '"]');
          if (!element) return null;
          const rect = element.getBoundingClientRect();
          return { label, left: rect.left, right: rect.right, width: rect.width };
        }),
        fixtureRows: [...document.querySelectorAll('[id^="chat-item-"]')].map((element) => {
          const rect = element?.getBoundingClientRect();
          return {
            id: element.id,
            hasLayout: Boolean(element && rect && rect.width > 0 && rect.height > 0
              && element.getClientRects().length > 0),
            text: element.textContent ?? "",
          };
        }),
      };
    function inspectScrollbarPseudo(element, property) {
      try {
        return getComputedStyle(element, "::-webkit-scrollbar")[property] || null;
      } catch {
        return null;
      }
    }
  })()`);
}

async function measureMixedFlow(window) {
  return window.webContents.executeJavaScript(`(() => {
    const answer = document.querySelector('#chat-item-answer-1');
    const phraseText = 'Your request reached an old API pod';
    const listItem = [...(answer?.querySelectorAll('div') ?? [])].find((element) => {
      const marker = [...element.children].find((child) => child.textContent?.trim() === '1.');
      const hasPhrase = [...element.children].some((child) => child.textContent?.includes(phraseText));
      return Boolean(marker && hasPhrase);
    });
    const phrase = [...(listItem?.querySelectorAll('*') ?? [])].find((element) =>
      element.textContent?.trim() === phraseText);
    const marker = [...(listItem?.children ?? [])].find((element) =>
      element.textContent?.trim() === '1.');
    const table = answer?.querySelector('[aria-label="Markdown table"]');
    // A table's own container also contains the whole answer text. Restrict
    // the measurement to the direct row -> cell hierarchy.
    const tableRows = [...(table?.children ?? [])];
    const tableCells = tableRows.flatMap((row) => [...row.children]);
    const tableCell = tableCells.find((element) =>
      element.textContent?.includes('all 45 tests passed'));
    const listItemRect = listItem?.getBoundingClientRect();
    const markerRect = marker?.getBoundingClientRect();
    const phraseRect = phrase?.getBoundingClientRect();
    const phraseParentRect = phrase?.parentElement?.getBoundingClientRect();
    const tableRect = tableCell?.getBoundingClientRect();
    const tableContainerRect = table?.getBoundingClientRect();
    const phraseStyle = phrase ? getComputedStyle(phrase) : undefined;
    const markerStyle = marker ? getComputedStyle(marker) : undefined;
    return {
      listItemDisplay: listItem ? getComputedStyle(listItem).display : '',
      listItemWidth: listItemRect?.width ?? 0,
      listItemHeight: listItemRect?.height ?? 0,
      markerRight: markerRect?.right ?? 0,
      markerWidth: markerRect?.width ?? 0,
      phraseWidth: phraseRect?.width ?? 0,
      phraseHeight: phraseRect?.height ?? 0,
      phraseLeft: phraseRect?.left ?? 0,
      phraseRight: phraseRect?.right ?? 0,
      phraseParentDisplay: phrase?.parentElement ? getComputedStyle(phrase.parentElement).display : '',
      phraseParentWidth: phraseParentRect?.width ?? 0,
      phraseParentRight: phraseParentRect?.right ?? 0,
      phraseLineHeight: phraseStyle ? Number.parseFloat(phraseStyle.lineHeight) || Number.parseFloat(phraseStyle.fontSize) * 1.2 : 0,
      phraseFontSize: phraseStyle ? Number.parseFloat(phraseStyle.fontSize) || 0 : 0,
      markerLineHeight: markerStyle ? Number.parseFloat(markerStyle.lineHeight) || Number.parseFloat(markerStyle.fontSize) * 1.2 : 0,
      tableRows: tableRows.length,
      tableCellDirectRow: Boolean(tableCell?.parentElement?.parentElement === table),
      tableCellWidth: tableRect?.width ?? 0,
      tableCellHeight: tableRect?.height ?? 0,
      tableWidth: tableContainerRect?.width ?? 0,
      tableCellRight: tableRect?.right ?? 0,
      tableRight: tableContainerRect?.right ?? 0,
    };
  })()`);
}

function mixedFlowIsContinuous(metrics) {
  return metrics.listItemDisplay === "flex"
    && metrics.phraseParentDisplay !== "flex"
    && metrics.phraseWidth > 0
    && metrics.phraseHeight <= metrics.phraseLineHeight * 1.5
    && metrics.listItemWidth > metrics.phraseWidth
    && metrics.phraseLeft >= metrics.markerRight - 0.5
    && metrics.phraseRight <= metrics.phraseParentRight + 0.5
    && metrics.phraseParentWidth >= metrics.listItemWidth - metrics.markerWidth - 12
    && metrics.tableRows >= 2
    && metrics.tableCellDirectRow
    && metrics.tableCellWidth > 0
    && metrics.tableCellHeight > 0
    && metrics.tableCellRight <= metrics.tableRight + 0.5;
}

async function waitForMixedFlowLayout(window) {
  await waitFor(window, `(() => {
    const answer = document.querySelector('#chat-item-answer-1');
    const listItem = [...(answer?.querySelectorAll('div') ?? [])].find((element) =>
      [...element.children].some((child) => child.textContent?.trim() === '1.'));
    const table = answer?.querySelector('[aria-label="Markdown table"]');
    const tableCell = [...(table?.children ?? [])]
      .flatMap((row) => [...row.children])
      .find((element) => element.textContent?.includes('all 45 tests passed'));
    if (!answer || !listItem || !tableCell) return false;
    const listRect = listItem.getBoundingClientRect();
    const cellRect = tableCell.getBoundingClientRect();
    return listRect.width > 0 && listRect.height > 0
      && cellRect.width > 0 && cellRect.height > 0
      && listRect.right <= window.innerWidth + 1
      && cellRect.right <= window.innerWidth + 1;
  })()`);
  await window.webContents.executeJavaScript(`new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  })`);
}

async function measureDetails(window) {
  return window.webContents.executeJavaScript(`(() => {
    const popup = document.querySelector('[aria-label="Chat technical details"]');
    const header = document.querySelector('[aria-label="Chat header rail"]');
    if (!popup || !header) return null;
    const popupRect = popup.getBoundingClientRect();
    const headerRect = header.getBoundingClientRect();
    return {
      popup: { left: popupRect.left, right: popupRect.right, width: popupRect.width, height: popupRect.height },
      header: { left: headerRect.left, right: headerRect.right, width: headerRect.width },
      documentScrollWidth: document.documentElement.scrollWidth,
      viewportWidth: window.innerWidth,
    };
  })()`);
}

async function measureTimeline(window) {
  return window.webContents.executeJavaScript(`(() => {
    const timeline = document.querySelector('[aria-label="Chat timeline"]');
    if (!timeline) return { scrollTop: -1, distanceFromBottom: -1 };
    return {
      scrollTop: timeline.scrollTop,
      distanceFromBottom: timeline.scrollHeight - (timeline.scrollTop + timeline.clientHeight),
      scrollHeight: timeline.scrollHeight,
      clientHeight: timeline.clientHeight,
    };
  })()`);
}

function assertDetailsGeometry(metrics, surface) {
  assert(metrics, `${surface} renders the Chat Details popup`);
  assert(metrics.popup.width > 0 && metrics.popup.height > 0,
    `${surface} Chat Details popup has nonzero layout`);
  assert(Math.abs(metrics.popup.right - metrics.header.right) <= 1,
    `${surface} Chat Details popup aligns with the header rail right edge`);
  assert(metrics.documentScrollWidth <= metrics.viewportWidth,
    `${surface} Chat Details popup does not add horizontal overflow`);
}

function assertRailGeometry(metrics, surface, { checkFixtures = true } = {}) {
  const rails = metrics.rails;
  assert(rails.every(Boolean), `${surface} exposes every expected rail`);
  assert(metrics.timelineScrollWidth >= 0 && metrics.timelineClientWidth >= 0,
    `${surface} exposes the real Chat timeline scroll container`);
  assert(metrics.timelineScrollWidth <= metrics.timelineClientWidth,
    `${surface} keeps the real Chat timeline free of horizontal overflow`);
  assert(metrics.timelineOverflowY === "auto" || metrics.timelineOverflowY === "scroll",
    `${surface} keeps the real Chat timeline vertically scrollable`);
  assert(metrics.timelineScrollbarWidth !== "none"
    && metrics.timelineWebkitScrollbarDisplay !== "none"
    && metrics.timelineWebkitScrollbarWidth !== "0px",
  `${surface} keeps the real Chat timeline scrollbar visible`);
  if (checkFixtures) assertFixtureRows(metrics, surface);
  const first = rails[0];
  const isNarrow = metrics.viewportWidth < 1_036;
  const expectedWidth = isNarrow ? metrics.viewportWidth - 56 : 980;
  for (const rail of rails.filter(({ label }) => label !== "Chat timeline rail")) {
    assert(Math.abs(rail.width - expectedWidth) <= 1,
      `${surface} ${rail.label} uses the shared ${expectedWidth}-point width`);
    assert(Math.abs(rail.left - first.left) <= 1 && Math.abs(rail.right - first.right) <= 1,
      `${surface} ${rail.label} aligns with the header rail`);
  }
  const timelineRail = rails.find(({ label }) => label === "Chat timeline rail");
  assert(timelineRail, `${surface} exposes the Chat timeline rail`);
  const expectedTimelineWidth = Math.min(980, metrics.timelineClientWidth - 56);
  assert(Math.abs(timelineRail.width - expectedTimelineWidth) <= 1,
    `${surface} Chat timeline rail uses the scroll viewport width ${expectedTimelineWidth}`);
  assert(Math.abs((timelineRail.left + timelineRail.right) / 2
    - (metrics.timelineLeft + metrics.timelineClientWidth / 2)) <= 1,
  `${surface} Chat timeline rail centers in the actual scroll viewport`);
  if (isNarrow) {
    assert(Math.abs(first.left - 28) <= 1 && Math.abs(first.right - (metrics.viewportWidth - 28)) <= 1,
      `${surface} keeps 28-point narrow insets`);
  } else {
    assert(Math.abs(first.left - ((metrics.viewportWidth - 980) / 2)) <= 1,
      `${surface} centers the 980-point rail`);
  }
}

function assertFixtureRows(metrics, surface) {
  const rowsByID = new Map(metrics.fixtureRows.map((row) => [row.id, row]));
  assert(metrics.fixtureRows.length >= Object.keys(expectedFixtureContent).length,
    `${surface} discovers the expected Chat fixture row count from the DOM`);
  for (const [id, content] of Object.entries(expectedFixtureContent)) {
    const row = rowsByID.get(id);
    assert(row?.hasLayout, `${surface} lays out fixture row ${id}`);
    assert(content.every((expected) => row.text.includes(expected)),
      `${surface} renders fixture content for ${id}`);
  }
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

async function clearComposer(window) {
  await dispatchComposerKey(window, { key: "Escape" });
  await waitFor(window, `document.querySelector('[aria-label="Chat message"]')?.value === ''
    && !document.querySelector('[aria-label^="Attached image "]')`);
}

async function setInputSelection(window, label, start, end) {
  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="${label}"]');
    input?.setSelectionRange(${start}, ${end});
  })()`);
}

async function dispatchComposerKey(window, { key, shiftKey = false, isComposing = false }) {
  return window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    if (!input) return { defaultPrevented: true, value: null };
    const event = new KeyboardEvent('keydown', {
      bubbles: true,
      cancelable: true,
      key: ${JSON.stringify(key)},
      shiftKey: ${String(shiftKey)},
      isComposing: ${String(isComposing)},
    });
    input.dispatchEvent(event);
    return { defaultPrevented: event.defaultPrevented, value: input.value };
  })()`);
}

async function addPickerImage(window, name) {
  await window.webContents.executeJavaScript(`(() => {
    const originalClick = HTMLInputElement.prototype.click;
    const file = new File([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])], ${JSON.stringify(name)}, { type: 'image/png' });
    HTMLInputElement.prototype.click = function interceptedClick() {
      if (this.type !== 'file') return originalClick.call(this);
      const transfer = new DataTransfer();
      transfer.items.add(file);
      Object.defineProperty(this, 'files', { configurable: true, value: transfer.files });
      this.onchange?.();
    };
    document.querySelector('[aria-label="Add image"]')?.click();
    HTMLInputElement.prototype.click = originalClick;
  })()`);
}

async function pasteImage(window, name, type, bytes) {
  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    if (!input) return;
    const file = new File([new Uint8Array(${JSON.stringify(bytes)})], ${JSON.stringify(name)}, { type: ${JSON.stringify(type)} });
    const transfer = new DataTransfer();
    transfer.items.add(file);
    const event = new Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(event, 'clipboardData', { configurable: true, value: transfer });
    input.dispatchEvent(event);
  })()`);
}

async function pasteImageItem(window, name, type, bytes) {
  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    if (!input) return;
    const file = new File([new Uint8Array(${JSON.stringify(bytes)})], ${JSON.stringify(name)}, { type: ${JSON.stringify(type)} });
    const event = new Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(event, 'clipboardData', { configurable: true, value: {
      files: [],
      items: [{ kind: 'file', type: ${JSON.stringify(type)}, getAsFile: () => file }],
      getData: () => '',
    } });
    input.dispatchEvent(event);
  })()`);
}

async function pasteMixedImageItem(window, name, type, bytes) {
  return window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    if (!input) return { defaultPrevented: true, value: null };
    const image = new File([new Uint8Array(${JSON.stringify(bytes)})], ${JSON.stringify(name)}, { type: ${JSON.stringify(type)} });
    const notes = new File(['plain text'], 'notes.txt', { type: 'text/plain' });
    const event = new Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(event, 'clipboardData', { configurable: true, value: {
      files: [notes],
      items: [{ kind: 'file', type: ${JSON.stringify(type)}, getAsFile: () => image }],
      getData: () => '',
    } });
    input.dispatchEvent(event);
    return { defaultPrevented: event.defaultPrevented, value: input.value };
  })()`);
}

async function pasteImageURL(window, url) {
  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    if (!input) return;
    const event = new Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(event, 'clipboardData', { configurable: true, value: {
      files: [],
      items: [{ kind: 'string', type: 'text/uri-list', getAsString: (callback) => callback(${JSON.stringify(url)}) }],
      getData: (type) => type === 'text/uri-list' ? ${JSON.stringify(url)} : '',
    } });
    input.dispatchEvent(event);
  })()`);
}

async function pasteText(window, value) {
  return window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    if (!input) return { defaultPrevented: true, value: null };
    const event = new Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(event, 'clipboardData', { configurable: true, value: {
      files: [],
      items: [{ kind: 'string', type: 'text/plain', getAsString: (callback) => callback(${JSON.stringify(value)}) }],
      getData: (type) => type === 'text/plain' ? ${JSON.stringify(value)} : '',
    } });
    input.dispatchEvent(event);
    return new Promise((resolve) => setTimeout(() => resolve({
      defaultPrevented: event.defaultPrevented,
      value: input.value,
    }), 0));
  })()`);
}

async function startDeferredTextPaste(window) {
  return window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    const event = new Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(event, 'clipboardData', { configurable: true, value: {
      files: [],
      items: [{ kind: 'string', type: 'text/plain', getAsString: (callback) => {
        globalThis.__agentVisorReleasePaste = callback;
      } }],
      getData: () => '',
    } });
    input?.dispatchEvent(event);
    return event.defaultPrevented;
  })()`);
}

async function releaseDeferredTextPaste(window, value) {
  await window.webContents.executeJavaScript(`(() => {
    const release = globalThis.__agentVisorReleasePaste;
    delete globalThis.__agentVisorReleasePaste;
    release?.(${JSON.stringify(value)});
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
