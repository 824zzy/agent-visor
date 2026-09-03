import { describe, expect, it } from "vitest";
import {
  CHAT_IMAGE_MAX_TOTAL_BASE64_CHARS,
  CHAT_PERMISSION_MODE_EXPECTED_MAX_CHARS,
  CHAT_SEND_MAX_ENVELOPE_BYTES,
  CHAT_SEND_MAX_JSON_BYTES_PER_UTF16_UNIT,
  CHAT_SEND_MAX_TEXT_UTF16_UNITS,
  CHAT_SEND_MAX_TEXT_WIRE_BYTES,
  CHAT_SEND_MAX_WIRE_BYTES,
  CHAT_MAX_WIRE_BYTES,
  CHAT_RESPONSE_MAX_ANSWER_ARRAY_ITEMS,
  CHAT_RESPONSE_MAX_ANSWER_CHARS,
  CHAT_RESPONSE_MAX_ANSWER_ITEM_CHARS,
  CHAT_RESPONSE_MAX_ANSWER_KEY_CHARS,
  CHAT_RESPONSE_MAX_ANSWER_KEYS,
  CHAT_RESPONSE_MAX_ANSWER_SCALAR_CHARS,
  CHAT_RESPONSE_MAX_ANSWER_BYTES,
  CHAT_RESPONSE_MAX_WIRE_BYTES,
  CHAT_USAGE_GLANCE_DETAIL_MAX_CHARS,
  CHAT_USAGE_GLANCE_LABEL_MAX_CHARS,
  NATIVE_HELPER_MAX_FRAME_BYTES,
  NATIVE_HELPER_MAX_TEXT_BYTES,
  PROTOCOL_VERSION,
  chatCommandsSchema,
  chatItemSchema,
  chatPageSchema,
  defaultChatVisibility,
  daemonErrorSchema,
  clientMessageSchema,
  nativeServicesStateSchema,
  serverMessageSchema,
  sessionSnapshotSchema,
} from "./index.js";

describe("session snapshot protocol", () => {
  it("keeps native helper limits aligned with the Swift wire contract", () => {
    expect(NATIVE_HELPER_MAX_TEXT_BYTES).toBe(65_536);
    expect(NATIVE_HELPER_MAX_FRAME_BYTES).toBe(1_048_576);
  });

  it("budgets every schema-valid send for worst-case escaped UTF-8 text", () => {
    const escapedText = "\u0000".repeat(CHAT_SEND_MAX_TEXT_UTF16_UNITS);
    const emojiText = "😀".repeat(CHAT_SEND_MAX_TEXT_UTF16_UNITS / 2);
    const escapedTextBytes = new TextEncoder().encode(JSON.stringify(escapedText)).byteLength;
    const emojiTextBytes = new TextEncoder().encode(JSON.stringify(emojiText)).byteLength;

    expect(escapedTextBytes).toBe(CHAT_SEND_MAX_TEXT_WIRE_BYTES);
    expect(escapedTextBytes).toBe(CHAT_SEND_MAX_TEXT_UTF16_UNITS * CHAT_SEND_MAX_JSON_BYTES_PER_UTF16_UNIT + 2);
    expect(emojiTextBytes).toBeLessThan(escapedTextBytes);
    expect(
      CHAT_IMAGE_MAX_TOTAL_BASE64_CHARS + CHAT_SEND_MAX_TEXT_WIRE_BYTES + CHAT_SEND_MAX_ENVELOPE_BYTES,
    ).toBe(CHAT_SEND_MAX_WIRE_BYTES);
  });

  it("accepts one complete macOS session summary", () => {
    const snapshot = {
      type: "session_snapshot",
      revision: 7,
      sessions: [
        {
          id: "pi-123",
          title: "Fix provider timeout",
          subtitle: "Waiting for review",
          source: "Pi",
          project: "agent-visor",
          owner: "Ghostty",
          cwd: "/Users/me/Codes/agent-visor",
          section: "ready",
          updatedAt: "2026-08-22T08:00:00.000Z",
          canOpenOwner: true,
          canEnterChat: true,
        },
      ],
    };

    expect(sessionSnapshotSchema.parse(snapshot)).toEqual(snapshot);
  });

  it("preserves the typed session class in snapshots", () => {
    const snapshot = {
      type: "session_snapshot",
      revision: 7,
      sessions: [{
        id: "codex-exec",
        title: "Headless automation",
        subtitle: "Ready to continue",
        source: "Codex",
        project: "agent-visor",
        owner: "Codex",
        cwd: "/Users/me/Codes/agent-visor",
        section: "ready",
        sessionClass: "automation",
        updatedAt: "2026-08-22T08:00:00.000Z",
        canOpenOwner: true,
        canEnterChat: true,
      }],
    };

    expect(sessionSnapshotSchema.parse(snapshot)).toEqual(snapshot);
  });

  it("rejects unknown sections instead of inventing UI state", () => {
    expect(() =>
      sessionSnapshotSchema.parse({
        type: "session_snapshot",
        revision: 1,
        sessions: [{ section: "almost_done" }],
      }),
    ).toThrow();
  });

  it("validates the versioned hello message", () => {
    expect(
      serverMessageSchema.parse({
        type: "hello",
        protocolVersion: PROTOCOL_VERSION,
      }),
    ).toEqual({ type: "hello", protocolVersion: 1 });
  });

  it("validates bounded daemon response errors with request context", () => {
    const error = {
      type: "daemon_error" as const,
      code: "response_too_large" as const,
      message: "Daemon response exceeded the protocol wire limit.",
      responseType: "chat_page",
      requestType: "open_chat",
      requestId: "request-1",
      sessionId: "session-1",
    };
    expect(daemonErrorSchema.parse(error)).toEqual(error);
    expect(serverMessageSchema.parse(error)).toEqual(error);
    expect(serverMessageSchema.safeParse({ ...error, unexpected: true }).success).toBe(false);
  });

  it("validates paged Chat content and capability-aware actions", () => {
    const page = {
      type: "chat_page",
      sessionId: "session-1",
      items: [
        { id: "user-1", kind: "user", text: "Fix it", images: [], timestamp: "2026-08-22T10:00:00.000Z" },
        { id: "tool-1", kind: "tool", name: "Bash", input: { command: "npm test" }, status: "success", result: "45 passed", timestamp: "2026-08-22T10:00:01.000Z" },
      ],
      hasMoreBefore: true,
      nextBefore: 2048,
      metadata: {
        model: "GPT-5.6-Sol",
        modelId: "gpt-5.6-sol",
        reasoningEffort: "high",
        sandbox: "workspace-write",
        approvalPolicy: "on-request",
        contextTokens: 12_000,
        contextWindow: 258_400,
      },
      capabilities: {
        canSendText: true,
        canSendImages: false,
        canCancel: true,
        cancelDeliveryId: "delivery-1",
        canApprove: true,
        canAnswer: true,
        maxTextBytes: 65_536,
      },
      pendingAction: null,
    };
    expect(chatPageSchema.parse(page)).toEqual(page);
    expect(chatPageSchema.safeParse({ ...page, unexpected: true }).success).toBe(false);
  });

  it("validates labeled subagent and delegation activity items", () => {
    const activity = {
      kind: "activity" as const,
      activity: "subagent" as const,
      id: "fixture-notification",
      title: "fixture-agent",
      text: "Review finished.",
      timestamp: "2026-09-02T07:42:00.000Z",
    };

    expect(chatItemSchema.parse(activity)).toEqual(activity);
    expect(chatItemSchema.parse({ ...activity, activity: "delegation" })).toMatchObject({
      kind: "activity", activity: "delegation",
    });
    expect(chatItemSchema.safeParse({ ...activity, title: "" }).success).toBe(false);
    expect(chatItemSchema.safeParse({ ...activity, text: "" }).success).toBe(false);
  });

  it("keeps activity identity and labels within existing chat item bounds", () => {
    const activity = {
      kind: "activity" as const,
      activity: "delegation" as const,
      id: "i".repeat(512),
      title: "t".repeat(512),
      text: "Delegation complete",
    };

    expect(chatItemSchema.safeParse(activity).success).toBe(true);
    expect(chatItemSchema.safeParse({ ...activity, id: `${activity.id}x` }).success).toBe(false);
    expect(chatItemSchema.safeParse({ ...activity, title: `${activity.title}x` }).success).toBe(false);
  });

  it("validates settings, permission, and update messages", () => {
    const state = {
      type: "native_services_state",
      revision: 3,
      settings: {
        appearance: "dark",
        contentScale: 1.2,
        pillsEnabled: true,
        pillScreen: { mode: "automatic" },
        fullScreenPolicy: "onDemand",
        codexUsageGlanceEnabled: true,
        claudeUsageGlanceEnabled: false,
        notificationSound: "Pop",
        hotkeyTrigger: "shift",
        customHotkeyCombo: null,
        sessionShortcutModifierFamily: "optionCommand",
        editorPreference: "auto",
        observedWindowHours: 42,
        launchAtLogin: false,
        chatVisibility: defaultChatVisibility,
      },
      permissions: { accessibility: "granted", notifications: "authorized" },
      agents: [
        { id: "claude", name: "Claude Code", available: true, installed: true, control: "toggle" },
        { id: "cursor", name: "Cursor", available: true, installed: false, control: "read_only" },
      ],
      pillScreens: [{
        displayId: 1, name: "Built-in Retina Display", isBuiltIn: true, isMain: true,
      }],
      update: { status: "up_to_date", currentVersion: "2.6.2" },
    };
    expect(nativeServicesStateSchema.parse(state)).toEqual(state);
    expect(clientMessageSchema.safeParse({ type: "get_native_services" }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "focus_session", id: "focus-1", sessionId: "pi-123",
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "update_settings", id: "settings-1", patch: {
        appearance: "system",
        chatVisibility: { ...defaultChatVisibility, showThinking: false },
      },
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "native_service_action", id: "native-1", action: "request_accessibility",
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "set_agent_connection", id: "agent-1", agent: "claude", enabled: true,
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "set_agent_connection", id: "agent-2", agent: "cursor", enabled: true,
    }).success).toBe(false);
    expect(clientMessageSchema.safeParse({
      type: "native_service_action", id: "native-2", action: "invented",
    }).success).toBe(false);
  });

  it("carries exact approval identity and responding state for concurrent actions", () => {
    const approval = {
      type: "approval" as const,
      toolUseId: "tool-a",
      approvalId: "codex-request-7",
      responding: true,
      toolName: "Command",
      input: { command: "echo a" },
      canPersist: false,
    };
    const page = {
      type: "chat_page" as const,
      sessionId: "session-1",
      items: [],
      hasMoreBefore: false,
      capabilities: {
        canSendText: false, canSendImages: false, canCancel: false,
        canApprove: true, canAnswer: false,
      },
      pendingAction: approval,
      pendingActions: [approval],
    };
    expect(chatPageSchema.parse(page)).toEqual(page);
    expect(clientMessageSchema.parse({
      type: "respond_chat", id: "response-7", sessionId: "session-1",
      toolUseId: "tool-a", approvalId: "codex-request-7", generation: 3,
      decision: "allow",
    })).toMatchObject({ approvalId: "codex-request-7", generation: 3 });
  });

  it("validates Chat page, send, and response client messages", () => {
    expect(clientMessageSchema.safeParse({
      type: "open_chat", sessionId: "session-1", before: 2048, limit: 500,
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "send_chat", id: "request-1", sessionId: "session-1", generation: 3,
      deliveryId: "delivery-1", text: "Continue", images: [],
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "send_chat", id: "request-1", sessionId: "session-1", text: "Continue", images: [],
    }).success).toBe(false);
    expect(clientMessageSchema.safeParse({
      type: "cancel_chat", id: "cancel-1", sessionId: "session-1", generation: 7, deliveryId: "request-1",
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "respond_chat", id: "request-2", sessionId: "session-1", toolUseId: "tool-1", decision: "allow",
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "respond_chat", id: "request-3", sessionId: "session-1",
      toolUseId: "tool-1", approvalId: "approval-1", generation: 4, decision: "allow",
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "respond_chat", id: "request-2", sessionId: "session-1", toolUseId: "tool-1", decision: "invented",
    }).success).toBe(false);
    expect(serverMessageSchema.safeParse({
      type: "chat_action_result", id: "cancel-1", action: "cancel",
      sessionId: "session-1", generation: 7, deliveryId: "request-1", ok: true,
    }).success).toBe(true);
    expect(serverMessageSchema.safeParse({
      type: "chat_action_result", id: "request-1", action: "send",
      sessionId: "session-1", generation: 3, deliveryId: "delivery-1", ok: true,
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "cycle_permission_mode", id: "cycle-1", sessionId: "claude-1",
      generation: 3, expectedMode: "default",
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "cycle_permission_mode", id: "cycle-2", sessionId: "claude-1",
      generation: 3,
    }).success).toBe(false);
    expect(serverMessageSchema.safeParse({
      type: "chat_action_result", id: "cycle-1", action: "cycle_permission_mode",
      sessionId: "claude-1", generation: 3, ok: true,
    }).success).toBe(true);
    expect(CHAT_PERMISSION_MODE_EXPECTED_MAX_CHARS).toBe(256);
    expect(clientMessageSchema.safeParse({
      type: "cycle_permission_mode", id: "cycle-max", sessionId: "claude-1",
      generation: 3, expectedMode: "x".repeat(CHAT_PERMISSION_MODE_EXPECTED_MAX_CHARS),
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "cycle_permission_mode", id: "cycle-over", sessionId: "claude-1",
      generation: 3, expectedMode: "x".repeat(CHAT_PERMISSION_MODE_EXPECTED_MAX_CHARS + 1),
    }).success).toBe(false);
  });

  it("accepts only bounded provider-authoritative usage metadata", () => {
    expect(CHAT_USAGE_GLANCE_LABEL_MAX_CHARS).toBe(128);
    expect(CHAT_USAGE_GLANCE_DETAIL_MAX_CHARS).toBe(512);
    const usage = {
      provider: "codex",
      percentUsed: 42,
      label: "5h 42% used",
      detail: "Codex usage, 5 hour block 42 percent used",
      observedAt: "2026-08-29T12:00:00.000Z",
    };
    const parsed = chatPageSchema.parse({
      type: "chat_page", sessionId: "codex-1", items: [], hasMoreBefore: false,
      metadata: { model: "GPT-5.6", usageGlance: usage },
      capabilities: {
        canSendText: false, canSendImages: false, canCancel: false,
        canApprove: false, canAnswer: false,
      }, pendingAction: null,
    });
    expect(parsed.metadata?.usageGlance).toEqual(usage);
    expect(chatPageSchema.safeParse({
      ...parsed, metadata: { usageGlance: { ...usage, percentUsed: 101 } },
    }).success).toBe(false);
    expect(chatPageSchema.safeParse({
      ...parsed,
      metadata: {
        usageGlance: {
          ...usage,
          label: "x".repeat(CHAT_USAGE_GLANCE_LABEL_MAX_CHARS + 1),
        },
      },
    }).success).toBe(false);
    expect(chatPageSchema.safeParse({
      ...parsed,
      metadata: {
        usageGlance: {
          ...usage,
          detail: "x".repeat(CHAT_USAGE_GLANCE_DETAIL_MAX_CHARS + 1),
        },
      },
    }).success).toBe(false);
  });

  it("bounds response answers at every nested and aggregate boundary", () => {
    const response = (answers: Record<string, string | string[]>) => ({
      type: "respond_chat" as const,
      id: "request-2",
      sessionId: "session-1",
      toolUseId: "tool-1",
      decision: "answer" as const,
      answers,
    });
    const maxKeys = Object.fromEntries(Array.from({ length: CHAT_RESPONSE_MAX_ANSWER_KEYS }, (_, index) => [
      `q${index}`, "ok",
    ]));
    expect(clientMessageSchema.safeParse(response(maxKeys)).success).toBe(true);
    expect(clientMessageSchema.safeParse(response({
      ...maxKeys,
      extra: "nope",
    })).success).toBe(false);
    expect(clientMessageSchema.safeParse(response({
      [`k${"x".repeat(CHAT_RESPONSE_MAX_ANSWER_KEY_CHARS)}`]: "nope",
    })).success).toBe(false);
    expect(clientMessageSchema.safeParse(response({
      key: "x".repeat(CHAT_RESPONSE_MAX_ANSWER_SCALAR_CHARS),
    })).success).toBe(true);
    expect(clientMessageSchema.safeParse(response({
      key: "x".repeat(CHAT_RESPONSE_MAX_ANSWER_SCALAR_CHARS + 1),
    })).success).toBe(false);
    expect(clientMessageSchema.safeParse(response({
      key: Array.from({ length: CHAT_RESPONSE_MAX_ANSWER_ARRAY_ITEMS }, () => "ok"),
    })).success).toBe(true);
    expect(clientMessageSchema.safeParse(response({
      key: Array.from({ length: CHAT_RESPONSE_MAX_ANSWER_ARRAY_ITEMS + 1 }, () => "ok"),
    })).success).toBe(false);
    expect(clientMessageSchema.safeParse(response({
      key: ["x".repeat(CHAT_RESPONSE_MAX_ANSWER_ITEM_CHARS)],
    })).success).toBe(true);
    expect(clientMessageSchema.safeParse(response({
      key: ["x".repeat(CHAT_RESPONSE_MAX_ANSWER_ITEM_CHARS + 1)],
    })).success).toBe(false);
    // The three keys contribute three UTF-16 units. Distribute the remaining
    // value units across arrays so each per-item and item-count cap is tested.
    const makeItems = (units: number) => [
      ...Array.from({ length: Math.floor(units / CHAT_RESPONSE_MAX_ANSWER_ITEM_CHARS) },
        () => "x".repeat(CHAT_RESPONSE_MAX_ANSWER_ITEM_CHARS)),
      ...(units % CHAT_RESPONSE_MAX_ANSWER_ITEM_CHARS
        ? ["x".repeat(units % CHAT_RESPONSE_MAX_ANSWER_ITEM_CHARS)]
        : []),
    ];
    const exactAggregate = CHAT_RESPONSE_MAX_ANSWER_CHARS - 3;
    const exactAnswers = {
      a: makeItems(409_600),
      b: makeItems(409_600),
      c: makeItems(exactAggregate - 819_200),
    };
    expect(clientMessageSchema.safeParse(response(exactAnswers)).success).toBe(true);
    const overAnswers = { ...exactAnswers, c: [...exactAnswers.c, "x"] };
    expect(clientMessageSchema.safeParse(response(overAnswers)).success).toBe(false);
    expect(CHAT_RESPONSE_MAX_ANSWER_BYTES)
      .toBe(CHAT_RESPONSE_MAX_ANSWER_CHARS * CHAT_SEND_MAX_JSON_BYTES_PER_UTF16_UNIT);
    expect(CHAT_RESPONSE_MAX_WIRE_BYTES).toBeGreaterThan(
      CHAT_RESPONSE_MAX_ANSWER_BYTES,
    );
    expect(CHAT_MAX_WIRE_BYTES).toBe(Math.max(CHAT_SEND_MAX_WIRE_BYTES, CHAT_RESPONSE_MAX_WIRE_BYTES));
  });

  it("validates the lazy, provider-neutral slash command catalog", () => {
    const commands = {
      type: "chat_commands",
      sessionId: "session-1",
      truncated: false,
      commands: [{
        name: "review",
        aliases: [],
        description: "Review the current branch",
        argNames: [],
        source: "builtin",
        isHidden: false,
        opensInTerminalDialog: false,
      }],
    };
    expect(chatCommandsSchema.parse(commands)).toEqual(commands);
    expect(serverMessageSchema.parse(commands)).toEqual(commands);
    expect(chatCommandsSchema.safeParse({ ...commands, truncated: undefined }).success).toBe(false);
    expect(clientMessageSchema.safeParse({
      type: "get_chat_commands", id: "commands-1", sessionId: "session-1",
    }).success).toBe(true);
  });
});
