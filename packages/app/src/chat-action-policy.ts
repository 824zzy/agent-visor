import type { ChatPendingAction, ChatResponseAnswers } from "@agent-visor/protocol";

export function pendingChatActionIdentity(action: ChatPendingAction): string {
  return action.approvalId ?? action.toolUseId;
}

export function chatActionTitle(action: ChatPendingAction, source: string): string {
  if (action.type === "approval") return `${source} asks for approval: ${action.toolName}`;
  return `${source} asks a question`;
}

export { validateQuestionAnswers } from "@agent-visor/protocol";

export function normalizeQuestionAnswers(
  action: Extract<ChatPendingAction, { type: "question" }>,
  answers: ChatResponseAnswers,
): ChatResponseAnswers {
  const normalized: ChatResponseAnswers = {};
  for (const question of action.questions) {
    const value = answers[question.id];
    if (Array.isArray(value)) normalized[question.id] = value.filter((item) => item.trim());
    else if (typeof value === "string") normalized[question.id] = value.trim();
  }
  return normalized;
}
