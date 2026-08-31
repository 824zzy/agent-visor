import { z } from "zod";

export const PROTOCOL_VERSION = 1 as const;

// Native helper wire limits are shared with AgentVisorCore's
// NativeHelperWireLimits. Terminal input is measured in UTF-8 bytes (the
// helper ultimately writes bytes to a PTY), while the frame limit is the
// length-prefixed JSON payload, excluding its four-byte length prefix.
// ponytail: changing either bound requires updating the Swift constants and
// the preflight serializer before changing any helper transport allocation.
export const NATIVE_HELPER_MAX_TEXT_BYTES = 65_536;
export const NATIVE_HELPER_MAX_FRAME_BYTES = 1_048_576;

export const sessionSectionSchema = z.enum([
  "needs_you",
  "ready",
  "working",
  "history",
]);

export const sessionAttentionTierSchema = z.enum([
  "needs_you",
  "ready",
  "working",
  "acknowledged_ready",
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
  attentionTier: sessionAttentionTierSchema.optional(),
  updatedAt: z.iso.datetime(),
  canOpenOwner: z.boolean(),
  canEnterChat: z.boolean(),
});

export const sessionSnapshotSchema = z.object({
  type: z.literal("session_snapshot"),
  revision: z.number().int().nonnegative(),
  sessions: z.array(sessionSummarySchema),
});

export const CHAT_IMAGE_MAX_BYTES = 10_000_000;
// ponytail: if the image transport limit changes, update this policy and the
// renderer's visible validation copy together; do not expose arbitrary files.
export const CHAT_IMAGE_MAX_BASE64_CHARS = 4 * Math.ceil(CHAT_IMAGE_MAX_BYTES / 3);
// ponytail: if the decoded image cap changes, keep this derived bound coupled
// to it so callers reject oversized base64 before decoding.
export const CHAT_IMAGE_SUPPORTED_MIME_TYPES = [
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "image/tiff",
  "image/heic",
] as const;

export const chatImageSchema = z.object({
  name: z.string().min(1).max(512),
  mimeType: z.enum(["image/png", "image/jpeg", "image/gif", "image/webp", "image/tiff", "image/heic"]),
  data: z.string().max(CHAT_IMAGE_MAX_BASE64_CHARS).optional(),
  byteLength: z.number().finite().int().nonnegative().max(CHAT_IMAGE_MAX_BYTES).optional(),
}).strict();

export function chatImageBytesMatchMime(mimeType: string, bytes: Uint8Array): boolean {
  const at = (offset: number) => bytes[offset];
  const ascii = (offset: number, value: string) => value.split("").every((character, index) => (
    at(offset + index) === character.charCodeAt(0)
  ));
  if (mimeType === "image/png") {
    return bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].every((value, index) => at(index) === value);
  }
  if (mimeType === "image/jpeg") return bytes.length >= 3 && at(0) === 255 && at(1) === 216 && at(2) === 255;
  if (mimeType === "image/gif") return bytes.length >= 6 && (ascii(0, "GIF87a") || ascii(0, "GIF89a"));
  if (mimeType === "image/webp") return bytes.length >= 12 && ascii(0, "RIFF") && ascii(8, "WEBP");
  if (mimeType === "image/tiff") {
    return bytes.length >= 4
      && ((at(0) === 73 && at(1) === 73 && at(2) === 42 && at(3) === 0)
        || (at(0) === 77 && at(1) === 77 && at(2) === 0 && at(3) === 42));
  }
  if (mimeType === "image/heic") {
    return bytes.length >= 12 && ascii(4, "ftyp")
      && ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].some((brand) => ascii(8, brand));
  }
  return false;
}

export type ChatImageMimeType = (typeof CHAT_IMAGE_SUPPORTED_MIME_TYPES)[number];

/** Decode one canonical, bounded image payload before any consumer stores it. */
export function chatImageBase64Bytes(value: unknown): Uint8Array | undefined {
  if (typeof value !== "string"
    || !value
    || value.length > CHAT_IMAGE_MAX_BASE64_CHARS
    || value.length % 4 !== 0
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    return undefined;
  }
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  const decodedLength = value.length / 4 * 3 - padding;
  if (decodedLength <= 0 || decodedLength > CHAT_IMAGE_MAX_BYTES) return undefined;
  try {
    const binary = globalThis.atob(value);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    return undefined;
  }
}

export function chatImageMimeForBytes(bytes: Uint8Array): ChatImageMimeType | undefined {
  return CHAT_IMAGE_SUPPORTED_MIME_TYPES.find((mimeType) => chatImageBytesMatchMime(mimeType, bytes));
}

export const CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE = 10;
// ponytail: if the provider transport changes its attachment count, update
// this shared schema and the renderer validation policy together.
export const CHAT_IMAGE_MAX_TOTAL_BYTES = CHAT_IMAGE_MAX_BYTES * CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE;
export const CHAT_IMAGE_MAX_TOTAL_BASE64_CHARS = CHAT_IMAGE_MAX_BASE64_CHARS * CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE;
export const CHAT_SEND_MAX_TEXT_UTF16_UNITS = 1_000_000;
export const CHAT_SEND_MAX_JSON_BYTES_PER_UTF16_UNIT = 6;
// ponytail: if the send text ceiling changes, re-check JSON escaping and UTF-8
// expansion before changing this derived wire budget.
export const CHAT_SEND_MAX_TEXT_WIRE_BYTES = CHAT_SEND_MAX_TEXT_UTF16_UNITS
  * CHAT_SEND_MAX_JSON_BYTES_PER_UTF16_UNIT + 2;
const CHAT_SEND_MAX_ID_UTF16_UNITS = 128;
const CHAT_SEND_MAX_SESSION_ID_UTF16_UNITS = 512;
const CHAT_IMAGE_NAME_MAX_UTF16_UNITS = 512;
// This fixed allowance covers send JSON keys, punctuation, image MIME values,
// byteLength numbers, and their quotes. The variable strings are derived below.
const CHAT_SEND_FIXED_ENVELOPE_BYTES = 2_048;
// ponytail: if send envelope fields grow, replace this allowance with a new
// field-by-field bound before increasing the WebSocket parser limit.
export const CHAT_SEND_MAX_ENVELOPE_BYTES = CHAT_SEND_FIXED_ENVELOPE_BYTES
  + CHAT_SEND_MAX_JSON_BYTES_PER_UTF16_UNIT * (
    CHAT_SEND_MAX_ID_UTF16_UNITS
    + CHAT_SEND_MAX_SESSION_ID_UTF16_UNITS
    + CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE * CHAT_IMAGE_NAME_MAX_UTF16_UNITS
  );
// ponytail: if aggregate attachment volume or text reaches this derived bound,
// add a streamed/paged request protocol before raising the parser limit.
export const CHAT_SEND_MAX_WIRE_BYTES = CHAT_IMAGE_MAX_TOTAL_BASE64_CHARS
  + CHAT_SEND_MAX_TEXT_WIRE_BYTES
  + CHAT_SEND_MAX_ENVELOPE_BYTES;

export const CHAT_RESPONSE_MAX_ANSWER_KEYS = 100;
// Keep answer identifiers aligned with the question-id ceiling in the
// provider-neutral pending-action contract.
export const CHAT_RESPONSE_MAX_ANSWER_KEY_CHARS = 16_384;
export const CHAT_RESPONSE_MAX_ANSWER_SCALAR_CHARS = 16_384;
export const CHAT_RESPONSE_MAX_ANSWER_ARRAY_ITEMS = 100;
export const CHAT_RESPONSE_MAX_ANSWER_ITEM_CHARS = 4_096;
// ponytail: if answer payloads need more retained text, add a paged response
// protocol before increasing these parser and renderer memory bounds.
export const CHAT_RESPONSE_MAX_ANSWER_CHARS = 1_000_000;
// This is a worst-case JSON/UTF-8 retention bound: every UTF-16 unit can be
// represented by a six-byte escaped sequence (for example, a NUL).
export const CHAT_RESPONSE_MAX_ANSWER_BYTES = CHAT_RESPONSE_MAX_ANSWER_CHARS
  * CHAT_SEND_MAX_JSON_BYTES_PER_UTF16_UNIT;
// JSON punctuation and quotes are retained in addition to the escaped answer
// characters. This is derived from the maximum key and array-item counts.
const CHAT_RESPONSE_MAX_ANSWER_JSON_OVERHEAD_BYTES = 2
  + CHAT_RESPONSE_MAX_ANSWER_KEYS * (8 + CHAT_RESPONSE_MAX_ANSWER_ARRAY_ITEMS * 3);
const CHAT_RESPONSE_MAX_ID_UTF16_UNITS = 128;
const CHAT_RESPONSE_MAX_SESSION_ID_UTF16_UNITS = 512;
const CHAT_RESPONSE_MAX_TOOL_USE_ID_UTF16_UNITS = 512;
const CHAT_RESPONSE_MAX_REASON_UTF16_UNITS = 16_384;
const CHAT_RESPONSE_FIXED_ENVELOPE_BYTES = 2_048;
// ponytail: if response envelope fields grow, derive their bound here before
// increasing the global WebSocket parser limit.
export const CHAT_RESPONSE_MAX_ENVELOPE_BYTES = CHAT_RESPONSE_FIXED_ENVELOPE_BYTES
  + CHAT_SEND_MAX_JSON_BYTES_PER_UTF16_UNIT * (
    CHAT_RESPONSE_MAX_ID_UTF16_UNITS
    + CHAT_RESPONSE_MAX_SESSION_ID_UTF16_UNITS
    + CHAT_RESPONSE_MAX_TOOL_USE_ID_UTF16_UNITS
    + CHAT_RESPONSE_MAX_REASON_UTF16_UNITS
  );
// Keep the parser bound large enough for either direction of the protocol.
// ponytail: if either direction changes its hard caps, update both derived
// wire bounds and retain this max relationship.
export const CHAT_RESPONSE_MAX_WIRE_BYTES = CHAT_RESPONSE_MAX_ANSWER_BYTES
  + CHAT_RESPONSE_MAX_ANSWER_JSON_OVERHEAD_BYTES
  + CHAT_RESPONSE_MAX_ENVELOPE_BYTES;
export const CHAT_MAX_WIRE_BYTES = Math.max(CHAT_SEND_MAX_WIRE_BYTES, CHAT_RESPONSE_MAX_WIRE_BYTES);

export const CHAT_SLASH_COMMAND_MAX_RESULTS = 1_000;
// ponytail: if real installations exceed this catalog size, add a query/page
// protocol before raising this bound so the renderer stays responsive.

export const CHAT_SLASH_SOURCE_LABEL_MAX_CHARS = 512;
// ponytail: if source labels need more context, add structured source metadata
// before increasing this renderer-facing string bound.

// This is the provider-neutral projection of Swift's SlashCommand. File paths
// stay in the daemon; the renderer only receives data needed for completion.
export const chatSlashCommandSchema = z.object({
  name: z.string().min(1).max(512),
  aliases: z.array(z.string().min(1).max(512)).max(32),
  description: z.string().max(16_384),
  argumentHint: z.string().min(1).max(512).optional(),
  argNames: z.array(z.string().min(1).max(512)).max(32),
  source: z.enum(["builtin", "user", "project", "plugin"]),
  sourceLabel: z.string().min(1).max(CHAT_SLASH_SOURCE_LABEL_MAX_CHARS).optional(),
  isHidden: z.boolean(),
  opensInTerminalDialog: z.boolean(),
}).strict();

export const chatCommandsSchema = z.object({
  type: z.literal("chat_commands"),
  sessionId: z.string().min(1).max(512),
  commands: z.array(chatSlashCommandSchema).max(CHAT_SLASH_COMMAND_MAX_RESULTS),
  truncated: z.boolean(),
}).strict();

const chatTimestamp = z.iso.datetime().optional();
export const chatItemSchema = z.discriminatedUnion("kind", [
  z.object({
    id: z.string().min(1).max(512),
    kind: z.literal("user"),
    text: z.string().max(20_000_000),
    images: z.array(chatImageSchema).max(20),
    // Provider transcripts may carry the original request identity. These
    // fields stay absent when the provider does not persist them.
    requestId: z.string().min(1).max(128).optional(),
    deliveryId: z.string().min(1).max(128).optional(),
    providerMessageId: z.string().min(1).max(512).optional(),
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
    family: z.enum([
      "bash", "read", "write", "edit", "grep", "glob", "web_fetch", "web_search",
      "todo_write", "task", "ask_user_question", "bash_output", "kill_shell",
      "plan_mode", "mcp", "other",
    ]).optional(),
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
    category: z.enum([
      "interrupted", "turn_duration", "recap", "compact_boundary",
      "local_command_output", "other",
    ]).optional(),
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

export const defaultChatVisibility = {
  showUserMessage: true,
  showAssistantMessage: true,
  showThinking: true,
  showInterrupted: true,
  showTurnDuration: true,
  showRecap: true,
  showCompactBoundary: true,
  showLocalCommandOutput: true,
  showBash: true,
  showRead: true,
  showWrite: true,
  showEdit: true,
  showGrep: true,
  showGlob: true,
  showWebFetch: true,
  showWebSearch: true,
  showTodoWrite: true,
  showTask: true,
  showAskUserQuestion: true,
  showBashOutput: true,
  showKillShell: true,
  showPlanMode: true,
  showMCP: true,
  showOtherTools: true,
  collapseClaudeTurns: true,
  collapseCodexTurns: true,
  collapsePiTurns: true,
} as const;

export const chatVisibilitySchema = z.object(
  Object.fromEntries(Object.entries(defaultChatVisibility).map(([key, value]) => [
    key,
    z.boolean().default(value),
  ])) as { [K in keyof typeof defaultChatVisibility]: z.ZodDefault<z.ZodBoolean> },
).strict();

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
  chatVisibility: chatVisibilitySchema.default(defaultChatVisibility),
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

export const daemonErrorSchema = z.object({
  type: z.literal("daemon_error"),
  code: z.enum(["response_too_large", "invalid_response", "serialization_failed"]),
  message: z.string().min(1).max(512),
  responseType: z.string().min(1).max(64).optional(),
  requestType: z.string().min(1).max(64).optional(),
  requestId: z.string().min(1).max(128).optional(),
  sessionId: z.string().min(1).max(512).optional(),
}).strict();

export const chatCapabilitiesSchema = z.object({
  canSendText: z.boolean(),
  canSendImages: z.boolean(),
  /** True only when the daemon has verified a live provider control route. */
  canCancel: z.boolean(),
  /** The exact active delivery that the verified cancel route controls. */
  cancelDeliveryId: z.string().min(1).max(128).optional(),
  canApprove: z.boolean(),
  canAnswer: z.boolean(),
  /** True only when a verified Claude terminal can receive Shift+Tab. */
  canCyclePermissionMode: z.boolean().optional(),
  /** Provider-native terminal text ceiling, in UTF-8 bytes. */
  maxTextBytes: z.number().int().positive().max(NATIVE_HELPER_MAX_TEXT_BYTES).optional(),
  readOnlyReason: z.string().min(1).max(1_024).optional(),
}).strict();

export const chatPendingActionSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("approval"),
    toolUseId: z.string().min(1).max(512),
    // Provider request identity shown to the renderer. Older providers may
    // omit this because toolUseId is their stable approval identity.
    approvalId: z.string().min(1).max(512).optional(),
    responding: z.boolean().optional(),
    toolName: z.string().min(1).max(512),
    input: z.record(z.string(), z.unknown()),
    canPersist: z.boolean(),
  }).strict(),
  z.object({
    type: z.literal("question"),
    toolUseId: z.string().min(1).max(512),
    approvalId: z.string().min(1).max(512).optional(),
    responding: z.boolean().optional(),
    questions: z.array(z.object({
      id: z.string().min(1).max(16_384),
      question: z.string().min(1).max(16_384),
      choices: z.array(z.string().min(1).max(4_096)).max(100),
      multiple: z.boolean(),
    }).strict()).min(1).max(100),
  }).strict(),
]);

const chatAnswerValueSchema = z.union([
  z.string().max(CHAT_RESPONSE_MAX_ANSWER_SCALAR_CHARS),
  z.array(z.string().max(CHAT_RESPONSE_MAX_ANSWER_ITEM_CHARS)).max(CHAT_RESPONSE_MAX_ANSWER_ARRAY_ITEMS),
]);

export type ChatResponseAnswers = Record<string, string | string[]>;

export function chatResponseAnswerSizes(answers: ChatResponseAnswers): {
  chars: number;
  bytes: number;
} {
  let chars = 0;
  for (const [key, answer] of Object.entries(answers)) {
    chars += key.length;
    chars += Array.isArray(answer)
      ? answer.reduce((total, item) => total + item.length, 0)
      : answer.length;
  }
  return {
    chars,
    bytes: chars * CHAT_SEND_MAX_JSON_BYTES_PER_UTF16_UNIT,
  };
}

const chatResponseAnswersSchema = z.record(
  z.string().max(CHAT_RESPONSE_MAX_ANSWER_KEY_CHARS),
  chatAnswerValueSchema,
).superRefine((answers, context) => {
  if (Object.keys(answers).length > CHAT_RESPONSE_MAX_ANSWER_KEYS) {
    context.addIssue({
      code: "custom",
      message: `answers must contain at most ${CHAT_RESPONSE_MAX_ANSWER_KEYS} keys`,
    });
    return;
  }
  const sizes = chatResponseAnswerSizes(answers);
  if (sizes.chars > CHAT_RESPONSE_MAX_ANSWER_CHARS || sizes.bytes > CHAT_RESPONSE_MAX_ANSWER_BYTES) {
    context.addIssue({
      code: "custom",
      message: "answers exceed the retained response budget",
    });
  }
});

// ponytail: if the usage label cap increases, update the native-helper usage
// label contract and the status-bar layout tests together.
export const CHAT_USAGE_GLANCE_LABEL_MAX_CHARS = 128;
// ponytail: if the usage detail cap increases, update the native-helper usage
// detail contract and the accessible status announcement budget together.
export const CHAT_USAGE_GLANCE_DETAIL_MAX_CHARS = 512;
// ponytail: if the expected-mode cap increases, update the renderer/server
// action envelope budget and the native-helper action tests together.
export const CHAT_PERMISSION_MODE_EXPECTED_MAX_CHARS = 256;

export const chatUsageGlanceSchema = z.object({
  /** Provider identity prevents one provider's quota from being shown as another's. */
  provider: z.enum(["codex", "claude"]),
  percentUsed: z.number().finite().min(0).max(100),
  label: z.string().min(1).max(CHAT_USAGE_GLANCE_LABEL_MAX_CHARS),
  detail: z.string().min(1).max(CHAT_USAGE_GLANCE_DETAIL_MAX_CHARS),
  observedAt: z.iso.datetime(),
}).strict();

export const chatMetadataSchema = z.object({
  model: z.string().min(1).max(256).optional(),
  modelId: z.string().min(1).max(256).optional(),
  modelProvider: z.string().min(1).max(256).optional(),
  reasoningEffort: z.string().min(1).max(256).optional(),
  permissionMode: z.string().min(1).max(256).optional(),
  sandbox: z.string().min(1).max(256).optional(),
  approvalPolicy: z.string().min(1).max(256).optional(),
  contextTokens: z.number().int().positive().max(Number.MAX_SAFE_INTEGER).optional(),
  contextWindow: z.number().int().positive().max(Number.MAX_SAFE_INTEGER).optional(),
  /** Optional provider-authoritative usage. Omit when the provider cannot report it. */
  usageGlance: chatUsageGlanceSchema.optional(),
}).strict();

/** Authority carried with a transcript page used for delivery reconciliation. */
export const chatTranscriptEvidenceSchema = z.object({
  authoritative: z.boolean(),
  complete: z.boolean(),
  /** The newest provider timestamp observed in this page, when present. */
  sourceTimestamp: chatTimestamp,
}).strict();

export const chatPageSchema = z.object({
  type: z.literal("chat_page"),
  sessionId: z.string().min(1).max(512),
  /** Request identity/mode are attached by the daemon for out-of-order pages. */
  requestId: z.string().min(1).max(128).optional(),
  mode: z.enum(["latest", "earlier"]).optional(),
  items: z.array(chatItemSchema).max(1_000),
  hasMoreBefore: z.boolean(),
  nextBefore: z.number().int().nonnegative().optional(),
  metadata: chatMetadataSchema.optional(),
  transcriptEvidence: chatTranscriptEvidenceSchema.optional(),
  capabilities: chatCapabilitiesSchema,
  pendingAction: chatPendingActionSchema.nullable(),
  /** Multiple provider approvals may be pending in one session. */
  pendingActions: z.array(chatPendingActionSchema).max(32).optional(),
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
    // Kept optional for existing native clients; Electron always supplies it
    // so concurrent latest/earlier responses can be matched exactly.
    id: z.string().min(1).max(128).optional(),
    type: z.literal("open_chat"),
    sessionId: z.string().min(1).max(512),
    // The active renderer generation is carried on the authoritative latest
    // open so the daemon can reject arbitrary future send generations.
    generation: z.number().int().positive().max(2_147_483_647).optional(),
    before: z.number().int().nonnegative().optional(),
    limit: z.number().int().min(1).max(1_000).optional(),
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("get_chat_commands"),
    sessionId: z.string().min(1).max(512),
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("send_chat"),
    sessionId: z.string().min(1).max(512),
    generation: z.number().int().positive().max(2_147_483_647),
    deliveryId: z.string().min(1).max(128),
    text: z.string().max(1_000_000),
    images: z.array(chatImageSchema.required({ data: true, byteLength: true })).max(CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE),
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("cancel_chat"),
    sessionId: z.string().min(1).max(512),
    generation: z.number().int().positive().max(2_147_483_647),
    deliveryId: z.string().min(1).max(128).optional(),
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("respond_chat"),
    sessionId: z.string().min(1).max(512),
    toolUseId: z.string().min(1).max(512),
    /** Exact pending approval identity rendered in the action card. */
    approvalId: z.string().min(1).max(512).optional(),
    generation: z.number().int().positive().max(2_147_483_647).optional(),
    decision: z.enum(["allow", "allow_always", "deny", "answer"]),
    reason: z.string().max(16_384).optional(),
    answers: chatResponseAnswersSchema.optional(),
  }).strict(),
  z.object({
    ...requestEnvelope,
    type: z.literal("cycle_permission_mode"),
    sessionId: z.string().min(1).max(512),
    generation: z.number().int().positive().max(2_147_483_647),
    /** Raw mode observed by the renderer; the daemon rejects stale modes. */
    expectedMode: z.string().min(1).max(CHAT_PERMISSION_MODE_EXPECTED_MAX_CHARS),
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
  daemonErrorSchema,
  z.object({ type: z.literal("health"), status: z.literal("ok") }),
  sessionSnapshotSchema,
  chatPageSchema,
  chatCommandsSchema,
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
    action: z.enum(["send", "cancel", "respond", "cycle_permission_mode"]).optional(),
    sessionId: z.string().min(1).max(512).optional(),
    generation: z.number().int().positive().max(2_147_483_647).optional(),
    deliveryId: z.string().min(1).max(128).optional(),
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
  attentionTier: sessionAttentionTierSchema.optional(),
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
  /** Owning agent process identity; TTY names alone can be reused. */
  pid: z.number().int().positive().max(2_147_483_647).optional(),
  /** Helper-derived process-instance token; PID reuse must fail closed. */
  processStartToken: z.string().min(1).max(256).optional(),
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

const nativeHelperTerminalTextSchema = z.string()
  .max(NATIVE_HELPER_MAX_TEXT_BYTES)
  .superRefine((text, context) => {
    if (new TextEncoder().encode(text).byteLength > NATIVE_HELPER_MAX_TEXT_BYTES) {
      context.addIssue({
        code: "custom",
        message: `terminal text must be at most ${NATIVE_HELPER_MAX_TEXT_BYTES} UTF-8 bytes`,
      });
    }
  });

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
      text: nativeHelperTerminalTextSchema,
      submit: z.boolean(),
    }).strict(),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("cancel_terminal"),
    params: z.object({ target: nativeHelperTerminalTargetSchema }).strict(),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("cycle_permission_mode"),
    params: z.object({ target: nativeHelperTerminalTargetSchema }).strict(),
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
export type ChatUsageGlance = z.infer<typeof chatUsageGlanceSchema>;
export type ChatSlashCommand = z.infer<typeof chatSlashCommandSchema>;
export type ChatCommands = z.infer<typeof chatCommandsSchema>;
export type ChatImage = z.infer<typeof chatImageSchema>;
export type ChatItem = z.infer<typeof chatItemSchema>;
export type ChatMetadata = z.infer<typeof chatMetadataSchema>;
export type ChatPage = z.infer<typeof chatPageSchema>;
export type ChatPendingAction = z.infer<typeof chatPendingActionSchema>;
export type ChatVisibility = z.infer<typeof chatVisibilitySchema>;
export type ClientMessage = z.infer<typeof clientMessageSchema>;
export type DaemonError = z.infer<typeof daemonErrorSchema>;
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
export type SessionAttentionTier = z.infer<typeof sessionAttentionTierSchema>;
