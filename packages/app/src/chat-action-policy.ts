import type { ChatPendingAction, ChatResponseAnswers } from "@agent-visor/protocol";

export function pendingChatActionIdentity(action: ChatPendingAction): string {
  return action.approvalId ?? action.toolUseId;
}

export function chatActionTitle(action: ChatPendingAction, source: string): string {
  if (action.type === "approval") return `${source} asks for approval: ${action.toolName}`;
  return `${source} asks a question`;
}

/** Validate the complete answer map before it crosses the daemon seam. */
export function validateQuestionAnswers(
  action: Extract<ChatPendingAction, { type: "question" }>,
  answers: ChatResponseAnswers,
): string[] {
  const errors: string[] = [];
  for (const question of action.questions) {
    const answer = answers[question.id];
    if (question.choices.length) {
      const selected = Array.isArray(answer) ? answer : typeof answer === "string" ? [answer] : [];
      if (!selected.length) {
        errors.push(`Answer “${question.question}”.`);
        continue;
      }
      if (!question.multiple && selected.length !== 1) {
        errors.push(`Choose one answer for “${question.question}”.`);
      }
      if (selected.some((value) => !question.choices.includes(value))) {
        errors.push(`Choose an available answer for “${question.question}”.`);
      }
    } else if (typeof answer !== "string" || !answer.trim()) {
      errors.push(`Answer “${question.question}”.`);
    }
  }
  return errors;
}

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
