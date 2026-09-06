import { describe, expect, it } from "vitest";
import type { ChatPage } from "@agent-visor/protocol";
import {
  CHAT_DELIVERY_TTL_MS,
  type DeliveryClock,
} from "./chat-delivery.js";
import { createChatSessionController } from "./chat-session-controller.js";

class TestClock implements DeliveryClock {
  constructor(private current = 1_700_000_000_000) {}

  now(): number { return this.current; }

  advance(milliseconds: number): void { this.current += milliseconds; }
}

const page = (sessionId: string, items: ChatPage["items"] = []): ChatPage => ({
  type: "chat_page",
  sessionId,
  items,
  hasMoreBefore: false,
  sessionState: {
    conversation: "open",
    turn: "ready",
    route: "available",
  },
  capabilities: {
    canSendText: true,
    canSendImages: true,
    canCancel: false,
    canApprove: false,
    canAnswer: false,
  },
  pendingAction: null,
});

const connection = {
  close: () => undefined,
  send: () => true,
};

function controllerWith(
  clock = new TestClock(),
  onOpenLatest: (requestId: string) => void = () => undefined,
) {
  return createChatSessionController({
    onState: () => undefined,
    onSlashCommands: () => undefined,
    onOpenLatest: (_connection, _sessionId, requestId) => onOpenLatest(requestId),
  }, {
    deliveryClock: clock,
    createRequestId: (() => {
      let index = 0;
      return () => `request-${++index}`;
    })(),
    createDeliveryId: (() => {
      let index = 0;
      return () => `delivery-${++index}`;
    })(),
  });
}

function canonical(
  id: string,
  text: string,
  identity: Record<string, string> = {},
  timestamp?: string,
): ChatPage["items"][number] {
  return { id, kind: "user", text, images: [], ...identity, ...(timestamp ? { timestamp } : {}) };
}

function sendAck(
  requestId: string,
  deliveryId: string,
  generation: number,
  ok = true,
): string {
  return JSON.stringify({
    type: "chat_action_result",
    id: requestId,
    action: "send",
    sessionId: "session",
    generation,
    deliveryId,
    ok,
    ...(ok ? {} : { error: "Provider rejected the message." }),
  });
}

describe("Chat session delivery integration", () => {
  it("inserts an optimistic row immediately and keeps it through ack-before-page ordering", () => {
    let latestRequestId: string | undefined;
    const controller = controllerWith(new TestClock(), (requestId) => { latestRequestId = requestId; });
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify(page("session")), connection);
    const delivery = controller.beginDelivery(generation, { text: "hello", images: [] });

    expect(delivery).toMatchObject({
      requestId: "request-1",
      deliveryId: "delivery-1",
      sessionId: "session",
      generation,
    });
    expect(controller.currentState().page?.items).toMatchObject([
      { id: "pending-delivery-1", kind: "user", text: "hello", deliveryId: "delivery-1" },
    ]);

    controller.receive(generation, sendAck("request-1", "delivery-1", generation), connection);
    expect(controller.currentState().page?.items).toMatchObject([
      { id: "pending-delivery-1", kind: "user", text: "hello" },
    ]);

    controller.receive(generation, JSON.stringify({
      ...page("session", [
        canonical("canonical-1", "hello", { requestId: "request-1", deliveryId: "delivery-1" }),
      ]),
      requestId: latestRequestId,
      mode: "latest",
    }), connection);
    expect(controller.currentState().page?.items).toEqual([
      canonical("canonical-1", "hello", { requestId: "request-1", deliveryId: "delivery-1" }),
    ]);
  });

  it("reconciles page-before-ack and does not duplicate a canonical row", () => {
    const controller = controllerWith();
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify(page("session")), connection);
    const delivery = controller.beginDelivery(generation, { text: "hello", images: [] })!;
    const item = canonical("canonical-1", "hello", {
      requestId: delivery.requestId,
      deliveryId: delivery.deliveryId,
    });

    controller.receive(generation, JSON.stringify(page("session", [item])), connection);
    expect(controller.currentState().page?.items).toEqual([item]);
    controller.receive(generation, sendAck(delivery.requestId, delivery.deliveryId, generation), connection);
    expect(controller.currentState().page?.items).toEqual([item]);
    controller.receive(generation, JSON.stringify(page("session", [item])), connection);
    expect(controller.currentState().page?.items).toEqual([item]);
  });

  it("reconciles a post-submit latest row before seeding IDs after reattach", () => {
    const controller = controllerWith();
    const firstGeneration = controller.activate("session");
    const oldTimestamp = new Date(Date.now() - 10_000).toISOString();
    controller.receive(firstGeneration, JSON.stringify(page("session", [
      canonical("old", "same", {}, oldTimestamp),
    ])), connection);
    const delivery = controller.beginDelivery(firstGeneration, { text: "same", images: [] })!;

    controller.deactivate(firstGeneration);
    const reattachedGeneration = controller.activate("session");
    const newTimestamp = new Date(Date.now() + 1_000).toISOString();
    const oldRow = canonical("old", "same", {}, oldTimestamp);
    const newRow = canonical("new", "same", {}, newTimestamp);
    controller.receive(reattachedGeneration, JSON.stringify(page("session", [oldRow, newRow])), connection);

    expect(controller.currentState().page?.items).toEqual([oldRow, newRow]);
    expect(controller.currentState().page?.items).not.toContainEqual(
      expect.objectContaining({ id: delivery.optimisticRowId }),
    );
  });

  it("reconciles an exact identity on the first latest page even without a source timestamp", () => {
    const controller = controllerWith();
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify(page("session")), connection);
    const delivery = controller.beginDelivery(generation, { text: "image commit", images: [] })!;
    const row = canonical("exact-first", "image commit", {
      requestId: delivery.requestId,
      deliveryId: delivery.deliveryId,
    });

    controller.receive(generation, JSON.stringify(page("session", [row])), connection);

    expect(controller.currentState().page?.items).toEqual([row]);
  });

  it("keeps two identical submissions one-to-one across a duplicate page reload", () => {
    const controller = controllerWith();
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify(page("session")), connection);
    const first = controller.beginDelivery(generation, { text: "repeat", images: [] })!;
    const second = controller.beginDelivery(generation, { text: "repeat", images: [] })!;
    const firstItem = canonical("canonical-1", "repeat", {
      requestId: first.requestId,
      deliveryId: first.deliveryId,
    });
    const secondItem = canonical("canonical-2", "repeat", {
      requestId: second.requestId,
      deliveryId: second.deliveryId,
    });

    controller.receive(generation, JSON.stringify(page("session", [firstItem])), connection);
    expect(controller.currentState().page?.items).toEqual([
      firstItem,
      { id: "pending-delivery-2", kind: "user", text: "repeat", images: [], requestId: "request-2", deliveryId: "delivery-2", timestamp: expect.any(String) },
    ]);
    controller.receive(generation, JSON.stringify(page("session", [firstItem])), connection);
    expect(controller.currentState().page?.items).toEqual([
      firstItem,
      { id: "pending-delivery-2", kind: "user", text: "repeat", images: [], requestId: "request-2", deliveryId: "delivery-2", timestamp: expect.any(String) },
    ]);
    controller.receive(generation, JSON.stringify(page("session", [firstItem, secondItem])), connection);
    expect(controller.currentState().page?.items).toEqual([firstItem, secondItem]);
  });

  it("ignores mismatched and stale send results or pages", () => {
    const controller = controllerWith();
    const firstGeneration = controller.activate("session");
    controller.receive(firstGeneration, JSON.stringify(page("session")), connection);
    const old = controller.beginDelivery(firstGeneration, { text: "old", images: [] })!;
    const secondGeneration = controller.activate("other");
    controller.receive(secondGeneration, JSON.stringify(page("other")), connection);

    controller.receive(firstGeneration, sendAck(old.requestId, old.deliveryId, firstGeneration), connection);
    controller.receive(firstGeneration, JSON.stringify(page("session", [canonical("old", "old")])), connection);
    expect(controller.currentState().sessionId).toBe("other");
    expect(controller.currentState().page?.items).toEqual([]);
  });

  it("turns an unacknowledged delivery into a visible failed row at the fake-clock TTL", () => {
    const clock = new TestClock();
    const controller = controllerWith(clock);
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify(page("session")), connection);
    controller.beginDelivery(generation, { text: "timeout", images: [] });
    clock.advance(CHAT_DELIVERY_TTL_MS);

    expect(controller.expireDeliveries(generation)).toMatchObject([{
      status: "failed",
      error: "The provider did not confirm this message before the delivery window expired.",
    }]);
    expect(controller.currentState().page?.items).toMatchObject([
      { id: "pending-delivery-1", kind: "user", text: "timeout" },
    ]);
  });

  it("keeps the exact Stop route after an acknowledged delivery becomes uncertain", () => {
    const clock = new TestClock();
    const sent: string[] = [];
    let latestRequestId: string | undefined;
    const controller = controllerWith(clock, (requestId) => { latestRequestId = requestId; });
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify({
      ...page("session"),
      hasMoreBefore: true,
      nextBefore: 10,
    }), connection);
    const delivery = controller.beginDelivery(generation, { text: "long turn", images: [] })!;
    controller.receive(generation, sendAck(delivery.requestId, delivery.deliveryId, generation), connection);

    const workingPage: ChatPage = {
      ...page("session"),
      sessionState: {
        conversation: "open",
        turn: "working",
        route: "available",
      },
      capabilities: {
        ...page("session").capabilities,
        canSendText: false,
        canCancel: true,
        cancelDeliveryId: delivery.deliveryId,
      },
    };
    expect(latestRequestId).toBeDefined();
    controller.receive(generation, JSON.stringify({
      ...workingPage,
      requestId: latestRequestId,
      mode: "latest",
    }), connection);
    clock.advance(CHAT_DELIVERY_TTL_MS);

    expect(controller.expireDeliveries(generation)).toMatchObject([{
      requestId: delivery.requestId,
      status: "uncertain",
    }]);
    expect(controller.currentState().canCancelForActiveDelivery).toBe(true);

    const cancelConnection = {
      close: () => undefined,
      send: (data: string) => {
        sent.push(data);
        return true;
      },
    };
    expect(controller.requestCancel(generation, cancelConnection)).toBe(true);
    expect(JSON.parse(sent.at(-1)!)).toMatchObject({
      type: "cancel_chat",
      deliveryId: delivery.deliveryId,
    });
  });

  it("reconciles an exact canonical row after the delivery deadline and clears the false warning", () => {
    const clock = new TestClock();
    let latestRequestId: string | undefined;
    const controller = controllerWith(clock, (requestId) => { latestRequestId = requestId; });
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify({
      ...page("session"),
      hasMoreBefore: true,
      nextBefore: 10,
    }), connection);
    const delivery = controller.beginDelivery(generation, { text: "late transcript", images: [] })!;
    controller.receive(generation, sendAck(delivery.requestId, delivery.deliveryId, generation), connection);
    expect(latestRequestId).toBeDefined();
    controller.receive(generation, JSON.stringify({
      ...page("session"),
      sessionState: {
        conversation: "open",
        turn: "working",
        route: "available",
      },
      capabilities: {
        ...page("session").capabilities,
        canSendText: false,
        canCancel: true,
        cancelDeliveryId: delivery.deliveryId,
      },
      requestId: latestRequestId,
      mode: "latest",
    }), connection);
    clock.advance(CHAT_DELIVERY_TTL_MS);
    controller.expireDeliveries(generation);
    expect(controller.currentState().error).toBe(
      "The provider acknowledged this message but did not publish it in the transcript before the delivery window expired.",
    );

    expect(controller.refresh(generation, connection)).toBe(true);
    expect(latestRequestId).toBeDefined();
    const canonicalRow = canonical("late-canonical", "late transcript", {
      requestId: delivery.requestId,
      deliveryId: delivery.deliveryId,
    });
    controller.receive(generation, JSON.stringify({
      ...page("session", [canonicalRow]),
      sessionState: {
        conversation: "open",
        turn: "working",
        route: "available",
      },
      capabilities: {
        ...page("session").capabilities,
        canSendText: false,
        canCancel: true,
        cancelDeliveryId: delivery.deliveryId,
      },
      requestId: latestRequestId,
      mode: "latest",
    }), connection);

    expect(controller.currentState().page?.items).toEqual([canonicalRow]);
    expect(controller.currentState().recovery).toBeUndefined();
    expect(controller.currentState().error).toBeUndefined();
    expect(controller.currentState().canCancelForActiveDelivery).toBe(true);
  });

  it("keeps another delivery's timeout warning when a late row reconciles", () => {
    const clock = new TestClock();
    let latestRequestId: string | undefined;
    const controller = controllerWith(clock, (requestId) => { latestRequestId = requestId; });
    const generation = controller.activate("session");
    controller.receive(generation, JSON.stringify({
      ...page("session"),
      hasMoreBefore: true,
      nextBefore: 10,
    }), connection);
    const unacknowledged = controller.beginDelivery(generation, { text: "unacknowledged", images: [] })!;
    const acknowledged = controller.beginDelivery(generation, { text: "acknowledged", images: [] })!;
    controller.receive(
      generation,
      sendAck(acknowledged.requestId, acknowledged.deliveryId, generation),
      connection,
    );
    expect(latestRequestId).toBeDefined();
    controller.receive(generation, JSON.stringify({
      ...page("session"),
      sessionState: {
        conversation: "open",
        turn: "working",
        route: "available",
      },
      capabilities: {
        ...page("session").capabilities,
        canSendText: false,
        canCancel: true,
        cancelDeliveryId: acknowledged.deliveryId,
      },
      requestId: latestRequestId,
      mode: "latest",
    }), connection);

    clock.advance(CHAT_DELIVERY_TTL_MS);
    expect(controller.expireDeliveries(generation)).toMatchObject([
      { requestId: unacknowledged.requestId, status: "failed" },
      { requestId: acknowledged.requestId, status: "uncertain" },
    ]);
    expect(controller.currentState().error).toBe(
      "The provider did not confirm this message before the delivery window expired.",
    );

    expect(controller.refresh(generation, connection)).toBe(true);
    const lateRow = canonical("late-acknowledged", "acknowledged", {
      requestId: acknowledged.requestId,
      deliveryId: acknowledged.deliveryId,
    });
    controller.receive(generation, JSON.stringify({
      ...page("session", [lateRow]),
      sessionState: {
        conversation: "open",
        turn: "working",
        route: "available",
      },
      capabilities: {
        ...page("session").capabilities,
        canSendText: false,
        canCancel: true,
        cancelDeliveryId: acknowledged.deliveryId,
      },
      requestId: latestRequestId,
      mode: "latest",
    }), connection);

    expect(controller.currentState().error).toBe(
      "The provider did not confirm this message before the delivery window expired.",
    );
    expect(controller.currentState().recovery).toMatchObject([{
      requestId: unacknowledged.requestId,
      status: "failed",
    }]);
  });
});
