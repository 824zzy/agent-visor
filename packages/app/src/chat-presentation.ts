import type {
  ChatItem,
  ChatMetadata,
  ChatPage,
  ChatVisibility,
} from "@agent-visor/protocol";

export type ChatMetadataRow = { label: string; value: string };

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

export function filterChatItems(items: ChatItem[], rules: ChatVisibility): ChatItem[] {
  return items.filter((item) => {
    if (item.kind === "user") return rules.showUserMessage;
    if (item.kind === "assistant") return rules.showAssistantMessage;
    if (item.kind === "thinking") return rules.showThinking;
    if (item.kind === "tool") return rules[toolVisibilitySetting(item)];
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
    let lastWork = -1;
    for (let index = 0; index < body.length; index += 1) {
      if (["thinking", "tool"].includes(body[index]!.kind)) lastWork = index;
    }
    const work = body.filter((item, index) =>
      item.kind === "thinking" || item.kind === "tool"
      || (item.kind === "assistant" && index <= lastWork));
    const answers = body.filter((item, index) =>
      (item.kind === "assistant" && index > lastWork) || item.kind === "system");
    turns.push({
      id: prompt?.id ?? body[0]!.id,
      ...(prompt ? { prompt } : {}),
      work,
      answers,
      live: body.length > 0 && answers.length === 0,
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
  };
}

export function mergeChatLatest(current: ChatItem[], incoming: ChatItem[]): ChatItem[] {
  const incomingIDs = new Set(incoming.map(({ id }) => id));
  const overlap = current.findIndex(({ id }) => incomingIDs.has(id));
  return overlap < 0 ? incoming : [...current.slice(0, overlap), ...incoming];
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
