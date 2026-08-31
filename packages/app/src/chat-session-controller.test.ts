import { describe, expect, it } from "vitest";
import type { ChatPage } from "@agent-visor/protocol";
import { createChatSessionController } from "./chat-session-controller.js";

const page = (sessionId: string, text: string): ChatPage => ({
  type: "chat_page",
  sessionId,
  items: [{ id: `${sessionId}-item`, kind: "assistant", text }],
  hasMoreBefore: false,
  capabilities: {
    canSendText: true,
    canSendImages: false,
    canCancel: false,
    canApprove: false,
    canAnswer: false,
  },
  pendingAction: null,
});

describe("Chat session controller", () => {
  it("sends one identity-bound cancel request only for a working cancellable page", () => {
    const states: Array<ReturnType<typeof createChatSessionController>["currentState"] extends () => infer T ? T : never> = [];
    const sent: string[] = [];
    const controller = createChatSessionController({
      onState: (state) => states.push(state),
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, { createRequestId: () => "cancel-1" });
    const transport = {
      close: () => undefined,
      send: (data: string) => { sent.push(data); return true; },
    };
    const generation = controller.activate("session", "working");
    controller.receive(generation, JSON.stringify({
      ...page("session", "working"),
      capabilities: {
        ...page("session", "working").capabilities,
        canCancel: true,
        cancelDeliveryId: "send-1",
      },
    }), transport);
    controller.noteDelivery(generation, "send-1");

    expect(controller.requestCancel(generation, transport)).toBe(true);
    expect(controller.requestCancel(generation, transport)).toBe(false);
    expect(sent).toHaveLength(1);
    expect(JSON.parse(sent[0]!)).toEqual({
      type: "cancel_chat",
      id: "cancel-1",
      sessionId: "session",
      generation,
      deliveryId: "send-1",
    });
    expect(controller.currentState()).toMatchObject({
      cancel: { status: "canceling", requestId: "cancel-1", generation, deliveryId: "send-1" },
    });
    expect(states.at(-1)).toMatchObject({ cancel: { status: "canceling" } });
  });

  it("cycles Claude permission mode with exact request identity and canonical confirmation", () => {
    const sent: string[] = [];
    let latestRequestId: string | undefined;
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: (_connection, _sessionId, requestId) => { latestRequestId = requestId; },
    }, { createRequestId: () => "cycle-1" });
    const transport = { close: () => undefined, send: (data: string) => { sent.push(data); return true; } };
    const generation = controller.activate("claude", "working");
    controller.receive(generation, JSON.stringify({
      ...page("claude", "working"),
      metadata: { permissionMode: "default" },
      capabilities: {
        ...page("claude", "working").capabilities,
        canCyclePermissionMode: true,
      },
    }), transport);

    expect(controller.requestCyclePermissionMode(generation, transport)).toBe(true);
    expect(JSON.parse(sent[0]!)).toEqual({
      type: "cycle_permission_mode",
      id: "cycle-1",
      sessionId: "claude",
      generation,
      expectedMode: "default",
    });
    expect(controller.currentState()).toMatchObject({
      optimisticPermissionMode: "acceptEdits",
      permissionModeCycle: {
        status: "cycling", requestId: "cycle-1", generation,
        expectedMode: "default", nextMode: "acceptEdits",
      },
    });

    controller.receive(generation, JSON.stringify({
      type: "chat_action_result", id: "wrong", action: "cycle_permission_mode",
      sessionId: "claude", generation, ok: true,
    }), transport);
    expect(controller.currentState().permissionModeCycle?.status).toBe("cycling");

    controller.receive(generation, JSON.stringify({
      type: "chat_action_result", id: "cycle-1", action: "cycle_permission_mode",
      sessionId: "claude", generation, ok: true,
    }), transport);
    expect(controller.currentState().permissionModeCycle).toBeUndefined();
    expect(controller.currentState().optimisticPermissionMode).toBe("acceptEdits");
    expect(latestRequestId).toBeDefined();

    controller.receive(generation, JSON.stringify({
      ...page("claude", "updated"),
      requestId: latestRequestId,
      mode: "latest",
      metadata: { permissionMode: "acceptEdits" },
      capabilities: { ...page("claude", "updated").capabilities, canCyclePermissionMode: true },
    }), transport);
    expect(controller.currentState().optimisticPermissionMode).toBeUndefined();
  });

  it("ignores a permission-cycle result from another session or generation", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, { createRequestId: () => "cycle-exact" });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("claude", "working");
    controller.receive(generation, JSON.stringify({
      ...page("claude", "working"), metadata: { permissionMode: "plan" },
      capabilities: { ...page("claude", "working").capabilities, canCyclePermissionMode: true },
    }), transport);
    controller.requestCyclePermissionMode(generation, transport);
    controller.receive(generation, JSON.stringify({
      type: "chat_action_result", id: "cycle-exact", action: "cycle_permission_mode",
      sessionId: "other", generation, ok: true,
    }), transport);
    expect(controller.currentState().permissionModeCycle).toBeDefined();
    controller.receive(generation, JSON.stringify({
      type: "chat_action_result", id: "cycle-exact", action: "cycle_permission_mode",
      sessionId: "claude", generation: generation + 1, ok: true,
    }), transport);
    expect(controller.currentState().permissionModeCycle).toBeDefined();
  });

  it("shows Stop only when the page's active cancellation delivery matches the current delivery", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, { createRequestId: () => "request-1", createDeliveryId: () => "send-1" });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    const workingPage = {
      ...page("session", "working"),
      capabilities: {
        ...page("session", "working").capabilities,
        canCancel: true,
        cancelDeliveryId: "send-1",
      },
    };
    controller.receive(generation, JSON.stringify(workingPage), transport);
    controller.noteDelivery(generation, "send-1");
    expect(controller.requestCancel(generation, transport)).toBe(true);

    const mismatch = {
      ...workingPage,
      capabilities: { ...workingPage.capabilities, cancelDeliveryId: "other-delivery" },
    };
    const next = controller.activate("session", "working");
    controller.receive(next, JSON.stringify(mismatch), transport);
    controller.noteDelivery(next, "send-1");
    expect(controller.requestCancel(next, transport)).toBe(false);

    const missing = controller.activate("session", "working");
    const missingIdentityPage = {
      ...page("session", "working"),
      capabilities: { ...page("session", "working").capabilities, canCancel: true },
    };
    controller.receive(missing, JSON.stringify(missingIdentityPage), transport);
    expect(controller.currentState().canCancelForActiveDelivery).toBeUndefined();
    controller.noteDelivery(missing, "send-1");
    expect(controller.currentState().canCancelForActiveDelivery).toBeUndefined();
    controller.receive(missing, JSON.stringify(missingIdentityPage), transport);
    expect(controller.currentState().canCancelForActiveDelivery).toBeUndefined();
    expect(controller.requestCancel(missing, transport)).toBe(false);
  });

  it("does not transfer delivery A cancellation to a new delivery B before daemon confirmation", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, {
      createRequestId: (() => {
        const ids = ["request-b", "cancel-b"];
        return () => ids.shift() ?? "unexpected-request";
      })(),
      createDeliveryId: () => "delivery-b",
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    const pageA = {
      ...page("session", "delivery A working"),
      capabilities: {
        ...page("session", "delivery A working").capabilities,
        canCancel: true,
        cancelDeliveryId: "delivery-a",
      },
    };
    controller.receive(generation, JSON.stringify(pageA), transport);
    controller.noteDelivery(generation, "delivery-a");
    expect(controller.currentState().canCancelForActiveDelivery).toBe(true);

    expect(controller.beginDelivery(generation, { text: "delivery B", images: [] })).toMatchObject({
      requestId: "request-b",
      deliveryId: "delivery-b",
    });
    expect(controller.currentState().page?.capabilities.cancelDeliveryId).toBe("delivery-a");
    expect(controller.currentState().canCancelForActiveDelivery).toBeUndefined();
    expect(controller.requestCancel(generation, transport)).toBe(false);

    // A delayed page for A must not make the new B submission cancellable.
    controller.receive(generation, JSON.stringify(pageA), transport);
    expect(controller.currentState().canCancelForActiveDelivery).toBeUndefined();
    expect(controller.requestCancel(generation, transport)).toBe(false);

    const pageB = {
      ...page("session", "delivery B working"),
      capabilities: {
        ...page("session", "delivery B working").capabilities,
        canCancel: true,
        cancelDeliveryId: "delivery-b",
      },
    };
    controller.receive(generation, JSON.stringify(pageB), transport);
    expect(controller.currentState()).toMatchObject({
      activeDeliveryId: "delivery-b",
      canCancelForActiveDelivery: true,
    });
    expect(controller.requestCancel(generation, transport)).toBe(true);
  });

  it("adopts an existing server-provided active delivery on initial page load", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.receive(generation, JSON.stringify({
      ...page("session", "working"),
      capabilities: {
        ...page("session", "working").capabilities,
        canCancel: true,
        cancelDeliveryId: "existing-delivery",
      },
    }), transport);
    expect(controller.currentState()).toMatchObject({
      activeDeliveryId: "existing-delivery",
      canCancelForActiveDelivery: true,
    });
  });

  it("keeps an exact provider cancel capability after canonical reconciliation", () => {
    const sent: string[] = [];
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, {
      createRequestId: (() => {
        const ids = ["request-1", "cancel-1"];
        return () => ids.shift() ?? "unexpected-request";
      })(),
      createDeliveryId: () => "delivery-1",
    });
    const transport = { close: () => undefined, send: (data: string) => { sent.push(data); return true; } };
    const generation = controller.activate("session", "working");
    controller.receive(generation, JSON.stringify({
      ...page("session", "working"),
      capabilities: { ...page("session", "working").capabilities, canCancel: true, cancelDeliveryId: "delivery-1" },
    }), transport);
    controller.noteComposerDraft(generation, { text: "turn", images: [] });
    const delivery = controller.beginDelivery(generation, { text: "turn", images: [] });
    expect(delivery).toMatchObject({ deliveryId: expect.any(String) });
    const deliveryId = delivery!.deliveryId;
    controller.receive(generation, JSON.stringify({
      ...page("session", "working"),
      items: [{ id: "canonical-1", kind: "user", text: "turn", images: [], requestId: delivery!.requestId, deliveryId }],
      capabilities: { ...page("session", "working").capabilities, canCancel: true, cancelDeliveryId: deliveryId },
    }), transport);

    expect(controller.currentState().canCancelForActiveDelivery).toBe(true);
    expect(controller.requestCancel(generation, transport)).toBe(true);
    expect(JSON.parse(sent.at(-1)!)).toMatchObject({ type: "cancel_chat", deliveryId });
  });

  it("requires the matching cancel identity and exposes confirmed or failed results", () => {
    const opened: string[] = [];
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: (_connection, sessionId) => opened.push(sessionId),
    }, { createRequestId: () => "cancel-2" });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.receive(generation, JSON.stringify({
      ...page("session", "working"),
      capabilities: {
        ...page("session", "working").capabilities,
        canCancel: true,
        cancelDeliveryId: "send-2",
      },
    }), transport);
    controller.noteDelivery(generation, "send-2");
    controller.requestCancel(generation, transport);

    controller.receive(generation, JSON.stringify({
      type: "chat_action_result", id: "wrong", action: "cancel", sessionId: "session",
      generation, deliveryId: "send-2", ok: true,
    }), transport);
    expect(controller.currentState().cancel?.status).toBe("canceling");

    controller.receive(generation, JSON.stringify({
      type: "chat_action_result", id: "cancel-2", action: "cancel", sessionId: "session",
      generation, deliveryId: "send-2", ok: true,
    }), transport);
    expect(controller.currentState()).toMatchObject({ cancel: { status: "confirmed" } });
    expect(opened).toEqual(["session"]);

    const second = controller.activate("session", "working");
    controller.receive(second, JSON.stringify({
      ...page("session", "working"),
      capabilities: {
        ...page("session", "working").capabilities,
        canCancel: true,
        cancelDeliveryId: "send-3",
      },
    }), transport);
    controller.noteDelivery(second, "send-3");
    controller.requestCancel(second, transport);
    controller.receive(second, JSON.stringify({
      type: "chat_action_result", id: "cancel-2", action: "cancel", sessionId: "session",
      generation: second, deliveryId: "send-3", ok: false, error: "The turn could not be cancelled.",
    }), transport);
    expect(controller.currentState()).toMatchObject({
      cancel: { status: "failed", requestId: "cancel-2" },
      error: "The turn could not be cancelled.",
    });
  });

  it("keeps a confirmed cancellation visible across its transcript refresh", () => {
    let latestRequestId: string | undefined;
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: (_connection, _sessionId, requestId) => { latestRequestId = requestId; },
    }, { createRequestId: () => "cancel-refresh" });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.receive(generation, JSON.stringify({
      ...page("session", "working"),
      capabilities: {
        ...page("session", "working").capabilities,
        canCancel: true,
        cancelDeliveryId: "send-refresh",
      },
    }), transport);
    controller.noteDelivery(generation, "send-refresh");

    expect(controller.requestCancel(generation, transport)).toBe(true);
    controller.receive(generation, JSON.stringify({
      type: "chat_action_result",
      id: "cancel-refresh",
      action: "cancel",
      sessionId: "session",
      generation,
      deliveryId: "send-refresh",
      ok: true,
    }), transport);
    expect(controller.currentState().cancel?.status).toBe("confirmed");

    controller.receive(generation, JSON.stringify({
      ...page("session", "refreshed transcript"),
      requestId: latestRequestId,
      mode: "latest",
      capabilities: { ...page("session", "refreshed transcript").capabilities, canCancel: true },
    }), transport);
    expect(controller.currentState()).toMatchObject({
      cancel: { status: "confirmed", requestId: "cancel-refresh" },
      page: { items: [{ text: "refreshed transcript" }] },
    });
  });

  it("keeps a failed cancellation error visible across its transcript refresh", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, { createRequestId: () => "cancel-failed-refresh" });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    const workingPage = {
      ...page("session", "working"),
      capabilities: {
        ...page("session", "working").capabilities,
        canCancel: true,
        cancelDeliveryId: "send-failed-refresh",
      },
    };
    controller.receive(generation, JSON.stringify(workingPage), transport);
    controller.noteDelivery(generation, "send-failed-refresh");

    expect(controller.requestCancel(generation, transport)).toBe(true);
    controller.receive(generation, JSON.stringify({
      type: "chat_action_result",
      id: "cancel-failed-refresh",
      action: "cancel",
      sessionId: "session",
      generation,
      deliveryId: "send-failed-refresh",
      ok: false,
      error: "The turn could not be cancelled.",
    }), transport);
    expect(controller.currentState()).toMatchObject({
      cancel: { status: "failed", requestId: "cancel-failed-refresh" },
      error: "The turn could not be cancelled.",
    });

    controller.receive(generation, JSON.stringify({
      ...workingPage,
      items: [{ id: "session-refreshed", kind: "assistant", text: "refreshed after failed cancel" }],
    }), transport);
    expect(controller.currentState()).toMatchObject({
      cancel: { status: "failed", requestId: "cancel-failed-refresh" },
      error: "The turn could not be cancelled.",
      page: { items: [
        { id: "session-item", text: "working" },
        { id: "chat-history-gap", kind: "system" },
        { id: "session-refreshed", text: "refreshed after failed cancel" },
      ] },
    });
  });

  it("clears the prior cancellation outcome when a new delivery begins", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, {
      createRequestId: (() => {
        let serial = 0;
        return () => `request-${++serial}`;
      })(),
      createDeliveryId: (() => {
        let serial = 0;
        return () => `delivery-${++serial}`;
      })(),
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    const workingPage = {
      ...page("session", "working"),
      capabilities: {
        ...page("session", "working").capabilities,
        canCancel: true,
        cancelDeliveryId: "send-new-delivery",
      },
    };
    controller.receive(generation, JSON.stringify(workingPage), transport);
    controller.noteDelivery(generation, "send-new-delivery");
    expect(controller.requestCancel(generation, transport)).toBe(true);
    controller.receive(generation, JSON.stringify({
      type: "chat_action_result",
      id: "request-1",
      action: "cancel",
      sessionId: "session",
      generation,
      deliveryId: "send-new-delivery",
      ok: false,
      error: "The turn could not be cancelled.",
    }), transport);
    expect(controller.currentState().cancel?.status).toBe("failed");

    expect(controller.beginDelivery(generation, { text: "new turn", images: [] })).toMatchObject({
      requestId: "request-2",
      deliveryId: "delivery-1",
    });
    expect(controller.currentState().cancel).toBeUndefined();
    expect(controller.currentState().error).toBeUndefined();
  });

  it("fails closed for ready or non-cancellable sessions and ignores old generations", () => {
    const sent: string[] = [];
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, { createRequestId: () => "cancel-3" });
    const transport = {
      close: () => undefined,
      send: (data: string) => { sent.push(data); return true; },
    };
    const first = controller.activate("first", "working");
    controller.receive(first, JSON.stringify(page("first", "not cancellable")), transport);
    expect(controller.requestCancel(first, transport)).toBe(false);

    const second = controller.activate("second", "ready");
    controller.receive(second, JSON.stringify({
      ...page("second", "ready"),
      capabilities: { ...page("second", "ready").capabilities, canCancel: true },
    }), transport);
    expect(controller.requestCancel(second, transport)).toBe(false);
    controller.receive(first, JSON.stringify({
      type: "chat_action_result", id: "cancel-3", action: "cancel", sessionId: "first",
      generation: first, ok: true,
    }), transport);
    expect(sent).toEqual([]);
    expect(controller.currentState()).toEqual({ sessionId: "second", status: "loaded", page: expect.anything() });
  });

  it("resets on session reuse and ignores late callbacks from the old session", () => {
    const states: Array<{ sessionId: string; status: string; page?: ChatPage; error?: string }> = [];
    const controller = createChatSessionController({
      onState: (state) => states.push(state),
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };

    const firstGeneration = controller.activate("first");
    controller.receive(firstGeneration, JSON.stringify(page("first", "old content")), transport);
    expect(controller.currentState()).toMatchObject({
      sessionId: "first",
      status: "loaded",
      page: { items: [{ text: "old content" }] },
    });

    const secondGeneration = controller.activate("second");
    expect(controller.currentState()).toEqual({ sessionId: "second", status: "loading" });

    controller.receive(firstGeneration, JSON.stringify(page("first", "late old content")), transport);
    controller.receive(firstGeneration, JSON.stringify({
      type: "chat_action_result",
      id: "old-action",
      ok: false,
      error: "old failure",
    }), transport);
    expect(controller.currentState()).toEqual({ sessionId: "second", status: "loading" });

    controller.receive(secondGeneration, JSON.stringify(page("second", "new content")), transport);
    expect(controller.currentState()).toMatchObject({
      sessionId: "second",
      status: "loaded",
      page: { items: [{ text: "new content" }] },
    });
    expect(states.some((state) => state.error === "old failure")).toBe(false);
  });

  it("accepts the initial page only after registering its request identity", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");

    controller.requestLatest(generation, "initial-page");
    controller.receive(generation, JSON.stringify({
      ...page("session", "initial content"),
      requestId: "initial-page",
      mode: "latest",
    }), transport);

    expect(controller.currentState()).toMatchObject({
      status: "loaded",
      page: { items: [{ text: "initial content" }] },
    });
  });

  it("does not reconcile an optimistic delivery from an earlier, non-authoritative page", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, {
      createRequestId: () => "send-1",
      createDeliveryId: () => "delivery-1",
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.receive(generation, JSON.stringify({
      ...page("session", "baseline"),
      items: [{ id: "old-user", kind: "user", text: "repeat", images: [] }],
    }), transport);
    const delivery = controller.beginDelivery(generation, { text: "repeat", images: [] })!;
    controller.requestEarlier(generation, "earlier-1");

    controller.receive(generation, JSON.stringify({
      ...page("session", "earlier response"),
      requestId: "earlier-1",
      mode: "earlier",
      items: [{ id: "old-user", kind: "user", text: "repeat", images: [] }],
    }), transport);

    expect(controller.currentState().page?.items).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: delivery.optimisticRowId, text: "repeat" }),
      expect.objectContaining({ id: "old-user", text: "repeat" }),
    ]));
    expect(controller.currentState().page?.items.filter((item) => item.id === delivery.optimisticRowId)).toHaveLength(1);
  });

  it("associates out-of-order page responses with their exact latest/earlier request", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.receive(generation, JSON.stringify(page("session", "baseline")), transport);
    controller.requestEarlier(generation, "earlier-1");

    controller.receive(generation, JSON.stringify({
      ...page("session", "unrelated latest"),
      requestId: "unknown-latest",
      mode: "latest",
    }), transport);
    expect(controller.currentState().page?.items).toMatchObject([{ text: "baseline" }]);

    controller.receive(generation, JSON.stringify({
      ...page("session", "authoritative earlier"),
      requestId: "earlier-1",
      mode: "earlier",
    }), transport);
    expect(controller.currentState().page?.items).toMatchObject([{ text: "authoritative earlier" }]);
    expect(controller.currentState().page?.items.some((item) => item.kind === "user" && item.text === "baseline")).toBe(false);
  });

  it("rejects a page whose mode does not match its registered request", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.receive(generation, JSON.stringify(page("session", "baseline")), transport);
    controller.requestEarlier(generation, "earlier-1");

    controller.receive(generation, JSON.stringify({
      ...page("session", "wrong latest response"),
      requestId: "earlier-1",
      mode: "latest",
    }), transport);

    expect(controller.currentState().page?.items).toMatchObject([{ text: "baseline" }]);
  });

  it("rejects an earlier page for a registered latest request before merging", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.receive(generation, JSON.stringify(page("session", "baseline")), transport);
    controller.requestLatest(generation, "latest-1");

    controller.receive(generation, JSON.stringify({
      ...page("session", "wrong earlier response"),
      requestId: "latest-1",
      mode: "earlier",
    }), transport);

    expect(controller.currentState().page?.items).toMatchObject([{ text: "baseline" }]);
  });

  it("ignores an older latest page after a newer latest request publishes", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");

    controller.requestLatest(generation, "latest-r1");
    controller.requestLatest(generation, "latest-r2");
    controller.receive(generation, JSON.stringify({
      ...page("session", "u3"),
      requestId: "latest-r2",
      mode: "latest",
      items: [{ id: "u3", kind: "user", text: "u3", images: [] }],
    }), transport);
    controller.receive(generation, JSON.stringify({
      ...page("session", "stale-u1"),
      requestId: "latest-r1",
      mode: "latest",
      items: [{ id: "u1", kind: "user", text: "stale-u1", images: [] }],
    }), transport);

    expect(controller.currentState().page?.items).toEqual([
      expect.objectContaining({ id: "u3", text: "u3" }),
    ]);
  });

  it("expires no-response page requests and rejects their late page and error", () => {
    let now = 0;
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, { deliveryClock: { now: () => now } });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.requestLatest(generation, "expired-page");
    now = 61_000;

    controller.receive(generation, JSON.stringify({
      ...page("session", "late page"),
      requestId: "expired-page",
      mode: "latest",
    }), transport);
    controller.receive(generation, JSON.stringify({
      type: "daemon_error",
      code: "invalid_response",
      message: "late page error",
      responseType: "chat_page",
      requestType: "open_chat",
      requestId: "expired-page",
      sessionId: "session",
    }), transport);

    expect(controller.currentState()).toEqual({ sessionId: "session", status: "loading" });
  });

  it("clears open-page identities on disconnect so a late response cannot apply after reconnect", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.requestLatest(generation, "before-disconnect");
    controller.disconnect(generation);

    controller.receive(generation, JSON.stringify({
      ...page("session", "late disconnected page"),
      requestId: "before-disconnect",
      mode: "latest",
    }), transport);
    expect(controller.currentState()).toEqual({ sessionId: "session", status: "loading" });

    controller.requestLatest(generation, "after-reconnect");
    controller.receive(generation, JSON.stringify({
      ...page("session", "fresh page"),
      requestId: "after-reconnect",
      mode: "latest",
    }), transport);
    expect(controller.currentState()).toMatchObject({
      status: "loaded", page: { items: [{ text: "fresh page" }] },
    });
  });

  it("forwards slash catalog truncation without inventing a result count", () => {
    let received: unknown;
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: (catalog) => { received = catalog; },
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify({
      type: "chat_commands",
      sessionId: "session",
      commands: [],
      truncated: true,
    }), transport);

    expect(received).toEqual(expect.objectContaining({ commands: [], truncated: true }));
  });

  it("surfaces a bounded daemon response error for its active session", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify({
      type: "daemon_error",
      code: "response_too_large",
      message: "Daemon response exceeded the protocol wire limit.",
      responseType: "chat_page",
      requestType: "open_chat",
      sessionId: "session",
    }), transport);

    expect(controller.currentState()).toMatchObject({
      sessionId: "session",
      status: "failed",
      error: "Daemon response exceeded the protocol wire limit.",
    });
  });

  it("accepts an active Chat-page error when responseType is absent", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify({
      type: "daemon_error",
      code: "invalid_response",
      message: "Daemon produced an invalid protocol response.",
      requestType: "open_chat",
      sessionId: "session",
    }), transport);

    expect(controller.currentState()).toMatchObject({
      sessionId: "session",
      status: "failed",
      error: "Daemon produced an invalid protocol response.",
    });
  });

  it("accepts a request-scoped Chat page error for the registered latest page", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");
    controller.requestLatest(generation, "page-request");

    controller.receive(generation, JSON.stringify({
      type: "daemon_error",
      code: "invalid_response",
      message: "Daemon produced an invalid protocol response.",
      responseType: "chat_page",
      requestType: "open_chat",
      requestId: "page-request",
      sessionId: "session",
    }), transport);

    expect(controller.currentState()).toMatchObject({
      sessionId: "session",
      status: "failed",
      error: "Daemon produced an invalid protocol response.",
    });
  });

  it("ignores stale or mismatched Chat-page errors across session generations", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const firstGeneration = controller.activate("first");
    controller.receive(firstGeneration, JSON.stringify({
      type: "daemon_error",
      code: "response_too_large",
      message: "old session response",
      responseType: "chat_page",
      requestType: "open_chat",
      sessionId: "other",
    }), transport);
    expect(controller.currentState()).toEqual({ sessionId: "first", status: "loading" });

    const secondGeneration = controller.activate("second");
    controller.receive(firstGeneration, JSON.stringify({
      type: "daemon_error",
      code: "invalid_response",
      message: "late first response",
      responseType: "chat_page",
      requestType: "open_chat",
      sessionId: "first",
    }), transport);
    expect(controller.currentState()).toEqual({ sessionId: "second", status: "loading" });

    controller.receive(secondGeneration, JSON.stringify({
      type: "daemon_error",
      code: "invalid_response",
      message: "second response is invalid",
      responseType: "chat_page",
      requestType: "open_chat",
      sessionId: "second",
    }), transport);
    expect(controller.currentState()).toMatchObject({
      sessionId: "second",
      status: "failed",
      error: "second response is invalid",
    });
  });

  it("only resolves a slash error for the active command request", () => {
    let slashError: string | undefined;
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: (_commands, _sessionId, error) => { slashError = error; },
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");
    controller.requestSlashCommands(generation, "slash-1");

    controller.receive(generation, JSON.stringify({
      type: "daemon_error",
      code: "invalid_response",
      message: "stale slash response",
      responseType: "chat_commands",
      requestType: "get_chat_commands",
      requestId: "slash-old",
      sessionId: "session",
    }), transport);
    expect(slashError).toBeUndefined();

    controller.receive(generation, JSON.stringify({
      type: "daemon_error",
      code: "invalid_response",
      message: "Slash command discovery failed.",
      responseType: "chat_commands",
      requestType: "get_chat_commands",
      requestId: "slash-1",
      sessionId: "session",
    }), transport);
    expect(slashError).toBe("Slash command discovery failed.");
    expect(controller.currentState()).toEqual({ sessionId: "session", status: "loading" });
  });

  it("accepts an active slash error when responseType is absent", () => {
    let slashError: string | undefined;
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: (_commands, _sessionId, error) => { slashError = error; },
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");
    controller.requestSlashCommands(generation, "slash-1");

    controller.receive(generation, JSON.stringify({
      type: "daemon_error",
      code: "invalid_response",
      message: "Daemon produced an invalid protocol response.",
      requestType: "get_chat_commands",
      requestId: "slash-1",
      sessionId: "session",
    }), transport);

    expect(slashError).toBe("Daemon produced an invalid protocol response.");
  });

  it("rejects an explicitly mismatched daemon response type", () => {
    let slashError: string | undefined;
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: (_commands, _sessionId, error) => { slashError = error; },
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");
    controller.requestSlashCommands(generation, "slash-1");

    controller.receive(generation, JSON.stringify({
      type: "daemon_error",
      code: "invalid_response",
      message: "wrong response type",
      responseType: "chat_page",
      requestType: "get_chat_commands",
      requestId: "slash-1",
      sessionId: "session",
    }), transport);

    expect(slashError).toBeUndefined();
  });

  it("bounds expanded history, surfaces the safety cap, and keeps optimistic rows inside it", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, {
      createRequestId: () => "delivery-request",
      createDeliveryId: () => "delivery-id",
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session", "working");
    controller.requestLatest(generation, "latest-page");

    const makeItems = (prefix: string) => Array.from({ length: 1_000 }, (_, index) => ({
      id: `${prefix}-${index}`,
      kind: "assistant" as const,
      text: `${prefix}-${index}`,
    }));

    controller.receive(generation, JSON.stringify({
      ...page("session", "latest"),
      requestId: "latest-page",
      mode: "latest",
      items: makeItems("latest"),
      hasMoreBefore: true,
      nextBefore: 1,
    }), transport);

    // Each earlier page is protocol-valid at 1,000 items. The renderer grows
    // its own window by 100 at a time until the explicit 4,000-row cap.
    for (let pageIndex = 0; pageIndex < 39; pageIndex += 1) {
      const requestId = `earlier-${pageIndex}`;
      controller.requestEarlier(generation, requestId);
      controller.receive(generation, JSON.stringify({
        ...page("session", `earlier-${pageIndex}`),
        requestId,
        mode: "earlier",
        items: makeItems(`earlier-${pageIndex}`),
        hasMoreBefore: pageIndex < 38,
        ...(pageIndex < 38 ? { nextBefore: pageIndex + 2 } : {}),
      }), transport);
    }

    const capped = controller.currentState();
    expect(capped.page?.items).toHaveLength(4_000);
    expect(capped.clientHistoryLimitReached).toBe(true);

    const retainedIDs = capped.page?.items.map(({ id }) => id);
    controller.requestEarlier(generation, "blocked-earlier");
    controller.receive(generation, JSON.stringify({
      ...page("session", "must not load"),
      requestId: "blocked-earlier",
      mode: "earlier",
      items: makeItems("must-not-load"),
      hasMoreBefore: false,
    }), transport);
    expect(controller.currentState().page?.items.map(({ id }) => id)).toEqual(retainedIDs);

    const delivery = controller.beginDelivery(generation, { text: "optimistic", images: [] });
    expect(delivery).toBeDefined();
    expect(controller.currentState().page?.items).toHaveLength(4_000);
    expect(controller.currentState().page?.items.at(-1)?.id).toBe(delivery?.optimisticRowId);
    expect(controller.currentState().clientHistoryLimitReached).toBe(true);
  });

  it("retains an oversized complete latest page instead of dropping its local prefix", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");
    controller.requestLatest(generation, "latest-oversized");
    const items = Array.from({ length: 101 }, (_, index) => ({
      id: `item-${index}`,
      kind: "assistant" as const,
      text: `item-${index}`,
    }));

    controller.receive(generation, JSON.stringify({
      ...page("session", "oversized"),
      requestId: "latest-oversized",
      mode: "latest",
      items,
      hasMoreBefore: false,
    }), transport);

    expect(controller.currentState().page?.items).toEqual(items);
    expect(controller.currentState().clientHistoryLimitReached).toBeUndefined();
  });

  it("single-flights earlier pages by cursor, rolls back a reservation, and expands only unique rows", () => {
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    });
    const transport = { close: () => undefined, send: () => true };
    const generation = controller.activate("session");
    controller.requestLatest(generation, "latest");
    const currentItems = Array.from({ length: 100 }, (_, index) => ({
      id: `item-${index}`,
      kind: "assistant" as const,
      text: `item-${index}`,
    }));
    controller.receive(generation, JSON.stringify({
      ...page("session", "current"),
      requestId: "latest",
      mode: "latest",
      items: currentItems,
      hasMoreBefore: true,
      nextBefore: 100,
    }), transport);

    expect(controller.requestEarlier(generation, "earlier-1", 100)).toBe(true);
    expect(controller.requestEarlier(generation, "earlier-duplicate", 100)).toBe(false);
    expect(controller.cancelEarlier(generation, "earlier-1")).toBe(true);
    expect(controller.requestEarlier(generation, "earlier-1-retry", 100)).toBe(true);

    const earlierItems = [
      ...currentItems.slice(0, 99),
      { id: "earlier-unique", kind: "assistant" as const, text: "earlier-unique" },
    ];
    controller.receive(generation, JSON.stringify({
      ...page("session", "earlier"),
      requestId: "earlier-1-retry",
      mode: "earlier",
      items: earlierItems,
      hasMoreBefore: false,
    }), transport);
    expect(controller.currentState().page?.items).toHaveLength(101);

    controller.receive(generation, JSON.stringify({
      ...page("session", "replayed"),
      requestId: "earlier-1-retry",
      mode: "earlier",
      items: Array.from({ length: 100 }, (_, index) => ({
        id: `replayed-${index}`,
        kind: "assistant" as const,
        text: `replayed-${index}`,
      })),
      hasMoreBefore: false,
    }), transport);
    expect(controller.currentState().page?.items).toHaveLength(101);
  });
});
