import { z } from "zod";

export const PROTOCOL_VERSION = 1 as const;

export const sessionSectionSchema = z.enum([
  "needs_you",
  "ready",
  "working",
  "history",
]);

export const sessionSummarySchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  subtitle: z.string(),
  source: z.string().min(1),
  project: z.string().min(1),
  owner: z.string().min(1),
  cwd: z.string().min(1),
  section: sessionSectionSchema,
  updatedAt: z.iso.datetime(),
  canOpenOwner: z.boolean(),
  canEnterChat: z.boolean(),
});

export const sessionSnapshotSchema = z.object({
  type: z.literal("session_snapshot"),
  revision: z.number().int().nonnegative(),
  sessions: z.array(sessionSummarySchema),
});

export const chatImageSchema = z.object({
  name: z.string().min(1).max(512),
  mimeType: z.enum(["image/png", "image/jpeg", "image/gif", "image/webp"]),
  data: z.string().max(20_000_000).optional(),
}).strict();

const chatTimestamp = z.iso.datetime().optional();
export const chatItemSchema = z.discriminatedUnion("kind", [
  z.object({
    id: z.string().min(1).max(512),
    kind: z.literal("user"),
    text: z.string().max(20_000_000),
    images: z.array(chatImageSchema).max(20),
    timestamp: chatTimestamp,
  }).strict(),
  z.object({
    id: z.string().min(1).max(512),
    kind: z.literal("assistant"),
    text: z.string().min(1).max(20_000_000),
    timestamp: chatTimestamp,
  }).strict(),
  z.object({
    id: z.string().min(1).max(512),
    kind: z.literal("thinking"),
    text: z.string().min(1).max(20_000_000),
    timestamp: chatTimestamp,
  }).strict(),
  z.object({
    id: z.string().min(1).max(512),
    kind: z.literal("tool"),
    name: z.string().min(1).max(512),
    input: z.record(z.string(), z.unknown()),
    status: z.enum(["running", "waiting", "success", "error", "interrupted"]),
    result: z.string().max(20_000_000).optional(),
    timestamp: chatTimestamp,
  }).strict(),
  z.object({
    id: z.string().min(1).max(512),
    kind: z.literal("system"),
    text: z.string().min(1).max(20_000_000),
    tone: z.enum(["neutral", "error", "compact"]),
    timestamp: chatTimestamp,
  }).strict(),
]);

const macFunctionKeyCodes = new Set([
  122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
  103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
]);

const customHotkeyComboSchema = z.string()
  .regex(/^\d{1,5}:\d{1,2}$/)
  .max(8)
  .refine((value) => {
    const parts = value.split(":").map(Number);
    const keyCode = parts[0]!;
    const modifiers = parts[1]!;
    return keyCode <= 65_535 && modifiers <= 15
      && (modifiers > 0 || macFunctionKeyCodes.has(keyCode));
  });

export const pillScreenSchema = z.discriminatedUnion("mode", [
  z.object({ mode: z.literal("automatic") }).strict(),
  z.object({
    mode: z.literal("specific"),
    displayId: z.number().int().nonnegative().max(4_294_967_295),
    name: z.string().min(1).max(128),
  }).strict(),
]);

export const appSettingsSchema = z.object({
  appearance: z.enum(["system", "dark", "light"]),
  contentScale: z.number().min(0.8).max(2.5),
  pillsEnabled: z.boolean(),
  pillScreen: pillScreenSchema,
  fullScreenPolicy: z.enum(["onDemand", "alwaysHide", "alwaysShow"]),
  codexUsageGlanceEnabled: z.boolean(),
  claudeUsageGlanceEnabled: z.boolean(),
  notificationSound: z.enum([
    "None", "Pop", "Ping", "Tink", "Glass", "Blow", "Bottle", "Frog",
    "Funk", "Hero", "Morse", "Purr", "Sosumi", "Submarine", "Basso",
  ]),
  hotkeyTrigger: z.enum(["off", "cmd", "ctrl", "option", "shift", "custom"]),
  customHotkeyCombo: customHotkeyComboSchema.nullable(),
  sessionShortcutModifierFamily: z.enum([
    "off", "controlCommand", "optionCommand", "controlOptionCommand",
  ]),
  editorPreference: z.enum([
    "auto", "cursor", "vscode", "vscode-insiders", "zed", "xcode", "system-default",
  ]),
  observedWindowHours: z.number().int().min(1).max(168),
  launchAtLogin: z.boolean(),
}).strict();

export const appSettingsPatchSchema = appSettingsSchema.partial().strict();

export const pillScreenOptionSchema = z.object({
  displayId: z.number().int().nonnegative().max(4_294_967_295),
  name: z.string().min(1).max(128),
  isBuiltIn: z.boolean(),
  isMain: z.boolean(),
}).strict();

export const agentConnectionSchema = z.object({
  id: z.enum(["claude", "auggie", "codex", "cursor", "pi"]),
  name: z.string().min(1).max(64),
  available: z.boolean(),
  installed: z.boolean(),
  control: z.enum(["toggle", "automatic", "read_only"]),
}).strict();

export const nativeServicesStateSchema = z.object({
  type: z.literal("native_services_state"),
  revision: z.number().int().nonnegative(),
  settings: appSettingsSchema,
  permissions: z.object({
    accessibility: z.enum(["granted", "needed"]),
    notifications: z.enum(["not_determined", "denied", "authorized"]),
  }).strict(),
  agents: z.array(agentConnectionSchema).max(5),
  pillScreens: z.array(pillScreenOptionSchema).max(16),
  update: z.object({
    status: z.enum(["idle", "checking", "up_to_date", "available", "error"]),
    currentVersion: z.string().min(1).max(64),
    availableVersion: z.string().min(1).max(64).optional(),
    releaseUrl: z.url().optional(),
    error: z.string().min(1).max(1_024).optional(),
  }).strict(),
}).strict();

export const chatCapabilitiesSchema = z.object({
  canSendText: z.boolean(),
  canSendImages: z.boolean(),
  canApprove: z.boolean(),
  canAnswer: z.boolean(),
  readOnlyReason: z.string().min(1).max(1_024).optional(),
}).strict();

export const chatPendingActionSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("approval"),
    toolUseId: z.string().min(1).max(512),
    toolName: z.string().min(1).max(512),
    input: z.record(z.string(), z.unknown()),
    canPersist: z.boolean(),
  }).strict(),
  z.object({
    type: z.literal("question"),
    toolUseId: z.string().min(1).max(512),
    questions: z.array(z.object({
      id: z.string().min(1).max(16_384),
      question: z.string().min(1).max(16_384),
      choices: z.array(z.string().min(1).max(4_096)).max(100),
      multiple: z.boolean(),
    }).strict()).min(1).max(100),
  }).strict(),
]);

export const chatPageSchema = z.object({
  type: z.literal("chat_page"),
  sessionId: z.string().min(1).max(512),
  items: z.array(chatItemSchema).max(1_000),
  hasMoreBefore: z.boolean(),
  nextBefore: z.number().int().nonnegative().optional(),
  capabilities: chatCapabilitiesSchema,
  pendingAction: chatPendingActionSchema.nullable(),
}).strict();

const requestEnvelope = { id: z.string().min(1).max(128) };
export const clientMessageSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("health") }).strict(),
  z.object({ type: z.literal("subscribe_sessions") }).strict(),
  z.object({ type: z.literal("get_native_services") }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("focus_session"),
    sessionId: z.string().min(1).max(512),
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("update_settings"),
    patch: appSettingsPatchSchema,
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("native_service_action"),
    action: z.enum([
      "request_accessibility", "open_accessibility_settings",
      "request_notifications", "check_updates", "open_update",
    ]),
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("set_agent_connection"),
    agent: z.enum(["claude", "auggie", "codex"]),
    enabled: z.boolean(),
  }).strict(),
  z.object({
    type: z.literal("open_chat"),
    sessionId: z.string().min(1).max(512),
    before: z.number().int().nonnegative().optional(),
    limit: z.number().int().min(1).max(1_000).optional(),
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("send_chat"),
    sessionId: z.string().min(1).max(512),
    text: z.string().max(1_000_000),
    images: z.array(chatImageSchema.required({ data: true })).max(10),
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("respond_chat"),
    sessionId: z.string().min(1).max(512),
    toolUseId: z.string().min(1).max(512),
    decision: z.enum(["allow", "allow_always", "deny", "answer"]),
    reason: z.string().max(16_384).optional(),
    answers: z.record(z.string(), z.union([z.string(), z.array(z.string())])).optional(),
  }).strict(),
]);

export const hookEventSchema = z.object({
  session_id: z.string().min(1).max(256),
  cwd: z.string().min(1).max(4_096),
  event: z.string().min(1).max(128),
  status: z.string().max(128),
  pid: z.number().int().positive().optional(),
  tty: z.string().max(256).nullable().optional(),
  session_file: z.string().max(4_096).optional(),
  tool: z.string().max(256).optional(),
  tool_input: z.record(z.string(), z.unknown()).optional(),
  tool_use_id: z.string().max(256).optional(),
  notification_type: z.string().max(256).optional(),
  message: z.string().max(16_384).optional(),
  agent: z.enum(["claude", "auggie", "codex", "cursor", "pi"]).optional(),
  permission_suggestions: z.array(z.unknown()).optional(),
  is_idle: z.boolean().optional(),
});

export const serverMessageSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("hello"),
    protocolVersion: z.literal(PROTOCOL_VERSION),
  }),
  z.object({ type: z.literal("health"), status: z.literal("ok") }),
  sessionSnapshotSchema,
  chatPageSchema,
  nativeServicesStateSchema,
  z.object({
    type: z.literal("native_action_result"),
    id: z.string().min(1).max(128),
    ok: z.boolean(),
    error: z.string().min(1).max(1_024).optional(),
  }).strict(),
  z.object({
    type: z.literal("chat_action_result"),
    id: z.string().min(1).max(128),
    ok: z.boolean(),
    error: z.string().min(1).max(1_024).optional(),
  }).strict(),
]);

const helperEnvelope = {
  version: z.literal(PROTOCOL_VERSION),
  id: z.string().min(1).max(128),
};

const rectangleSchema = z.object({
  x: z.number().finite(),
  y: z.number().finite(),
  width: z.number().finite().nonnegative(),
  height: z.number().finite().nonnegative(),
}).strict();

const nativeHelperSessionInspectorSchema = z.object({
  status: z.string().min(1).max(64),
  runtimeItems: z.array(z.string().min(1).max(256)).min(1).max(4),
  detailRows: z.array(z.object({
    label: z.string().min(1).max(64),
    value: z.string().min(1).max(512),
  }).strict()).max(8),
  projectPath: z.string().min(1).max(4_096),
  activityAt: z.iso.datetime(),
  context: z.object({
    usedLabel: z.string().min(1).max(64),
    windowLabel: z.string().min(1).max(64),
    percentage: z.number().int().min(0).max(100),
  }).strict().optional(),
}).strict();

export const nativeHelperPillSchema = z.object({
  id: z.string().min(1).max(128),
  title: z.string().min(1).max(256),
  subtitle: z.string().max(512).optional(),
  source: z.string().min(1).max(128).optional(),
  project: z.string().min(1).max(256).optional(),
  owner: z.string().min(1).max(128).optional(),
  inspector: nativeHelperSessionInspectorSchema.optional(),
  phase: sessionSectionSchema,
  priority: z.number().int(),
  accessibilityLabel: z.string().min(1).max(512),
}).strict();

export const nativeHelperUsageGlanceSchema = z.object({
  id: z.enum(["codex", "claude"]),
  heading: z.string().min(1).max(64).optional(),
  width: z.number().finite().min(28).max(200).optional(),
  label: z.string().min(1).max(128),
  detail: z.string().min(1).max(512),
  tone: z.enum(["normal", "warning", "critical"]),
  priority: z.number().int(),
  accessibilityLabel: z.string().min(1).max(512),
  observedAt: z.iso.datetime().optional(),
  windows: z.array(z.object({
    title: z.string().min(1).max(64),
    remainingPercent: z.number().int().min(0).max(100),
    tone: z.enum(["normal", "warning", "critical"]).optional(),
    resetsAt: z.iso.datetime().optional(),
  }).strict()).max(2).optional(),
  resetCreditsAvailable: z.number().int().nonnegative().max(1_000_000).optional(),
  stale: z.boolean().optional(),
}).strict();

export const nativeHelperFocusTargetSchema = z.object({
  pid: z.number().int().positive().max(2_147_483_647),
  bundleIdentifier: z.string().min(1).max(255),
  windowId: z.number().int().nonnegative().max(4_294_967_295).optional(),
}).strict();

export const nativeHelperTerminalTargetSchema = z.object({
  application: z.enum(["Ghostty", "iTerm2", "Terminal"]),
  tty: z.string().regex(/^(?:\/dev\/)?ttys\d+$/).max(32),
  cwd: z.string().startsWith("/").max(4_096),
}).strict();

export const nativeHelperNotificationPermissionSchema = z.enum([
  "not_determined", "denied", "authorized",
]);

export const nativeHelperNotificationSchema = z.object({
  id: z.string().min(1).max(128),
  sessionId: z.string().min(1).max(512),
  title: z.string().min(1).max(256),
  subtitle: z.string().min(1).max(512).optional(),
  body: z.string().max(4_096),
  toolUseId: z.string().min(1).max(512).optional(),
  sound: appSettingsSchema.shape.notificationSound,
}).strict();

export const nativeHelperPiRestorationCandidateSchema = z.object({
  sessionId: z.string().min(1).max(512),
  sessionFile: z.string().startsWith("/").max(4_096),
  cwd: z.string().startsWith("/").max(4_096),
  sessionName: z.string().min(1).max(256).optional(),
  pid: z.number().int().positive().max(2_147_483_647),
  tty: z.string().regex(/^(?:\/dev\/)?ttys\d+$/).max(32),
}).strict();

const piRestorationSessionIdSchema = z.string().min(1).max(512);
export const nativeHelperPiRestorationUpdateSchema = z.object({
  candidates: z.array(nativeHelperPiRestorationCandidateSchema).max(64),
  liveSessionIds: z.array(piRestorationSessionIdSchema).max(64),
  removeCandidateSessionIds: z.array(piRestorationSessionIdSchema).max(64),
  cleanTermination: z.boolean(),
}).strict();

export const nativeHelperRequestSchema = z.discriminatedUnion("method", [
  z.object({
    ...helperEnvelope,
    method: z.literal("screen_topology"),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("accessibility_status"),
  }).strict(),
  z.object({ ...helperEnvelope, method: z.literal("request_accessibility") }).strict(),
  z.object({ ...helperEnvelope, method: z.literal("notification_status") }).strict(),
  z.object({ ...helperEnvelope, method: z.literal("request_notifications") }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("reconcile_notifications"),
    params: z.object({
      notifications: z.array(nativeHelperNotificationSchema).max(128),
      presentNew: z.boolean(),
    }).strict(),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("reconcile_pi_restoration"),
    params: nativeHelperPiRestorationUpdateSchema,
  }).strict(),
  z.object({ ...helperEnvelope, method: z.literal("open_accessibility_settings") }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("present_pills"),
    params: z.object({
      pills: z.array(nativeHelperPillSchema).max(64),
      navigatorPills: z.array(nativeHelperPillSchema).max(512).optional(),
      usageGlances: z.array(nativeHelperUsageGlanceSchema).max(8).optional(),
      shortcutModifierFamily: appSettingsSchema.shape.sessionShortcutModifierFamily.optional(),
      pillScreen: pillScreenSchema.optional(),
      fullScreenPolicy: appSettingsSchema.shape.fullScreenPolicy.optional(),
      hotkeyTrigger: appSettingsSchema.shape.hotkeyTrigger.optional(),
      customHotkeyCombo: appSettingsSchema.shape.customHotkeyCombo.optional(),
    }).strict(),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("focus"),
    params: z.object({ target: nativeHelperFocusTargetSchema }).strict(),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("focus_terminal"),
    params: z.object({ target: nativeHelperTerminalTargetSchema }).strict(),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("send_terminal"),
    params: z.object({
      target: nativeHelperTerminalTargetSchema,
      text: z.string().max(65_536),
      submit: z.boolean(),
    }).strict(),
  }).strict(),
]);

export const nativeHelperScreenSchema = z.object({
  displayId: z.number().int().nonnegative().max(4_294_967_295),
  name: z.string().min(1).max(128),
  isBuiltIn: z.boolean(),
  frame: rectangleSchema,
  visibleFrame: rectangleSchema,
  scale: z.number().finite().positive(),
  isMain: z.boolean(),
}).strict();

const nativeHelperResultSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("screen_topology"),
    screens: z.array(nativeHelperScreenSchema),
  }).strict(),
  z.object({
    type: z.literal("accessibility_status"),
    trusted: z.boolean(),
  }).strict(),
  z.object({
    type: z.literal("notification_status"),
    status: nativeHelperNotificationPermissionSchema,
  }).strict(),
  z.object({
    type: z.literal("accepted"),
  }).strict(),
]);

const nativeHelperResponseEnvelopeSchema = z.discriminatedUnion("ok", [
  z.object({
    ...helperEnvelope,
    ok: z.literal(true),
    result: nativeHelperResultSchema,
  }).strict(),
  z.object({
    ...helperEnvelope,
    ok: z.literal(false),
    error: z.object({
      code: z.enum(["invalid_request", "unsupported", "failed"]),
      message: z.string().min(1).max(512),
    }).strict(),
  }).strict(),
]);

export const nativeHelperResponseSchema = z.union([
  nativeHelperResponseEnvelopeSchema,
  z.union([
    z.object({
      version: z.literal(PROTOCOL_VERSION),
      type: z.literal("event"),
      event: z.literal("activate_pill"),
      sessionId: z.string().min(1).max(128),
      intent: z.enum(["standard", "chat"]).optional(),
    }).strict(),
    z.object({
      version: z.literal(PROTOCOL_VERSION),
      type: z.literal("event"),
      event: z.enum(["open_sessions", "toggle_sessions", "open_settings", "refresh_usage"]),
    }).strict(),
    z.object({
      version: z.literal(PROTOCOL_VERSION),
      type: z.literal("event"),
      event: z.literal("notification_permission"),
      status: nativeHelperNotificationPermissionSchema,
    }).strict(),
    z.object({
      version: z.literal(PROTOCOL_VERSION),
      type: z.literal("event"),
      event: z.literal("notification_action"),
      action: z.literal("activate"),
      sessionId: z.string().min(1).max(512),
    }).strict(),
    z.object({
      version: z.literal(PROTOCOL_VERSION),
      type: z.literal("event"),
      event: z.literal("notification_action"),
      action: z.enum(["approve", "deny"]),
      sessionId: z.string().min(1).max(512),
      toolUseId: z.string().min(1).max(512),
    }).strict(),
  ]),
]);

export type AgentConnection = z.infer<typeof agentConnectionSchema>;
export type AppSettings = z.infer<typeof appSettingsSchema>;
export type AppSettingsPatch = z.infer<typeof appSettingsPatchSchema>;
export type ChatCapabilities = z.infer<typeof chatCapabilitiesSchema>;
export type ChatImage = z.infer<typeof chatImageSchema>;
export type ChatItem = z.infer<typeof chatItemSchema>;
export type ChatPage = z.infer<typeof chatPageSchema>;
export type ChatPendingAction = z.infer<typeof chatPendingActionSchema>;
export type ClientMessage = z.infer<typeof clientMessageSchema>;
export type HookEvent = z.infer<typeof hookEventSchema>;
export type NativeHelperFocusTarget = z.infer<typeof nativeHelperFocusTargetSchema>;
export type NativeHelperNotificationPermission = z.infer<
  typeof nativeHelperNotificationPermissionSchema
>;
export type NativeHelperNotification = z.infer<typeof nativeHelperNotificationSchema>;
export type NativeHelperPiRestorationCandidate = z.infer<
  typeof nativeHelperPiRestorationCandidateSchema
>;
export type NativeHelperPiRestorationUpdate = z.infer<
  typeof nativeHelperPiRestorationUpdateSchema
>;
export type NativeHelperTerminalTarget = z.infer<typeof nativeHelperTerminalTargetSchema>;
export type NativeServicesState = z.infer<typeof nativeServicesStateSchema>;
export type NativeHelperPill = z.infer<typeof nativeHelperPillSchema>;
export type NativeHelperUsageGlance = z.infer<typeof nativeHelperUsageGlanceSchema>;
export type NativeHelperRequest = z.infer<typeof nativeHelperRequestSchema>;
export type NativeHelperResponse = z.infer<typeof nativeHelperResponseSchema>;
export type NativeHelperScreen = z.infer<typeof nativeHelperScreenSchema>;
export type ServerMessage = z.infer<typeof serverMessageSchema>;
export type SessionSection = z.infer<typeof sessionSectionSchema>;
export type SessionSnapshot = z.infer<typeof sessionSnapshotSchema>;
export type SessionSummary = z.infer<typeof sessionSummarySchema>;
