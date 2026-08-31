import { describe, expect, it } from "vitest";
import { chatStatusSummary, contextSummary, nextPermissionMode } from "./chat-status.js";

describe("Chat status summary", () => {
  it("shows resolved model, effort, context, and Claude permission mode", () => {
    const summary = chatStatusSummary(
      { source: "Claude Code", project: "agent-visor", cwd: "/tmp/agent-visor" },
      {
        model: "Sonnet 4.6",
        modelId: "claude-sonnet-4-6",
        reasoningEffort: "high",
        permissionMode: "acceptEdits",
        contextTokens: 12_000,
        contextWindow: 100_000,
      },
      { canSendText: true },
    );
    expect(summary).toMatchObject({
      model: "Sonnet 4.6",
      effort: "high",
      permission: { raw: "acceptEdits", label: "Accept Edits" },
      context: { percent: 12, label: "12,000 / 100,000 tokens (12%)" },
      project: "agent-visor",
      source: "Claude Code",
      path: "/tmp/agent-visor",
      readOnly: false,
    });
    expect(summary.accessibilityLabel).toContain("Permission Accept Edits");
  });

  it("gates permission presentation by provider and keeps invalid context absent", () => {
    const summary = chatStatusSummary(
      { source: "Codex", project: "project", cwd: "/tmp/project" },
      { permissionMode: "dangerouslySkipPermissions", contextTokens: 100, contextWindow: 10 },
      { canSendText: false, readOnlyReason: "This session has ended." },
    );
    expect(summary.permission).toBeUndefined();
    expect(summary.context).toBeUndefined();
    expect(summary.readOnly).toBe(true);
    expect(summary.readOnlyReason).toBe("This session has ended.");
    expect(contextSummary(0, 100)).toBeUndefined();
  });

  it("shows only provider-matching authoritative usage", () => {
    const usage = {
      provider: "codex" as const,
      percentUsed: 39,
      label: "5h 82% | 7d 61%",
      detail: "Codex usage",
      observedAt: "2026-08-24T12:00:00.000Z",
    };
    expect(chatStatusSummary(
      { source: "Codex", project: "project", cwd: "/tmp/project" },
      { usageGlance: usage },
      { canSendText: false },
    ).usage).toEqual(usage);
    expect(chatStatusSummary(
      { source: "Claude Code", project: "project", cwd: "/tmp/project" },
      { usageGlance: usage },
      { canSendText: true },
    ).usage).toBeUndefined();
  });

  it("uses the Swift Claude permission cycle and fails closed for unknown modes", () => {
    expect(nextPermissionMode("default")).toBe("acceptEdits");
    expect(nextPermissionMode("acceptEdits")).toBe("plan");
    expect(nextPermissionMode("plan")).toBe("default");
    expect(nextPermissionMode("bypassPermissions")).toBe("default");
    expect(nextPermissionMode("enterpriseFutureMode")).toBeUndefined();
  });
});
