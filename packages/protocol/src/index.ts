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

export const appSettingsSchema = z.object({
  appearance: z.enum(["system", "dark", "light"]),
  contentScale: z.number().min(0.8).max(2.5),
  pillsEnabled: z.boolean(),
  codexUsageGlanceEnabled: z.boolean(),
  claudeUsageGlanceEnabled: z.boolean(),
  notificationSound: z.enum([
    "None", "Pop", "Ping", "Tink", "Glass", "Blow", "Bottle", "Frog",
    "Funk", "Hero", "Morse", "Purr", "Sosumi", "Submarine", "Basso",
  ]),
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

export const nativeServicesStateSchema = z.object({
  type: z.literal("native_services_state"),
  revision: z.number().int().nonnegative(),
  settings: appSettingsSchema,
  permissions: z.object({
    accessibility: z.enum(["granted", "needed"]),
    notifications: z.enum(["not_determined", "denied", "authorized"]),
  }).strict(),
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

export const nativeHelperPillSchema = z.object({
  id: z.string().min(1).max(128),
  title: z.string().min(1).max(256),
  subtitle: z.string().max(512).optional(),
  source: z.string().min(1).max(128).optional(),
  project: z.string().min(1).max(256).optional(),
  owner: z.string().min(1).max(128).optional(),
  phase: sessionSectionSchema,
  priority: z.number().int(),
  accessibilityLabel: z.string().min(1).max(512),
}).strict();

export const nativeHelperUsageGlanceSchema = z.object({
  id: z.enum(["codex", "claude"]),
  label: z.string().min(1).max(128),
  detail: z.string().min(1).max(512),
  tone: z.enum(["normal", "warning", "critical"]),
  priority: z.number().int(),
  accessibilityLabel: z.string().min(1).max(512),
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
  z.object({ ...helperEnvelope, method: z.literal("open_accessibility_settings") }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("present_pills"),
    params: z.object({
      pills: z.array(nativeHelperPillSchema).max(64),
      usageGlances: z.array(nativeHelperUsageGlanceSchema).max(8).optional(),
      shortcutModifierFamily: appSettingsSchema.shape.sessionShortcutModifierFamily.optional(),
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
  z.discriminatedUnion("event", [
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
      event: z.literal("open_sessions"),
    }).strict(),
  ]),
]);

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
