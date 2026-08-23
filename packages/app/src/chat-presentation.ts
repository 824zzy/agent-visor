import type { ChatItem } from "@agent-visor/protocol";

export type ChatTurn = {
  id: string;
  prompt?: Extract<ChatItem, { kind: "user" }>;
  work: ChatItem[];
  answers: ChatItem[];
  live: boolean;
};

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
