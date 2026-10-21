import { describe, expect, it } from "vitest";
import type { SessionSummary } from "@agent-visor/protocol";
import {
  chatSessionFor,
  reduceChatSelection,
  type ChatSelection,
} from "./chat-selection.js";

const session = (id: string, overrides: Partial<SessionSummary> = {}): SessionSummary => ({
  id,
  title: `${id} transcript`,
  subtitle: "Closed terminal conversation",
  source: "Claude Code",
  project: "agent-visor",
  owner: "Ghostty",
  cwd: "/Users/me/Codes/agent-visor",
  section: "history",
  sessionClass: "terminal",
  ambientEligible: false,
  updatedAt: "2026-10-21T18:00:00.000Z",
  canOpenOwner: false,
  canEnterChat: true,
  ...overrides,
});

describe("Chat selection", () => {
  it("keeps the exact historical Chat displayed when a refresh replaces its page", () => {
    const historical = session("historical", { title: "Selected transcript" });
    const unrelated = session("unrelated", { title: "Unrelated transcript" });
    let selection: ChatSelection = {};

    selection = reduceChatSelection(selection, { type: "open", session: historical });
    expect(chatSessionFor(selection, [historical])?.id).toBe("historical");

    // The unrelated live row closes. History refreshes page one and evicts the
    // selected later-page row from the current browser membership.
    selection = reduceChatSelection(selection, { type: "refresh", sessions: [unrelated] });
    expect(chatSessionFor(selection, [unrelated])).toMatchObject({
      id: "historical",
      title: "Selected transcript",
      canOpenOwner: false,
      canEnterChat: false,
    });
  });

  it("prefers an exact fresh summary and keeps explicit navigation and back behavior", () => {
    const historical = session("historical", { title: "Selected transcript" });
    const fresh = session("historical", {
      title: "Fresh transcript",
      section: "ready",
      canOpenOwner: true,
    });
    const other = session("other", { title: "Other transcript", canEnterChat: true });
    let selection: ChatSelection = reduceChatSelection({}, { type: "open", session: historical });

    selection = reduceChatSelection(selection, { type: "refresh", sessions: [fresh] });
    expect(chatSessionFor(selection, [fresh])).toBe(fresh);

    selection = reduceChatSelection(selection, {
      type: "navigate",
      sessionId: "other",
      sessions: [other],
    });
    expect(chatSessionFor(selection, [other])).toBe(other);

    selection = reduceChatSelection(selection, { type: "back" });
    expect(chatSessionFor(selection, [other])).toBeUndefined();
  });

  it("clears an explicit navigation target when its summary is unresolved", () => {
    const selection = reduceChatSelection({}, {
      type: "navigate",
      sessionId: "missing",
      sessions: [],
    });

    // An unresolved native navigation must return to Sessions rather than
    // leaving the browser hidden behind an empty Chat surface.
    expect(selection).toEqual({});
  });
});
