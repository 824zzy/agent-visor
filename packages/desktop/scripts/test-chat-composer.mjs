import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { app, BrowserWindow, nativeTheme } from "electron";

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(directory, "../../..");
let artifactRoot;
let profileRoot;
let ownsArtifactRoot = false;
let ownsProfileRoot = false;
const token = "chat-composer-fixture-token-000000000000000000000";
const validImageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

app.on("window-all-closed", () => {});

const mainSession = {
  id: "composer-main",
  title: "Composer Main Chat",
  subtitle: "Ready",
  source: "Codex",
  project: "fixture",
  owner: "Codex",
  cwd: "/fixture/project",
  section: "ready",
  updatedAt: "2026-08-31T10:00:00.000Z",
  canOpenOwner: true,
  canEnterChat: true,
};
const workingSession = {
  ...mainSession,
  id: "composer-working",
  title: "Composer Working Chat",
  subtitle: "Agent is working",
  source: "Claude Code",
  owner: "Ghostty",
  section: "working",
  updatedAt: "2026-08-31T09:00:00.000Z",
};
const gatedPermissionSession = {
  ...workingSession,
  id: "composer-permission-gated",
  title: "Composer Permission Gated Chat",
  subtitle: "Permission display only",
  updatedAt: "2026-08-31T08:30:00.000Z",
};
const imageOnlySession = {
  ...mainSession,
  id: "composer-image-only",
  title: "Composer Image Only Chat",
  subtitle: "Images only",
  source: "Pi",
  updatedAt: "2026-08-31T08:00:00.000Z",
};
const readOnlySession = {
  ...mainSession,
  id: "composer-read-only",
  title: "Composer Read Only Chat",
  subtitle: "Session ended",
  section: "history",
  cwd: "/fixture/archive",
  updatedAt: "2026-08-31T07:00:00.000Z",
};
const sessions = [mainSession, workingSession, gatedPermissionSession, imageOnlySession, readOnlySession];

const metadata = {
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
    label: "5 hour 42 percent used",
    detail: "Codex usage, 5 hour 42 percent used",
    observedAt: "2026-08-31T09:00:00.000Z",
  },
};

let server;
let window;
let exitCode = 0;
const actions = [];
let claudePermissionMode = "default";
let pendingApproval = false;
let releasePermissionCycle;
let releaseWorkingCancel;

void (async () => {
  try {
    await prepareFixtureRoots();
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
      if (ownsArtifactRoot) {
        await rm(artifactRoot, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
      }
      if (ownsProfileRoot) {
        await rm(profileRoot, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
      }
    } catch (error) {
      process.stderr.write(`Fixture cleanup failed: ${error instanceof Error ? error.stack : String(error)}\n`);
      exitCode = 1;
    } finally {
      if (app.isReady()) app.exit(exitCode);
    }
  }
})();

async function prepareFixtureRoots() {
  profileRoot = process.env.AGENT_VISOR_COMPOSER_PROFILE_ROOT;
  if (!profileRoot) {
    profileRoot = await mkdtemp(path.join(tmpdir(), "agent-visor-composer-profile-"));
    ownsProfileRoot = true;
  }
  artifactRoot = process.env.AGENT_VISOR_COMPOSER_ARTIFACT_ROOT;
  if (!artifactRoot) {
    artifactRoot = await mkdtemp(path.join(tmpdir(), "agent-visor-composer-artifacts-"));
    ownsArtifactRoot = true;
  }
  await mkdir(artifactRoot, { recursive: true });
  await mkdir(profileRoot, { recursive: true });
}

async function run() {
  const { startServer } = await import(pathToFileURL(path.join(root, "packages/server/dist/server.js")).href);
  const source = {
    current: () => ({ type: "session_snapshot", revision: 1, sessions }),
    subscribe: () => () => {},
    chatPage: async (sessionId) => {
      const target = sessions.find(({ id }) => id === sessionId) ?? mainSession;
      if (target.id === readOnlySession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "read-only-answer", kind: "assistant", text: "Archived evidence." }],
          hasMoreBefore: false,
          capabilities: {
            canSendText: false,
            canSendImages: false,
            canCancel: false,
            canApprove: false,
            canAnswer: false,
            readOnlyReason: "This archived conversation is read only.",
          },
          pendingAction: null,
          metadata,
        };
      }
      if (target.id === imageOnlySession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "image-only-answer", kind: "assistant", text: "Attach an image to continue." }],
          hasMoreBefore: false,
          capabilities: {
            canSendText: false,
            canSendImages: true,
            canCancel: false,
            canApprove: false,
            canAnswer: false,
            readOnlyReason: "Text messages are unavailable from this session.",
          },
          pendingAction: null,
          metadata,
        };
      }
      if (target.id === gatedPermissionSession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "permission-gated-answer", kind: "assistant", text: "Permission display fixture." }],
          hasMoreBefore: false,
          capabilities: {
            canSendText: true,
            canSendImages: true,
            canCancel: false,
            canApprove: false,
            canAnswer: false,
          },
          pendingAction: null,
          metadata: { ...metadata, permissionMode: "default" },
        };
      }
      if (target.id === workingSession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "working-answer", kind: "assistant", text: "Working fixture." }],
          hasMoreBefore: false,
          capabilities: {
            canSendText: true,
            canSendImages: true,
            canCancel: true,
            cancelDeliveryId: "working-delivery",
            canApprove: false,
            canAnswer: false,
            canCyclePermissionMode: true,
          },
          pendingAction: null,
          metadata: { ...metadata, permissionMode: claudePermissionMode },
        };
      }
      if (target.id === mainSession.id && pendingApproval) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "main-answer", kind: "assistant", text: "Composer fixture." }],
          hasMoreBefore: false,
          capabilities: {
            canSendText: true,
            canSendImages: true,
            canCancel: false,
            canApprove: true,
            canAnswer: false,
          },
          pendingAction: {
            type: "approval",
            toolUseId: "composer-approval",
            toolName: "Bash",
            input: { command: "npm publish" },
            canPersist: true,
          },
          metadata,
        };
      }
      return {
        type: "chat_page",
        sessionId,
        items: [{ id: "main-answer", kind: "assistant", text: "Composer fixture." }],
        hasMoreBefore: false,
        capabilities: {
          canSendText: true,
          canSendImages: true,
          canCancel: false,
          canApprove: false,
          canAnswer: false,
        },
        pendingAction: null,
        metadata,
      };
    },
    chatAction: async (message) => {
      actions.push(message);
      if (message.type === "cycle_permission_mode") {
        return new Promise((resolve) => {
          releasePermissionCycle = () => {
            claudePermissionMode = "acceptEdits";
            resolve();
          };
        });
      }
      if (message.type === "cancel_chat" && message.sessionId === workingSession.id) {
        return new Promise((resolve) => { releaseWorkingCancel = resolve; });
      }
      if (message.type === "respond_chat" && pendingApproval) pendingApproval = false;
      return undefined;
    },
  };
  server = await startServer({ port: 0, token, source });
  nativeTheme.themeSource = "light";
  window = new BrowserWindow({
    show: false,
    width: 1_200,
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

  await openChat(mainSession);
  const emptyProbe = await probeComposer();
  assert(emptyProbe.outer && emptyProbe.rail, `integrated composer exposes one public enclosure and rail (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.borderWidth === "1px" && emptyProbe.borderRadius >= 20 && emptyProbe.borderRadius <= 22,
    `composer enclosure uses the neutral 1px 20-22px surface (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.inputBorderWidth === "0px" && emptyProbe.inputBackground === "rgba(0, 0, 0, 0)",
    `composer input is transparent and unboxed (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.outerHeight >= 100 && emptyProbe.outerHeight <= 112,
    `empty composer keeps the compact 100-112px target range (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.plusWidth >= 44 && emptyProbe.plusHeight >= 44,
    `Add image keeps a 44px target (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.plusGlyphSize >= 18 && emptyProbe.sendFaceWidth === 32 && emptyProbe.sendFaceHeight === 32
    && emptyProbe.sendTargetWidth >= 44 && emptyProbe.sendTargetHeight >= 44
    && emptyProbe.sendGlyphContained,
    `composer action glyphs keep the approved optical sizes (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.sendDisabled, "empty composer disables Send");
  await waitFor("document.activeElement?.getAttribute('aria-label') === 'Chat message'");
  const contextProbe = await window.webContents.executeJavaScript(`(() => {
    const context = document.querySelector('[aria-label="Composer model and effort"]');
    return {
      text: context?.textContent ?? '',
      role: context?.getAttribute('role') ?? '',
      hasPopup: context?.getAttribute('aria-haspopup') ?? '',
      selector: Boolean(document.querySelector('[aria-label="Select model"], [aria-label="Model selector"], [aria-haspopup="listbox"]')),
    };
  })()`);
  assert(contextProbe.text.includes("GPT-5.6 Sol")
    && contextProbe.text.includes("Reasoning High")
    && contextProbe.role !== "button"
    && contextProbe.hasPopup === ""
    && !contextProbe.selector,
  `model and effort context stays passive without a fake selector (${JSON.stringify(contextProbe)})`);
  await capture("light-empty.png");

  const compactHeight = emptyProbe.outerHeight;
  const multilineDraft = ["line one", "line two", "line three", "line four", "line five"].join("\n");
  await setInput(multilineDraft);
  await waitFor(`document.querySelector('[aria-label="Chat composer"]')?.getBoundingClientRect().height > ${compactHeight + 20}`);
  const multilineProbe = await probeComposer();
  assert(multilineProbe.outerHeight > compactHeight && multilineProbe.inputHeight > 42,
    `multiline draft grows the integrated composer (${JSON.stringify({ compactHeight, multilineProbe })})`);
  await addPickerImage("composer.png");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image composer.png\"]'))");
  assert(await probeSendDisabled() === false, "a multiline draft with an allowed image enables Send");
  await capture("light-draft-image.png");

  pendingApproval = true;
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Back to Sessions\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Open Chat for Composer Main Chat\"]'))");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Open Chat for Composer Main Chat\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Approval composer-approval\"]'))");
  const pendingApprovalProbe = await window.webContents.executeJavaScript(`(() => ({
    action: Boolean(document.querySelector('[aria-label="Approval composer-approval"]')),
    actionRail: Boolean(document.querySelector('[aria-label="Chat action rail"]')),
    composer: Boolean(document.querySelector('[aria-label="Chat composer"]')),
    input: Boolean(document.querySelector('[aria-label="Chat message"]')),
    send: Boolean(document.querySelector('[aria-label="Send"]')),
    stop: Boolean(document.querySelector('[aria-label="Stop agent"], [aria-label="Canceling agent"], [aria-label="Agent stopped"], [aria-label="Retry stopping agent"]')),
    allow: Boolean(document.querySelector('[aria-label="Allow"]')),
  }))()`);
  assert(pendingApprovalProbe.action && pendingApprovalProbe.actionRail
    && !pendingApprovalProbe.composer && !pendingApprovalProbe.input
    && !pendingApprovalProbe.send && !pendingApprovalProbe.stop && pendingApprovalProbe.allow,
  `pending approval owns the action surface without generic Send or Stop (${JSON.stringify(pendingApprovalProbe)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Allow\"]')?.click()");
  await waitUntil(() => actions.some((action) => action.type === "respond_chat"
    && action.approvalId === "composer-approval" && action.decision === "allow"));
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Back to Sessions\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Open Chat for Composer Main Chat\"]'))");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Open Chat for Composer Main Chat\"]')?.click()");
  await waitFor("document.querySelector('[aria-label=\"Chat message\"]')?.value === " + JSON.stringify(multilineDraft));
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image composer.png\"]'))");
  assert(await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat message"]')?.value === ${JSON.stringify(multilineDraft)}
    && Boolean(document.querySelector('[aria-label="Attached image composer.png"]'))`),
  "approval response restores the stored text and image draft");

  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Remove image composer.png\"]')?.click()");
  await waitFor("!document.querySelector('[aria-label=\"Attached image composer.png\"]')");
  await setInput("paste draft");
  const pasteHandled = await pasteImage("pasted.png", "image/png", [137, 80, 78, 71, 13, 10, 26, 10]);
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image pasted.png\"]'))");
  assert(pasteHandled && await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Chat message\"]')?.value === 'paste draft'"),
    "pasting an allowed image is consumed without changing the text draft");
  const shiftEnter = await dispatchComposerKey({ key: "Enter", shiftKey: true });
  const composingEnter = await dispatchComposerKey({ key: "Enter", isComposing: true });
  assert(!shiftEnter.defaultPrevented && shiftEnter.value === "paste draft"
    && !composingEnter.defaultPrevented && composingEnter.value === "paste draft",
  `Shift+Enter and IME Enter leave the draft available (${JSON.stringify({ shiftEnter, composingEnter })})`);
  const plainEnter = await dispatchComposerKey({ key: "Enter" });
  assert(plainEnter.defaultPrevented, "plain Enter is consumed by the submit action");
  await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.text === "paste draft"));
  await waitFor("document.querySelector('[aria-label=\"Chat message\"]')?.value === ''");
  await waitFor("!document.querySelector('[aria-label=\"Attached image pasted.png\"]')");

  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Chat composer\"]')?.getBoundingClientRect().height <= " + (compactHeight + 1));
  const clearedProbe = await probeComposer();
  assert(clearedProbe.outerHeight <= compactHeight + 1,
    `clearing the draft returns the composer to its compact height (${JSON.stringify({ compactHeight, clearedProbe })})`);

  await setInput("hello from the fixture");
  await waitFor("document.querySelector('[aria-label=\"Send\"]')?.getAttribute('aria-disabled') !== 'true'");
  assert(await probeSendDisabled() === false, "a valid text draft enables Send");
  await setInput("");
  await addPickerImage("composer.png");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image composer.png\"]'))");
  assert(await probeSendDisabled() === false, "an image-only draft enables Send when images are allowed");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Remove image composer.png\"]')?.click()");
  await waitFor("!document.querySelector('[aria-label=\"Attached image composer.png\"]')");
  assert(await probeSendDisabled(), "removing the last attachment disables Send for an empty draft");

  await openChat(gatedPermissionSession);
  await waitFor("Boolean(document.querySelector('[aria-label=\"Permission mode: Default\"]'))");
  const gatedPermission = await window.webContents.executeJavaScript(`(() => {
    const permission = document.querySelector('[aria-label="Permission mode: Default"]');
    const before = ${actions.length};
    permission?.click();
    return {
      role: permission?.getAttribute('role') ?? '',
      disabled: permission?.getAttribute('aria-disabled') ?? '',
      hasPopup: permission?.getAttribute('aria-haspopup') ?? '',
      before,
    };
  })()`);
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert(gatedPermission.role !== "button"
    && gatedPermission.disabled !== "true"
    && gatedPermission.hasPopup === ""
    && actions.length === gatedPermission.before,
  `permission without canCyclePermissionMode is passive (${JSON.stringify(gatedPermission)})`);

  await openChat(mainSession);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Chat Details\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Chat technical details\"]'))");
  const detailsProbe = await window.webContents.executeJavaScript(`(() => {
    const details = document.querySelector('[aria-label="Chat technical details"]');
    const composer = document.querySelector('[aria-label="Chat composer"]');
    const status = document.querySelector('[aria-label="Chat status rail"]');
    return {
      detailsText: details?.textContent ?? '',
      composerText: composer?.textContent ?? '',
      statusText: status?.textContent ?? '',
      usageInsideDetails: Boolean(details?.querySelector('[aria-label*="used"]')),
      usageInsideStatus: Boolean(status?.querySelector('[aria-label*="used"]')),
    };
  })()`);
  assert(detailsProbe.usageInsideDetails && !detailsProbe.usageInsideStatus,
    `usage diagnostics live in Details, not a status toolbar (${JSON.stringify(detailsProbe)})`);
  assert(detailsProbe.detailsText.includes("Model provider: OpenAI Codex")
    && detailsProbe.detailsText.includes("Context: 12,000 / 114,688 tokens")
    && detailsProbe.detailsText.includes("Path: /fixture/project"),
  `Details retains provider, context, and path diagnostics (${JSON.stringify(detailsProbe)})`);
  assert(detailsProbe.composerText.includes("GPT-5.6 Sol")
    && detailsProbe.composerText.includes("Reasoning High")
    && !detailsProbe.composerText.includes("/fixture/project"),
  `composer retains passive model and effort context (${JSON.stringify(detailsProbe)})`);
  await capture("light-details.png");

  await openChat(workingSession);
  await waitFor("Boolean(document.querySelector('[aria-label=\"Permission mode: Default\"]'))");
  const permissionBeforeCycle = await window.webContents.executeJavaScript(`(() => ({
    role: document.querySelector('[aria-label="Permission mode: Default"]')?.getAttribute('role') ?? '',
    disabled: document.querySelector('[aria-label="Permission mode: Default"]')?.getAttribute('aria-disabled') ?? '',
    model: document.querySelector('[aria-label="Composer model and effort"]')?.textContent ?? '',
  }))()`);
  assert(permissionBeforeCycle.role === "button" && permissionBeforeCycle.disabled !== "true"
    && permissionBeforeCycle.model.includes("GPT-5.6 Sol"),
  `Claude permission mode is actionable only when the page grants cycling (${JSON.stringify(permissionBeforeCycle)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Permission mode: Default\"]')?.click()");
  await waitFor("document.querySelector('[aria-label=\"Permission mode: Accept Edits\"]')?.getAttribute('aria-disabled') === 'true'");
  const permissionActionCount = actions.filter((action) => action.type === "cycle_permission_mode").length;
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Permission mode: Accept Edits\"]')?.click()");
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert(permissionActionCount === 1
    && actions.filter((action) => action.type === "cycle_permission_mode").length === permissionActionCount,
  "permission mode cycling issues one request and disables duplicates while pending");
  releasePermissionCycle?.();
  releasePermissionCycle = undefined;
  await waitFor("Boolean(document.querySelector('[aria-label=\"Permission mode: Accept Edits\"]')) && document.querySelector('[aria-label=\"Permission mode: Accept Edits\"]')?.getAttribute('aria-disabled') !== 'true'");
  await waitUntil(() => actions.some((action) => action.type === "cycle_permission_mode"
    && action.sessionId === workingSession.id && action.expectedMode === "default"));
  await waitFor("Boolean(document.querySelector('[aria-label=\"Stop agent\"]'))");
  const emptyWorking = await probeActions();
  assert(emptyWorking.stopVisible && emptyWorking.sendDisabled && emptyWorking.stopEnabled,
    `empty working composer makes Stop the available primary action (${JSON.stringify(emptyWorking)})`);
  await setInput("draft survives stop");
  await waitFor("document.querySelector('[aria-label=\"Send\"]')?.getAttribute('aria-disabled') !== 'true'");
  const simultaneous = await probeActions();
  assert(simultaneous.stopVisible && simultaneous.sendVisible && simultaneous.stopEnabled
    && simultaneous.sendEnabled && simultaneous.sameActionCluster,
  `valid drafts retain both Send and Stop in one action cluster (${JSON.stringify(simultaneous)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Stop agent\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Canceling agent\"]'))");
  const cancellationCount = actions.filter((action) => action.type === "cancel_chat").length;
  const cancelingProbe = await probeActions();
  assert(cancelingProbe.stopVisible && !cancelingProbe.stopEnabled
    && cancelingProbe.sendVisible && cancelingProbe.sendEnabled,
  `deferred cancellation disables duplicate Stop while preserving Send (${JSON.stringify(cancelingProbe)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Canceling agent\"]')?.click()");
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert(actions.filter((action) => action.type === "cancel_chat").length === cancellationCount,
    "deferred cancellation ignores a duplicate Stop action");
  await setInput("newer draft survives deferred stop");
  await addPickerImage("cancel-newer.png");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image cancel-newer.png\"]'))");
  await capture("light-canceling.png");
  releaseWorkingCancel?.();
  releaseWorkingCancel = undefined;
  await waitFor("Boolean(document.querySelector('[aria-label=\"Agent stopped\"]'))");
  assert(await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Chat message\"]')?.value === 'newer draft survives deferred stop' && Boolean(document.querySelector('[aria-label=\"Attached image cancel-newer.png\"]'))"),
    "confirmed cancellation preserves a newer text and image draft");

  await openChat(imageOnlySession);
  await waitFor("Boolean(document.querySelector('[aria-label=\"Chat composer\"]'))");
  const imageOnly = await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    return {
      editable: !input?.hasAttribute('aria-disabled') && !input?.disabled && !input?.readOnly,
      hasAddImage: Boolean(document.querySelector('[aria-label="Add image"]')),
    };
  })()`);
  assert(!imageOnly.editable && imageOnly.hasAddImage, `image-only capability keeps attachment composition (${JSON.stringify(imageOnly)})`);
  assert(await probeSendDisabled(), "image-only composer is disabled until an image is attached");
  await addPickerImage("image-only.png");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image image-only.png\"]'))");
  assert(await probeSendDisabled() === false, "image-only composer enables Send after an allowed image");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Send\"]')?.click()");
  await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.sessionId === imageOnlySession.id));
  const imageOnlySend = actions.findLast((action) => action.type === "send_chat" && action.sessionId === imageOnlySession.id);
  assert(imageOnlySend?.text === "" && imageOnlySend.images.length === 1,
    `image-only draft reaches the existing send route (${JSON.stringify(imageOnlySend)})`);

  await openChat(readOnlySession);
  await waitFor("Boolean(document.querySelector('[aria-label=\"Chat read-only notice\"]'))");
  const readOnlyProbe = await window.webContents.executeJavaScript(`(() => ({
    composer: Boolean(document.querySelector('[aria-label="Chat composer"]')),
    input: Boolean(document.querySelector('[aria-label="Chat message"]')),
    reasonCount: document.querySelectorAll('[aria-label="This archived conversation is read only."]').length,
    ownerAction: Boolean(document.querySelector('[aria-label="Open in Codex"]')),
  }))()`);
  assert(!readOnlyProbe.composer && !readOnlyProbe.input && readOnlyProbe.reasonCount === 1 && readOnlyProbe.ownerAction,
    `read-only mode has one reason and the supported source action without a dead composer (${JSON.stringify(readOnlyProbe)})`);
  await capture("light-read-only.png");

  await openChat(mainSession);
  await window.setSize(520, 760);
  await waitFor("window.innerWidth <= 600");
  const narrowProbe = await probeComposer();
  assert(narrowProbe.outerWidth <= 464 && narrowProbe.toolbarScrollWidth <= narrowProbe.toolbarClientWidth + 1,
    `narrow composer stays contained in its viewport (${JSON.stringify(narrowProbe)})`);
  await capture("light-narrow.png");
  nativeTheme.themeSource = "dark";
  await new Promise((resolve) => setTimeout(resolve, 120));
  const darkProbe = await window.webContents.executeJavaScript(`(() => ({
    bodyBackground: getComputedStyle(document.body).backgroundColor,
    surfaceBackground: getComputedStyle(document.querySelector('[aria-label="Chat composer"]')).backgroundColor,
  }))()`);
  assert(darkProbe.bodyBackground !== "" && darkProbe.surfaceBackground !== "rgba(0, 0, 0, 0)",
    `dark mode keeps a visible neutral composer surface (${JSON.stringify(darkProbe)})`);
  await capture("dark-narrow.png");
  await window.setSize(1_200, 760);
  for (let index = 0; index < 15; index += 1) {
    await window.webContents.executeJavaScript("window.dispatchEvent(new KeyboardEvent('keydown', { key: '+', metaKey: true, bubbles: true }))");
  }
  await new Promise((resolve) => setTimeout(resolve, 160));
  const scaledProbe = await probeComposer();
  assert(scaledProbe.inputFontSize >= 30
    && scaledProbe.inputHeight >= scaledProbe.inputLineHeight
    && scaledProbe.outerWidth <= 980
    && scaledProbe.sendTargetWidth >= 44 && scaledProbe.sendTargetHeight >= 44
    && scaledProbe.sendFaceWidth === 32 && scaledProbe.sendFaceHeight === 32
    && scaledProbe.sendGlyphContained,
  `scaled composer preserves readable input and public Send geometry (${JSON.stringify(scaledProbe)})`);
  await capture("dark-scaled.png");
  for (let index = 0; index < 15; index += 1) {
    await window.webContents.executeJavaScript("window.dispatchEvent(new KeyboardEvent('keydown', { key: '-', metaKey: true, bubbles: true }))");
  }
  await waitFor("document.querySelector('[aria-label=\"Chat message\"]') && Number.parseFloat(getComputedStyle(document.querySelector('[aria-label=\"Chat message\"]')).fontSize) <= 15");
  const unscaledProbe = await probeComposer();
  assert(unscaledProbe.inputFontSize <= 15 && unscaledProbe.inputHeight <= compactHeight + 1
    && unscaledProbe.sendTargetWidth >= 44 && unscaledProbe.sendTargetHeight >= 44
    && unscaledProbe.sendGlyphContained,
  `scaling back down restores compact input and public Send geometry (${JSON.stringify(unscaledProbe)})`);

  console.log(JSON.stringify({
    artifactRoot,
    actions: actions.map(({ type, sessionId, text, deliveryId }) => ({ type, sessionId, text, deliveryId })),
      files: ["light-empty.png", "light-draft-image.png", "light-details.png", "light-canceling.png", "light-read-only.png", "light-narrow.png", "dark-narrow.png", "dark-scaled.png"],
  }, null, 2));
}

async function openChat(target) {
  const targetTitle = JSON.stringify(target.title);
  const activeChat = await window.webContents.executeJavaScript("Boolean(document.querySelector('[aria-label=\"Back to Sessions\"]'))");
  if (activeChat) {
    const isTarget = await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat header rail"]')?.textContent.includes(${targetTitle}) === true`);
    if (!isTarget) {
      await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Back to Sessions\"]')?.click()");
      await waitFor(`Boolean(document.querySelector('[aria-label="Open Chat for ${target.title}"]'))`);
    }
  }
  const alreadyTarget = await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Chat header rail"]')?.textContent.includes(${targetTitle}) === true`);
  if (!alreadyTarget) {
    await waitFor(`Boolean(document.querySelector('[aria-label="Open Chat for ${target.title}"]'))`);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Open Chat for ${target.title}"]')?.click()`);
  }
  await waitFor(`document.querySelector('[aria-label="Chat header rail"]')?.textContent.includes(${targetTitle}) === true`);
  const encodedSessionId = encodeURIComponent(target.id);
  if (target.id === readOnlySession.id) {
    await waitFor(`Boolean(document.querySelector('#chat-timeline-${encodedSessionId}')) && Boolean(document.querySelector('[aria-label="Chat read-only notice"]'))`);
  } else {
    await waitFor(`Boolean(document.querySelector('#chat-timeline-${encodedSessionId}')) && Boolean(document.querySelector('#chat-composer-input-${encodedSessionId}'))`);
  }
}

async function probeComposer() {
  return window.webContents.executeJavaScript(`(() => {
    const outer = document.querySelector('[aria-label="Chat composer"]');
    const rail = document.querySelector('[aria-label="Chat composer rail"]');
    const input = document.querySelector('[aria-label="Chat message"]');
    const plus = document.querySelector('[aria-label="Add image"]');
    const send = document.querySelector('[aria-label="Send"]');
    const toolbar = document.querySelector('[aria-label="Chat composer actions"]');
    const style = outer ? getComputedStyle(outer) : null;
    const inputStyle = input ? getComputedStyle(input) : null;
    const plusStyle = plus ? getComputedStyle(plus) : null;
    const plusGlyph = plus?.firstElementChild;
    const glyphCandidates = [...(send?.querySelectorAll('*') ?? [])]
      .filter((element) => element.textContent?.trim() === '↑');
    const glyph = glyphCandidates.at(-1);
    const face = glyph?.parentElement ?? send?.firstElementChild;
    const faceRect = face?.getBoundingClientRect();
    const glyphRect = glyph?.getBoundingClientRect();
    const outerRect = outer?.getBoundingClientRect();
    const toolbarRect = toolbar?.getBoundingClientRect();
    const sendRect = send?.getBoundingClientRect();
    return {
      outer: Boolean(outer), rail: Boolean(rail),
      outerWidth: outerRect?.width ?? 0, outerHeight: outerRect?.height ?? 0,
      borderWidth: style?.borderWidth ?? "", borderRadius: Number.parseFloat(style?.borderRadius ?? "0"),
      inputBorderWidth: inputStyle?.borderWidth ?? "", inputBackground: inputStyle?.backgroundColor ?? "",
      inputFontSize: Number.parseFloat(inputStyle?.fontSize ?? "0"),
      inputLineHeight: Number.parseFloat(inputStyle?.lineHeight ?? "0"),
      inputHeight: input?.getBoundingClientRect().height ?? 0,
      inputScrollHeight: input?.scrollHeight ?? 0,
      inputOverflowY: inputStyle?.overflowY ?? "",
      plusWidth: plus?.getBoundingClientRect().width ?? 0, plusHeight: plus?.getBoundingClientRect().height ?? 0,
      plusGlyphSize: plusGlyph ? Number.parseFloat(getComputedStyle(plusGlyph).fontSize) : 0,
      sendDisabled: send?.getAttribute('aria-disabled') === 'true',
      sendTargetWidth: sendRect?.width ?? 0, sendTargetHeight: sendRect?.height ?? 0,
      sendFaceWidth: faceRect?.width ?? 0, sendFaceHeight: faceRect?.height ?? 0,
      sendGlyphWidth: glyphRect?.width ?? 0, sendGlyphHeight: glyphRect?.height ?? 0,
      sendGlyphContained: Boolean(faceRect && glyphRect
        && glyphRect.left >= faceRect.left
        && glyphRect.right <= faceRect.right
        && glyphRect.top >= faceRect.top
        && glyphRect.bottom <= faceRect.bottom),
      toolbarClientWidth: toolbar?.clientWidth ?? 0, toolbarScrollWidth: toolbar?.scrollWidth ?? 0,
      toolbarWidth: toolbarRect?.width ?? 0,
    };
  })()`);
}

async function probeSendDisabled() {
  return window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Send\"]')?.getAttribute('aria-disabled') === 'true'");
}

async function probeActions() {
  return window.webContents.executeJavaScript(`(() => {
    const cluster = document.querySelector('[aria-label="Chat composer actions"]');
    const send = document.querySelector('[aria-label="Send"]');
    const stop = document.querySelector('[aria-label="Stop agent"], [aria-label="Canceling agent"], [aria-label="Agent stopped"], [aria-label="Retry stopping agent"]');
    return {
      sendVisible: Boolean(send),
      sendDisabled: send?.getAttribute('aria-disabled') === 'true',
      sendEnabled: send?.getAttribute('aria-disabled') !== 'true',
      stopVisible: Boolean(stop),
      stopEnabled: stop?.getAttribute('aria-disabled') !== 'true',
      sameActionCluster: Boolean(cluster && send && stop && cluster.contains(send) && cluster.contains(stop)),
    };
  })()`);
}

async function setInput(value) {
  await window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    setter?.call(input, ${JSON.stringify(value)});
    input?.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
}

async function dispatchComposerKey({ key, shiftKey = false, isComposing = false }) {
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

async function addPickerImage(name) {
  await window.webContents.executeJavaScript(`(() => {
    const originalClick = HTMLInputElement.prototype.click;
    const file = new File([Uint8Array.from(atob(${JSON.stringify(validImageBase64)}), (value) => value.charCodeAt(0))], ${JSON.stringify(name)}, { type: 'image/png' });
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

async function pasteImage(name, type, bytes) {
  return window.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('[aria-label="Chat message"]');
    if (!input) return false;
    const file = new File([new Uint8Array(${JSON.stringify(bytes)})], ${JSON.stringify(name)}, { type: ${JSON.stringify(type)} });
    const transfer = new DataTransfer();
    transfer.items.add(file);
    const event = new Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(event, 'clipboardData', { configurable: true, value: transfer });
    input.dispatchEvent(event);
    return event.defaultPrevented;
  })()`);
}

async function capture(name) {
  const image = await window.webContents.capturePage();
  await writeFile(path.join(artifactRoot, name), image.toPNG());
}

async function waitFor(expression, timeoutMs = 6_000) {
  for (let elapsed = 0; elapsed < timeoutMs; elapsed += 50) {
    if (await window.webContents.executeJavaScript(`Boolean(${expression})`)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const state = await window.webContents.executeJavaScript("({ body: document.body?.textContent ?? '', labels: [...document.querySelectorAll('[aria-label]')].map((element) => element.getAttribute('aria-label')) })").catch(() => ({ body: "<no body>", labels: [] }));
  throw new Error(`Composer fixture did not reach ${expression}; state=${JSON.stringify(state)}`);
}

async function waitUntil(condition, timeoutMs = 6_000) {
  for (let elapsed = 0; elapsed < timeoutMs; elapsed += 20) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error("Composer fixture did not record the expected daemon action.");
}
