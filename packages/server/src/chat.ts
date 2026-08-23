import { open, stat } from "node:fs/promises";
import type { ChatCapabilities, ChatImage, ChatItem, ChatPage } from "@agent-visor/protocol";
import { summaryWork } from "./machine.js";
import type { DiscoveredProviderSession, ProviderID } from "./sessions.js";

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
  const page = await readLinesBackward(path, end, fileSize, session.provider, limit);
  return {
    type: "chat_page",
    sessionId: session.id,
    items: page.items,
    hasMoreBefore: page.start > 0,
    nextBefore: page.start > 0 ? page.start : undefined,
    capabilities: chatCapabilities(session),
    pendingAction: null,
  };
}

export function chatCapabilities(session: DiscoveredProviderSession): ChatCapabilities {
  if (session.messageTransport) {
    return {
      canSendText: true,
      canSendImages: (session.provider === "claude_code"
        && session.controlTarget?.kind === "terminal"
        && session.controlTarget.target.application !== "Terminal")
        || session.provider === "pi"
        || session.messageTransport === "codex_app_server",
      canApprove: false,
      canAnswer: false,
    };
  }
  const readOnlyReason = session.owner === "Zed"
    ? "Continue in Zed. Zed-hosted Chat is read only."
    : session.provider === "cursor"
      ? "Continue in Cursor. Cursor Chat is read only."
      : !session.canOpenOwner
        ? "Chat history is read only."
        : "Continue in the source app while native message transport is unavailable.";
  return {
    canSendText: false,
    canSendImages: false,
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
): Promise<{ items: ChatItem[]; start: number }> {
  return summaryWork.run(async () => {
    const file = await open(path, "r");
    try {
      let start = end;
      let buffer = Buffer.alloc(0);
      let lines: Array<{ text: string; start: number }> = [];
      let items: ChatItem[] = [];
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
      items = parseChatLines(provider, lines.slice(selectedLine).map((line) => line.text)).slice(-1_000);
      return { items, start: lines[selectedLine]?.start ?? 0 };
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
    capabilities: { ...chatCapabilities(session), readOnlyReason },
    pendingAction: null,
  };
}

export function parseChatLines(provider: ProviderID, lines: string[]): ChatItem[] {
  const items: ChatItem[] = [];
  const tools = new Map<string, number>();
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    let value: unknown;
    try { value = JSON.parse(lines[lineIndex]!); } catch { continue; }
    if (!record(value)) continue;
    if (provider === "claude_code") parseClaude(value, lineIndex, items, tools);
    if (provider === "codex") parseCodex(value, lineIndex, items, tools);
    if (provider === "pi") parsePi(value, lineIndex, items, tools);
    if (provider === "cursor") parseCursor(value, lineIndex, items, tools);
  }
  return items.filter((item) => item.kind !== "user" || item.text.length > 0 || item.images.length > 0);
}

function parseClaude(
  value: Record<string, unknown>,
  lineIndex: number,
  items: ChatItem[],
  tools: Map<string, number>,
): void {
  const message = record(value.message) ? value.message : undefined;
  if (!message) return;
  const role = text(message.role);
  const content = message.content;
  const id = text(value.uuid) || `claude-${lineIndex}`;
  const timestamp = iso(value.timestamp);
  if (role === "user") {
    if (typeof content === "string") {
      if (content.trim()) items.push(user(id, content, [], timestamp));
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
        const mimeType = imageMime(block.source.media_type);
        const data = text(block.source.data);
        if (mimeType && data) images.push({ name: `image-${images.length + 1}`, mimeType, data });
      }
    }
    if (userText.trim() || images.length) items.push(user(id, userText, images, timestamp));
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
  const id = text(payload.id) || `codex-${lineIndex}`;
  if (value.type === "event_msg") return;
  if (value.type !== "response_item") return;
  if (type === "message") {
    const role = text(payload.role);
    const blocks = Array.isArray(payload.content) ? payload.content : [];
    const body = blocks.filter(record).map((block) => text(block.text)).filter(Boolean).join("\n");
    const images = blocks.filter(record).flatMap((block, index): ChatImage[] => {
      if (block.type !== "input_image") return [];
      const data = text(block.image_url || block.url);
      return data ? [{ name: `image-${index + 1}`, mimeType: "image/png", data }] : [];
    });
    if (role === "user" && (body.trim() || images.length)) items.push(user(id, body, images, timestamp));
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

function parsePi(
  value: Record<string, unknown>,
  lineIndex: number,
  items: ChatItem[],
  tools: Map<string, number>,
): void {
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
      const mimeType = imageMime(part.mimeType);
      const data = text(part.data);
      return mimeType && data ? [{ name: `image-${index + 1}`, mimeType, data }] : [];
    });
    if (body.trim() || images.length) items.push(user(id, body, images, timestamp));
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
        ? user(id, text(block.text), [], undefined)
        : { id, kind: "assistant", text: text(block.text) });
    } else if (role === "assistant" && block.type === "tool_use") {
      addTool(items, tools, id, text(block.name) || "Tool", input(block.input), undefined);
    }
  }
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
  items.push({ id, kind: "tool", name: displayToolName(name), input: toolInput, status: "running", timestamp });
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

function user(id: string, body: string, images: ChatImage[], timestamp?: string): ChatItem {
  const text = body
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "")
    .replace(/<ide_(?:opened_file|selection)>[\s\S]*?<\/ide_(?:opened_file|selection)>/g, "")
    .trim();
  return { id, kind: "user", text, images, timestamp };
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
  return ["image/png", "image/jpeg", "image/gif", "image/webp"].includes(text(value))
    ? text(value) as ChatImage["mimeType"]
    : undefined;
}

function displayToolName(name: string): string {
  return name.split(/[_-]/).filter(Boolean)
    .map((part) => part[0]!.toUpperCase() + part.slice(1))
    .join(" ");
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
