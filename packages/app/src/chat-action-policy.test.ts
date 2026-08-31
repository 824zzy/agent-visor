import { describe, expect, it } from "vitest";
import type { ChatPendingAction } from "@agent-visor/protocol";
import {
  chatActionTitle,
  normalizeQuestionAnswers,
  pendingChatActionIdentity,
  validateQuestionAnswers,
} from "./chat-action-policy.js";

const question: Extract<ChatPendingAction, { type: "question" }> = {
  type: "question",
  toolUseId: "tool-1",
  approvalId: "approval-1",
  questions: [
    { id: "one", question: "Pick one", choices: ["A", "B"], multiple: false },
    { id: "many", question: "Pick many", choices: ["X", "Y"], multiple: true },
    { id: "text", question: "Explain", choices: [], multiple: false },
  ],
};

describe("Chat action policy", () => {
  it("uses the exact provider approval identity and context title", () => {
    expect(pendingChatActionIdentity(question)).toBe("approval-1");
    expect(chatActionTitle(question, "Codex")).toBe("Codex asks a question");
    expect(chatActionTitle({
      type: "approval", toolUseId: "tool-2", toolName: "Bash", input: {}, canPersist: false,
    }, "Claude Code")).toBe("Claude Code asks for approval: Bash");
  });

  it("rejects incomplete, invalid, and wrong-card answers", () => {
    expect(validateQuestionAnswers(question, {
      one: "C", many: ["X", "Z"], text: "  ", other: "unexpected",
    })).toEqual([
      "Choose an available answer for “Pick one”.",
      "Choose an available answer for “Pick many”.",
      "Answer “Explain”.",
    ]);
    expect(validateQuestionAnswers(question, { one: "A", many: ["X", "Y"], text: "done" })).toEqual([]);
  });

  it("trims text answers and preserves multiple-choice arrays", () => {
    expect(normalizeQuestionAnswers(question, { one: " A ", many: ["X", "", "Y"], text: " explain " }))
      .toEqual({ one: "A", many: ["X", "Y"], text: "explain" });
  });
});
