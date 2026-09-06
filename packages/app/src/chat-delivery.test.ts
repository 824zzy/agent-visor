import { describe, expect, it } from "vitest";
import {
  CHAT_DELIVERY_TTL_MS,
  createPendingChatDeliveryStore,
  type CanonicalChatUserTurn,
  type DeliveryClock,
  type SubmittedChatDraft,
} from "./chat-delivery.js";

class TestClock implements DeliveryClock {
  constructor(private current = 1_700_000_000_000) {}

  now(): number { return this.current; }

  advance(milliseconds: number): void { this.current += milliseconds; }
}

const draft = (text = "Fix it"): SubmittedChatDraft => ({
  text,
  images: [{ name: "diagram.png", mimeType: "image/png", byteLength: 8, data: "iVBORw0KGgo=" }],
});

function canonical(
  id: string,
  text: string,
  identity: Partial<CanonicalChatUserTurn> = {},
  timestamp?: string,
): CanonicalChatUserTurn {
  return {
    item: { id, kind: "user", text, images: [], ...(timestamp ? { timestamp } : {}) },
    ...identity,
  };
}

const postSubmitTimestamp = (): string => new Date(Date.now() + 1_000).toISOString();

function activate(store: ReturnType<typeof createPendingChatDeliveryStore>, sessionId = "session", generation = 1): void {
  store.activate(sessionId, generation);
}

describe("pending chat delivery store", () => {
  it("creates an immediate optimistic row with an isolated submitted draft", () => {
    const clock = new TestClock();
    const store = createPendingChatDeliveryStore({ clock, createId: (() => {
      let index = 0;
      return () => `generated-${++index}`;
    })() });
    activate(store);
    const submitted = draft();
    const delivery = store.begin({
      sessionId: "session",
      generation: 1,
      requestId: "request-1",
      deliveryId: "delivery-1",
      draft: submitted,
    });

    expect(delivery).toMatchObject({
      requestId: "request-1",
      deliveryId: "delivery-1",
      sessionId: "session",
      generation: 1,
      optimisticRowId: "pending-delivery-1",
      status: "pending",
      optimisticRow: { id: "pending-delivery-1", kind: "user", text: "Fix it" },
    });
    submitted.text = "mutated after send";
    submitted.images[0]!.name = "mutated.png";
    expect(delivery?.draft).toEqual(draft());
  });

  it("retains provider settings with the delivery snapshot for retries", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    const submitted: SubmittedChatDraft = {
      text: "Use the selected profile",
      images: [],
      settings: {
        modelId: "gpt-6-astra",
        reasoningEffort: "max",
        permissionProfile: ":danger-full-access",
      },
    };
    const delivery = store.begin({
      sessionId: "session",
      generation: 1,
      requestId: "settings-request",
      deliveryId: "settings-delivery",
      draft: submitted,
    });
    expect(delivery?.draft.settings).toEqual(submitted.settings);
    submitted.settings!.modelId = "mutated-after-submit";
    expect(delivery?.draft.settings).toEqual({
      modelId: "gpt-6-astra",
      reasoningEffort: "max",
      permissionProfile: ":danger-full-access",
    });
  });

  it("reserves request and delivery IDs as one symmetric pair", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    const first = store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1",
      draft: draft("first"),
    });
    expect(store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-2",
      draft: draft("second"),
    })).toBeUndefined();
    expect(store.begin({
      sessionId: "session", generation: 1, requestId: "request-2", deliveryId: "delivery-1",
      draft: draft("second"),
    })).toBeUndefined();
    expect(store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1",
      draft: draft("changed"),
    })).toMatchObject({ requestId: first?.requestId, deliveryId: first?.deliveryId });
    expect(store.get("session", 1)).toHaveLength(1);
  });

  it("accounts for UTF-8/base64 snapshot bytes and preserves actionable failure state", () => {
    const store = createPendingChatDeliveryStore({ maxSnapshotBytesPerScope: 110 });
    activate(store);
    const first = store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", draft: {
        text: "é",
        images: [{ name: "first.png", mimeType: "image/png", byteLength: 8, data: "A".repeat(64) }],
      },
    })!;
    store.acknowledge({ sessionId: "session", generation: 1, requestId: first.requestId, ok: false });
    const second = store.begin({
      sessionId: "session", generation: 1, requestId: "request-2", draft: {
        text: "新",
        images: [{ name: "second.png", mimeType: "image/png", byteLength: 8, data: "B".repeat(64) }],
      },
    });

    expect(second).toBeUndefined();
    expect(store.get("session", 1)).toMatchObject([{ requestId: "request-1", status: "failed" }]);
  });

  it("rejects admission when every record at the cap is still actionable", () => {
    const store = createPendingChatDeliveryStore({ maxDeliveriesPerScope: 1 });
    activate(store);
    store.begin({ sessionId: "session", generation: 1, requestId: "request-1", draft: draft("first") });
    store.acknowledge({ sessionId: "session", generation: 1, requestId: "request-1", ok: false });
    expect(store.begin({ sessionId: "session", generation: 1, requestId: "request-2", draft: draft("second") }))
      .toBeUndefined();
    expect(store.get("session", 1)).toMatchObject([{ requestId: "request-1", status: "failed" }]);
  });

  it("reconciles a canonical turn before or after its acknowledgement exactly once", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", draft: draft("same"),
      allowContentFallback: true,
    });

    const beforeAck = store.reconcile({
      sessionId: "session",
      generation: 1,
      turns: [canonical("canonical-1", " same ", {}, postSubmitTimestamp())],
    });
    expect(beforeAck[0]).toMatchObject({ requestId: "request-1", status: "confirmed" });
    expect(store.acknowledge({
      sessionId: "session", generation: 1, requestId: "request-1", ok: true,
    })).toMatchObject({ status: "confirmed" });
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-1", "same", {}, postSubmitTimestamp())],
    })).toEqual([]);

    store.begin({
      sessionId: "session", generation: 1, requestId: "request-2", draft: draft("second"),
      allowContentFallback: true,
    });
    expect(store.acknowledge({
      sessionId: "session", generation: 1, requestId: "request-2", ok: true,
    })).toMatchObject({ status: "acknowledged" });
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-2", "second", {}, postSubmitTimestamp())],
    })).toMatchObject([{ requestId: "request-2", status: "confirmed" }]);
    expect(store.optimisticRows("session", 1)).toEqual([]);
  });

  it("does not let a duplicate page reload consume a later identical delivery", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", draft: draft("same"),
      allowContentFallback: true,
    });
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-1", "same", {}, postSubmitTimestamp())],
    })).toHaveLength(1);

    store.begin({
      sessionId: "session", generation: 1, requestId: "request-2", draft: draft("same"),
      allowContentFallback: true,
    });
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-1", "same", {}, postSubmitTimestamp())],
    })).toEqual([]);
    expect(store.get("session", 1)).toMatchObject([
      { requestId: "request-1", status: "confirmed" },
      { requestId: "request-2", status: "pending" },
    ]);
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [
        canonical("canonical-1", "same", {}, postSubmitTimestamp()),
        canonical("canonical-2", "same", {}, postSubmitTimestamp()),
      ],
    })).toMatchObject([{ requestId: "request-2", status: "confirmed" }]);
  });

  it("fails closed for one content-only row with two identical live deliveries", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", draft: draft("repeat"),
      allowContentFallback: true,
    });
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-2", draft: draft("repeat"),
      allowContentFallback: true,
    });

    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-1", "repeat", {}, postSubmitTimestamp())],
    })).toEqual([]);
    expect(store.get("session", 1)).toMatchObject([
      { requestId: "request-1", status: "pending" },
      { requestId: "request-2", status: "pending" },
    ]);
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [
        canonical("canonical-1", "repeat", {}, postSubmitTimestamp()),
        canonical("canonical-2", "repeat", {}, postSubmitTimestamp()),
      ],
    })).toEqual([]);
    expect(store.get("session", 1)).toMatchObject([
      { requestId: "request-1", status: "pending" },
      { requestId: "request-2", status: "pending" },
    ]);
  });

  it("trusts request/provider identity and does not fall back to content on an identified mismatch", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1", draft: draft("same"),
    });
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-1", "same", { requestId: "other-request" })],
    })).toEqual([]);
    expect(store.get("session", 1)[0]).toMatchObject({ status: "pending" });
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-1", "same", { requestId: "request-1" })],
    })).toMatchObject([{ status: "confirmed" }]);
  });

  it("uses request and delivery identity when native annotation arrives after the action ack", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-native", deliveryId: "delivery-native",
      draft: draft("native turn"),
    });
    expect(store.acknowledge({
      sessionId: "session", generation: 1,
      requestId: "request-native", deliveryId: "delivery-native", ok: true,
    })).toMatchObject({ status: "acknowledged" });

    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("native-row", "native turn", {
        requestId: "request-native",
        deliveryId: "delivery-native",
        providerMessageId: "native-user-1",
      })],
    })).toMatchObject([{
      requestId: "request-native",
      deliveryId: "delivery-native",
      providerMessageId: "native-user-1",
      status: "confirmed",
    }]);
  });

  it("rejects a known conflicting provider annotation and provider-only unknown rows", () => {
    const knownProvider = createPendingChatDeliveryStore();
    activate(knownProvider);
    knownProvider.begin({
      sessionId: "session", generation: 1, requestId: "request-known", deliveryId: "delivery-known",
      draft: draft("same"),
    });
    expect(knownProvider.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("known-provider", "same", {
        requestId: "request-known",
        deliveryId: "delivery-known",
        providerMessageId: "native-user-1",
      })],
    })).toMatchObject([{ status: "confirmed", providerMessageId: "native-user-1" }]);
    expect(knownProvider.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("wrong-provider", "same", {
        requestId: "request-known",
        deliveryId: "delivery-known",
        providerMessageId: "native-user-2",
      })],
    })).toEqual([]);
    expect(knownProvider.get("session", 1)).toMatchObject([{
      status: "confirmed", providerMessageId: "native-user-1",
    }]);

    const unknownProvider = createPendingChatDeliveryStore();
    activate(unknownProvider);
    unknownProvider.begin({
      sessionId: "session", generation: 1, requestId: "request-unknown", deliveryId: "delivery-unknown",
      draft: draft("provider only"),
    });
    expect(unknownProvider.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("provider-only", "provider only", {
        providerMessageId: "native-user-3",
      })],
    })).toEqual([]);
    expect(unknownProvider.get("session", 1)).toMatchObject([{ status: "pending" }]);
  });

  it("keeps original and retry lineage ambiguous for content-only canonical rows", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "original-request", deliveryId: "original-delivery",
      draft: draft("same"),
    });
    store.acknowledge({
      sessionId: "session", generation: 1, requestId: "original-request", deliveryId: "original-delivery", ok: false,
    });
    expect(store.begin({
      sessionId: "session", generation: 1, requestId: "retry-request", deliveryId: "retry-delivery",
      draft: draft("same"), replace: { requestId: "original-request", deliveryId: "original-delivery" },
    })).toBeTruthy();
    expect(store.reconcile({
      sessionId: "session", generation: 1, turns: [canonical("ambiguous", "same")],
    })).toEqual([]);
    expect(store.get("session", 1)).toMatchObject([{ requestId: "retry-request", status: "pending" }]);
  });

  it("fails closed when one identity-less canonical row matches multiple current deliveries", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "failed-request", deliveryId: "failed-delivery",
      draft: draft("same"), allowContentFallback: true,
    });
    store.acknowledge({
      sessionId: "session", generation: 1,
      requestId: "failed-request", deliveryId: "failed-delivery", ok: false,
    });
    store.begin({
      sessionId: "session", generation: 1, requestId: "pending-request", deliveryId: "pending-delivery",
      draft: draft("same"), allowContentFallback: true,
    });

    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("ambiguous-current", "same", {}, postSubmitTimestamp())],
    })).toEqual([]);
    expect(store.get("session", 1)).toMatchObject([
      { requestId: "failed-request", status: "failed" },
      { requestId: "pending-request", status: "pending" },
    ]);
  });

  it("lets exact provider identity win even when another current delivery has identical content", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "first-request", deliveryId: "first-delivery",
      draft: draft("same"), allowContentFallback: true,
    });
    store.begin({
      sessionId: "session", generation: 1, requestId: "second-request", deliveryId: "second-delivery",
      draft: draft("same"), allowContentFallback: true,
    });

    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("identified-second", "same", {
        requestId: "second-request", deliveryId: "second-delivery",
      })],
    })).toMatchObject([{ requestId: "second-request", status: "confirmed" }]);
    expect(store.get("session", 1)).toMatchObject([
      { requestId: "first-request", status: "pending" },
      { requestId: "second-request", status: "confirmed" },
    ]);
  });

  it("settles an admitted retry only by its exact provider identity", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "original-request", deliveryId: "original-delivery",
      draft: draft("same"),
    });
    store.acknowledge({
      sessionId: "session", generation: 1, requestId: "original-request", deliveryId: "original-delivery", ok: false,
    });
    // Use a larger record bound so the original source can remain in lineage.
    const retry = createPendingChatDeliveryStore({ maxDeliveriesPerScope: 3 });
    activate(retry);
    retry.begin({
      sessionId: "session", generation: 1, requestId: "original-request", deliveryId: "original-delivery",
      draft: draft("same"),
    });
    retry.acknowledge({
      sessionId: "session", generation: 1, requestId: "original-request", deliveryId: "original-delivery", ok: false,
    });
    expect(retry.begin({
      sessionId: "session", generation: 1, requestId: "retry-request", deliveryId: "retry-delivery",
      draft: draft("same"), replace: { requestId: "original-request", deliveryId: "original-delivery" },
    })).toBeTruthy();
    expect(retry.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("ambiguous", "same")],
    })).toEqual([]);
    expect(retry.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("late-original", "same", { requestId: "original-request", deliveryId: "original-delivery" })],
    })).toMatchObject([{ requestId: "original-request", status: "confirmed" }]);
    expect(retry.get("session", 1)).toMatchObject([{ requestId: "retry-request", status: "pending" }]);
    expect(retry.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("late-retry", "same", { requestId: "retry-request", deliveryId: "retry-delivery" })],
    })).toMatchObject([{ requestId: "retry-request", status: "confirmed" }]);
  });

  it("ignores stale acknowledgements and pages after a session generation switch", () => {
    const store = createPendingChatDeliveryStore();
    activate(store, "first", 1);
    store.begin({ sessionId: "first", generation: 1, requestId: "old-request", draft: draft("old") });
    activate(store, "second", 2);
    store.begin({ sessionId: "second", generation: 2, requestId: "new-request", draft: draft("new") });

    expect(store.acknowledge({
      sessionId: "first", generation: 1, requestId: "old-request", ok: true,
    })).toBeUndefined();
    expect(store.reconcile({
      sessionId: "first", generation: 1,
      turns: [canonical("old-canonical", "old")],
    })).toEqual([]);
    expect(store.get("first", 1)[0]).toMatchObject({ status: "pending" });
    expect(store.get("second", 2)[0]).toMatchObject({ status: "pending" });
  });

  it("marks an unacknowledged delivery failed at the fake-clock TTL", () => {
    const clock = new TestClock();
    const store = createPendingChatDeliveryStore({ clock });
    activate(store);
    store.begin({ sessionId: "session", generation: 1, requestId: "request-1", draft: draft() });
    clock.advance(CHAT_DELIVERY_TTL_MS);
    expect(store.expire({ sessionId: "session", generation: 1 })).toMatchObject([{
      requestId: "request-1",
      status: "failed",
      error: "The provider did not confirm this message before the delivery window expired.",
    }]);
    expect(store.optimisticRows("session", 1)).toHaveLength(1);
  });

  it("expires only the explicitly requested session and generation scope", () => {
    const clock = new TestClock();
    const store = createPendingChatDeliveryStore({ clock });
    activate(store, "first", 1);
    store.begin({ sessionId: "first", generation: 1, requestId: "first-request", draft: draft("first") });
    activate(store, "second", 2);
    store.begin({ sessionId: "second", generation: 2, requestId: "second-request", draft: draft("second") });
    clock.advance(CHAT_DELIVERY_TTL_MS);

    expect(store.expire({ sessionId: "second", generation: 2 })).toMatchObject([
      { requestId: "second-request", sessionId: "second", generation: 2, status: "failed" },
    ]);
    expect(store.get("first", 1)[0]).toMatchObject({ requestId: "first-request", status: "pending" });
    expect(store.get("second", 2)[0]).toMatchObject({ requestId: "second-request", status: "failed" });
  });

  it("reclaims the oldest inactive scope at the explicit scope bound", () => {
    const store = createPendingChatDeliveryStore({ maxScopes: 2 });
    activate(store, "first", 1);
    store.begin({ sessionId: "first", generation: 1, requestId: "first-request", draft: draft("first") });
    activate(store, "second", 2);
    store.begin({ sessionId: "second", generation: 2, requestId: "second-request", draft: draft("second") });
    activate(store, "third", 3);

    expect(store.get("first", 1)).toMatchObject([{ requestId: "first-request", status: "pending" }]);
    expect(store.get("second", 2)).toMatchObject([{ requestId: "second-request", status: "pending" }]);
    expect(store.begin({
      sessionId: "third", generation: 3, requestId: "third-request", draft: draft("third"),
    })).toBeUndefined();
  });

  it("cancels a pending delivery and ignores late acknowledgement or canonical replay", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1", draft: draft(),
    });
    expect(store.cancel({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1",
    })).toMatchObject({ status: "canceled" });
    expect(store.acknowledge({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1", ok: true,
    })).toBeUndefined();
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-1", "Fix it")],
    })).toEqual([]);
    expect(store.get("session", 1)[0]).toMatchObject({ status: "canceled" });
    expect(store.optimisticRows("session", 1)).toEqual([]);
  });

  it("keeps a failed acknowledgement visible and makes duplicate acknowledgements idempotent", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({ sessionId: "session", generation: 1, requestId: "request-1", draft: draft() });
    const failed = store.acknowledge({
      sessionId: "session", generation: 1, requestId: "request-1", ok: false, error: "Transport failed.",
    });
    expect(failed).toMatchObject({ status: "failed", error: "Transport failed." });
    expect(store.acknowledge({
      sessionId: "session", generation: 1, requestId: "request-1", ok: true,
    })).toBeUndefined();
    expect(store.optimisticRows("session", 1)).toMatchObject([{ id: "pending-request-1" }]);
  });

  it("dismisses only a failed delivery row", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({ sessionId: "session", generation: 1, requestId: "request-1", draft: draft("first") });
    store.begin({ sessionId: "session", generation: 1, requestId: "request-2", draft: draft("second") });
    store.acknowledge({ sessionId: "session", generation: 1, requestId: "request-1", ok: false });

    expect(store.dismiss({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "request-1",
    })).toMatchObject({ requestId: "request-1", status: "failed" });
    expect(store.optimisticRows("session", 1)).toMatchObject([{ text: "second" }]);
  });

  it("requires every supplied identity field to refer to the same delivery", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1",
      draft: draft("first"),
    });
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-2", deliveryId: "delivery-2",
      draft: draft("second"),
    });

    expect(store.acknowledge({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-2", ok: true,
    })).toBeUndefined();
    expect(store.cancel({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-2",
    })).toBeUndefined();
    expect(store.dismiss({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-2",
    })).toBeUndefined();
    expect(store.get("session", 1)).toMatchObject([
      { requestId: "request-1", deliveryId: "delivery-1", status: "pending" },
      { requestId: "request-2", deliveryId: "delivery-2", status: "pending" },
    ]);
  });

  it("keeps an acknowledged synthetic row cancelable until canonical delivery arrives", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1",
      draft: draft("first"),
    });
    expect(store.acknowledge({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1", ok: true,
    })).toMatchObject({ status: "acknowledged" });
    expect(store.optimisticRows("session", 1)).toHaveLength(1);
    expect(store.cancel({
      sessionId: "session", generation: 1, requestId: "request-1", deliveryId: "delivery-1",
    })).toMatchObject({ status: "canceled" });
    expect(store.optimisticRows("session", 1)).toEqual([]);

    store.begin({
      sessionId: "session", generation: 1, requestId: "request-2", deliveryId: "delivery-2",
      draft: draft("second"),
    });
    store.acknowledge({
      sessionId: "session", generation: 1, requestId: "request-2", deliveryId: "delivery-2", ok: true,
    });
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-2", "second", { requestId: "request-2", deliveryId: "delivery-2" })],
    })).toMatchObject([{ requestId: "request-2", status: "confirmed" }]);
    expect(store.cancel({
      sessionId: "session", generation: 1, requestId: "request-2", deliveryId: "delivery-2",
    })).toBeUndefined();
    expect(store.optimisticRows("session", 1)).toEqual([]);
  });

  it("keeps an acknowledged delivery explicit until canonical proof, then expires it as uncertain", () => {
    const clock = new TestClock();
    const store = createPendingChatDeliveryStore({ clock });
    activate(store);
    const delivery = store.begin({
      sessionId: "session", generation: 1, requestId: "request-ack", deliveryId: "delivery-ack",
      draft: draft("acknowledged"),
    })!;

    expect(store.acknowledge({
      sessionId: "session", generation: 1,
      requestId: delivery.requestId, deliveryId: delivery.deliveryId, ok: true,
    })).toMatchObject({ status: "acknowledged" });
    expect(store.cancel({
      sessionId: "session", generation: 1,
      requestId: delivery.requestId, deliveryId: delivery.deliveryId,
    })).toMatchObject({ status: "canceled" });
    // Recreate the acknowledged state: a canonical deadline is distinct from
    // an action acknowledgement, but the exact provider route remains
    // cancellable while the turn is still active.
    const second = store.begin({
      sessionId: "session", generation: 1, requestId: "request-ack-2", deliveryId: "delivery-ack-2",
      draft: draft("no transcript"),
    })!;
    store.acknowledge({
      sessionId: "session", generation: 1,
      requestId: second.requestId, deliveryId: second.deliveryId, ok: true,
    });
    clock.advance(CHAT_DELIVERY_TTL_MS);

    expect(store.expire({ sessionId: "session", generation: 1 })).toMatchObject([{
      requestId: second.requestId,
      status: "uncertain",
      error: "The provider acknowledged this message but did not publish it in the transcript before the delivery window expired.",
    }]);
    expect(store.cancel({
      sessionId: "session", generation: 1,
      requestId: second.requestId, deliveryId: second.deliveryId,
    })).toMatchObject({ status: "canceled" });
    expect(store.optimisticRows("session", 1)).toEqual([]);
  });

  it("settles a canceled delivery when its exact canonical row arrives later", () => {
    const store = createPendingChatDeliveryStore();
    activate(store);
    store.begin({
      sessionId: "session", generation: 1,
      requestId: "request-canceled", deliveryId: "delivery-canceled",
      draft: draft("stopped"),
    });
    store.acknowledge({
      sessionId: "session", generation: 1,
      requestId: "request-canceled", deliveryId: "delivery-canceled", ok: true,
    });
    expect(store.cancel({
      sessionId: "session", generation: 1,
      requestId: "request-canceled", deliveryId: "delivery-canceled",
    })).toMatchObject({ status: "canceled" });

    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("canonical-stopped", "stopped", {
        requestId: "request-canceled",
        deliveryId: "delivery-canceled",
      })],
    })).toMatchObject([{
      requestId: "request-canceled",
      deliveryId: "delivery-canceled",
      status: "canceled",
    }]);
    expect(store.optimisticRows("session", 1)).toEqual([]);
  });

  it("requires a post-submit timestamp and an authoritative baseline for content fallback", () => {
    const clock = new TestClock(1_700_000_000_000);
    const store = createPendingChatDeliveryStore({ clock });
    activate(store);
    store.begin({
      sessionId: "session", generation: 1, requestId: "request-time", deliveryId: "delivery-time",
      draft: draft("same"), allowContentFallback: true,
    });

    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("old", "same", { })],
    })).toEqual([]);
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("before-submit", "same", {
        item: { id: "before-submit", kind: "user", text: "same", images: [], timestamp: new Date(1_699_999_999_999).toISOString() },
      })],
    })).toEqual([]);
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("after-submit", "same", {
        item: { id: "after-submit", kind: "user", text: "same", images: [], timestamp: new Date(1_700_000_000_001).toISOString() },
      })],
    })).toMatchObject([{ requestId: "request-time", status: "confirmed" }]);

    store.begin({
      sessionId: "session", generation: 1, requestId: "request-no-fallback", deliveryId: "delivery-no-fallback",
      draft: draft("same"), allowContentFallback: false,
    });
    expect(store.reconcile({
      sessionId: "session", generation: 1,
      turns: [canonical("disabled", "same", {
        item: { id: "disabled", kind: "user", text: "same", images: [], timestamp: new Date(1_700_000_000_002).toISOString() },
      })],
    })).toEqual([]);
  });
});
