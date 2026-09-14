import type {
  ChatImage,
  ChatItem,
  ChatMetadata,
  ChatPage,
  ChatVisibility,
} from "@agent-visor/protocol";
import {
  CHAT_IMAGE_MAX_BASE64_CHARS,
  CHAT_IMAGE_SUPPORTED_MIME_TYPES,
  chatImageBase64Bytes,
  chatImageMimeForBytes,
  formatDuration,
  parseDuration,
} from "@agent-visor/protocol";

export type ChatMetadataRow = { label: string; value: string };

/**
 * Return an image URI only when the history payload is self-contained and
 * signature-valid. Incoming history must never turn an arbitrary URL or path
 * into a network/resource request from the renderer.
 */
export function historyImageDataURI(
  image: Pick<ChatImage, "data"> & Partial<Pick<ChatImage, "mimeType">>,
): string | undefined {
  const value = image.data;
  if (!value) return undefined;
  let payload = value;
  let uriMime: string | undefined;
  if (value.startsWith("data:")) {
    const comma = value.indexOf(",");
    if (comma <= 5) return undefined;
    const metadata = value.slice(5, comma).toLowerCase();
    if (!metadata.endsWith(";base64")) return undefined;
    uriMime = metadata.slice(0, -";base64".length);
    payload = value.slice(comma + 1);
  }
  const declaredMime = typeof image.mimeType === "string" && image.mimeType
    ? image.mimeType.toLowerCase()
    : undefined;
  if (uriMime && declaredMime && uriMime !== declaredMime) return undefined;
  const expectedMime = declaredMime ?? uriMime;
  if (expectedMime
    && !(CHAT_IMAGE_SUPPORTED_MIME_TYPES as readonly string[]).includes(expectedMime)) return undefined;
  if (payload.length > CHAT_IMAGE_MAX_BASE64_CHARS) return undefined;
  const bytes = chatImageBase64Bytes(payload);
  if (!bytes) return undefined;
  const detectedMime = chatImageMimeForBytes(bytes);
  if (!detectedMime || (expectedMime && detectedMime !== expectedMime)) return undefined;
  return `data:${detectedMime};base64,${payload}`;
}

/**
 * The small Markdown subset currently rendered by the Electron Chat surface.
 * Fenced code is kept as one opaque part so inline formatting never changes
 * literal code content. The renderer and accessibility projection consume
 * this same representation.
 */
export type ChatTextPart =
  | { kind: "text"; text: string }
  | { kind: "bold"; text: string }
  | { kind: "inline-code"; text: string }
  | { kind: "fenced-code"; text: string };

/**
 * Parse Chat text once for both visible rendering and accessibility text.
 * This intentionally preserves the current renderer's small Markdown
 * dialect, including treating malformed spans as literal text.
 */
export function parseChatText(text: string): ChatTextPart[] {
  const parts: ChatTextPart[] = [];
  let inFence = false;
  let segmentStart = 0;

  while (segmentStart <= text.length) {
    const fenceStart = text.indexOf("```", segmentStart);
    const segmentEnd = fenceStart < 0 ? text.length : fenceStart;
    const segment = text.slice(segmentStart, segmentEnd);
    if (inFence) {
      appendPart(parts, "fenced-code", stripFenceInfo(segment));
    } else {
      parseInlineSegment(segment, parts);
    }
    if (fenceStart < 0) break;
    inFence = !inFence;
    segmentStart = fenceStart + 3;
  }

  return parts;
}

function parseInlineSegment(segment: string, parts: ChatTextPart[]): void {
  let index = 0;
  let textStart = 0;

  const flushText = (end: number) => {
    if (end > textStart) appendPart(parts, "text", segment.slice(textStart, end));
  };

  while (index < segment.length) {
    const boldEnd = segment.startsWith("**", index)
      ? findBoldEnd(segment, index + 2)
      : -1;
    if (boldEnd >= 0) {
      flushText(index);
      appendPart(parts, "bold", segment.slice(index + 2, boldEnd));
      index = boldEnd + 2;
      textStart = index;
      continue;
    }

    if (segment[index] === "`") {
      const inlineEnd = segment.indexOf("`", index + 1);
      if (inlineEnd > index + 1) {
        flushText(index);
        appendPart(parts, "inline-code", segment.slice(index + 1, inlineEnd));
        index = inlineEnd + 1;
        textStart = index;
        continue;
      }
    }

    index += 1;
  }

  flushText(segment.length);
}

function findBoldEnd(text: string, contentStart: number): number {
  // The existing inline renderer accepts a non-empty run with no '*' inside
  // it. Keeping that rule makes malformed **a*b** literal instead of silently
  // changing the visible message during this parser consolidation.
  const firstStar = text.indexOf("*", contentStart);
  return firstStar > contentStart && text.startsWith("**", firstStar)
    ? firstStar
    : -1;
}

function stripFenceInfo(segment: string): string {
  const newline = segment.indexOf("\n");
  if (newline <= 0) return segment;
  const info = segment.slice(0, newline);
  for (const character of info) {
    const code = character.charCodeAt(0);
    const isWord = (code >= 48 && code <= 57)
      || (code >= 65 && code <= 90)
      || (code >= 97 && code <= 122)
      || character === "_";
    if (!isWord) return segment;
  }
  return segment.slice(newline + 1);
}

function appendPart(parts: ChatTextPart[], kind: "text", text: string): void;
function appendPart(parts: ChatTextPart[], kind: "bold", text: string): void;
function appendPart(parts: ChatTextPart[], kind: "inline-code", text: string): void;
function appendPart(parts: ChatTextPart[], kind: "fenced-code", text: string): void;
function appendPart(parts: ChatTextPart[], kind: ChatTextPart["kind"], text: string): void {
  if (!text) return;
  const previous = parts[parts.length - 1];
  if (kind === "text" && previous?.kind === "text") {
    previous.text += text;
    return;
  }
  switch (kind) {
    case "text": parts.push({ kind, text }); break;
    case "bold": parts.push({ kind, text }); break;
    case "inline-code": parts.push({ kind, text }); break;
    case "fenced-code": parts.push({ kind, text }); break;
  }
}

export function accessibleThinkingText(text: string): string {
  return parseChatText(text).map((part) => part.text).join(" ")
    .replace(/\s+/g, " ")
    .trim();
}

export function chatMetadataRows(metadata: ChatMetadata): ChatMetadataRow[] {
  const rows: ChatMetadataRow[] = [];
  if (metadata.model) rows.push({ label: "Model", value: metadata.model });
  if (metadata.modelId) rows.push({ label: "Model identifier", value: metadata.modelId });
  if (metadata.modelProvider) rows.push({
    label: "Model provider", value: displayMetadataValue(metadata.modelProvider),
  });
  if (metadata.reasoningEffort) rows.push({
    label: "Reasoning", value: displayMetadataValue(metadata.reasoningEffort),
  });
  if (metadata.permissionMode) rows.push({
    label: "Permission", value: displayMetadataValue(metadata.permissionMode),
  });
  if (metadata.sandbox) rows.push({
    label: "Sandbox", value: displayMetadataValue(metadata.sandbox),
  });
  if (metadata.approvalPolicy) rows.push({
    label: "Approval", value: displayMetadataValue(metadata.approvalPolicy),
  });
  if (metadata.contextTokens || metadata.contextWindow) {
    const used = metadata.contextTokens?.toLocaleString("en-US");
    const window = metadata.contextWindow?.toLocaleString("en-US");
    const percentage = metadata.contextTokens && metadata.contextWindow
      ? ` (${Math.round(metadata.contextTokens / metadata.contextWindow * 100)}%)`
      : "";
    rows.push({
      label: "Context",
      value: used && window ? `${used} / ${window} tokens${percentage}`
        : `${used ?? window} tokens`,
    });
  }
  return rows;
}

function displayMetadataValue(value: string): string {
  return value
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/[-_]+/g, " ")
    .split(" ")
    .filter(Boolean)
    .map((part) => part[0]!.toUpperCase() + part.slice(1))
    .join(" ")
    .replace(/\bOpenai\b/g, "OpenAI")
    .replace(/\bMcp\b/g, "MCP");
}

export type ChatTurn = {
  id: string;
  prompt?: Extract<ChatItem, { kind: "user" }>;
  work: ChatItem[];
  answers: ChatItem[];
  live: boolean;
};

// This row is deliberately a normal system item so the existing Chat
// accessibility projection announces the continuity boundary to assistive
// technology as well as sighted users.
export const CHAT_HISTORY_GAP_ID = "chat-history-gap";
export const CHAT_HISTORY_GAP_TEXT = "Some messages are not shown between these history segments.";

function chatHistoryGap(): Extract<ChatItem, { kind: "system" }> {
  return {
    id: CHAT_HISTORY_GAP_ID,
    kind: "system",
    text: CHAT_HISTORY_GAP_TEXT,
    tone: "neutral",
    category: "other",
  };
}

export function filterChatItems(items: ChatItem[], rules: ChatVisibility): ChatItem[] {
  return items.filter((item) => {
    if (item.kind === "user") return rules.showUserMessage;
    if (item.kind === "assistant") return rules.showAssistantMessage;
    if (item.kind === "thinking") return rules.showThinking;
    if (item.kind === "tool") return rules[toolVisibilitySetting(item)];
    // Agent activity follows the shared Tasks and subagents setting, while
    // remaining independent of the user-message visibility setting.
    if (item.kind === "activity") return rules.showTask;
    const setting = systemVisibilitySetting(item.category);
    return setting ? rules[setting] : true;
  });
}

export function filterChatTurns(turns: ChatTurn[], rules: ChatVisibility): ChatTurn[] {
  return turns.flatMap((turn) => {
    const prompt = turn.prompt && rules.showUserMessage ? turn.prompt : undefined;
    const work = filterChatItems(turn.work, rules);
    const answers = filterChatItems(turn.answers, rules);
    return prompt || work.length || answers.length
      ? [{ ...turn, prompt, work, answers }]
      : [];
  });
}

/**
 * Default disclosure state for a grouped turn's "Worked" header, used until
 * the user toggles it. Only a turn that is still running starts open, so its
 * steps stay in view while they happen. A tool waiting for approval also
 * keeps the turn open because it blocks progress. A finished turn always
 * starts collapsed, even when one of its steps failed.
 */
export function isTurnExpandedByDefault(turn: ChatTurn): boolean {
  return turn.live
    || turn.work.some((item) => item.kind === "tool" && item.status === "waiting");
}

/**
 * Liveness for the "Working…" header comes from the daemon, not from the
 * transcript's shape. The transcript heuristic in `groupChatTurns` (native
 * work with no trailing answer) reads "Worked" as soon as the agent posts
 * any text after its first tool call, even while it keeps going, and reads
 * "Working…" forever for a turn that ended on a tool call. When the daemon
 * knows the session's turn state, that wins: only the last turn can be
 * live, only while the turn is working, and only if it has native work.
 * An unknown state keeps the heuristic.
 */
export function applyTurnLiveness(
  turns: ChatTurn[],
  turnState: "needs_you" | "ready" | "working" | "unknown" | undefined,
): ChatTurn[] {
  if (turnState === undefined || turnState === "unknown") return turns;
  return turns.map((turn, index) => {
    const last = index === turns.length - 1;
    const hasNativeWork = turn.work.some((item) => item.kind === "thinking" || item.kind === "tool");
    return { ...turn, live: last && turnState === "working" && hasNativeWork };
  });
}

export function shouldGroupChatTurns(source: string, rules: ChatVisibility): boolean {
  if (source === "Claude Code") return rules.collapseClaudeTurns;
  if (source === "Codex") return rules.collapseCodexTurns;
  if (source === "Pi") return rules.collapsePiTurns;
  return true;
}

function toolVisibilitySetting(
  item: Extract<ChatItem, { kind: "tool" }>,
): keyof ChatVisibility {
  switch (item.family) {
    case "bash": return "showBash";
    case "read": return "showRead";
    case "write": return "showWrite";
    case "edit": return "showEdit";
    case "grep": return "showGrep";
    case "glob": return "showGlob";
    case "web_fetch": return "showWebFetch";
    case "web_search": return "showWebSearch";
    case "todo_write": return "showTodoWrite";
    case "task": return "showTask";
    case "ask_user_question": return "showAskUserQuestion";
    case "bash_output": return "showBashOutput";
    case "kill_shell": return "showKillShell";
    case "plan_mode": return "showPlanMode";
    case "mcp": return "showMCP";
    case "other": return "showOtherTools";
  }
  const normalized = item.name.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  if (["bash", "shell", "exec", "execute"].includes(normalized)) return "showBash";
  if (normalized === "read") return "showRead";
  if (normalized === "write") return "showWrite";
  if (normalized === "edit") return "showEdit";
  if (normalized === "grep") return "showGrep";
  if (normalized === "glob") return "showGlob";
  if (normalized === "web fetch") return "showWebFetch";
  if (normalized === "web search") return "showWebSearch";
  if (normalized === "todo write") return "showTodoWrite";
  if (["task", "agent", "subagent"].includes(normalized)) return "showTask";
  if (normalized === "ask user question") return "showAskUserQuestion";
  if (normalized === "bash output") return "showBashOutput";
  if (normalized === "kill shell") return "showKillShell";
  if (["enter plan mode", "exit plan mode"].includes(normalized)) return "showPlanMode";
  if (normalized === "mcp" || normalized.startsWith("mcp ")) return "showMCP";
  return "showOtherTools";
}

function systemVisibilitySetting(
  category: Extract<ChatItem, { kind: "system" }>["category"],
): keyof ChatVisibility | undefined {
  switch (category) {
    case "interrupted": return "showInterrupted";
    case "turn_duration": return "showTurnDuration";
    case "recap": return "showRecap";
    case "compact_boundary": return "showCompactBoundary";
    case "local_command_output": return "showLocalCommandOutput";
    default: return undefined;
  }
}

export function groupChatTurns(items: ChatItem[]): ChatTurn[] {
  const turns: ChatTurn[] = [];
  let prompt: Extract<ChatItem, { kind: "user" }> | undefined;
  let body: ChatItem[] = [];

  const flush = () => {
    if (!prompt && !body.length) return;
    // Only native work (thinking/tool) determines which assistant fragments
    // belong in the disclosure. Activity can arrive after a final answer and
    // must not pull that answer back into work.
    let lastNativeWork = -1;
    for (let index = 0; index < body.length; index += 1) {
      if (["thinking", "tool"].includes(body[index]!.kind)) lastNativeWork = index;
    }
    const work = body.filter((item, index) =>
      item.kind === "thinking" || item.kind === "tool" || item.kind === "activity"
      || (item.kind === "assistant" && index <= lastNativeWork));
    const answers = body.filter((item, index) =>
      (item.kind === "assistant" && index > lastNativeWork) || item.kind === "system");
    // Activity records describe delegated/subagent work that has already been
    // classified by the daemon. They are not evidence that the main turn is
    // still running, including when they are the only retained history.
    const hasNativeWork = body.some((item) => item.kind === "thinking" || item.kind === "tool");
    turns.push({
      id: prompt?.id ?? body[0]!.id,
      ...(prompt ? { prompt } : {}),
      work,
      answers,
      live: hasNativeWork && answers.length === 0,
    });
    prompt = undefined;
    body = [];
  };

  for (const item of items) {
    if (item.kind === "user") {
      flush();
      prompt = item;
    } else {
      body.push(item);
    }
  }
  flush();
  return turns;
}

export function mergeChatPage(
  current: ChatPage | undefined,
  incoming: ChatPage,
  mode: "latest" | "earlier",
): ChatPage {
  if (!current) return incoming;
  return {
    ...incoming,
    items: mode === "earlier"
      ? mergeChatPages(current.items, incoming.items)
      : mergeChatLatest(current.items, incoming.items),
    hasMoreBefore: mode === "earlier" ? incoming.hasMoreBefore : current.hasMoreBefore,
    nextBefore: mode === "earlier" ? incoming.nextBefore : current.nextBefore,
    metadata: mode === "earlier" ? current.metadata : incoming.metadata,
    // Earlier pages contain transcript history only. Keep the latest
    // capability/state projection so an old page cannot re-enable Send or
    // Stop after a newer state update has already denied it.
    capabilities: mode === "earlier" ? current.capabilities : incoming.capabilities,
    sessionState: mode === "earlier" ? current.sessionState : incoming.sessionState,
    stateRevision: mode === "earlier" ? current.stateRevision : incoming.stateRevision,
    chatSettings: mode === "earlier" ? current.chatSettings : incoming.chatSettings,
    pendingAction: mode === "earlier" ? current.pendingAction : incoming.pendingAction,
    pendingActions: mode === "earlier" ? current.pendingActions : incoming.pendingActions,
    transcriptEvidence: mode === "earlier" ? current.transcriptEvidence : incoming.transcriptEvidence,
  };
}

export function mergeChatLatest(current: ChatItem[], incoming: ChatItem[]): ChatItem[] {
  if (current.length === 0) return incoming;
  const incomingIDs = new Set(incoming.map(({ id }) => id));
  const overlap = current.findIndex(({ id }) => incomingIDs.has(id));
  if (overlap >= 0) return [...current.slice(0, overlap), ...incoming];

  // A latest page can legitimately jump after compaction, truncation, or a
  // provider-side rewrite. Keep the bounded rows already on screen and mark
  // the unknown interval instead of silently replacing that history. Reuse a
  // prior marker so repeated no-overlap refreshes cannot accumulate gaps.
  const existingGap = current.findIndex(({ id }) => id === CHAT_HISTORY_GAP_ID);
  if (existingGap >= 0) {
    // Move the one marker to the new page boundary. Earlier latest rows stay
    // visible as bounded history, while the newest page remains immediately
    // after the marker for screen-reader and visual continuity.
    return [
      ...current.filter(({ id }) => id !== CHAT_HISTORY_GAP_ID),
      chatHistoryGap(),
      ...incoming,
    ];
  }
  return [...current, chatHistoryGap(), ...incoming];
}

export function mergeChatPages(current: ChatItem[], incoming: ChatItem[]): ChatItem[] {
  const byID = new Map(current.map((item) => [item.id, item]));
  for (const item of incoming) byID.set(item.id, item);
  const incomingIDs = new Set(incoming.map(({ id }) => id));
  return [
    ...incoming,
    ...current.filter(({ id }) => !incomingIDs.has(id)),
  ].map(({ id }) => byID.get(id)!);
}

// ---------------------------------------------------------------------------
// Turn header summary
// ---------------------------------------------------------------------------

/**
 * Buckets a turn's tool calls into a few human verbs so the collapsed
 * "Worked" header can say what happened ("Edited 3 files · Ran 1 command")
 * instead of a bare step count. Ported from the Swift ClaudeTurnActivity so
 * both chats describe a turn the same way.
 */
export type ChatTurnActivity = {
  edited: number;
  ran: number;
  read: number;
  searched: number;
  web: number;
  delegated: number;
  planned: number;
  other: number;
  /** Tool calls that ended in error or were interrupted. */
  failed: number;
  /** Every tool call, categorized or not. */
  tools: number;
  /** Every work item, including thinking and agent activity. */
  steps: number;
};

export function summarizeTurnWork(work: ChatItem[]): ChatTurnActivity {
  const activity: ChatTurnActivity = {
    edited: 0, ran: 0, read: 0, searched: 0, web: 0, delegated: 0, planned: 0, other: 0,
    failed: 0, tools: 0, steps: work.length,
  };
  for (const item of work) {
    if (item.kind !== "tool") continue;
    activity.tools += 1;
    if (item.status === "error" || item.status === "interrupted") activity.failed += 1;
    switch (item.family) {
      case "edit": case "write": activity.edited += 1; break;
      case "bash": case "bash_output": case "kill_shell": activity.ran += 1; break;
      case "read": case "glob": activity.read += 1; break;
      case "grep": activity.searched += 1; break;
      case "web_fetch": case "web_search": activity.web += 1; break;
      case "task": activity.delegated += 1; break;
      case "plan_mode": activity.planned += 1; break;
      default: activity.other += 1;
    }
  }
  return activity;
}

/** Ordered clauses, highest-signal first: the actions that changed state lead. */
export function turnActivityClauses(activity: ChatTurnActivity): string[] {
  const clauses: string[] = [];
  const add = (count: number, verb: string, singular: string, plural = `${singular}s`) => {
    if (count > 0) clauses.push(`${verb} ${count} ${count === 1 ? singular : plural}`);
  };
  add(activity.edited, "Edited", "file");
  add(activity.ran, "Ran", "command");
  add(activity.read, "Read", "file");
  add(activity.searched, "Searched", "search", "searches");
  add(activity.web, "Fetched", "page");
  add(activity.delegated, "Delegated", "task");
  add(activity.planned, "Planned", "plan");
  return clauses;
}

/**
 * Header label: up to `maxClauses` clauses with the rest rolled into
 * "+N more". Falls back to a step count so the header is never blank.
 */
export function turnActivityLabel(activity: ChatTurnActivity, maxClauses = 2): string {
  const clauses = turnActivityClauses(activity);
  if (!clauses.length) return `${activity.steps} step${activity.steps === 1 ? "" : "s"}`;
  if (clauses.length <= maxClauses) return clauses.join(" · ");
  const shown = clauses.slice(0, maxClauses);
  const shownCount = shown.reduce(
    (sum, clause) => sum + (Number.parseInt(clause.split(" ")[1] ?? "0", 10) || 0), 0,
  );
  const remainder = activity.tools - shownCount;
  return remainder > 0 ? `${shown.join(" · ")} · +${remainder} more` : shown.join(" · ");
}

export function isTurnDurationItem(item: ChatItem): boolean {
  return item.kind === "system" && item.category === "turn_duration";
}

/**
 * Elapsed time for the turn, folded into the "Worked" header instead of a
 * separate system row. One prompt can hold several assistant turns (a
 * background task finishing re-enters the agent), each with its own duration
 * row; those are summed. If a row cannot be parsed, its text is shown as-is.
 */
export function turnDurationLabel(turn: ChatTurn): string | undefined {
  const rows = turn.answers.filter((item): item is Extract<ChatItem, { kind: "system" }> =>
    isTurnDurationItem(item));
  if (!rows.length) return undefined;
  let total = 0;
  for (const row of rows) {
    const ms = parseDuration(row.text);
    if (ms === undefined) return rows[rows.length - 1]!.text.replace(/^turn duration:\s*/i, "").trim() || undefined;
    total += ms;
  }
  return formatDuration(total);
}
