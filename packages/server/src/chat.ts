import { open, stat } from "node:fs/promises";
import {
  CHAT_IMAGE_MAX_BASE64_CHARS,
  CHAT_IMAGE_SUPPORTED_MIME_TYPES,
  NATIVE_HELPER_MAX_TEXT_BYTES,
  chatImageBase64Bytes,
  chatImageMimeForBytes,
  type ChatCapabilities,
  type ChatImage,
  type ChatItem,
  type ChatMetadata,
  type ChatPage,
} from "@agent-visor/protocol";
import { summaryWork } from "./machine.js";
import type { DiscoveredProviderSession, ProviderID } from "./sessions.js";
import { isVerifiableProcessInstanceToken } from "./providers/shared.js";

const pageChunkBytes = 256 * 1_024;
const maxPageBytes = 16 * 1_024 * 1_024;

export async function readChatPage(
  session: DiscoveredProviderSession,
  before?: number,
  limit = 500,
): Promise<ChatPage> {
  const path = session.chatPath;
  if (!path) return emptyPage(session, "No supported conversation record is available.");
  const fileSize = await summaryWork.run(async () => {
    try { return (await stat(path)).size; } catch { return 0; }
  });
  if (!fileSize) return emptyPage(session, "No conversation content is available.");
  const end = Math.min(before ?? fileSize, fileSize);
  const page = await readLinesBackward(
    path,
    end,
    fileSize,
    session.provider,
    limit,
    before === undefined,
    session.modelCatalog,
  );
  return {
    type: "chat_page",
    sessionId: session.id,
    items: page.items,
    hasMoreBefore: page.start > 0,
    nextBefore: page.start > 0 ? page.start : undefined,
    ...(page.metadata ? { metadata: page.metadata } : {}),
    transcriptEvidence: {
      // An empty page can be a missing/unloaded or partially written source;
      // callers must not use it for content-only delivery reconciliation.
      authoritative: page.items.some((item) => item.kind === "user")
        && page.parseErrors === 0
        && page.start === 0,
      complete: page.start === 0,
      ...(latestTimestamp(page.items) ? { sourceTimestamp: latestTimestamp(page.items) } : {}),
    },
    capabilities: chatCapabilities(session),
    pendingAction: null,
  };
}

export function chatCapabilities(session: DiscoveredProviderSession): ChatCapabilities {
  if (session.sessionClass === "automation") {
    return {
      canSendText: false,
      canSendImages: false,
      canCancel: false,
      canApprove: false,
      canAnswer: false,
      readOnlyReason: "Automation sessions are read only.",
    };
  }
  if (session.section === "history") {
    return {
      canSendText: false,
      canSendImages: false,
      canCancel: false,
      canApprove: false,
      canAnswer: false,
      readOnlyReason: "This session has ended. Chat history is read only.",
    };
  }
  const terminalTransport = session.messageTransport === "terminal"
    && (session.provider === "claude_code" || session.provider === "pi")
    && session.controlTarget?.kind === "terminal";
  const verifiedTerminalTransport = terminalTransport
    && session.controlTarget?.kind === "terminal"
    && isVerifiableProcessInstanceToken(
      session.controlTarget.target.pid,
      session.controlTarget.target.processStartToken,
    );
  const codexTransport = session.messageTransport === "codex_app_server"
    && session.provider === "codex";
  if (session.section === "working" && (verifiedTerminalTransport || codexTransport)) {
    return {
      canSendText: true,
      canSendImages: (session.provider === "claude_code"
        && session.controlTarget?.kind === "terminal"
        && session.controlTarget.target.application !== "Terminal")
        || session.provider === "pi"
        || session.messageTransport === "codex_app_server",
      canCancel: session.section === "working"
        && ((session.messageTransport === "codex_app_server" && session.provider === "codex")
          || (session.messageTransport === "terminal"
            && session.controlTarget?.kind === "terminal"
            && (session.provider === "claude_code" || session.provider === "pi"))),
      canApprove: false,
      canAnswer: false,
      ...(session.provider === "claude_code" && verifiedTerminalTransport
        ? { canCyclePermissionMode: true } : {}),
      ...(verifiedTerminalTransport ? { maxTextBytes: NATIVE_HELPER_MAX_TEXT_BYTES } : {}),
    };
  }
  const readOnlyReason = terminalTransport && !verifiedTerminalTransport
    ? "The terminal process identity is unavailable. Chat is read only until it can be verified."
    : session.owner === "Zed"
    ? "Continue in Zed. Zed-hosted Chat is read only."
    : session.provider === "cursor"
      ? "Continue in Cursor. Cursor Chat is read only."
      : !session.canOpenOwner
        ? "Chat history is read only."
        : session.section !== "working"
          ? "This session is not actively receiving messages."
        : "Continue in the source app while native message transport is unavailable.";
  return {
    canSendText: false,
    canSendImages: false,
    canCancel: false,
    canApprove: false,
    canAnswer: false,
    readOnlyReason,
  };
}

async function readLinesBackward(
  path: string,
  end: number,
  fileSize: number,
  provider: ProviderID,
  limit: number,
  includeMetadata: boolean,
  modelCatalog?: ChatModelCatalog,
): Promise<{ items: ChatItem[]; start: number; parseErrors: number; metadata?: ChatMetadata }> {
  return summaryWork.run(async () => {
    const file = await open(path, "r");
    try {
      let start = end;
      let buffer = Buffer.alloc(0);
      let lines: Array<{ text: string; start: number }> = [];
      let items: ChatItem[] = [];
      let parseErrors = 0;
      while (start > 0 && end - start < maxPageBytes
        && (items.length < limit || items[0]?.kind !== "user")) {
        const nextStart = Math.max(0, start - pageChunkBytes);
        const chunk = Buffer.alloc(start - nextStart);
        await file.read(chunk, 0, chunk.length, nextStart);
        buffer = Buffer.concat([chunk, buffer]);
        start = nextStart;
        lines = completeLines(buffer, start, end < fileSize);
        items = parseChatLines(provider, lines.map((line) => line.text));
      }

      let selectedLine = lines.length;
      let itemCount = 0;
      while (selectedLine > 0 && itemCount < limit) {
        selectedLine -= 1;
        itemCount += parseChatLines(provider, [lines[selectedLine]!.text]).length;
      }
      while (selectedLine > 0
        && !parseChatLines(provider, [lines[selectedLine]!.text]).some((item) => item.kind === "user")) {
        selectedLine -= 1;
      }
      const metadata = includeMetadata
        ? parseChatMetadata(provider, lines.map((line) => line.text), modelCatalog)
        : undefined;
      const parsed = parseChatLinesDetailed(provider, lines.slice(selectedLine).map((line) => line.text));
      items = parsed.items.slice(-1_000);
      parseErrors = parsed.parseErrors;
      return {
        items,
        start: lines[selectedLine]?.start ?? 0,
        parseErrors,
        ...(metadata && Object.keys(metadata).length ? { metadata } : {}),
      };
    } finally {
      await file.close();
    }
  });
}

function completeLines(buffer: Buffer, absoluteStart: number, endsBeforeEOF: boolean): Array<{ text: string; start: number }> {
  const results: Array<{ text: string; start: number }> = [];
  let lineStart = 0;
  for (let index = 0; index < buffer.length; index += 1) {
    if (buffer[index] !== 0x0a) continue;
    if (absoluteStart === 0 || lineStart > 0) {
      results.push({ text: buffer.subarray(lineStart, index).toString("utf8"), start: absoluteStart + lineStart });
    }
    lineStart = index + 1;
  }
  if (!endsBeforeEOF && lineStart < buffer.length && (absoluteStart === 0 || lineStart > 0)) {
    results.push({ text: buffer.subarray(lineStart).toString("utf8"), start: absoluteStart + lineStart });
  }
  return results;
}

function emptyPage(session: DiscoveredProviderSession, readOnlyReason: string): ChatPage {
  return {
    type: "chat_page",
    sessionId: session.id,
    items: [],
    hasMoreBefore: false,
    transcriptEvidence: { authoritative: false, complete: false },
    capabilities: { ...chatCapabilities(session), readOnlyReason },
    pendingAction: null,
  };
}

function latestTimestamp(items: ChatItem[]): string | undefined {
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const timestamp = items[index]?.timestamp;
    if (timestamp) return timestamp;
  }
  return undefined;
}

export function parseChatLines(provider: ProviderID, lines: string[]): ChatItem[] {
  return parseChatLinesDetailed(provider, lines).items;
}

export function parseChatLinesDetailed(
  provider: ProviderID,
  lines: string[],
): { items: ChatItem[]; parseErrors: number } {
  const items: ChatItem[] = [];
  const tools = new Map<string, number>();
  let parseErrors = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    let value: unknown;
    try { value = JSON.parse(lines[lineIndex]!); } catch { parseErrors += 1; continue; }
    if (!record(value)) continue;
    if (provider === "claude_code") parseClaude(value, lineIndex, items, tools);
    if (provider === "codex") parseCodex(value, lineIndex, items, tools);
    if (provider === "pi") parsePi(value, lineIndex, items, tools);
    if (provider === "cursor") parseCursor(value, lineIndex, items, tools);
  }
  return {
    items: items.filter((item) => item.kind !== "user" || item.text.length > 0 || item.images.length > 0),
    parseErrors,
  };
}

export type ChatModelCatalog = Record<string, {
  displayName: string;
  contextWindow?: number;
}>;

export function parseChatMetadata(
  provider: ProviderID,
  lines: string[],
  catalog: ChatModelCatalog = {},
) {
  let modelId: string | undefined;
  let modelProvider: string | undefined;
  let reasoningEffort: string | undefined;
  let permissionMode: string | undefined;
  let sandbox: string | undefined;
  let approvalPolicy: string | undefined;
  let contextTokens: number | undefined;
  let contextWindow: number | undefined;
  const setModel = (value: unknown, providerValue?: unknown) => {
    const next = boundedModel(value);
    if (next && next !== modelId) {
      modelId = next;
      contextTokens = undefined;
      contextWindow = undefined;
    }
    modelProvider = boundedText(providerValue) ?? modelProvider;
  };

  for (const line of lines) {
    let value: unknown;
    try { value = JSON.parse(line); } catch { continue; }
    if (!record(value)) continue;

    if (provider === "claude_code") {
      permissionMode = boundedText(value.permissionMode) ?? permissionMode;
      reasoningEffort = boundedText(value.effort) ?? reasoningEffort;
      const message = record(value.message) ? value.message : undefined;
      setModel(message?.model);
      const usage = record(message?.usage) ? message.usage : undefined;
      const context = sumNumbers(
        usage?.input_tokens,
        usage?.cache_read_input_tokens,
        usage?.cache_creation_input_tokens,
      );
      if (context > 0) contextTokens = context;
    }

    if (provider === "codex") {
      const payload = record(value.payload) ? value.payload : undefined;
      if (value.type === "session_meta" && payload) {
        modelProvider = boundedText(payload.model_provider) ?? modelProvider;
      }
      if (value.type === "turn_context" && payload) {
        setModel(payload.model);
        reasoningEffort = boundedText(payload.effort) ?? reasoningEffort;
        approvalPolicy = boundedText(payload.approval_policy) ?? approvalPolicy;
        const sandboxPolicy = record(payload.sandbox_policy) ? payload.sandbox_policy : undefined;
        sandbox = boundedText(sandboxPolicy?.type) ?? sandbox;
      }
      if (value.type === "event_msg" && payload?.type === "thread_settings_applied") {
        const applied = record(payload.thread_settings) ? payload.thread_settings : undefined;
        setModel(applied?.model);
        reasoningEffort = boundedText(applied?.reasoning_effort) ?? reasoningEffort;
        approvalPolicy = boundedText(applied?.approval_policy) ?? approvalPolicy;
        const profile = record(applied?.active_permission_profile)
          ? applied.active_permission_profile : record(applied?.permission_profile)
            ? applied.permission_profile : undefined;
        sandbox = boundedText(profile?.type) ?? sandbox;
      }
      if (value.type === "event_msg" && payload?.type === "token_count") {
        const info = record(payload.info) ? payload.info : undefined;
        const last = record(info?.last_token_usage) ? info.last_token_usage : undefined;
        contextTokens = positiveInteger(last?.total_tokens) ?? contextTokens;
        contextWindow = positiveInteger(info?.model_context_window) ?? contextWindow;
      }
      if (value.type === "event_msg" && payload?.type === "task_started") {
        contextWindow = positiveInteger(payload.model_context_window) ?? contextWindow;
      }
    }

    if (provider === "pi") {
      if (value.type === "model_change") {
        setModel(value.modelId, value.provider);
      }
      if (value.type === "thinking_level_change") {
        reasoningEffort = boundedText(value.thinkingLevel) ?? reasoningEffort;
      }
      const message = record(value.message) ? value.message : undefined;
      if (value.type === "message" && message?.role === "assistant") {
        setModel(message.model, message.provider);
        const usage = record(message.usage) ? message.usage : undefined;
        const context = sumNumbers(usage?.input, usage?.cacheRead, usage?.cacheWrite);
        if (context > 0) contextTokens = context;
      }
    }
  }

  const catalogModel = modelId
    ? catalog[modelProvider ? `${modelProvider}:${modelId}` : modelId] ?? catalog[modelId]
    : undefined;
  const model = modelId ? modelDisplayName(modelId, catalogModel?.displayName) : undefined;
  contextWindow ??= catalogModel?.contextWindow;
  if (contextTokens && contextWindow && contextTokens > contextWindow) contextWindow = undefined;
  return {
    ...(model ? { model } : {}),
    ...(modelId && model !== modelId ? { modelId } : {}),
    ...(modelProvider ? { modelProvider } : {}),
    ...(reasoningEffort ? { reasoningEffort } : {}),
    ...(permissionMode ? { permissionMode } : {}),
    ...(sandbox ? { sandbox } : {}),
    ...(approvalPolicy ? { approvalPolicy } : {}),
    ...(contextTokens ? { contextTokens } : {}),
    ...(contextWindow ? { contextWindow } : {}),
  };
}

function parseClaude(
  value: Record<string, unknown>,
  lineIndex: number,
  items: ChatItem[],
  tools: Map<string, number>,
): void {
  if (value.type === "system") {
    const id = text(value.uuid) || `claude-system-${lineIndex}`;
    const timestamp = iso(value.timestamp);
    const subtype = text(value.subtype);
    if (subtype === "turn_duration") {
      const duration = positiveInteger(value.durationMs);
      if (duration) addSystem(items, id, "turn_duration", `Turn duration: ${formatDuration(duration)}`, timestamp);
    } else if (subtype === "away_summary" && text(value.content)) {
      addSystem(items, id, "recap", text(value.content), timestamp);
    } else if (subtype === "compact_boundary") {
      addSystem(items, id, "compact_boundary", "Context compacted", timestamp, "compact");
    } else if (subtype === "local_command") {
      const output = text(value.content)
        .replace(/^<local-command-(?:stdout|stderr)>/, "")
        .replace(/<\/local-command-(?:stdout|stderr)>$/, "")
        .trim();
      if (output) addSystem(items, id, "local_command_output", output, timestamp);
    }
    return;
  }
  const message = record(value.message) ? value.message : undefined;
  if (!message) return;
  const role = text(message.role);
  const content = message.content;
  const id = text(value.uuid) || `claude-${lineIndex}`;
  const timestamp = iso(value.timestamp);
  if (role === "user") {
    if (typeof content === "string") {
      if (content.trim().startsWith("[Request interrupted by user")) {
        addSystem(items, id, "interrupted", content.trim(), timestamp, "error");
      } else if (content.trim()) {
        items.push(user(id, content, [], timestamp, chatIdentity(value, message)));
      }
      return;
    }
    if (!Array.isArray(content)) return;
    let userText = "";
    const images: ChatImage[] = [];
    for (const block of content) {
      if (!record(block)) continue;
      if (block.type === "tool_result") {
        finishTool(items, tools, text(block.tool_use_id), block.is_error === true, contentText(block.content));
      } else if (block.type === "text") {
        userText += text(block.text);
      } else if (block.type === "image" && record(block.source)) {
        const image = normalizeImage(block.source.data, block.source.media_type);
        if (image) images.push({ name: `image-${images.length + 1}`, ...image });
      }
    }
    if (userText.trim().startsWith("[Request interrupted by user")) {
      addSystem(items, id, "interrupted", userText.trim(), timestamp, "error");
    } else if (userText.trim() || images.length) {
      items.push(user(id, userText, images, timestamp, chatIdentity(value, message)));
    }
    return;
  }
  if (role !== "assistant" || !Array.isArray(content)) return;
  for (let index = 0; index < content.length; index += 1) {
    const block = content[index];
    if (!record(block)) continue;
    const blockID = `${id}-${index}`;
    if (block.type === "text" && text(block.text).trim()) {
      items.push({ id: blockID, kind: "assistant", text: text(block.text), timestamp });
    } else if (block.type === "thinking" && text(block.thinking).trim()) {
      items.push({ id: blockID, kind: "thinking", text: text(block.thinking), timestamp });
    } else if (block.type === "tool_use") {
      addTool(items, tools, text(block.id) || blockID, text(block.name) || "Tool", input(block.input), timestamp);
    }
  }
}

function parseCodex(
  value: Record<string, unknown>,
  lineIndex: number,
  items: ChatItem[],
  tools: Map<string, number>,
): void {
  const payload = record(value.payload) ? value.payload : undefined;
  if (!payload) return;
  const timestamp = iso(value.timestamp);
  const type = text(payload.type);
  const id = text(payload.id) || text(payload.turn_id) || `codex-${lineIndex}`;
  if (value.type === "event_msg") {
    if (type === "task_complete") {
      const duration = positiveInteger(payload.duration_ms);
      if (duration) addSystem(items, `${id}-duration`, "turn_duration", `Turn duration: ${formatDuration(duration)}`, timestamp);
    } else if (type === "context_compacted") {
      addSystem(items, `${id}-compact`, "compact_boundary", "Context compacted", timestamp, "compact");
    } else if (type === "turn_aborted") {
      addSystem(items, `${id}-interrupted`, "interrupted", "Request interrupted", timestamp, "error");
    }
    return;
  }
  if (value.type !== "response_item") return;
  if (type === "message") {
    const role = text(payload.role);
    const blocks = Array.isArray(payload.content) ? payload.content : [];
    const body = blocks.filter(record).map((block) => text(block.text))
      .filter((body) => body && !(role === "user" && isCodexContextBlock(body))).join("\n");
    const images = blocks.filter(record).flatMap((block, index): ChatImage[] => {
      if (block.type !== "input_image") return [];
      const image = normalizeImage(block.image_url || block.url, undefined);
      return image ? [{ name: `image-${index + 1}`, ...image }] : [];
    });
    if (role === "user" && (body.trim() || images.length)) {
      items.push(user(id, body, images, timestamp, chatIdentity(value, payload)));
    }
    if (role === "assistant" && body.trim()) items.push({ id, kind: "assistant", text: body, timestamp });
    return;
  }
  if (type === "reasoning") {
    const summary = Array.isArray(payload.summary)
      ? payload.summary.filter(record).map((part) => text(part.text)).filter(Boolean).join("\n")
      : text(payload.summary);
    if (summary.trim()) items.push({ id, kind: "thinking", text: summary, timestamp });
    return;
  }
  if (type === "function_call" || type === "custom_tool_call") {
    const callID = text(payload.call_id) || id;
    addTool(
      items,
      tools,
      callID,
      text(payload.name) || "Tool",
      type === "function_call" ? jsonInput(payload.arguments) : { input: payload.input },
      timestamp,
    );
    return;
  }
  if (type === "function_call_output" || type === "custom_tool_call_output") {
    finishTool(items, tools, text(payload.call_id), false, contentText(payload.output));
  }
}

function isCodexContextBlock(body: string): boolean {
  // Codex stores injected setup as user-role text. Match only a complete,
  // context-only block so quoted examples, mixed prose, and sibling images survive.
  const trimmed = body.trim();
  return [
    "environment_context", "developer_context", "permissions instructions",
    "app-context", "skills_instructions",
  ].some((tag) => {
    if (!trimmed.startsWith(`<${tag}>`)) return false;
    const closingTag = `</${tag}>`;
    const closingIndex = trimmed.indexOf(closingTag);
    return closingIndex >= 0 && closingIndex + closingTag.length === trimmed.length;
  });
}

function parsePi(
  value: Record<string, unknown>,
  lineIndex: number,
  items: ChatItem[],
  tools: Map<string, number>,
): void {
  if (value.type === "compaction") {
    addSystem(
      items,
      text(value.id) || `pi-compact-${lineIndex}`,
      "compact_boundary",
      text(value.summary) || "Context compacted",
      iso(value.timestamp),
      "compact",
    );
    return;
  }
  if (value.type !== "message" || !record(value.message)) return;
  const message = value.message;
  const role = text(message.role);
  const content = Array.isArray(message.content) ? message.content : [];
  const id = text(value.id) || `pi-${lineIndex}`;
  const timestamp = iso(value.timestamp) ?? iso(message.timestamp);
  if (role === "toolResult") {
    finishTool(items, tools, text(message.toolCallId), message.isError === true, contentText(content));
    return;
  }
  if (role === "user") {
    const body = content.filter(record).map((part) => text(part.text)).filter(Boolean).join("\n");
    const images = content.filter(record).flatMap((part, index): ChatImage[] => {
      if (part.type !== "image") return [];
      const image = normalizeImage(part.data, part.mimeType);
      return image ? [{ name: `image-${index + 1}`, ...image }] : [];
    });
    if (body.trim() || images.length) {
      items.push(user(id, body, images, timestamp, chatIdentity(value, message)));
    }
    return;
  }
  if (role !== "assistant") return;
  for (let index = 0; index < content.length; index += 1) {
    const block = content[index];
    if (!record(block)) continue;
    const blockID = `${id}-${index}`;
    if (block.type === "text" && text(block.text).trim()) {
      items.push({ id: blockID, kind: "assistant", text: text(block.text), timestamp });
    } else if (block.type === "thinking" && text(block.thinking).trim()) {
      items.push({ id: blockID, kind: "thinking", text: text(block.thinking), timestamp });
    } else if (block.type === "toolCall") {
      addTool(items, tools, text(block.id) || blockID, text(block.name) || "Tool", input(block.arguments), timestamp);
    }
  }
}

function parseCursor(
  value: Record<string, unknown>,
  lineIndex: number,
  items: ChatItem[],
  tools: Map<string, number>,
): void {
  if (value.type === "turn_ended") {
    for (const item of items) if (item.kind === "tool" && item.status === "running") item.status = "success";
    return;
  }
  if (!record(value.message) || !Array.isArray(value.message.content)) return;
  const role = text(value.role);
  for (let index = 0; index < value.message.content.length; index += 1) {
    const block = value.message.content[index];
    if (!record(block)) continue;
    const id = `cursor-${lineIndex}-${index}`;
    if (block.type === "text" && text(block.text).trim()) {
      items.push(role === "user"
        ? user(id, text(block.text), [], undefined, chatIdentity(value, value.message))
        : { id, kind: "assistant", text: text(block.text) });
    } else if (role === "assistant" && block.type === "tool_use") {
      addTool(items, tools, id, text(block.name) || "Tool", input(block.input), undefined);
    }
  }
}

function addSystem(
  items: ChatItem[],
  id: string,
  category: NonNullable<Extract<ChatItem, { kind: "system" }>["category"]>,
  body: string,
  timestamp?: string,
  tone: Extract<ChatItem, { kind: "system" }>["tone"] = "neutral",
): void {
  items.push({ id, kind: "system", text: body, tone, category, timestamp });
}

function formatDuration(milliseconds: number): string {
  return milliseconds < 1_000
    ? `${milliseconds}ms`
    : `${(milliseconds / 1_000).toFixed(milliseconds < 10_000 ? 1 : 0)}s`;
}

function addTool(
  items: ChatItem[],
  tools: Map<string, number>,
  id: string,
  name: string,
  toolInput: Record<string, unknown>,
  timestamp: string | undefined,
): void {
  tools.set(id, items.length);
  items.push({
    id,
    kind: "tool",
    name: displayToolName(name),
    family: toolFamily(name),
    input: toolInput,
    status: "running",
    timestamp,
  });
}

function finishTool(
  items: ChatItem[],
  tools: Map<string, number>,
  id: string,
  failed: boolean,
  result: string,
): void {
  const index = tools.get(id);
  if (index === undefined) return;
  const item = items[index];
  if (!item || item.kind !== "tool") return;
  item.status = failed ? "error" : "success";
  if (result) item.result = result;
}

type ChatUserIdentity = Pick<Extract<ChatItem, { kind: "user" }>,
  "requestId" | "deliveryId" | "providerMessageId">;

function user(
  id: string,
  body: string,
  images: ChatImage[],
  timestamp?: string,
  identity: ChatUserIdentity = {},
): ChatItem {
  const text = normalizeChatText(body);
  return {
    id,
    kind: "user",
    text,
    images,
    timestamp,
    ...(identity.requestId ? { requestId: identity.requestId } : {}),
    ...(identity.deliveryId ? { deliveryId: identity.deliveryId } : {}),
    ...(identity.providerMessageId ? { providerMessageId: identity.providerMessageId } : {}),
  };
}

/** Use the same provider-neutral normalization for canonical and submitted turns. */
export function normalizeChatText(body: string): string {
  return body
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "")
    .replace(/<ide_(?:opened_file|selection)>[\s\S]*?<\/ide_(?:opened_file|selection)>/g, "")
    .trim();
}

function chatIdentity(...values: Array<Record<string, unknown> | undefined>): ChatUserIdentity {
  const requestId = firstIdentityValue(values, ["requestId", "request_id"]);
  const deliveryId = firstIdentityValue(values, ["deliveryId", "delivery_id"]);
  const providerMessageId = firstIdentityValue(values, [
    "providerMessageId", "provider_message_id", "messageId", "message_id",
  ]);
  return {
    ...(requestId ? { requestId } : {}),
    ...(deliveryId ? { deliveryId } : {}),
    ...(providerMessageId ? { providerMessageId } : {}),
  };
}

function firstIdentityValue(
  values: Array<Record<string, unknown> | undefined>,
  keys: string[],
): string | undefined {
  for (const value of values) {
    if (!value) continue;
    for (const key of keys) {
      const candidate = text(value[key]).trim();
      if (candidate) return candidate;
    }
  }
  return undefined;
}

function contentText(value: unknown): string {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return record(value) ? text(value.text || value.output) : "";
  return value.map((part) => record(part) ? text(part.text || part.output || part.content) : text(part)).filter(Boolean).join("\n");
}

function jsonInput(value: unknown): Record<string, unknown> {
  if (record(value)) return value;
  if (typeof value !== "string") return {};
  try {
    const parsed: unknown = JSON.parse(value);
    return record(parsed) ? parsed : { input: value };
  } catch {
    return { input: value };
  }
}

function input(value: unknown): Record<string, unknown> {
  return record(value) ? value : {};
}

function iso(value: unknown): string | undefined {
  if (typeof value === "number") {
    const date = new Date(value > 10_000_000_000 ? value : value * 1_000);
    return Number.isNaN(date.valueOf()) ? undefined : date.toISOString();
  }
  if (typeof value !== "string" || !value) return undefined;
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? undefined : date.toISOString();
}

function imageMime(value: unknown): ChatImage["mimeType"] | undefined {
  return (CHAT_IMAGE_SUPPORTED_MIME_TYPES as readonly string[]).includes(text(value))
    ? text(value) as ChatImage["mimeType"]
    : undefined;
}

function normalizeImage(
  value: unknown,
  declaredMime: unknown,
): Pick<ChatImage, "mimeType" | "data"> | undefined {
  const input = text(value);
  if (!input) return undefined;
  let payload = input;
  let uriMime: ChatImage["mimeType"] | undefined;
  if (input.startsWith("data:")) {
    const comma = input.indexOf(",");
    if (comma <= 5) return undefined;
    const metadata = input.slice(5, comma).toLowerCase();
    if (!metadata.endsWith(";base64")) return undefined;
    const candidate = metadata.slice(0, -";base64".length);
    uriMime = imageMime(candidate);
    if (!uriMime) return undefined;
    payload = input.slice(comma + 1);
  }
  if (payload.length > CHAT_IMAGE_MAX_BASE64_CHARS) return undefined;
  const declared = imageMime(declaredMime);
  if (text(declaredMime) && !declared) return undefined;
  if (declared && uriMime && declared !== uriMime) return undefined;
  const expected = declared ?? uriMime;
  const bytes = chatImageBase64Bytes(payload);
  if (!bytes) return undefined;
  const detected = chatImageMimeForBytes(bytes);
  if (!detected || (expected && expected !== detected)) return undefined;
  return { mimeType: detected, data: payload };
}

function toolFamily(name: string): NonNullable<Extract<ChatItem, { kind: "tool" }>["family"]> {
  const normalized = name.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  if (normalized === "mcp" || normalized.startsWith("mcp ")) return "mcp";
  if (["bash", "shell", "command", "exec", "execute", "exec command"].includes(normalized)
    || normalized.endsWith(" shell")) return "bash";
  if (normalized === "read" || normalized.startsWith("read ")) return "read";
  if (normalized === "write" || normalized.startsWith("write ")) return "write";
  if (normalized === "edit" || normalized.startsWith("edit ")
    || normalized === "apply patch") return "edit";
  if (normalized === "grep" || normalized.startsWith("grep ")) return "grep";
  if (normalized === "glob" || normalized.startsWith("glob ")) return "glob";
  if (normalized === "web fetch") return "web_fetch";
  if (normalized === "web search") return "web_search";
  if (normalized === "todo write") return "todo_write";
  if (["task", "agent", "subagent"].includes(normalized)) return "task";
  if (normalized === "ask user question") return "ask_user_question";
  if (normalized === "bash output") return "bash_output";
  if (normalized === "kill shell") return "kill_shell";
  if (["enter plan mode", "exit plan mode"].includes(normalized)) return "plan_mode";
  return "other";
}

function displayToolName(name: string): string {
  return name.split(/[_-]/).filter(Boolean)
    .map((part) => part[0]!.toUpperCase() + part.slice(1))
    .join(" ");
}

function modelDisplayName(modelId: string, catalogName?: string): string {
  if (catalogName?.trim()) return catalogName.trim();
  if (modelId.startsWith("gpt-")) {
    const [version, ...variants] = modelId.slice(4).split("-");
    return variants.length
      ? `GPT-${version} ${variants.map(capitalize).join(" ")}`
      : `GPT-${version}`;
  }
  const claude = /^(?:claude-)?(opus|sonnet|haiku)-(\d+)-(\d+)(?:\[.*)?$/i.exec(modelId);
  return claude ? `${capitalize(claude[1]!)} ${claude[2]}.${claude[3]}` : modelId;
}

function capitalize(value: string): string {
  return value ? value[0]!.toUpperCase() + value.slice(1) : value;
}

function boundedModel(value: unknown): string | undefined {
  const model = boundedText(value);
  return model?.startsWith("<") ? undefined : model;
}

function boundedText(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed && trimmed.length <= 256 ? trimmed : undefined;
}

function positiveInteger(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    ? value : undefined;
}

function sumNumbers(...values: unknown[]): number {
  return values.reduce<number>((sum, value) =>
    sum + (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0), 0);
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
