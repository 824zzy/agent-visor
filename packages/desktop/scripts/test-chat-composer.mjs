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

const readyState = { conversation: "open", turn: "ready", route: "available" };
const workingState = {
  conversation: "open",
  turn: "working",
  route: "waiting",
  unavailableReason: "turn_in_progress",
};
const archivedState = {
  conversation: "archived",
  turn: "unknown",
  route: "unavailable",
  unavailableReason: "archived",
};

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
  sessionState: readyState,
  stateRevision: 1,
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
  sessionState: workingState,
  stateRevision: 1,
};
const gatedPermissionSession = {
  ...workingSession,
  id: "composer-permission-gated",
  title: "Composer Permission Gated Chat",
  subtitle: "Permission display only",
  section: "ready",
  updatedAt: "2026-08-31T08:30:00.000Z",
  sessionState: readyState,
  stateRevision: 1,
};
const permissionReadySession = {
  ...mainSession,
  id: "composer-permission-ready",
  title: "Composer Permission Ready Chat",
  source: "Claude Code",
  owner: "Ghostty",
  section: "ready",
  subtitle: "Ready",
  sessionState: readyState,
  stateRevision: 1,
};
const imageOnlySession = {
  ...mainSession,
  id: "composer-image-only",
  title: "Composer Image Only Chat",
  subtitle: "Images only",
  source: "Pi",
  updatedAt: "2026-08-31T08:00:00.000Z",
  sessionState: readyState,
  stateRevision: 1,
};
const readOnlySession = {
  ...mainSession,
  id: "composer-read-only",
  title: "Composer Read Only Chat",
  subtitle: "Session ended",
  section: "history",
  cwd: "/fixture/archive",
  updatedAt: "2026-08-31T07:00:00.000Z",
  sessionState: archivedState,
  stateRevision: 1,
};
const missingModelSession = {
  ...mainSession,
  id: "composer-missing-model",
  title: "Composer Missing Model Chat",
  sessionState: readyState,
  stateRevision: 1,
};
const sessions = [mainSession, workingSession, gatedPermissionSession, permissionReadySession, imageOnlySession, readOnlySession, missingModelSession];

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
      reasoningEfforts: [
        { value: "low", description: "Quick reasoning." },
        { value: "medium", description: "Balanced reasoning." },
        { value: "high", description: "More deliberate reasoning." },
        { value: "xhigh", description: "Extra deliberate reasoning." },
        { value: "max", description: "Maximum reasoning." },
        { value: "ultra", description: "Most extensive reasoning." },
      ],
      defaultReasoningEffort: "high",
      supportsImages: true,
      isDefault: true,
    },
    {
      id: "gpt-6-astra",
      displayName: "GPT-6 Astra",
      description: "Most capable model.",
      reasoningEfforts: [
        { value: "high", description: "More deliberate reasoning." },
        { value: "max", description: "Maximum reasoning." },
      ],
      defaultReasoningEffort: "max",
      supportsImages: true,
      isDefault: false,
    },
    {
      id: "gpt-rejected",
      displayName: "Rejected model",
      description: "Fixture model rejected by the provider.",
      reasoningEfforts: [
        { value: "high", description: "More deliberate reasoning." },
      ],
      defaultReasoningEffort: "high",
      supportsImages: true,
      isDefault: false,
    },
    {
      id: "gpt-text-only",
      displayName: "Text only",
      description: "Fixture model without image input.",
      reasoningEfforts: [
        { value: "high", description: "More deliberate reasoning." },
      ],
      defaultReasoningEffort: "high",
      supportsImages: false,
      isDefault: false,
    },
  ],
  permissionProfiles: [
    { id: ":workspace", displayName: "Workspace", description: "Access files in the workspace.", allowed: true },
    { id: ":danger-full-access", displayName: "Full access", description: "Allow unrestricted local access.", allowed: true },
    { id: ":read-only", displayName: "Read only", description: "Inspect without writing.", allowed: false },
  ],
  appliesTo: "next_turn",
  canChange: true,
};

let server;
let window;
let exitCode = 0;
const actions = [];
let claudePermissionMode = "default";
let pendingApproval = false;
let releasePermissionCycle;
let releaseWorkingCancel;

function completeWorkingSession() {
  workingSession.sessionState = readyState;
  workingSession.section = "ready";
  workingSession.stateRevision += 1;
}

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
      return (async () => {
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
            readOnlyReason: "This conversation is archived. Open it in Codex to restore it.",
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
      if (target.id === permissionReadySession.id) {
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "permission-ready-answer", kind: "assistant", text: "Permission mode fixture." }],
          hasMoreBefore: false,
          capabilities: {
            canSendText: true,
            canSendImages: true,
            canCancel: false,
            canApprove: false,
            canAnswer: false,
            canCyclePermissionMode: true,
          },
          pendingAction: null,
          metadata: { ...metadata, permissionMode: claudePermissionMode },
          chatSettings,
        };
      }
      if (target.id === workingSession.id) {
        const working = target.sessionState.turn === "working";
        return {
          type: "chat_page",
          sessionId,
          items: [{ id: "working-answer", kind: "assistant", text: "Working fixture." }],
          hasMoreBefore: false,
          capabilities: {
            canSendText: !working,
            canSendImages: !working,
            canCancel: working,
            ...(working ? { cancelDeliveryId: "working-delivery", unavailableReason: "turn_in_progress" } : {}),
            canApprove: false,
            canAnswer: false,
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
          chatSettings,
        };
      }
      if (target.id === missingModelSession.id) {
        return {
          type: "chat_page", sessionId,
          items: [{ id: "missing-model-answer", kind: "assistant", text: "Current model is absent from the selectable catalog." }],
          hasMoreBefore: false,
          capabilities: { canSendText: true, canSendImages: true, canCancel: false, canApprove: false, canAnswer: false },
          pendingAction: null,
          metadata: { ...metadata, model: "GPT-6 Astra", modelId: "gpt-6-astra", reasoningEffort: "xhigh" },
          chatSettings: {
            ...chatSettings,
            current: { ...chatSettings.current, modelId: "gpt-6-astra", reasoningEffort: "xhigh" },
            models: [
              ...chatSettings.models.filter(({ id }) => id !== "gpt-6-astra"),
              ...["one", "two", "three"].map((suffix) => ({ ...chatSettings.models[0], id: `extra-${suffix}`, displayName: `Additional model ${suffix}` })),
            ],
          },
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
        chatSettings,
      };
      })().then((page) => ({
        ...page,
        sessionState: target.sessionState,
        stateRevision: target.stateRevision,
      }));
    },
    chatAction: async (message) => {
      actions.push(message);
      if (message.type === "send_chat" && message.settings?.modelId === "gpt-rejected") {
        return "The provider rejected this model for the next turn.";
      }
      if (message.type === "cycle_permission_mode") {
        return new Promise((resolve) => {
          releasePermissionCycle = () => {
            claudePermissionMode = "acceptEdits";
            resolve();
          };
        });
      }
      if (message.type === "cancel_chat" && message.sessionId === workingSession.id) {
        return new Promise((resolve) => {
          releaseWorkingCancel = (value) => {
            completeWorkingSession();
            resolve(value);
          };
        });
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
  await waitFor("document.activeElement?.getAttribute('aria-label') === 'Chat message'");
  window.webContents.debugger.attach("1.3");
  await window.webContents.debugger.sendCommand("DOM.enable");
  await window.webContents.debugger.sendCommand("CSS.enable");
  const { root: documentNode } = await window.webContents.debugger.sendCommand("DOM.getDocument");
  const { nodeId: composerInputNodeId } = await window.webContents.debugger.sendCommand("DOM.querySelector", {
    nodeId: documentNode.nodeId,
    selector: '[aria-label="Chat message"]',
  });
  await window.webContents.debugger.sendCommand("CSS.forcePseudoState", {
    nodeId: composerInputNodeId,
    forcedPseudoClasses: ["focus-visible"],
  });
  const emptyProbe = await probeComposer();
  window.webContents.debugger.detach();
  assert(emptyProbe.outer && emptyProbe.rail, `integrated composer exposes one public enclosure and rail (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.surfaceBackground === emptyProbe.canvasBackground,
    `composer enclosure shares the light Chat canvas (${emptyProbe.canvasBackground} → ${emptyProbe.surfaceBackground})`);
  assert(emptyProbe.borderWidth === "1px" && emptyProbe.borderRadius >= 20 && emptyProbe.borderRadius <= 22,
    `composer enclosure uses the neutral 1px 20-22px surface (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.inputBorderWidth === "0px" && emptyProbe.inputBackground === "rgba(0, 0, 0, 0)",
    `composer input is transparent and unboxed (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.inputOutlineWidth === "0px" || emptyProbe.inputOutlineStyle === "none",
    `focused composer input has no browser focus frame (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.outerHeight >= 100 && emptyProbe.outerHeight <= 112,
    `empty composer keeps the compact 100-112px target range (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.plusWidth >= 44 && emptyProbe.plusHeight >= 44,
    `Add image keeps a 44px target (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.plusGlyphSize >= 18 && emptyProbe.sendFaceWidth === 32 && emptyProbe.sendFaceHeight === 32
    && emptyProbe.sendTargetWidth >= 44 && emptyProbe.sendTargetHeight >= 44
    && emptyProbe.sendGlyphContained,
    `composer action glyphs keep the approved optical sizes (${JSON.stringify(emptyProbe)})`);
  assert(emptyProbe.sendDisabled, "empty composer disables Send");
  const contextProbe = await window.webContents.executeJavaScript(`(() => {
    const context = document.querySelector('[aria-label="Composer model and effort"]');
    const permission = document.querySelector('[aria-label="Permission: Workspace"]');
    return {
      text: context?.textContent ?? '',
      role: context?.getAttribute('role') ?? '',
      hasPopup: context?.getAttribute('aria-haspopup') ?? '',
      expanded: context?.getAttribute('aria-expanded') ?? '',
      permissionRole: permission?.getAttribute('role') ?? '',
      permissionPopup: permission?.getAttribute('aria-haspopup') ?? '',
      modelLeft: context?.getBoundingClientRect().left ?? -1,
      permissionLeft: permission?.getBoundingClientRect().left ?? -1,
      sendLeft: document.querySelector('[aria-label="Send"]')?.getBoundingClientRect().left ?? -1,
    };
  })()`);
  assert(contextProbe.text.includes("GPT-5.6 Sol")
    && contextProbe.text.includes("High")
    && !contextProbe.text.includes("Reasoning High")
    && contextProbe.role === "button"
    && contextProbe.hasPopup === "menu"
    && contextProbe.expanded === "false"
    && contextProbe.permissionRole === "button"
    && contextProbe.permissionPopup === "menu"
    && contextProbe.modelLeft < contextProbe.permissionLeft
    && contextProbe.permissionLeft < contextProbe.sendLeft,
  `Codex model, effort, and permission controls expose provider options (${JSON.stringify(contextProbe)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Composer model and effort menu\"]'))");
  const modelMenuProbe = await window.webContents.executeJavaScript(`(() => ({
    expanded: document.querySelector('[aria-label="Composer model and effort"]')?.getAttribute('aria-expanded') ?? '',
    menuRole: document.querySelector('[aria-label="Composer model and effort menu"]')?.getAttribute('role') ?? '',
    options: [...document.querySelectorAll('[aria-label^="Model:"]')].map((item) => item.textContent?.trim()),
    scope: document.querySelector('[aria-label="Applies from your next message (until changed)"]')?.textContent ?? '',
  }))()`);
  assert(modelMenuProbe.expanded === "true"
    && modelMenuProbe.menuRole === "menu"
    && modelMenuProbe.options.some((option) => option.includes("GPT-6 Astra"))
    && modelMenuProbe.scope === "Applies from your next message (until changed)",
  `model menu exposes catalog options and next-message scope (${JSON.stringify(modelMenuProbe)})`);
  await new Promise((resolve) => setTimeout(resolve, 100));
  await capture("light-model-menu.png");
  await window.webContents.executeJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true, cancelable: true }))");
  await waitFor("document.activeElement?.getAttribute('aria-label') === 'Model: GPT-6 Astra'");
  const keyboardMenuProbe = await window.webContents.executeJavaScript(`(() => ({
    focused: document.activeElement?.getAttribute('aria-label') ?? '',
    active: document.querySelector('[aria-label="Model: GPT-6 Astra"]')?.getAttribute('aria-selected') ?? '',
  }))()`);
  assert(keyboardMenuProbe.focused === "Model: GPT-6 Astra" && keyboardMenuProbe.active === "false",
    `ArrowDown moves focus without changing the staged selection (${JSON.stringify(keyboardMenuProbe)})`);
  await window.webContents.executeJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))");
  await waitFor("document.querySelector('[aria-label=\"Composer model and effort\"]')?.textContent.includes('GPT-6 Astra')");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Permission: Workspace\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Composer permission menu\"]'))");
  const permissionMenuProbe = await window.webContents.executeJavaScript(`(() => ({
    options: [...document.querySelectorAll('[aria-label^="Permission:"]')].map((item) => ({
      label: item.getAttribute('aria-label'), disabled: item.getAttribute('aria-disabled') ?? '',
    })),
    scope: document.querySelector('[aria-label="Applies from your next message (until changed)"]')?.textContent ?? '',
    approvalNote: document.querySelector('[aria-label="Existing approval settings are preserved."]')?.textContent ?? '',
  }))()`);
  assert(permissionMenuProbe.options.some(({ label }) => label === "Permission: Full access")
    && permissionMenuProbe.options.some(({ label, disabled }) => label === "Permission: Read only" && disabled === "true")
    && permissionMenuProbe.scope === "Applies from your next message (until changed)"
    && permissionMenuProbe.approvalNote === "Existing approval settings are preserved.",
  `permission menu exposes allowed and rejected provider profiles honestly (${JSON.stringify(permissionMenuProbe)})`);
  await new Promise((resolve) => setTimeout(resolve, 100));
  await capture("light-permission-menu.png");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Permission: Full access\"]')?.click()");
  await waitFor("document.querySelector('[aria-label=\"Permission: Full access\"]')?.getAttribute('aria-expanded') === 'false'");
  const stagedProbe = await window.webContents.executeJavaScript(`(() => ({
    model: document.querySelector('[aria-label="Composer model and effort"]')?.textContent ?? '',
    permission: document.querySelector('[aria-label="Permission: Full access"]')?.textContent ?? '',
    modelExpanded: document.querySelector('[aria-label="Composer model and effort"]')?.getAttribute('aria-expanded') ?? '',
  }))()`);
  assert(stagedProbe.model.includes("GPT-6 Astra") && stagedProbe.model.includes("Max")
    && stagedProbe.permission.includes("Full access"),
  `staged next-message settings update only after provider options are selected (${JSON.stringify(stagedProbe)})`);
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
    && Boolean(document.querySelector('[aria-label="Attached image composer.png"]'))
    && document.querySelector('[aria-label="Composer model and effort"]')?.textContent.includes('GPT-6 Astra')
    && document.querySelector('[aria-label="Permission: Full access"]')?.textContent.includes('Full access')`),
    "approval response restores the stored text, image, and provider settings draft");

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
  const configuredSend = actions.findLast((action) => action.type === "send_chat" && action.text === "paste draft");
  assert(configuredSend?.settings?.modelId === "gpt-6-astra"
    && configuredSend.settings.reasoningEffort === "max"
    && configuredSend.settings.permissionProfile === ":danger-full-access",
  `selected model, effort, and permission travel with the next send (${JSON.stringify(configuredSend?.settings)})`);
  await waitFor("document.querySelector('[aria-label=\"Chat message\"]')?.value === ''");
  await waitFor("!document.querySelector('[aria-label=\"Attached image pasted.png\"]')");

  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Composer model and effort menu\"]'))");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Model: Rejected model\"]')?.click()");
  await setInput("rejected setting");
  await waitFor("document.querySelector('[aria-label=\"Send\"]')?.getAttribute('aria-disabled') !== 'true'");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Send\"]')?.click()");
  await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.settings?.modelId === "gpt-rejected"));
  await waitFor("Boolean(document.querySelector('[aria-label=\"Chat delivery recovery\"]'))");
  await waitFor("document.querySelector('[aria-label=\"Chat message\"]')?.value === 'rejected setting'");
  const rejectedProbe = await window.webContents.executeJavaScript(`(() => ({
    model: document.querySelector('[aria-label="Composer model and effort"]')?.textContent ?? '',
    recovery: document.querySelector('[aria-label="Chat delivery recovery"]')?.textContent ?? '',
    draft: document.querySelector('[aria-label="Chat message"]')?.value ?? '',
  }))()`);
  assert(rejectedProbe.model.includes("Rejected model")
    && rejectedProbe.recovery.includes("provider rejected")
    && rejectedProbe.draft === "rejected setting",
  `a rejected setting remains clearly staged and actionable (${JSON.stringify(rejectedProbe)})`);

  await setInput("");
  await waitFor(`document.querySelector('[aria-label="Chat composer"]')?.getBoundingClientRect().height <= ${compactHeight + 1}`);
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

  await addPickerImage("capability.png");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image capability.png\"]'))");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Composer model and effort menu\"]'))");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Model: Text only\"]')?.click()");
  await waitFor("document.querySelector('[aria-label=\"Composer model and effort\"]')?.textContent.includes('Text only')");
  await waitFor("document.querySelector('[aria-label=\"Composer validation errors\"]')?.textContent.includes('Choose a model with image support')");
  const incompatibleImageProbe = await window.webContents.executeJavaScript(`(() => ({
    hasAttachment: Boolean(document.querySelector('[aria-label="Attached image capability.png"]')),
    hasAddImage: Boolean(document.querySelector('[aria-label="Add image"]')),
    sendDisabled: document.querySelector('[aria-label="Send"]')?.getAttribute('aria-disabled') ?? '',
    error: document.querySelector('[aria-label="Composer validation errors"]')?.textContent ?? '',
  }))()`);
  assert(incompatibleImageProbe.hasAttachment && !incompatibleImageProbe.hasAddImage
    && incompatibleImageProbe.sendDisabled === "true"
    && incompatibleImageProbe.error.includes("Choose a model with image support"),
  `text-only model preserves the image draft and blocks an incompatible send (${JSON.stringify(incompatibleImageProbe)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Composer model and effort menu\"]'))");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Model: GPT-6 Astra\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Add image\"]')) && document.querySelector('[aria-label=\"Send\"]')?.getAttribute('aria-disabled') !== 'true'");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Remove image capability.png\"]')?.click()");
  await waitFor("!document.querySelector('[aria-label=\"Attached image capability.png\"]')");

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
  assert(detailsProbe.composerText.includes("GPT-6 Astra")
    && detailsProbe.composerText.includes("Max")
    && !detailsProbe.composerText.includes("Reasoning Max")
    && !detailsProbe.composerText.includes("/fixture/project"),
  `composer retains model and effort context (${JSON.stringify(detailsProbe)})`);
  await capture("light-details.png");

  await openChat(permissionReadySession);
  await waitFor("Boolean(document.querySelector('[aria-label=\"Permission: Workspace\"]'))");
  const permissionBeforeCycle = await window.webContents.executeJavaScript(`(() => ({
    role: document.querySelector('[aria-label="Permission: Workspace"]')?.getAttribute('role') ?? '',
    disabled: document.querySelector('[aria-label="Permission: Workspace"]')?.getAttribute('aria-disabled') ?? '',
    model: document.querySelector('[aria-label="Composer model and effort"]')?.textContent ?? '',
  }))()`);
  assert(permissionBeforeCycle.role === "button" && permissionBeforeCycle.disabled !== "true"
    && permissionBeforeCycle.model.includes("GPT-5.6 Sol"),
  `Claude permission control is actionable while the ready page grants staging (${JSON.stringify(permissionBeforeCycle)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Permission: Workspace\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Composer permission menu\"]'))");
  const permissionReadyMenuProbe = await window.webContents.executeJavaScript(`(() => ({
    options: [...document.querySelectorAll('[aria-label^="Permission:"]')].map((item) => ({
      label: item.getAttribute('aria-label'), disabled: item.getAttribute('aria-disabled') ?? '',
    })),
  }))()`);
  assert(permissionReadyMenuProbe.options.some(({ label }) => label === "Permission: Full access")
    && permissionReadyMenuProbe.options.some(({ label, disabled }) => label === "Permission: Read only" && disabled === "true"),
  `ready permission menu exposes allowed and rejected profiles (${JSON.stringify(permissionReadyMenuProbe)})`);
  const permissionActionCount = actions.length;
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Permission: Full access\"]')?.click()");
  await waitFor("document.querySelector('[aria-label=\"Permission: Full access\"]')?.getAttribute('aria-expanded') === 'false'");
  assert(actions.length === permissionActionCount,
    "permission selection stages the next turn without sending a separate action");

  completeWorkingSession();
  await openChat(workingSession);
  await setInput("draft survives stop");
  await addPickerImage("cancel-existing.png");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image cancel-existing.png\"]'))");
  workingSession.sessionState = workingState;
  workingSession.section = "working";
  workingSession.stateRevision += 1;
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Back to Sessions\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Open Chat for Composer Working Chat\"]'))");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Open Chat for Composer Working Chat\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Stop agent\"]'))");
  const emptyWorking = await probeActions();
  assert(emptyWorking.stopVisible && emptyWorking.sendDisabled && emptyWorking.stopEnabled,
    `a busy working composer waits for the current turn while keeping exact Stop (${JSON.stringify(emptyWorking)})`);
  await waitFor("document.querySelector('[aria-label=\"Chat message\"]')?.value === 'draft survives stop' && Boolean(document.querySelector('[aria-label=\"Attached image cancel-existing.png\"]'))");
  const waitingWithDraft = await probeActions();
  assert(waitingWithDraft.stopVisible && waitingWithDraft.sendVisible
    && waitingWithDraft.stopEnabled && waitingWithDraft.sendDisabled,
  `a busy turn keeps the draft visible but waits before sending (${JSON.stringify(waitingWithDraft)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Stop agent\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Canceling agent\"]'))");
  const cancellationCount = actions.filter((action) => action.type === "cancel_chat").length;
  const cancelingProbe = await probeActions();
  assert(cancelingProbe.stopVisible && !cancelingProbe.stopEnabled
    && cancelingProbe.sendVisible && cancelingProbe.sendDisabled,
  `deferred cancellation disables duplicate Stop and keeps Send unavailable (${JSON.stringify(cancelingProbe)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Canceling agent\"]')?.click()");
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert(actions.filter((action) => action.type === "cancel_chat").length === cancellationCount,
    "deferred cancellation ignores a duplicate Stop action");
  await setInput("newer draft survives deferred stop");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image cancel-existing.png\"]'))");
  await capture("light-canceling.png");
  releaseWorkingCancel?.();
  releaseWorkingCancel = undefined;
  await waitFor("Boolean(document.querySelector('[aria-label=\"Agent stopped\"]'))");
  assert(await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Chat message\"]')?.value === 'newer draft survives deferred stop' && Boolean(document.querySelector('[aria-label=\"Attached image cancel-existing.png\"]'))"),
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
  assert(imageOnly.editable && imageOnly.hasAddImage, `image-only capability keeps the draft editable while exposing attachment composition (${JSON.stringify(imageOnly)})`);
  assert(await probeSendDisabled(), "image-only composer is disabled until an image is attached");
  await setInput("text-only draft");
  await waitFor("document.querySelector('[aria-label=\"Chat message\"]')?.value === 'text-only draft'");
  const textOnlySendCount = actions.filter((action) => action.type === "send_chat" && action.sessionId === imageOnlySession.id).length;
  await dispatchComposerKey({ key: "Enter" });
  await waitFor("document.querySelector('[aria-label=\"Composer validation errors\"]')?.textContent.includes('Text messages are unavailable')");
  assert(actions.filter((action) => action.type === "send_chat" && action.sessionId === imageOnlySession.id).length === textOnlySendCount,
    "image-only capability blocks a text-only submission");
  await addPickerImage("image-only.png");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Attached image image-only.png\"]'))");
  assert(await probeSendDisabled(), "image-only capability keeps mixed text and image submissions disabled");
  const mixedSendCount = actions.filter((action) => action.type === "send_chat" && action.sessionId === imageOnlySession.id).length;
  await dispatchComposerKey({ key: "Enter" });
  await waitFor("document.querySelector('[aria-label=\"Composer validation errors\"]')?.textContent.includes('Text messages are unavailable')");
  assert(actions.filter((action) => action.type === "send_chat" && action.sessionId === imageOnlySession.id).length === mixedSendCount,
    "image-only capability blocks a mixed text and image submission");
  await setInput("");
  await waitFor("document.querySelector('[aria-label=\"Chat message\"]')?.value === ''");
  assert(await probeSendDisabled() === false, "image-only composer enables Send after text is cleared");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Send\"]')?.click()");
  await waitUntil(() => actions.some((action) => action.type === "send_chat" && action.sessionId === imageOnlySession.id));
  const imageOnlySend = actions.findLast((action) => action.type === "send_chat" && action.sessionId === imageOnlySession.id);
  assert(imageOnlySend?.text === "" && imageOnlySend.images.length === 1,
    `image-only draft reaches the existing send route (${JSON.stringify(imageOnlySend)})`);

  await openChat(readOnlySession);
  await waitFor("Boolean(document.querySelector('[aria-label=\"Chat availability notice\"]'))");
  const readOnlyProbe = await window.webContents.executeJavaScript(`(() => ({
    composer: Boolean(document.querySelector('[aria-label="Chat composer"]')),
    inputDisabled: (() => {
      const input = document.querySelector('[aria-label="Chat message"]');
      return Boolean(input?.disabled || input?.readOnly || input?.getAttribute('aria-disabled') === 'true');
    })(),
    sendDisabled: document.querySelector('[aria-label="Send"]')?.getAttribute('aria-disabled') === 'true',
    reasonCount: document.querySelectorAll('[aria-label="This conversation is archived. Open it in Codex to restore it."]').length,
    ownerAction: Boolean(document.querySelector('[aria-label="Open in Codex"]')),
  }))()`);
  assert(readOnlyProbe.composer && readOnlyProbe.inputDisabled && readOnlyProbe.sendDisabled
    && readOnlyProbe.reasonCount === 1 && readOnlyProbe.ownerAction,
    `archived mode keeps one reason, a disabled composer, and the supported source action (${JSON.stringify(readOnlyProbe)})`);
  await capture("light-read-only.png");

  await openChat(mainSession);
  await window.setSize(520, 760);
  await waitFor("window.innerWidth <= 600");
  const narrowProbe = await probeComposer();
  assert(narrowProbe.outerWidth <= 464 && narrowProbe.toolbarScrollWidth <= narrowProbe.toolbarClientWidth + 1,
    `narrow composer stays contained in its viewport (${JSON.stringify(narrowProbe)})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Composer model and effort menu\"]'))");
  const narrowMenuProbe = await window.webContents.executeJavaScript(`(() => {
    const menu = document.querySelector('[aria-label="Composer model and effort menu"]')?.getBoundingClientRect();
    return { left: menu?.left ?? -1, right: menu?.right ?? -1, viewport: window.innerWidth };
  })()`);
  assert(narrowMenuProbe.left >= -1 && narrowMenuProbe.right <= narrowMenuProbe.viewport + 1,
    `narrow model menu remains inside the viewport (${JSON.stringify(narrowMenuProbe)})`);
  await new Promise((resolve) => setTimeout(resolve, 100));
  await capture("light-narrow-model-menu.png");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("document.querySelector('[aria-label=\"Composer model and effort\"]')?.getAttribute('aria-expanded') === 'false'");
  await capture("light-narrow.png");
  nativeTheme.themeSource = "dark";
  await new Promise((resolve) => setTimeout(resolve, 120));
  const darkProbe = await window.webContents.executeJavaScript(`(() => ({
    canvasBackground: getComputedStyle(document.getElementById('chat-canvas')).backgroundColor,
    surfaceBackground: getComputedStyle(document.querySelector('[aria-label="Chat composer"]')).backgroundColor,
  }))()`);
  assert(darkProbe.surfaceBackground === darkProbe.canvasBackground,
    `composer enclosure shares the dark Chat canvas (${darkProbe.canvasBackground} → ${darkProbe.surfaceBackground})`);
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Composer model and effort menu\"]'))");
  await new Promise((resolve) => setTimeout(resolve, 100));
  await capture("dark-model-menu.png");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("document.querySelector('[aria-label=\"Composer model and effort\"]')?.getAttribute('aria-expanded') === 'false'");
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

  await openChat(missingModelSession);
  await window.setSize(520, 760);
  await waitFor("window.innerWidth <= 600");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Composer model and effort menu\"]'))");
  const missingModelProbe = await window.webContents.executeJavaScript(`(() => {
    const trigger = document.querySelector('[aria-label="Composer model and effort"]');
    const menu = document.querySelector('[aria-label="Composer model and effort menu"]');
    const bounds = menu.getBoundingClientRect();
    return { label: trigger.textContent, vectorIcon: Boolean(trigger.querySelector('svg')),
      left: bounds.left, right: bounds.right, top: bounds.top, bottom: bounds.bottom,
      width: bounds.width, viewport: window.innerWidth, height: window.innerHeight,
      currentDisabled: document.querySelector('[aria-label="Model: GPT-6-astra"]')?.getAttribute('aria-disabled') };
  })()`);
  assert(missingModelProbe.label.includes("GPT-6-astra") && missingModelProbe.label.includes("Extra high")
    && missingModelProbe.vectorIcon && missingModelProbe.currentDisabled === "true",
  `missing current model remains visible without becoming selectable (${JSON.stringify(missingModelProbe)})`);
  assert(missingModelProbe.left >= 12 && missingModelProbe.right <= missingModelProbe.viewport - 12
    && missingModelProbe.top >= 12 && missingModelProbe.bottom <= missingModelProbe.height - 12
    && missingModelProbe.width >= 320,
  `missing-model menu stays readable and inside every viewport edge (${JSON.stringify(missingModelProbe)})`);
  await capture("missing-current-model.png");
  await window.webContents.executeJavaScript("document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))");
  await waitFor("document.querySelector('[aria-label=\"Composer model and effort\"]')?.getAttribute('aria-expanded') === 'false'");
  await waitFor("document.activeElement?.getAttribute('aria-label') === 'Composer model and effort'");
  assert(await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Chat header rail\"]')?.textContent.includes('Composer Missing Model Chat') && document.activeElement?.getAttribute('aria-label') === 'Composer model and effort'"),
    "Escape dismisses only the popup and restores trigger focus without leaving Chat");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Model: GPT-5.6 Sol\"]'))");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Model: GPT-5.6 Sol\"]')?.click()");
  await window.webContents.executeJavaScript("document.querySelector('[aria-label=\"Composer model and effort\"]')?.click()");
  await waitFor("Boolean(document.querySelector('[aria-label=\"Reasoning effort: Ultra\"]'))");
  const reasoningProbe = await window.webContents.executeJavaScript(`(() => {
    const menu = document.querySelector('[aria-label="Composer model and effort menu"]').getBoundingClientRect();
    const options = [...document.querySelectorAll('[aria-label^="Reasoning effort:"]')].map((node) => {
      const rect = node.getBoundingClientRect();
      return { top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right };
    });
    return { menu: { top: menu.top, bottom: menu.bottom, left: menu.left, right: menu.right }, options };
  })()`);
  assert(reasoningProbe.options.length === 6 && reasoningProbe.options.every((rect) =>
    rect.top >= reasoningProbe.menu.top && rect.bottom <= reasoningProbe.menu.bottom
    && rect.left >= reasoningProbe.menu.left && rect.right <= reasoningProbe.menu.right),
  `all six reasoning choices stay visible below the scrollable model catalog (${JSON.stringify(reasoningProbe)})`);
  await capture("reasoning-options-contained.png");

  console.log(JSON.stringify({
    artifactRoot,
    actions: actions.map(({ type, sessionId, text, deliveryId }) => ({ type, sessionId, text, deliveryId })),
      files: ["light-empty.png", "light-model-menu.png", "light-permission-menu.png", "light-draft-image.png", "light-details.png", "light-canceling.png", "light-read-only.png", "light-narrow-model-menu.png", "light-narrow.png", "dark-model-menu.png", "dark-narrow.png", "dark-scaled.png", "missing-current-model.png", "reasoning-options-contained.png"],
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
    await waitFor(`Boolean(document.querySelector('#chat-timeline-${encodedSessionId}')) && Boolean(document.querySelector('[aria-label="Chat availability notice"]'))`);
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
      canvasBackground: getComputedStyle(document.getElementById('chat-canvas')).backgroundColor,
      surfaceBackground: style?.backgroundColor ?? "",
      outerWidth: outerRect?.width ?? 0, outerHeight: outerRect?.height ?? 0,
      borderWidth: style?.borderWidth ?? "", borderRadius: Number.parseFloat(style?.borderRadius ?? "0"),
      inputBorderWidth: inputStyle?.borderWidth ?? "", inputBackground: inputStyle?.backgroundColor ?? "",
      inputOutlineWidth: inputStyle?.outlineWidth ?? "", inputOutlineStyle: inputStyle?.outlineStyle ?? "",
      inputOutlineColor: inputStyle?.outlineColor ?? "", inputBoxShadow: inputStyle?.boxShadow ?? "",
      inputFocusVisible: input?.matches(':focus-visible') ?? false,
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
